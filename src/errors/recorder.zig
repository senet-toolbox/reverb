const std = @import("std");
const pg = @import("pg");
const Reverb = @import("reverb");
const Main = @import("../main.zig");
const Context = Reverb.Context;

// ============================================================================
// Types
// ============================================================================

pub const StackFrameType = enum {
    wasm,
    js,
    unknown,
};

pub const StackFrame = struct {
    function: ?[]const u8 = null,
    wasm_function_index: ?u32 = null,
    wasm_offset: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
    frame_type: StackFrameType = .unknown,
    raw: ?[]const u8 = null,
};

pub const WasmError = struct {
    type: []const u8,
    message: []const u8,
    is_wasm_trap: bool,
    crash_site: ?StackFrame = null,
    user_stack: []const StackFrame,

    pub fn deinit(self: *WasmError, allocator: std.mem.Allocator) void {
        allocator.free(self.user_stack);
    }
};

const EventRecord = struct {
    timestamp: i64,
    event_type: enum { click, dblclick, hover, mousemove, input, scroll, state_change },
    element_id: ?[]const u8,
    serialized_args: []const u8,
};

const RecordError = struct {
    element_id: ?[]const u8 = null,
    args: ?[]const u8 = null,
    wasmError: WasmError,
    events: []const EventRecord,
    timestamp: i64,
};

// ============================================================================
// Fingerprinting
// ============================================================================

/// Compute a stable fingerprint for error grouping.
///
/// The fingerprint is a SHA-256 hex digest of:
///   error_type :: crash_function :: crash_file :: crash_line :: message
///
/// This groups errors that crash at the same location with the same type,
/// even if the message varies slightly (e.g. different pointer values).
/// The message is included as a tiebreaker for cases where crash site is
/// null (e.g. pure JS errors with no WASM frame info).
fn computeFingerprint(record: RecordError) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    hasher.update(record.wasmError.type);
    hasher.update("::");

    if (record.wasmError.crash_site) |cs| {
        hasher.update(cs.function orelse "");
        hasher.update("::");
        hasher.update(cs.file orelse "");
        hasher.update("::");
        if (cs.line) |line| {
            var buf: [16]u8 = undefined;
            const line_str = std.fmt.bufPrint(&buf, "{d}", .{line}) catch "";
            hasher.update(line_str);
        }
    } else {
        // No crash site — use empty fields so the format stays consistent
        hasher.update("::");
        hasher.update("::");
    }

    hasher.update("::");
    hasher.update(record.wasmError.message);

    const digest = hasher.finalResult();

    // Convert to hex string
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        const chars = "0123456789abcdef";
        hex[i * 2] = chars[byte >> 4];
        hex[i * 2 + 1] = chars[byte & 0x0f];
    }
    return hex;
}

// ============================================================================
// HTTP Handler
// ============================================================================

pub fn recordError(ctx: *Context) !void {
    var record: RecordError = undefined;
    ctx.bind(RecordError, &record) catch |err| {
        std.log.err("Failed to bind error record: {any}", .{err});
        return err;
    };

    try insertErrorReport(Main.crud.pool, record);
    try ctx.STRING("Recorded Error");
}

// ============================================================================
// Database Insertion (with grouping)
// ============================================================================

pub fn insertErrorReport(pool: *pg.Pool, record: RecordError) !void {
    const crash = record.wasmError.crash_site;

    // Extract crash site fields (same as before)
    const crash_function: ?[]const u8 = if (crash) |cs| cs.function else null;
    const crash_file: ?[]const u8 = if (crash) |cs| cs.file else null;
    const crash_line: ?i32 = if (crash) |cs| if (cs.line) |l| @as(i32, @intCast(l)) else null else null;
    const crash_column: ?i32 = if (crash) |cs| if (cs.column) |c| @as(i32, @intCast(c)) else null else null;
    const crash_wasm_index: ?i32 = if (crash) |cs| if (cs.wasm_function_index) |w| @as(i32, @intCast(w)) else null else null;
    const crash_wasm_offset: ?[]const u8 = if (crash) |cs| cs.wasm_offset else null;
    const crash_frame_type: ?[]const u8 = if (crash) |cs| @as([]const u8, @tagName(cs.frame_type)) else null;

    // ── Step 1: Compute fingerprint and upsert error_group ──────────
    const fingerprint = computeFingerprint(record);
    const fingerprint_slice: []const u8 = &fingerprint;

    var group_result = pool.query(
        \\INSERT INTO error_groups (
        \\  fingerprint, error_type, message,
        \\  crash_function, crash_file, crash_line, is_wasm_trap,
        \\  occurrence_count, first_seen, last_seen, status
        \\) VALUES (
        \\  $1, $2, $3,
        \\  $4, $5, $6, $7,
        \\  1, $8, $9,
        \\  CASE
        \\    WHEN EXISTS (
        \\      SELECT 1 FROM error_groups
        \\      WHERE fingerprint = $1 AND status = 'resolved'
        \\    ) THEN 'regressed'
        \\    ELSE 'unresolved'
        \\  END
        \\)
        \\ON CONFLICT (fingerprint) DO UPDATE SET
        \\  occurrence_count = error_groups.occurrence_count + 1,
        \\  last_seen = GREATEST(error_groups.last_seen, $9),
        \\  status = CASE
        \\    WHEN error_groups.status = 'resolved' THEN 'regressed'
        \\    WHEN error_groups.status = 'ignored'  THEN 'ignored'
        \\    ELSE error_groups.status
        \\  END
        \\RETURNING id
    , .{
        fingerprint_slice,
        @as([]const u8, record.wasmError.type),
        @as([]const u8, record.wasmError.message),
        crash_function,
        crash_file,
        crash_line,
        record.wasmError.is_wasm_trap,
        record.timestamp,
        record.timestamp,
    }) catch |err| {
        std.log.err("Error Groups Query Error: {any}", .{err});
        return err;
    };

    var group_uuid: [16]u8 = undefined;
    if (try group_result.next()) |row| {
        const bytes = try row.get([]u8, 0);
        @memcpy(&group_uuid, bytes[0..16]);
    } else {
        group_result.deinit();
        return error.NoGroupId;
    }
    group_result.deinit();

    const element_id: []const u8 = record.element_id orelse "";
    const args: []const u8 = record.args orelse "{}";

    // ── Step 2: Insert the individual error_report ──────────────────
    var report_result = pool.query(
        \\INSERT INTO error_reports (
        \\  error_id, error_type, message, is_wasm_trap,
        \\  callback_args, element_type, timestamp,
        \\  crash_function, crash_file, crash_line, crash_column,
        \\  crash_wasm_index, crash_wasm_offset, crash_frame_type,
        \\  group_id
        \\) VALUES (
        \\  $1, $2, $3, $4,
        \\  $5::jsonb, $6, $7,
        \\  $8, $9, $10, $11,
        \\  $12, $13, $14,
        \\  $15
        \\) RETURNING id
    , .{
        @as([]const u8, element_id),
        @as([]const u8, record.wasmError.type),
        @as([]const u8, record.wasmError.message),
        record.wasmError.is_wasm_trap,
        @as([]const u8, args),
        @as(?[]const u8, null),
        record.timestamp,
        crash_function,
        crash_file,
        crash_line,
        crash_column,
        crash_wasm_index,
        crash_wasm_offset,
        crash_frame_type,
        &group_uuid,
    }) catch |err| {
        std.log.err("Query Error: {any}", .{err});
        return err;
    };

    var report_uuid: [16]u8 = undefined;
    if (try report_result.next()) |row| {
        const bytes = try row.get([]u8, 0);
        @memcpy(&report_uuid, bytes[0..16]);
    } else {
        report_result.deinit();
        return error.NoReportId;
    }
    report_result.deinit();

    // ── Step 3: Insert stack frames (unchanged) ─────────────────────
    for (record.wasmError.user_stack, 0..) |frame, i| {
        const f_line: ?i32 = if (frame.line) |l| @as(i32, @intCast(l)) else null;
        const f_col: ?i32 = if (frame.column) |c| @as(i32, @intCast(c)) else null;
        const f_wasm_idx: ?i32 = if (frame.wasm_function_index) |w| @as(i32, @intCast(w)) else null;

        _ = pool.exec(
            \\INSERT INTO stack_frames (
            \\  error_report_id, position, function_name,
            \\  file, line, col, wasm_function_index,
            \\  wasm_offset, frame_type
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        , .{
            &report_uuid,
            @as(i32, @intCast(i)),
            frame.function,
            frame.file,
            f_line,
            f_col,
            f_wasm_idx,
            frame.wasm_offset,
            @as([]const u8, @tagName(frame.frame_type)),
        }) catch |err| {
            std.log.err("Exec Error: {any}", .{err});
            return err;
        };
    }

    // ── Step 4: Insert trace events (unchanged) ─────────────────────
    for (record.events) |event| {
        const delta_ms: i32 = @intCast(@divTrunc(event.timestamp - record.timestamp, 1000));
        _ = try pool.exec(
            \\INSERT INTO trace_events (
            \\  error_report_id, event_type, element_id,
            \\  serialized_args, timestamp, delta_ms
            \\) VALUES ($1, $2, $3, $4::jsonb, $5, $6)
        , .{
            &report_uuid,
            @as([]const u8, @tagName(event.event_type)),
            event.element_id,
            @as([]const u8, event.serialized_args),
            event.timestamp,
            delta_ms,
        });
    }

    // std.log.info("Error recorded: group={s} report={s}", .{
    //     std.fmt.fmtSliceHexLower(&group_uuid),
    //     std.fmt.fmtSliceHexLower(&report_uuid),
    // });
}

// ============================================================================
// Query helpers (for the dashboard API endpoints)
// ============================================================================

/// Fetch individual occurrences for a specific error group.
pub fn getGroupOccurrences(pool: *pg.Pool, group_id: []const u8, limit: i32) !pg.Result {
    return try pool.query(
        \\SELECT id, error_id, message, timestamp,
        \\       crash_function, crash_file, crash_line, crash_column,
        \\       element_type, session_id, route
        \\FROM error_reports
        \\WHERE group_id = $1
        \\ORDER BY timestamp DESC
        \\LIMIT $2
    , .{ group_id, limit });
}

/// Update the status of an error group (resolve, ignore, etc.)
pub fn updateGroupStatus(pool: *pg.Pool, group_id: []const u8, new_status: []const u8) !void {
    const resolved_at_clause = if (std.mem.eql(u8, new_status, "resolved"))
        "now()"
    else
        "resolved_at"; // keep existing value

    _ = try pool.exec(
        std.fmt.comptimePrint(
            \\UPDATE error_groups
            \\SET status = $1, resolved_at = {s}
            \\WHERE id = $2
        , .{resolved_at_clause}),
        .{ new_status, group_id },
    );
}

/// Get aggregate counts for the dashboard summary cards.
pub fn getDashboardStats(pool: *pg.Pool) !pg.Result {
    return try pool.query(
        \\SELECT
        \\  COUNT(*) FILTER (WHERE status = 'unresolved')  AS unresolved,
        \\  COUNT(*) FILTER (WHERE status = 'regressed')   AS regressed,
        \\  COUNT(*) FILTER (WHERE status = 'resolved')    AS resolved,
        \\  COUNT(*) FILTER (WHERE status = 'ignored')     AS ignored,
        \\  SUM(occurrence_count)                           AS total_occurrences,
        \\  COUNT(*) FILTER (WHERE last_seen > now() - interval '24 hours') AS active_24h
        \\FROM error_groups
    , .{});
}
