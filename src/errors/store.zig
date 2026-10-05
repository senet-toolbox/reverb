const std = @import("std");
const pg = @import("pg");
const types = @import("types.zig");
const fingerprint = @import("fingerprint.zig");
const Crud = @import("../pg/crud.zig").CRUD;
const ArrayList = std.array_list.Managed;
const ColumnInfo = @import("../pg/crud.zig").ColumnInfo;
const Value = @import("../pg/crud.zig").Value;

pub const ErrorStore = struct {
    pool: *pg.Pool,
    crud: *Crud,
    allocator: std.mem.Allocator,

    pub fn init(pool: *pg.Pool, crud: *Crud, allocator: std.mem.Allocator) ErrorStore {
        return .{ .pool = pool, .crud = crud, .allocator = allocator };
    }

    // ====================================================================
    // WRITE: Record a full error report
    // ====================================================================

    pub fn record(self: *ErrorStore, report: types.ErrorReport) !RecordResult {
        const fp = fingerprint.compute(report);
        const crash = types.CrashFields.extract(report.wasmError.crash_site);

        const group_id = try self.upsertGroup(report, &fp, crash);
        const report_id = try self.insertReport(report, &group_id, crash);
        try self.insertStackFrames(report, &report_id);
        try self.insertTraceEvents(report, &report_id);

        return .{ .group_id = group_id, .report_id = report_id };
    }

    pub const RecordResult = struct {
        group_id: [16]u8,
        report_id: [16]u8,
    };

    // ====================================================================
    // READ: Stack frames for the latest occurrence of an error group
    // ====================================================================

    pub fn getGroupStackFrames(self: *ErrorStore, group_id: []const u8) !Crud.QueryResponse {
        return self.parameterizedQuery(
            \\SELECT sf.position, sf.function_name, sf.file, sf.line, sf.col,
            \\       sf.wasm_function_index, sf.wasm_offset, sf.frame_type
            \\FROM stack_frames sf
            \\JOIN error_reports er ON er.id = sf.error_report_id
            \\WHERE er.group_id = $1
            \\ORDER BY er.timestamp DESC, sf.position ASC
            \\LIMIT 50
        , group_id);
    }

    // ====================================================================
    // READ: Trace events for the latest occurrence of an error group
    // ====================================================================

    pub fn getGroupTraceEvents(self: *ErrorStore, group_id: []const u8) !Crud.QueryResponse {
        return self.parameterizedQuery(
            \\SELECT te.event_type, te.element_id, te.serialized_args,
            \\       te.timestamp, te.delta_ms
            \\FROM trace_events te
            \\JOIN error_reports er ON er.id = te.error_report_id
            \\WHERE er.group_id = $1
            \\ORDER BY er.timestamp DESC, te.timestamp ASC
            \\LIMIT 100
        , group_id);
    }

    // ====================================================================
    // READ: Hourly error counts for last 24h (dashboard chart)
    // ====================================================================

    pub fn getErrorTimeSeries(self: *ErrorStore) !Crud.QueryResponse {
        return self.crud.rawQuery(
            \\SELECT
            \\  EXTRACT(EPOCH FROM date_trunc('hour', timestamp))::bigint AS hour_epoch,
            \\  COUNT(*)::bigint AS count,
            \\  COUNT(*) FILTER (WHERE is_wasm_trap)::bigint AS fatal_count
            \\FROM error_reports
            \\WHERE timestamp > now() - interval '24 hours'
            \\GROUP BY date_trunc('hour', timestamp)
            \\ORDER BY date_trunc('hour', timestamp) ASC
        );
    }

    // ====================================================================
    // WRITE: Delete
    // ====================================================================

    pub fn deleteGroup(self: *ErrorStore, group_id: []const u8) !Crud.QueryResponse {
        return self.parameterizedQuery(
            \\DELETE FROM error_groups WHERE id = $1 RETURNING id
        , group_id);
    }

    pub fn deleteAllResolved(self: *ErrorStore) !Crud.QueryResponse {
        return self.crud.rawQuery(
            \\DELETE FROM error_groups WHERE status = 'resolved' RETURNING id
        );
    }

    // ====================================================================
    // Parameterized read helper (single text/uuid param → QueryResponse)
    // ====================================================================

    fn parameterizedQuery(self: *ErrorStore, sql_str: []const u8, param: []const u8) !Crud.QueryResponse {
        var conn = try self.pool.acquire();

        var stmt = conn.prepareOpts(sql_str, .{ .column_names = true }) catch |err| {
            if (err == error.PG) {
                if (Crud.PgError.fromConn(conn, self.allocator)) |pg_err| {
                    conn.release();
                    return .{ .err = pg_err };
                }
            }
            conn.release();
            return err;
        };

        try stmt.bind(param);

        var result = stmt.execute() catch |err| {
            if (err == error.PG) {
                if (Crud.PgError.fromConn(conn, self.allocator)) |pg_err| {
                    conn.release();
                    return .{ .err = pg_err };
                }
            }
            conn.release();
            return err;
        };
        // Zig defers are LIFO: conn.release runs last, result.deinit runs first.
        defer conn.release();
        defer result.deinit();

        var columns = try self.allocator.alloc(ColumnInfo, result.number_of_columns);
        for (0..result.number_of_columns) |i| {
            columns[i] = .{
                .name = try self.allocator.dupe(u8, result.column_names[i]),
                .oid = result._oids[i],
                .type_name = Crud.oidToTypeName(result._oids[i]),
            };
        }

        var rows = ArrayList([]Value).init(self.allocator);
        defer rows.deinit();

        while (try result.next()) |row| {
            var values = try self.allocator.alloc(Value, result.number_of_columns);
            for (0..result.number_of_columns) |col| {
                values[col] = try self.crud.extractValue(row, col, row.oids[col]);
            }
            try rows.append(values);
        }

        const row_count = rows.items.len;
        return .{ .ok = .{
            .columns = columns,
            .rows = try rows.toOwnedSlice(),
            .row_count = row_count,
        } };
    }

    // ====================================================================
    // Internal: Write operations
    // ====================================================================

    fn upsertGroup(self: *ErrorStore, report: types.ErrorReport, fp: *const [64]u8, crash: types.CrashFields) ![16]u8 {
        const conn = try self.pool.acquire();
        errdefer self.pool.release(conn);

        var stmt = conn.prepare(
            \\INSERT INTO error_groups (
            \\  fingerprint, error_type, message,
            \\  crash_function, crash_file, crash_line, is_wasm_trap,
            \\  occurrence_count, first_seen, last_seen,
            \\  environment, release, route,
            \\  status
            \\) VALUES (
            \\  $1, $2, $3, $4, $5, $6, $7,
            \\  1, $8, $9,
            \\  $10, $11, $12,
            \\  CASE WHEN EXISTS (
            \\    SELECT 1 FROM error_groups WHERE fingerprint = $1 AND status = 'resolved'
            \\  ) THEN 'regressed' ELSE 'unresolved' END
            \\) ON CONFLICT (fingerprint) DO UPDATE SET
            \\  occurrence_count = error_groups.occurrence_count + 1,
            \\  last_seen = GREATEST(error_groups.last_seen, $9),
            \\  environment = COALESCE($10, error_groups.environment),
            \\  release = COALESCE($11, error_groups.release),
            \\  route = COALESCE($12, error_groups.route),
            \\  status = CASE
            \\    WHEN error_groups.status = 'resolved' THEN 'regressed'
            \\    WHEN error_groups.status = 'ignored'  THEN 'ignored'
            \\    ELSE error_groups.status END
            \\RETURNING id
        ) catch |err| {
            logPgError(conn, "upsertGroup");
            self.pool.release(conn);
            return err;
        };

        try stmt.bind(@as([]const u8, fp)); // $1  fingerprint
        try stmt.bind(@as([]const u8, report.wasmError.type)); // $2  error_type
        try stmt.bind(@as([]const u8, report.wasmError.message)); // $3  message
        try stmt.bind(crash.function); // $4  crash_function
        try stmt.bind(crash.file); // $5  crash_file
        try stmt.bind(crash.line); // $6  crash_line
        try stmt.bind(report.wasmError.is_wasm_trap); // $7  is_wasm_trap
        try stmt.bind(report.timestamp); // $8  first_seen
        try stmt.bind(report.timestamp); // $9  last_seen
        try stmt.bind(report.environment); // $10 environment
        try stmt.bind(report.release); // $11 release
        try stmt.bind(report.route); // $12 route

        var result = stmt.execute() catch |err| {
            logPgError(conn, "upsertGroup");
            self.pool.release(conn);
            return err;
        };
        defer conn.release();
        defer result.deinit();

        if (try result.next()) |row| {
            var uuid: [16]u8 = undefined;
            const bytes = try row.get([]u8, 0);
            @memcpy(&uuid, bytes[0..16]);
            return uuid;
        }
        return error.NoGroupId;
    }

    fn insertReport(self: *ErrorStore, report: types.ErrorReport, group_id: *const [16]u8, crash: types.CrashFields) ![16]u8 {
        const conn = try self.pool.acquire();
        errdefer self.pool.release(conn);

        var stmt = conn.prepare(
            \\INSERT INTO error_reports (
            \\  error_id, error_type, message, is_wasm_trap,
            \\  callback_args, element_type, timestamp,
            \\  crash_function, crash_file, crash_line, crash_column,
            \\  crash_wasm_index, crash_wasm_offset, crash_frame_type,
            \\  route, url, session_id, user_agent,
            \\  environment, release, user_id,
            \\  request_method, request_url, request_status_code,
            \\  request_body, request_elapsed_ms,
            \\  group_id
            \\) VALUES (
            \\  $1,$2,$3,$4,$5::jsonb,$6,$7,
            \\  $8,$9,$10,$11,$12,$13,$14,
            \\  $15,$16,$17,$18,
            \\  $19,$20,$21,
            \\  $22,$23,$24,$25,$26,
            \\  $27
            \\) RETURNING id
        ) catch |err| {
            logPgError(conn, "insertReport");
            self.pool.release(conn);
            return err;
        };

        try stmt.bind(@as([]const u8, report.element_id orelse "")); // $1  error_id
        try stmt.bind(@as([]const u8, report.wasmError.type)); // $2  error_type
        try stmt.bind(@as([]const u8, report.wasmError.message)); // $3  message
        try stmt.bind(report.wasmError.is_wasm_trap); // $4  is_wasm_trap
        try stmt.bind(@as([]const u8, report.args orelse "{}")); // $5  callback_args
        try stmt.bind(@as(?[]const u8, null)); // $6  element_type
        try stmt.bind(report.timestamp); // $7  timestamp
        try stmt.bind(crash.function); // $8  crash_function
        try stmt.bind(crash.file); // $9  crash_file
        try stmt.bind(crash.line); // $10 crash_line
        try stmt.bind(crash.column); // $11 crash_column
        try stmt.bind(crash.wasm_index); // $12 crash_wasm_index
        try stmt.bind(crash.wasm_offset); // $13 crash_wasm_offset
        try stmt.bind(crash.frame_type); // $14 crash_frame_type
        try stmt.bind(report.route); // $15 route
        try stmt.bind(report.url); // $16 url
        try stmt.bind(report.session_id); // $17 session_id
        try stmt.bind(report.user_agent); // $18 user_agent
        try stmt.bind(report.environment); // $19 environment
        try stmt.bind(report.release); // $20 release
        try stmt.bind(report.user_id); // $21 user_id

        // Request context (the fetch call that triggered the error, if any)
        if (report.request_context) |rc| {
            try stmt.bind(@as(?[]const u8, rc.method)); // $22 request_method
            try stmt.bind(@as(?[]const u8, rc.url)); // $23 request_url
            try stmt.bind(rc.status_code); // $24 request_status_code
            try stmt.bind(rc.body); // $25 request_body
            try stmt.bind(rc.elapsed_ms); // $26 request_elapsed_ms
        } else {
            try stmt.bind(@as(?[]const u8, null)); // $22
            try stmt.bind(@as(?[]const u8, null)); // $23
            try stmt.bind(@as(?u32, null)); // $24
            try stmt.bind(@as(?[]const u8, null)); // $25
            try stmt.bind(@as(?i64, null)); // $26
        }

        try stmt.bind(@as([]const u8, group_id)); // $27 group_id

        var result = stmt.execute() catch |err| {
            logPgError(conn, "insertReport");
            self.pool.release(conn);
            return err;
        };
        defer conn.release();
        defer result.deinit();

        if (try result.next()) |row| {
            var uuid: [16]u8 = undefined;
            const bytes = try row.get([]u8, 0);
            @memcpy(&uuid, bytes[0..16]);
            return uuid;
        }
        return error.NoReportId;
    }

    fn insertStackFrames(self: *ErrorStore, report: types.ErrorReport, report_id: *const [16]u8) !void {
        for (report.wasmError.user_stack, 0..) |frame, i| {
            const conn = try self.pool.acquire();
            errdefer self.pool.release(conn);
            var stmt = conn.prepare(
                \\INSERT INTO stack_frames (error_report_id,position,function_name,file,line,col,wasm_function_index,wasm_offset,frame_type)
                \\VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
            ) catch |err| {
                logPgError(conn, "insertFrames");
                self.pool.release(conn);
                return err;
            };
            try stmt.bind(@as([]const u8, report_id));
            try stmt.bind(@as(i32, @intCast(i)));
            try stmt.bind(frame.function);
            try stmt.bind(frame.file);
            try stmt.bind(if (frame.line) |l| @as(?i32, @intCast(l)) else null);
            try stmt.bind(if (frame.column) |c| @as(?i32, @intCast(c)) else null);
            try stmt.bind(if (frame.wasm_function_index) |w| @as(?i32, @intCast(w)) else null);
            try stmt.bind(frame.wasm_offset);
            try stmt.bind(@as([]const u8, @tagName(frame.frame_type)));
            var result = stmt.execute() catch |err| {
                logPgError(conn, "insertFrames");
                self.pool.release(conn);
                return err;
            };
            result.deinit();
            self.pool.release(conn);
        }
    }

    fn insertTraceEvents(self: *ErrorStore, report: types.ErrorReport, report_id: *const [16]u8) !void {
        for (report.events) |event| {
            const conn = try self.pool.acquire();
            errdefer self.pool.release(conn);
            var stmt = conn.prepare(
                \\INSERT INTO trace_events (error_report_id,event_type,element_id,serialized_args,timestamp,delta_ms)
                \\VALUES ($1,$2,$3,$4::jsonb,$5,$6)
            ) catch |err| {
                logPgError(conn, "insertEvents");
                self.pool.release(conn);
                return err;
            };
            try stmt.bind(@as([]const u8, report_id));
            try stmt.bind(@as([]const u8, @tagName(event.event_type)));
            try stmt.bind(event.element_id);
            try stmt.bind(@as([]const u8, event.serialized_args));
            try stmt.bind(event.timestamp);
            try stmt.bind(@as(i32, @intCast(@divTrunc(event.timestamp - report.timestamp, 1000))));
            var result = stmt.execute() catch |err| {
                logPgError(conn, "insertEvents");
                self.pool.release(conn);
                return err;
            };
            result.deinit();
            self.pool.release(conn);
        }
    }

    fn logPgError(conn: anytype, context: []const u8) void {
        if (conn.err) |pge| {
            std.log.err("[ErrorStore.{s}] PG {s}: {s}", .{ context, pge.code, pge.message });
        }
    }
};
