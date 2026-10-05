const std = @import("std");
const pg = @import("pg");
const sql = @import("sql.zig");
const result = @import("result.zig");
const query_mod = @import("query.zig");
const BoundedArray = @import("BoundedArray.zig").BoundedArray;

/// Raw SQL query builder with typed results
pub fn RawBuilder(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        sql_str: []const u8,
        params: BoundedArray(sql.Value, sql.MAX_PARAMS),
        column_indicies: [][]const u8,

        pub fn init(allocator: std.mem.Allocator, sql_string: []const u8, values: anytype) Self {
            var self = Self{
                .allocator = allocator,
                .sql_str = sql_string,
                .params = BoundedArray(sql.Value, sql.MAX_PARAMS){},
                .column_indicies = &[_][]const u8{},
            };

            // Store params
            inline for (std.meta.fields(@TypeOf(values))) |field| {
                self.params.append(sql.Value.from(@field(values, field.name))) catch {};
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.column_indicies.len > 0) self.allocator.free(self.column_indicies);
        }

        /// Provide column names so result mapping knows which columns map to which struct fields.
        /// Pass field enum literals (`.{ .id, .name }`) — same shape as the typed builders.
        pub fn columns(self: *Self, comptime field_enums: anytype) *Self {
            const meta = @import("meta.zig");
            const Meta = meta.ModelMeta(T);
            const indicies = self.allocator.alloc([]const u8, field_enums.len) catch return self;
            Meta.columnsNames(field_enums, indicies);
            self.column_indicies = indicies;
            return self;
        }

        /// Fetch all matching rows
        pub fn fetchAll(self: *Self, pool: *pg.Pool) !result.QueryResult(T) {
            var query_result = result.QueryResult(T).init(self.allocator);
            errdefer query_result.deinit();

            var pg_result = try query_mod.executeRawQuery(pool, self.sql_str, self.params.slice());
            defer pg_result.deinit();

            const alloc = query_result.allocator();
            var items: std.array_list.Managed(T) = .init(alloc);

            // If user didn't provide explicit columns, default to all model columns in order.
            const indicies = if (self.column_indicies.len > 0) self.column_indicies else blk: {
                const meta = @import("meta.zig");
                const Meta = meta.ModelMeta(T);
                const names = try alloc.alloc([]const u8, Meta.field_count);
                inline for (Meta.fields, 0..) |f, i| names[i] = f.name;
                break :blk names;
            };

            while (try pg_result.next()) |row| {
                const mapped = try result.mapRow(T, row, alloc, indicies);
                try items.append(mapped);
            }

            query_result.items = try items.toOwnedSlice();
            return query_result;
        }

        /// Fetch a single row
        pub fn fetchOne(self: *Self, pool: *pg.Pool) !result.SingleResult(T) {
            var single_result = result.SingleResult(T).init(self.allocator);
            errdefer single_result.deinit();

            var pg_result = try query_mod.executeRawQuery(pool, self.sql_str, self.params.slice());
            defer pg_result.deinit();

            const alloc = single_result.allocator();

            const indicies = if (self.column_indicies.len > 0) self.column_indicies else blk: {
                const meta = @import("meta.zig");
                const Meta = meta.ModelMeta(T);
                const names = try alloc.alloc([]const u8, Meta.field_count);
                inline for (Meta.fields, 0..) |f, i| names[i] = f.name;
                break :blk names;
            };

            if (try pg_result.next()) |row| {
                single_result.value = try result.mapRow(T, row, alloc, indicies);

                if (try pg_result.next()) |_| {
                    return error.MultipleRowsFound;
                }
            }

            return single_result;
        }
    };
}

/// Execute raw SQL without typed results (for DDL, etc.)
pub fn rawExec(pool: *pg.Pool, sql_str: []const u8, values: anytype) !?usize {
    var params = BoundedArray(sql.Value, sql.MAX_PARAMS){};

    inline for (std.meta.fields(@TypeOf(values))) |field| {
        try params.append(sql.Value.from(@field(values, field.name)));
    }

    return try query_mod.executeRawExec(pool, sql_str, params.slice());
}

/// Execute raw SQL and get pg.Result directly. Caller owns and must deinit.
pub fn rawQuery(pool: *pg.Pool, sql_str: []const u8, values: anytype) !*pg.Result {
    var params = BoundedArray(sql.Value, sql.MAX_PARAMS){};

    inline for (std.meta.fields(@TypeOf(values))) |field| {
        try params.append(sql.Value.from(@field(values, field.name)));
    }

    return try query_mod.executeRawQuery(pool, sql_str, params.slice());
}
