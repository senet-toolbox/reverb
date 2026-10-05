const std = @import("std");
const pg = @import("pg");
const meta = @import("meta.zig");
const ops = @import("operators.zig");
const sql = @import("sql.zig");
const clause = @import("clause.zig");
const result = @import("result.zig");

const Op = ops.Op;
const Order = ops.Order;
const Connector = clause.Connector;

/// SELECT query builder
pub fn QueryBuilder(comptime T: type) type {
    const Meta = meta.ModelMeta(T);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        select_columns: ?[]const u8,
        columns_indicies: [][]const u8,
        where_clause: clause.WhereClause,
        order_by_clause: clause.OrderByClause,
        limit_clause: clause.LimitClause,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .select_columns = null,
                .where_clause = clause.WhereClause.init(allocator),
                .order_by_clause = clause.OrderByClause.init(allocator),
                .limit_clause = .{},
                .columns_indicies = &[_][]const u8{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.where_clause.deinit();
            self.order_by_clause.deinit();
            self.allocator.free(self.columns_indicies);
        }

        // ====================================================================
        // SELECT columns
        // ====================================================================

        /// Select specific columns
        pub fn select(self: *Self, comptime columns: anytype) *Self {
            self.select_columns = comptime Meta.columns(columns);
            const indicies = self.allocator.alloc([]const u8, columns.len) catch return self;
            Meta.columnsNames(columns, indicies);
            self.columns_indicies = indicies;
            return self;
        }

        // ====================================================================
        // WHERE clauses
        // ====================================================================

        /// Add a WHERE condition (AND)
        pub fn where(self: *Self, comptime field: std.meta.FieldEnum(T), op: Op, value: anytype) *Self {
            const col_name = comptime Meta.columnName(field);
            self.where_clause.add(col_name, op, value, .@"and") catch {};
            return self;
        }

        /// Add a WHERE condition (OR)
        pub fn orWhere(self: *Self, comptime field: std.meta.FieldEnum(T), op: Op, value: anytype) *Self {
            const col_name = comptime Meta.columnName(field);
            self.where_clause.add(col_name, op, value, .@"or") catch {};
            return self;
        }

        /// Add a raw WHERE condition (AND)
        pub fn whereRaw(self: *Self, sql_fragment: []const u8, values: anytype) *Self {
            self.where_clause.addRaw(sql_fragment, values, .@"and") catch {};
            return self;
        }

        /// Add a raw WHERE condition (OR)
        pub fn orWhereRaw(self: *Self, sql_fragment: []const u8, values: anytype) *Self {
            self.where_clause.addRaw(sql_fragment, values, .@"or") catch {};
            return self;
        }

        // ====================================================================
        // ORDER BY
        // ====================================================================

        /// Add ORDER BY clause
        pub fn orderBy(self: *Self, comptime field: std.meta.FieldEnum(T), order: Order) *Self {
            const col_name = comptime Meta.columnName(field);
            self.order_by_clause.add(col_name, order) catch {};
            return self;
        }

        // ====================================================================
        // LIMIT / OFFSET
        // ====================================================================

        /// Set LIMIT
        pub fn limit(self: *Self, n: i64) *Self {
            self.limit_clause.limit = n;
            return self;
        }

        /// Set OFFSET
        pub fn offset(self: *Self, n: i64) *Self {
            self.limit_clause.offset = n;
            return self;
        }

        // ====================================================================
        // SQL Generation
        // ====================================================================

        /// Build the complete SQL query
        pub fn buildSql(self: *Self) !sql.SqlBuilder {
            var builder = sql.SqlBuilder.init(self.allocator);
            errdefer builder.deinit();

            // SELECT
            try builder.append("SELECT ");
            if (self.select_columns) |cols| {
                try builder.append(cols);
            } else {
                try builder.append(comptime Meta.allColumns());
            }

            // FROM
            try builder.append(" FROM ");
            try builder.append(comptime Meta.tableName());

            // WHERE
            try self.where_clause.build(&builder);

            // ORDER BY
            try self.order_by_clause.build(&builder);

            // LIMIT / OFFSET
            try self.limit_clause.build(&builder);

            return builder;
        }

        // ====================================================================
        // Debug
        // ====================================================================

        /// Get the SQL query string for debugging
        pub const SqlDebug = struct {
            sql_str: []const u8,
            param_count: usize,
            builder: sql.SqlBuilder,

            pub fn deinit(self: *SqlDebug) void {
                self.builder.deinit();
            }
        };

        pub fn toSql(self: *Self) !SqlDebug {
            var builder = try self.buildSql();
            return .{
                .sql_str = builder.toSql(),
                .param_count = builder.paramCount(),
                .builder = builder,
            };
        }

        // ====================================================================
        // Execution
        // ====================================================================

        /// Fetch all matching rows
        pub fn fetchAll(self: *Self, pool: *pg.Pool) !result.QueryResult(T) {
            var builder = try self.buildSql();
            defer builder.deinit();

            var query_result = result.QueryResult(T).init(self.allocator);
            errdefer query_result.deinit();

            try executeWithParams(T, pool, builder, &query_result, self.columns_indicies);

            return query_result;
        }

        /// Fetch a single row (returns null if not found, error if multiple)
        pub fn fetchOne(self: *Self, pool: *pg.Pool) !result.SingleResult(T) {
            // Add LIMIT 2 to detect multiple rows
            const orig_limit = self.limit_clause.limit;
            self.limit_clause.limit = 2;
            defer self.limit_clause.limit = orig_limit;

            var builder = try self.buildSql();
            defer builder.deinit();

            var single_result = result.SingleResult(T).init(self.allocator);
            errdefer single_result.deinit();

            try executeSingleWithParams(T, pool, builder, &single_result, self.columns_indicies);

            return single_result;
        }

        /// Count matching rows
        pub fn count(self: *Self, pool: *pg.Pool) !i64 {
            var builder = sql.SqlBuilder.init(self.allocator);
            defer builder.deinit();

            try builder.append("SELECT COUNT(*) FROM ");
            try builder.append(comptime Meta.tableName());
            try self.where_clause.build(&builder);

            return try executeCountWithParams(pool, builder);
        }

        /// Check if any matching rows exist
        pub fn exists(self: *Self, pool: *pg.Pool) !bool {
            var builder = sql.SqlBuilder.init(self.allocator);
            defer builder.deinit();

            try builder.append("SELECT 1 FROM ");
            try builder.append(comptime Meta.tableName());
            try self.where_clause.build(&builder);
            try builder.append(" LIMIT 1");

            return try executeExistsWithParams(pool, builder);
        }
    };
}

// ============================================================================
// Execution helpers that handle dynamic params
// ============================================================================

fn executeWithParams(
    comptime T: type,
    pool: *pg.Pool,
    builder: sql.SqlBuilder,
    query_result: *result.QueryResult(T),
    columns_indicies: [][]const u8,
) !void {
    const sql_str = builder.toSql();
    const params = builder.params.slice();
    const alloc = query_result.allocator();
    std.debug.print("Params: {s} {any}\n", .{ sql_str, params });

    // Build tuple of params at runtime - we need to handle this dynamically
    var pg_result = try executeRawQuery(pool, sql_str, params);
    defer pg_result.deinit();

    var items = std.array_list.Managed(T).init(alloc);

    while (try pg_result.next()) |row| {
        const mapped = try result.mapRow(T, row, alloc, columns_indicies);
        try items.append(mapped);
    }

    query_result.items = try items.toOwnedSlice();
}

fn executeSingleWithParams(
    comptime T: type,
    pool: *pg.Pool,
    builder: sql.SqlBuilder,
    single_result: *result.SingleResult(T),
    columns_indicies: [][]const u8,
) !void {
    const sql_str = builder.toSql();
    const params = builder.params.slice();
    const alloc = single_result.allocator();

    var pg_result = try executeRawQuery(pool, sql_str, params);
    defer pg_result.deinit();

    if (try pg_result.next()) |row| {
        single_result.value = try result.mapRow(T, row, alloc, columns_indicies);

        if (try pg_result.next()) |_| {
            return error.MultipleRowsFound;
        }
    }
}

fn executeCountWithParams(pool: *pg.Pool, builder: sql.SqlBuilder) !i64 {
    const sql_str = builder.toSql();
    const params = builder.params.slice();

    var pg_result = try executeRawQuery(pool, sql_str, params);
    defer pg_result.deinit();

    if (try pg_result.next()) |row| {
        return try row.get(i64, 0);
    }

    return 0;
}

fn executeExistsWithParams(pool: *pg.Pool, builder: sql.SqlBuilder) !bool {
    const sql_str = builder.toSql();
    const params = builder.params.slice();

    var pg_result = try executeRawQuery(pool, sql_str, params);
    defer pg_result.deinit();

    return (try pg_result.next()) != null;
}

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

/// Execute a raw query with Value params using pg.zig's Stmt API
/// This allows us to bind parameters one at a time at runtime
pub fn executeRawQuery(pool: *pg.Pool, sql_str: []const u8, params: []const sql.Value) !*pg.Result {
    const conn = try pool.acquire();
    errdefer pool.release(conn);

    var stmt = conn.prepare(sql_str) catch |err| {
        if (PgError.fromConn(conn, pool._allocator)) |pg_err| {
            std.debug.print("Postgres Error: {s}\n", .{pg_err.message});
        }
        return err;
    };

    errdefer stmt.deinit();

    // Bind each parameter
    for (params) |param| {
        try bindParam(&stmt, param);
    }

    return stmt.execute() catch |err| {
        if (err == error.PG) {
            // This is the magic line that tells you WHY it failed
            std.debug.print("Postgres Error: {s}\n", .{conn.err.?.message});
        }
        return err;
    };
}

/// Bind a single sql.Value onto a prepared pg.Stmt
fn bindParam(stmt: *pg.Stmt, param: sql.Value) !void {
    switch (param) {
        .int, .int32 => |v| try stmt.bind(v),
        .float => |v| try stmt.bind(v),
        .bool => |v| try stmt.bind(v),
        .string, .bytea, .jsonb => |v| try stmt.bind(v),
        .timestamp => |v| try stmt.bind(v),
        .uuid => |v| try stmt.bind(@as([]const u8, v[0..])),
        .null => try stmt.bind(@as(?i32, null)),
    }
}

/// Execute raw SQL for exec (INSERT/UPDATE/DELETE without results)
pub fn executeRawExec(pool: *pg.Pool, sql_str: []const u8, params: []const sql.Value) !?usize {
    const conn = try pool.acquire();
    defer pool.release(conn);

    var stmt = try conn.prepare(sql_str);
    errdefer stmt.deinit();

    // Bind each parameter
    for (params) |param| {
        try bindParam(&stmt, param);
    }

    var _result = stmt.execute() catch |err| {
        if (err == error.PG) {
            // This is the magic line that tells you WHY it failed
            std.debug.print("Postgres Error: {s}\n", .{conn.err.?.message});
        }
        return err;
    };
    defer _result.deinit();

    // For non-SELECT, we just need affected count
    // pg.zig doesn't expose this directly from execute, need to drain
    var count: usize = 0;
    while (try _result.next()) |_| {
        count += 1;
    }

    return count;
}

// ============================================================================
// Tests
// ============================================================================

test "QueryBuilder SQL generation" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var qb = QueryBuilder(User).init(std.testing.allocator);
    defer qb.deinit();

    _ = qb
        .select(.{ .id, .name })
        .where(.power, .gt, 9000)
        .orderBy(.name, .asc)
        .limit(10);

    var debug = try qb.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "SELECT id, name FROM users WHERE power > $1 ORDER BY name ASC LIMIT $2",
        debug.sql_str,
    );
}
