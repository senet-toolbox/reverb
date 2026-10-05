const std = @import("std");
const pg = @import("pg");
const meta = @import("meta.zig");
const ops = @import("operators.zig");
const sql = @import("sql.zig");
const clause = @import("clause.zig");
const query_mod = @import("query.zig");

const Op = ops.Op;
const Connector = clause.Connector;

/// UPDATE query builder
pub fn UpdateBuilder(comptime T: type) type {
    const Meta = meta.ModelMeta(T);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        set_clauses: std.array_list.Managed(SetClause),
        where_clause: clause.WhereClause,

        const SetClause = struct {
            column: []const u8,
            value: sql.Value,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .set_clauses = std.array_list.Managed(SetClause).init(allocator),
                .where_clause = clause.WhereClause.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.set_clauses.deinit();
            self.where_clause.deinit();
        }

        // ====================================================================
        // SET
        // ====================================================================

        /// Set columns to update
        pub fn set(self: *Self, data: anytype) *Self {
            const DataType = @TypeOf(data);
            const data_fields = std.meta.fields(DataType);

            inline for (data_fields) |field| {
                const field_enum = @field(std.meta.FieldEnum(T), field.name);
                const col_name = comptime Meta.columnName(field_enum);
                const value = sql.Value.from(@field(data, field.name));

                self.set_clauses.append(.{
                    .column = col_name,
                    .value = value,
                }) catch {};
            }

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

        // ====================================================================
        // SQL Generation
        // ====================================================================

        pub fn buildSql(self: *Self) !sql.SqlBuilder {
            var builder = sql.SqlBuilder.init(self.allocator);
            errdefer builder.deinit();

            if (self.set_clauses.items.len == 0) {
                return error.NoColumnsToUpdate;
            }

            // UPDATE table
            try builder.append("UPDATE ");
            try builder.append(comptime Meta.tableName());

            // SET
            try builder.append(" SET ");

            for (self.set_clauses.items, 0..) |sc, i| {
                if (i > 0) try builder.append(", ");
                try builder.append(sc.column);
                try builder.append(" = ");
                try builder.storeParam(sc.value);
                try builder.appendFmt("${d}", .{builder.paramCount()});
            }

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

        /// Execute the update and return affected row count
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

test "UpdateBuilder SQL" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var ub = UpdateBuilder(User).init(std.testing.allocator);
    defer ub.deinit();

    _ = ub
        .set(.{ .power = 9500 })
        .where(.id, .eq, 1);

    var debug = try ub.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "UPDATE users SET power = $1 WHERE id = $2",
        debug.sql_str,
    );
}

test "UpdateBuilder multiple sets" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var ub = UpdateBuilder(User).init(std.testing.allocator);
    defer ub.deinit();

    _ = ub
        .set(.{ .power = 9500 })
        .set(.{ .name = "Kakarot" })
        .where(.id, .eq, 1);

    var debug = try ub.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "UPDATE users SET power = $1, name = $2 WHERE id = $3",
        debug.sql_str,
    );
}
