const std = @import("std");
const pg = @import("pg");
const ArrayList = std.array_list.Managed;

/// PostgreSQL OID constants (these are stable across versions)
pub const Oid = struct {
    pub const bool_ = 16;
    pub const bytea = 17;
    pub const char_ = 18;
    pub const name = 19; // <-- add this
    pub const int8 = 20;
    pub const int2 = 21;
    pub const int4 = 23;
    pub const text = 25;
    pub const oid = 26;
    pub const json = 114;
    pub const xml = 142;
    pub const float4 = 700;
    pub const float8 = 701;
    pub const money = 790;
    pub const inet = 869;
    pub const bpchar = 1042; // char(n)
    pub const varchar = 1043;
    pub const date = 1082;
    pub const time = 1083;
    pub const timestamp = 1114;
    pub const timestamptz = 1184;
    pub const interval = 1186;
    pub const numeric = 1700;
    pub const uuid = 2950;
    pub const jsonb = 3802;

    // Arrays (prefix with underscore convention)
    pub const tid = 27;
    pub const xid = 28;
    pub const cid = 29;
    pub const regproc = 24;
    pub const regtype = 2206;
    pub const int2vector = 22;
    pub const oidvector = 30;
    pub const pg_node_tree = 194;
    pub const aclitem = 1033;
    pub const anyarray = 2277;
    pub const trigger = 2279;
    pub const event_trigger = 3838;
    pub const pg_lsn = 3220;
    pub const bool_array = 1000;
    pub const int2_array = 1005;
    pub const int4_array = 1007;
    pub const text_array = 1009;
    pub const varchar_array = 1015;
    pub const float4_array = 1021;
    pub const float8_array = 1022;
};

/// PostgreSQL interval type (months, days, microseconds)
pub const Interval = struct {
    microseconds: i64,
    days: i32,
    months: i32,

    /// Convert to total microseconds (approximate: assumes 30 days/month)
    pub fn toMicroseconds(self: Interval) i64 {
        const month_us: i64 = @as(i64, self.months) * 30 * 24 * 3600 * 1_000_000;
        const day_us: i64 = @as(i64, self.days) * 24 * 3600 * 1_000_000;
        return month_us + day_us + self.microseconds;
    }

    /// Convert to total seconds (approximate for months/days)
    pub fn toSeconds(self: Interval) f64 {
        return @as(f64, @floatFromInt(self.toMicroseconds())) / 1_000_000.0;
    }

    /// Parse from PostgreSQL binary wire format (16 bytes, big-endian)
    /// Wire format: i64 microseconds | i32 days | i32 months
    pub fn fromBytes(data: []const u8) ?Interval {
        if (data.len < 16) return null;
        return .{
            .microseconds = @bitCast(std.mem.readInt(u64, data[0..8], .big)),
            .days = @bitCast(std.mem.readInt(u32, data[8..12], .big)),
            .months = @bitCast(std.mem.readInt(u32, data[12..16], .big)),
        };
    }

    /// Format as ISO 8601 duration string (e.g. "P1Y2M3DT4H5M6S")
    pub fn toIso8601(self: Interval, buf: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buf);

        writer.writeByte('P') catch return "";

        const years = @divTrunc(self.months, 12);
        const months = @mod(self.months, 12);

        if (years != 0) writer.print("{}Y", .{years}) catch return "";
        if (months != 0) writer.print("{}M", .{months}) catch return "";
        if (self.days != 0) writer.print("{}D", .{self.days}) catch return "";

        const total_us = if (self.microseconds < 0) -self.microseconds else self.microseconds;
        const hours = @divTrunc(total_us, 3_600_000_000);
        const mins = @divTrunc(@mod(total_us, 3_600_000_000), 60_000_000);
        const secs = @divTrunc(@mod(total_us, 60_000_000), 1_000_000);
        const frac_us = @mod(total_us, 1_000_000);

        if (hours != 0 or mins != 0 or secs != 0 or frac_us != 0) {
            writer.writeByte('T') catch return "";
            if (self.microseconds < 0) writer.writeByte('-') catch return "";
            if (hours != 0) writer.print("{}H", .{hours}) catch return "";
            if (mins != 0) writer.print("{}M", .{mins}) catch return "";
            if (secs != 0 or frac_us != 0) {
                if (frac_us != 0) {
                    writer.print("{}.{:0>6}S", .{ secs, frac_us }) catch return "";
                } else {
                    writer.print("{}S", .{secs}) catch return "";
                }
            }
        }

        // Handle zero interval
        if (writer.end == 1) writer.writeAll("T0S") catch return "";

        return buf[0..writer.end];
    }
};

/// A dynamic value that can hold any PostgreSQL type
pub const Value = union(enum) {
    null_,
    bool_: bool,
    int2: i16,
    int4: i32,
    int8: i64,
    float4: f32,
    float8: f64,
    text: []const u8,
    bytea: []const u8,
    json: []const u8,
    jsonb: []const u8,
    uuid: [16]u8,
    timestamp: i64, // microseconds since epoch
    interval: Interval, // PostgreSQL interval (months, days, microseconds)
    numeric: []const u8, // text representation
    unknown: []const u8, // raw bytes for unsupported types

    pub fn toJson(self: Value, writer: anytype) !void {
        switch (self) {
            .null_ => try writer.writeAll("null"),
            .bool_ => |v| try writer.print("{}", .{v}),
            .int2 => |v| try writer.print("{}", .{v}),
            .int4 => |v| try writer.print("{}", .{v}),
            .int8 => |v| try writer.print("{}", .{v}),
            .float4 => |v| try writer.print("{d}", .{v}),
            .float8 => |v| try writer.print("{d}", .{v}),
            .text, .numeric => |v| {
                try writer.writeByte('"');
                _ = try writer.write(v);
                try writer.writeByte('"');
            },
            .json, .jsonb => |v| try writer.writeAll(v), // already JSON
            .uuid => |v| {
                try writer.writeByte('"');
                const hex = pg.uuidToHex(&v) catch unreachable;
                _ = try writer.write(&hex);
                try writer.writeByte('"');
            },
            .timestamp => |v| {
                try writer.writeByte('"');
                try writer.print("{}", .{@divTrunc(v, 1_000_000)});
                try writer.writeByte('"');
            },
            .interval => |v| {
                // Output as ISO 8601 duration string
                var buf: [128]u8 = undefined;
                const iso = v.toIso8601(&buf);
                try writer.writeByte('"');
                _ = try writer.write(iso);
                try writer.writeByte('"');
            },
            else => {},
        }
    }
};

/// Column metadata
pub const ColumnInfo = struct {
    name: []const u8,
    oid: i32,
    type_name: []const u8,
};

/// Result of a query execution
pub const QueryResult = struct {
    columns: []ColumnInfo,
    rows: [][]Value,
    row_count: usize,

    pub fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        for (self.rows) |row| {
            allocator.free(row);
        }
        allocator.free(self.rows);
        allocator.free(self.columns);
    }

    pub fn toJson(self: QueryResult, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        const writer = &out.writer;

        try writer.writeAll("{\"columns\":[");
        for (self.columns, 0..) |col, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":\"{s}\",\"type\":\"{s}\",\"oid\":{}}}", .{ col.name, col.type_name, col.oid });
        }

        try writer.writeAll("],\"rows\":[");
        for (self.rows, 0..) |row, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeByte('[');
            for (row, 0..) |val, j| {
                if (j > 0) try writer.writeByte(',');
                try val.toJson(writer);
            }
            try writer.writeByte(']');
        }
        try writer.writeAll("]}");

        return out.toOwnedSlice();
    }

    // Add to QueryResult
    pub fn toFlatStringsJson(self: QueryResult, allocator: std.mem.Allocator) ![]u8 {
        // For EXPLAIN ANALYZE, etc. — returns {"lines": ["...", "..."]}
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        const writer = &out.writer;

        try writer.writeAll("{\"lines\":[");
        for (self.rows, 0..) |row, i| {
            if (i > 0) try writer.writeByte(',');
            // Take first column as text
            switch (row[0]) {
                .text => |v| {
                    try writer.writeByte('"');
                    try writer.writeAll(v);
                    try writer.writeByte('"');
                },
                else => |v| try v.toJson(writer),
            }
        }
        try writer.writeAll("]}");
        return out.toOwnedSlice();
    }

    /// Returns rows as array of objects: [{"col1": val, "col2": val}, ...]
    pub fn toObjectsJson(self: QueryResult, allocator: std.mem.Allocator) ![]u8 {
        var out = std.Io.Writer.Allocating.init(allocator);
        errdefer out.deinit();
        const writer = &out.writer;

        try writer.writeByte('[');
        for (self.rows, 0..) |row, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeByte('{');
            for (row, 0..) |val, j| {
                if (j > 0) try writer.writeByte(',');
                try writer.print("\"{s}\":", .{self.columns[j].name});
                try val.toJson(writer);
            }
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
        return out.toOwnedSlice();
    }

    /// Scalar — returns single value from first row, first column
    pub fn scalar(self: QueryResult) ?Value {
        if (self.rows.len == 0) return null;
        if (self.rows[0].len == 0) return null;
        return self.rows[0][0];
    }
};

pub const CRUD = struct {
    pool: *pg.Pool,
    allocator: std.mem.Allocator,

    pub const PgError = struct {
        code: []const u8,
        severity: []const u8,
        message: []const u8,
        detail: ?[]const u8 = null,
        hint: ?[]const u8 = null,
        table: ?[]const u8 = null,
        constraint: ?[]const u8 = null,
        schema: ?[]const u8 = null,
        column: ?[]const u8 = null,
        position: ?[]const u8 = null,

        pub fn fromConn(conn: anytype, allocator: std.mem.Allocator) ?PgError {
            const pge = conn.err orelse return null;
            return .{
                .code = allocator.dupe(u8, pge.code) catch return null,
                .severity = allocator.dupe(u8, pge.severity) catch return null,
                .message = allocator.dupe(u8, pge.message) catch return null,
                .detail = if (pge.detail) |d| allocator.dupe(u8, d) catch null else null,
                .hint = if (pge.hint) |h| allocator.dupe(u8, h) catch null else null,
                .table = if (pge.table) |t| allocator.dupe(u8, t) catch null else null,
                .constraint = if (pge.constraint) |c| allocator.dupe(u8, c) catch null else null,
                .schema = if (pge.schema) |s| allocator.dupe(u8, s) catch null else null,
                .column = if (pge.column) |c| allocator.dupe(u8, c) catch null else null,
                .position = if (pge.position) |p| allocator.dupe(u8, p) catch null else null,
            };
        }

        pub fn isUnique(self: PgError) bool {
            return std.mem.eql(u8, self.code, "23505");
        }

        pub fn isForeignKey(self: PgError) bool {
            return std.mem.eql(u8, self.code, "23503");
        }

        pub fn isNotNull(self: PgError) bool {
            return std.mem.eql(u8, self.code, "23502");
        }

        pub fn isSyntax(self: PgError) bool {
            return std.mem.eql(u8, self.code, "42601");
        }

        pub fn isUndefinedTable(self: PgError) bool {
            return std.mem.eql(u8, self.code, "42P01");
        }

        pub fn toJson(self: PgError, allocator: std.mem.Allocator) ![]const u8 {
            return std.json.Stringify.valueAlloc(allocator, self, .{ .emit_null_optional_fields = false });
        }
    };

    pub const QueryResponse = union(enum) {
        ok: QueryResult,
        err: PgError,

        pub fn isOk(self: QueryResponse) bool {
            return self == .ok;
        }

        pub fn isErr(self: QueryResponse) bool {
            return self == .err;
        }
    };

    pub fn init(pool: *pg.Pool, allocator: std.mem.Allocator) CRUD {
        return .{ .pool = pool, .allocator = allocator };
    }

    pub fn toQueryResponse(self: *CRUD, result: *pg.Result) !QueryResponse {
        var columns = try self.allocator.alloc(ColumnInfo, result.number_of_columns);
        for (0..result.number_of_columns) |i| {
            columns[i] = .{
                .name = try self.allocator.dupe(u8, result.column_names[i]),
                .oid = result._oids[i],
                .type_name = oidToTypeName(result._oids[i]),
            };
        }

        var rows = ArrayList([]Value).init(self.allocator);
        defer rows.deinit();

        while (try result.next()) |row| {
            var values = try self.allocator.alloc(Value, result.number_of_columns);
            for (0..result.number_of_columns) |col| {
                values[col] = try self.extractValue(row, col, row.oids[col]);
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

    pub fn rawQuery(self: *CRUD, sql_query: []const u8) !QueryResponse {
        var conn = try self.pool.acquire();

        var result = conn.queryOpts(sql_query, .{}, .{ .column_names = true }) catch |err| {
            defer conn.release();
            if (err == error.PG) {
                if (PgError.fromConn(conn, self.allocator)) |pg_err| {
                    return .{ .err = pg_err };
                }
            }
            // Non-PG errors (network, OOM, etc.) still propagate as Zig errors
            return err;
        };
        defer conn.release();
        defer result.deinit();

        return try toQueryResponse(self, &result);

        // var columns = try self.allocator.alloc(ColumnInfo, result.number_of_columns);
        // for (0..result.number_of_columns) |i| {
        //     columns[i] = .{
        //         .name = try self.allocator.dupe(u8, result.column_names[i]),
        //         .oid = result._oids[i],
        //         .type_name = oidToTypeName(result._oids[i]),
        //     };
        // }
        //
        // var rows = ArrayList([]Value).init(self.allocator);
        // defer rows.deinit();
        //
        // while (try result.next()) |row| {
        //     var values = try self.allocator.alloc(Value, result.number_of_columns);
        //     for (0..result.number_of_columns) |col| {
        //         values[col] = try self.extractValue(row, col, row.oids[col]);
        //     }
        //     try rows.append(values);
        // }
        //
        // const row_count = rows.items.len;
        // return .{ .ok = .{
        //     .columns = columns,
        //     .rows = try rows.toOwnedSlice(),
        //     .row_count = row_count,
        // } };
    }
    /// Extract a value based on OID at runtime
    pub fn extractValue(self: *CRUD, row: pg.Row, col: usize, oid: i32) !Value {
        // Check for null first
        if (row.values[col].is_null) {
            return .null_;
        }

        return switch (oid) {
            Oid.bool_ => .{ .bool_ = try row.get(bool, col) },
            Oid.int2 => .{ .int2 = try row.get(i16, col) },
            Oid.int4 => .{ .int4 = try row.get(i32, col) },
            Oid.int8 => .{ .int8 = try row.get(i64, col) },
            Oid.float4 => .{ .float4 = try row.get(f32, col) },
            Oid.float8 => .{ .float8 = try row.get(f64, col) },
            Oid.text, Oid.varchar, Oid.bpchar, Oid.char_, Oid.name => blk: {
                const data = try row.get([]const u8, col);
                break :blk .{ .text = self.allocator.dupe(u8, data) catch data };
            },
            Oid.bytea => blk: {
                const data = try row.get([]const u8, col);
                break :blk .{ .bytea = self.allocator.dupe(u8, data) catch data };
            },
            Oid.json, Oid.jsonb => blk: {
                const data = try row.get([]const u8, col);
                break :blk if (oid == Oid.json)
                    .{ .json = self.allocator.dupe(u8, data) catch data }
                else
                    .{ .jsonb = self.allocator.dupe(u8, data) catch data };
            },
            Oid.uuid => blk: {
                const data = try row.get([]const u8, col);
                var uuid: [16]u8 = undefined;
                @memcpy(&uuid, data[0..16]);
                break :blk .{ .uuid = uuid };
            },
            Oid.timestamp, Oid.timestamptz => .{ .timestamp = try row.get(i64, col) },
            Oid.interval => blk: {
                // pg.zig can't read interval as i64 — read raw bytes and parse
                // PostgreSQL binary wire format: i64 microseconds | i32 days | i32 months (big-endian)
                const data = try row.get([]const u8, col);
                break :blk if (Interval.fromBytes(data)) |iv|
                    .{ .interval = iv }
                else
                    .{ .text = self.allocator.dupe(u8, "invalid interval") catch "invalid interval" };
            },
            Oid.numeric => blk: {
                const numeric = try row.get(pg.Numeric, col);
                var buf: [128]u8 = undefined;
                const str = numeric.toString(&buf) catch unreachable;
                break :blk .{ .numeric = self.allocator.dupe(u8, str) catch str };
            },
            else => blk: {
                const data = try row.get([]const u8, col);
                break :blk .{ .text = self.allocator.dupe(u8, data) catch data };
            },
        };
    }

    pub fn oidToTypeName(oid: i32) []const u8 {
        return switch (oid) {
            Oid.bool_ => "boolean",
            Oid.int2 => "smallint",
            Oid.int4 => "integer",
            Oid.int8 => "bigint",
            Oid.float4 => "real",
            Oid.float8 => "double precision",
            Oid.text => "text",
            Oid.varchar => "varchar",
            Oid.bpchar => "char",
            Oid.bytea => "bytea",
            Oid.json => "json",
            Oid.jsonb => "jsonb",
            Oid.uuid => "uuid",
            Oid.timestamp => "timestamp",
            Oid.timestamptz => "timestamptz",
            Oid.date => "date",
            Oid.time => "time",
            Oid.interval => "interval",
            Oid.numeric => "numeric",
            Oid.name => "name",
            else => "unknown",
        };
    }

    // ============ TABLE EDITOR APIs ============

    /// Get table schema
    pub fn getTableSchema(self: *CRUD, schema: []const u8, table: []const u8) !QueryResult {
        const sql_query =
            \\SELECT 
            \\    c.column_name,
            \\    c.data_type,
            \\    c.is_nullable,
            \\    c.column_default,
            \\    c.character_maximum_length,
            \\    CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_primary_key
            \\FROM information_schema.columns c
            \\LEFT JOIN (
            \\    SELECT ku.column_name
            \\    FROM information_schema.table_constraints tc
            \\    JOIN information_schema.key_column_usage ku
            \\        ON tc.constraint_name = ku.constraint_name
            \\    WHERE tc.constraint_type = 'PRIMARY KEY'
            \\        AND tc.table_schema = $1
            \\        AND tc.table_name = $2
            \\) pk ON c.column_name = pk.column_name
            \\WHERE c.table_schema = $1 AND c.table_name = $2
            \\ORDER BY c.ordinal_position;
        ;
        _ = schema;
        _ = table;
        // You'd use parameterized query here
        return self.rawQuery(sql_query);
    }

    /// List tables in schema
    pub fn listTables(self: *CRUD, schema: []const u8) !QueryResult {
        _ = schema;
        const sql_query =
            \\SELECT table_name, table_type
            \\FROM information_schema.tables
            \\WHERE table_schema = $1
            \\ORDER BY table_name;
        ;
        return self.rawQuery(sql_query);
    }

    /// Paginated table data
    pub fn getTableData(
        self: *CRUD,
        schema: []const u8,
        table: []const u8,
        limit: usize,
        offset: usize,
    ) !QueryResult {
        _ = schema;
        _ = table;
        _ = limit;
        _ = offset;
        // Build safe query with identifiers (be careful about SQL injection!)
        const sql_query = "SELECT * FROM {s}.{s} LIMIT {d} OFFSET {d}";
        _ = sql_query;
        // ... format and execute
        return self.rawQuery("SELECT 1"); // placeholder
    }

    // Add to CRUD
    pub const ResponseFormat = enum {
        table, // {columns: [...], rows: [...]}  — current default
        objects, // [{col: val, ...}, ...]         — easier for frontend
        flat, // {lines: ["...", ...]}           — for EXPLAIN, etc.
    };

    pub fn query(self: *CRUD, sql: []const u8, format: ResponseFormat) !QueryResponse {
        const response = try self.rawQuery(sql);
        // Store the preferred format so the handler can use it
        if (response == .ok) {
            return .{ .ok = response.ok, .format = format };
        }
        return response;
    }

    pub fn getErrorGroups(self: *CRUD, status_filter: ?[]const u8, limit: i32) !QueryResponse {
        var pool = self.pool;
        var result = if (status_filter) |status| blk: {
            break :blk try pool.queryOpts(
                \\SELECT id, fingerprint, error_type, message,
                \\       crash_function, crash_file, crash_line, is_wasm_trap,
                \\       occurrence_count, first_seen, last_seen, status
                \\FROM error_groups
                \\WHERE status = $1
                \\ORDER BY last_seen DESC
                \\LIMIT $2
            , .{ status, limit }, .{ .column_names = true });
        } else blk: {
            break :blk try pool.queryOpts(
                \\SELECT id, fingerprint, error_type, message,
                \\       crash_function, crash_file, crash_line, is_wasm_trap,
                \\       occurrence_count, first_seen, last_seen, status
                \\FROM error_groups
                \\ORDER BY last_seen DESC
                \\LIMIT $1
            , .{limit}, .{ .column_names = true });
        };
        defer result.deinit();

        var columns = try self.allocator.alloc(ColumnInfo, result.number_of_columns);
        for (0..result.number_of_columns) |i| {
            columns[i] = .{
                .name = try self.allocator.dupe(u8, result.column_names[i]),
                .oid = result._oids[i],
                .type_name = oidToTypeName(result._oids[i]),
            };
        }

        var rows = ArrayList([]Value).init(self.allocator);
        defer rows.deinit();

        while (try result.next()) |row| {
            var values = try self.allocator.alloc(Value, result.number_of_columns);
            for (0..result.number_of_columns) |col| {
                values[col] = try self.extractValue(row, col, row.oids[col]);
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

    pub fn updateGroupStatus(self: *CRUD, group_id: []const u8, new_status: []const u8) !QueryResponse {
        const resolved_at_clause = if (std.mem.eql(u8, new_status, "resolved"))
            "now()"
        else
            "resolved_at"; // keep existing value

        const fmt = try std.fmt.allocPrint(self.allocator,
            \\UPDATE error_groups
            \\SET status = $1, resolved_at = {s}
            \\WHERE id = $2
        , .{resolved_at_clause});

        defer self.allocator.free(fmt);

        var pool = self.pool;

        const result = try pool.exec(fmt, .{ new_status, group_id });
        if (result) |_| {
            return .{ .ok = .{ .columns = &.{}, .rows = &.{}, .row_count = 0 } };
        }

        const conn = pool.acquire() catch return error.NoConn;

        return .{ .err = PgError.fromConn(conn, self.allocator) orelse return error.NoPgErr };
    }

    pub fn getErrorGroupOccurrences(self: *CRUD, group_id: []const u8, limit: i32) !QueryResponse {
        var pool = self.pool;
        var result = try pool.queryOpts(
            \\SELECT id, error_id, message, timestamp,
            \\       crash_function, crash_file, crash_line, crash_column,
            \\       element_type, session_id, route
            \\FROM error_reports
            \\WHERE group_id = $1
            \\ORDER BY timestamp DESC
            \\LIMIT $2
        , .{ group_id, limit }, .{ .column_names = true });
        defer result.deinit();

        var columns = try self.allocator.alloc(ColumnInfo, result.number_of_columns);
        for (0..result.number_of_columns) |i| {
            columns[i] = .{
                .name = try self.allocator.dupe(u8, result.column_names[i]),
                .oid = result._oids[i],
                .type_name = oidToTypeName(result._oids[i]),
            };
        }

        var rows = ArrayList([]Value).init(self.allocator);
        defer rows.deinit();

        while (try result.next()) |row| {
            var values = try self.allocator.alloc(Value, result.number_of_columns);
            for (0..result.number_of_columns) |col| {
                values[col] = try self.extractValue(row, col, row.oids[col]);
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
};
