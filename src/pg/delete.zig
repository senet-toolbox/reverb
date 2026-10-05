const std = @import("std");
const pg = @import("pg");
const meta = @import("meta.zig");
const ops = @import("operators.zig");
const sql = @import("sql.zig");
const clause = @import("clause.zig");
const query_mod = @import("query.zig");

const Op = ops.Op;
const Connector = clause.Connector;

/// DELETE query builder
pub fn DeleteBuilder(comptime T: type) type {
    const Meta = meta.ModelMeta(T);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        where_clause: clause.WhereClause,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .where_clause = clause.WhereClause.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.where_clause.deinit();
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

        // ====================================================================
        // SQL Generation
        // ====================================================================

        pub fn buildSql(self: *Self) !sql.SqlBuilder {
            var builder = sql.SqlBuilder.init(self.allocator);
            errdefer builder.deinit();

            // DELETE FROM table
            try builder.append("DELETE FROM ");
            try builder.append(comptime Meta.tableName());

            // WHERE
            try self.where_clause.build(&builder);

            return builder;
        }

        // ====================================================================
        // Debug
        // ====================================================================

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

        /// Execute the delete and return affected row count
        pub fn exec(self: *Self, pool: *pg.Pool) !usize {
            var builder = try self.buildSql();
            defer builder.deinit();

            const sql_str = builder.toSql();
            const params = builder.params.slice();

            const affected = try query_mod.executeRawExec(pool, sql_str, params);
            return affected orelse 0;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "DeleteBuilder SQL" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var db = DeleteBuilder(User).init(std.testing.allocator);
    defer db.deinit();

    _ = db.where(.power, .lt, 1000);

    var debug = try db.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "DELETE FROM users WHERE power < $1",
        debug.sql_str,
    );
}

test "DeleteBuilder multiple conditions" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var db = DeleteBuilder(User).init(std.testing.allocator);
    defer db.deinit();

    _ = db
        .where(.power, .lt, 1000)
        .orWhere(.name, .eq, "Yamcha");

    var debug = try db.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "DELETE FROM users WHERE power < $1 OR name = $2",
        debug.sql_str,
    );
}
