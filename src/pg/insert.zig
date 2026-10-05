const std = @import("std");
const pg = @import("pg");
const meta = @import("meta.zig");
const sql = @import("sql.zig");
const result = @import("result.zig");
const query_mod = @import("query.zig");

/// INSERT query builder
pub fn InsertBuilder(comptime T: type) type {
    const Meta = meta.ModelMeta(T);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        values_list: std.array_list.Managed(ValueSet),
        returning_columns: ?[]const u8,
        conflict_columns: ?[]const u8,
        conflict_action: ConflictAction,
        update_columns: ?[]const u8,
        columns_indicies: [][]const u8,

        const ValueSet = struct {
            columns: []const u8,
            values: []sql.Value,
        };

        const ConflictAction = enum {
            none,
            do_nothing,
            do_update,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .values_list = std.array_list.Managed(ValueSet).init(allocator),
                .returning_columns = null,
                .conflict_columns = null,
                .conflict_action = .none,
                .update_columns = null,
                .columns_indicies = &[_][]const u8{},
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.values_list.items) |vs| {
                self.allocator.free(vs.values);
                // vs.columns is a comptime literal, no free
            }
            self.values_list.deinit();
        }

        // ====================================================================
        // VALUES
        // ====================================================================

        /// Add values to insert
        pub fn values(self: *Self, data: anytype) *Self {
            const DataType = @TypeOf(data);
            const data_fields = std.meta.fields(DataType);

            // Build column-name list at comptime — same shape every call.
            const columns_str = comptime blk: {
                var s: []const u8 = "";
                for (data_fields, 0..) |field, i| {
                    const field_enum = @field(std.meta.FieldEnum(T), field.name);
                    if (i > 0) s = s ++ ", ";
                    s = s ++ Meta.columnName(field_enum);
                }
                break :blk s;
            };

            // Collect values at runtime
            var vals = self.allocator.alloc(sql.Value, data_fields.len) catch return self;

            inline for (data_fields, 0..) |field, i| {
                vals[i] = sql.Value.from(@field(data, field.name));
            }

            self.values_list.append(.{
                .columns = columns_str,
                .values = vals,
            }) catch {};

            return self;
        }

        // ====================================================================
        // RETURNING
        // ====================================================================

        /// Specify columns to return after insert
        pub fn returning(self: *Self, comptime columns: anytype) *Self {
            self.returning_columns = comptime Meta.columns(columns);
            return self;
        }

        /// Return all columns
        pub fn returningAll(self: *Self) *Self {
            self.returning_columns = comptime Meta.allColumns();
            return self;
        }

        // ====================================================================
        // ON CONFLICT (Upsert)
        // ====================================================================

        /// Specify conflict columns for upsert
        pub fn onConflict(self: *Self, comptime columns: anytype) *Self {
            self.conflict_columns = comptime Meta.columns(columns);
            return self;
        }

        /// Do nothing on conflict
        pub fn doNothing(self: *Self) *Self {
            self.conflict_action = .do_nothing;
            return self;
        }

        /// Update specified columns on conflict
        pub fn doUpdate(self: *Self, comptime columns: anytype) *Self {
            self.conflict_action = .do_update;
            self.update_columns = comptime Meta.columns(columns);
            return self;
        }

        // ====================================================================
        // SQL Generation
        // ====================================================================
        pub fn buildSql(self: *Self) !sql.SqlBuilder {
            var builder = sql.SqlBuilder.init(self.allocator);
            errdefer builder.deinit();

            if (self.values_list.items.len == 0) {
                return error.NoValuesToInsert;
            }

            // INSERT INTO table
            try builder.append("INSERT INTO ");
            try builder.append(comptime Meta.tableName());

            // (columns)
            try builder.append(" (");
            try builder.append(self.values_list.items[0].columns);
            try builder.append(")");

            // VALUES
            try builder.append(" VALUES ");

            for (self.values_list.items, 0..) |vs, row_idx| {
                if (row_idx > 0) try builder.append(", ");
                try builder.append("(");

                for (vs.values, 0..) |val, i| {
                    if (i > 0) try builder.append(", ");
                    try builder.storeParam(val);
                    try builder.appendFmt("${d}", .{builder.paramCount()});
                }

                try builder.append(")");
            }

            // ON CONFLICT
            if (self.conflict_columns) |conflict_cols| {
                try builder.append(" ON CONFLICT (");
                try builder.append(conflict_cols);
                try builder.append(")");

                switch (self.conflict_action) {
                    .do_nothing => {
                        try builder.append(" DO NOTHING");
                    },
                    .do_update => {
                        try builder.append(" DO UPDATE SET ");
                        if (self.update_columns) |update_cols| {
                            // Parse column list and generate SET clause
                            var iter = std.mem.splitSequence(u8, update_cols, ", ");
                            var first = true;
                            while (iter.next()) |col| {
                                if (!first) try builder.append(", ");
                                first = false;
                                try builder.append(col);
                                try builder.append(" = EXCLUDED.");
                                try builder.append(col);
                            }
                        }
                    },
                    .none => {},
                }
            }

            // RETURNING
            if (self.returning_columns) |ret_cols| {
                try builder.append(" RETURNING ");
                try builder.append(ret_cols);
            }

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

        /// Execute the insert and return affected row count
        pub fn exec(self: *Self, pool: *pg.Pool) !ExecResult(T) {
            var builder = try self.buildSql();
            defer builder.deinit();

            const sql_str = builder.toSql();
            const params = builder.params.slice();

            if (self.returning_columns != null) {
                // Return the inserted rows
                var exec_result = ExecResult(T){
                    .rows = result.QueryResult(T).init(self.allocator),
                    .affected_count = 0,
                };
                errdefer exec_result.rows.deinit();

                var pg_result = try query_mod.executeRawQuery(pool, sql_str, params);
                defer pg_result.deinit();

                const alloc = exec_result.rows.allocator();
                var items = std.array_list.Managed(T).init(alloc);

                while (try pg_result.next()) |row| {
                    const mapped = try result.mapRow(T, row, alloc, self.columns_indicies);
                    try items.append(mapped);
                }

                exec_result.rows.items = try items.toOwnedSlice();
                exec_result.affected_count = exec_result.rows.items.len;

                return exec_result;
            } else {
                // Just execute, return count
                const affected = try query_mod.executeRawExec(pool, sql_str, params);
                return ExecResult(T){
                    .rows = result.QueryResult(T).init(self.allocator),
                    .affected_count = affected orelse 0,
                };
            }
        }
    };
}

/// Result of an insert operation
pub fn ExecResult(comptime T: type) type {
    return struct {
        rows: result.QueryResult(T),
        affected_count: usize,

        pub fn deinit(self: *@This()) void {
            self.rows.deinit();
        }
    };
}

pub fn buildSqlFromColumns(
    allocator: std.mem.Allocator,
    table_name: []const u8,
    columns: []const []const u8,
    values_list: []const []const []const u8,
    returning_columns: ?[]const []const u8,
) !sql.SqlBuilder {
    var builder = sql.SqlBuilder.init(allocator);
    errdefer builder.deinit();

    // INSERT INTO table
    try builder.append("INSERT INTO ");
    try builder.append(table_name);

    // (columns)
    try builder.append(" (");
    for (columns, 0..) |col, i| {
        if (i > 0) builder.append(", ") catch unreachable;
        // Get the actual column name from model metadata
        builder.append(col) catch {};
    }
    try builder.append(")");

    // VALUES
    try builder.append(" VALUES ");

    for (values_list, 0..) |vs, row_idx| {
        if (row_idx > 0) try builder.append(", ");
        try builder.append("(");

        for (vs, 0..) |val, i| {
            if (i > 0) try builder.append(", ");
            try builder.storeParam(val);
            try builder.appendFmt("${d}", .{builder.paramCount()});
        }

        try builder.append(")");
    }

    // // ON CONFLICT
    // if (self.conflict_columns) |conflict_cols| {
    //     try builder.append(" ON CONFLICT (");
    //     try builder.append(conflict_cols);
    //     try builder.append(")");
    //
    //     switch (self.conflict_action) {
    //         .do_nothing => {
    //             try builder.append(" DO NOTHING");
    //         },
    //         .do_update => {
    //             try builder.append(" DO UPDATE SET ");
    //             if (self.update_columns) |update_cols| {
    //                 // Parse column list and generate SET clause
    //                 var iter = std.mem.splitSequence(u8, update_cols, ", ");
    //                 var first = true;
    //                 while (iter.next()) |col| {
    //                     if (!first) try builder.append(", ");
    //                     first = false;
    //                     try builder.append(col);
    //                     try builder.append(" = EXCLUDED.");
    //                     try builder.append(col);
    //                 }
    //             }
    //         },
    //         .none => {},
    //     }
    // }

    // RETURNING
    if (returning_columns == null) return builder;
    try builder.append(" RETURNING ");
    for (returning_columns.?, 0..) |ret_cols, i| {
        if (i > 0) builder.append(", ") catch unreachable;
        // Get the actual column name from model metadata
        try builder.append(ret_cols);
    }

    return builder;
}

// ============================================================================
// Tests
// ============================================================================

test "InsertBuilder single insert SQL" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var ib = InsertBuilder(User).init(std.testing.allocator);
    defer ib.deinit();

    _ = ib.values(.{ .name = "Goku", .power = 9001 });

    var debug = try ib.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "INSERT INTO users (name, power) VALUES ($1, $2)",
        debug.sql_str,
    );
}

test "InsertBuilder with returning" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var ib = InsertBuilder(User).init(std.testing.allocator);
    defer ib.deinit();

    _ = ib
        .values(.{ .name = "Goku", .power = 9001 })
        .returning(.{ .id, .name });

    var debug = try ib.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "INSERT INTO users (name, power) VALUES ($1, $2) RETURNING id, name",
        debug.sql_str,
    );
}

test "InsertBuilder batch insert" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var ib = InsertBuilder(User).init(std.testing.allocator);
    defer ib.deinit();

    _ = ib
        .values(.{ .name = "Goku", .power = 9001 })
        .values(.{ .name = "Vegeta", .power = 8500 });

    var debug = try ib.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "INSERT INTO users (name, power) VALUES ($1, $2), ($3, $4)",
        debug.sql_str,
    );
}

test "InsertBuilder upsert" {
    const User = struct {
        id: i32,
        email: []const u8,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    var ib = InsertBuilder(User).init(std.testing.allocator);
    defer ib.deinit();

    _ = ib
        .values(.{ .email = "goku@cc.com", .name = "Goku", .power = 9001 })
        .onConflict(.{.email})
        .doUpdate(.{ .name, .power });

    var debug = try ib.toSql();
    defer debug.deinit();

    try std.testing.expectEqualStrings(
        "INSERT INTO users (email, name, power) VALUES ($1, $2, $3) ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name, power = EXCLUDED.power",
        debug.sql_str,
    );
}
