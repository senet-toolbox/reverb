const std = @import("std");
const pg = @import("pg");

/// Result container for multiple rows
pub fn QueryResult(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        arena: std.heap.ArenaAllocator,

        pub fn init(child_allocator: std.mem.Allocator) Self {
            return .{
                .items = &[_]T{},
                .arena = std.heap.ArenaAllocator.init(child_allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn len(self: *const Self) usize {
            return self.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.items.len == 0;
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }
    };
}

/// Result container for a single optional row
pub fn SingleResult(comptime T: type) type {
    return struct {
        const Self = @This();

        value: ?T,
        arena: std.heap.ArenaAllocator,

        pub fn init(child_allocator: std.mem.Allocator) Self {
            return .{
                .value = null,
                .arena = std.heap.ArenaAllocator.init(child_allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// Unwrap the value or return error.NotFound
        pub fn unwrap(self: *const Self) !T {
            return self.value orelse return error.NotFound;
        }

        /// Check if a value exists
        pub fn exists(self: *const Self) bool {
            return self.value != null;
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }
    };
}

/// Maps a pg.Row to a struct T
pub fn mapRow(comptime T: type, row: pg.Row, alloc: std.mem.Allocator, column_indicies: [][]const u8) !T {
    var result: T = undefined;

    // 1. Iterate over the fields of the struct at compile-time
    inline for (std.meta.fields(T)) |field| {

        // 2. Find the index of the column that matches this field's name at runtime
        var found_index: ?usize = null;
        for (column_indicies, 0..) |col_name, i| {
            if (std.mem.eql(u8, col_name, field.name)) {
                found_index = i;
                break;
            }
        }

        if (found_index) |idx| {
            // 3. field.type is known at comptime, so getColumnValue works!
            const value = try getColumnValue(field.type, row, idx, alloc);
            @field(result, field.name) = value;
        } else {
            // Handle the case where a struct field isn't in the SQL result
            // return error.ColumnNotFound;
        }
    }

    return result;
}

/// Maps specific columns to a struct T
pub fn mapRowColumns(comptime T: type, row: anytype, comptime column_indices: anytype, alloc: std.mem.Allocator) !T {
    var result: T = undefined;
    const fields = std.meta.fields(T);

    inline for (fields, 0..) |field, i| {
        const col_idx = column_indices[i];
        const FieldType = field.type;
        const value = try getColumnValue(FieldType, row, col_idx, alloc);
        @field(result, field.name) = value;
    }

    return result;
}

fn getColumnValue(comptime T: type, row: pg.Row, col: usize, alloc: std.mem.Allocator) !T {
    const type_info = @typeInfo(T);

    // Handle optionals
    if (type_info == .optional) {
        const Child = type_info.optional.child;
        // Use optional get
        const maybe_val = try row.get(?Child, col);
        if (maybe_val) |val| {
            if (Child == []const u8 or Child == []u8) {
                return try alloc.dupe(u8, val);
            }
            return val;
        }
        return null;
    }

    // Non-optional types
    const val = try row.get(T, col);

    // Duplicate strings to ensure they outlive the row
    if (T == []const u8 or T == []u8) {
        return try alloc.dupe(u8, val);
    }

    return val;
}

/// Execute a query and map results to structs
pub fn executeQuery(
    comptime T: type,
    pool: *pg.Pool,
    sql_str: []const u8,
    params: anytype,
    result: *QueryResult(T),
) !void {
    const alloc = result.allocator();

    var pg_result = try pool.query(sql_str, params);
    defer pg_result.deinit();

    // Count rows first
    var items = std.array_list.Managed(T).init(alloc);

    while (try pg_result.next()) |row| {
        const mapped = try mapRow(T, row, alloc);
        try items.append(mapped);
    }

    result.items = try items.toOwnedSlice();
}

/// Execute a query expecting a single row
pub fn executeSingleQuery(
    comptime T: type,
    pool: *pg.Pool,
    sql_str: []const u8,
    params: anytype,
    result: *SingleResult(T),
) !void {
    const alloc = result.allocator();

    var pg_result = try pool.query(sql_str, params);
    defer pg_result.deinit();

    if (try pg_result.next()) |row| {
        result.value = try mapRow(T, row, alloc);

        // Check for multiple rows
        if (try pg_result.next()) |_| {
            return error.MultipleRowsFound;
        }
    }
}

/// Execute a count query
pub fn executeCount(
    pool: *pg.Pool,
    sql_str: []const u8,
    params: anytype,
) !i64 {
    var pg_result = try pool.query(sql_str, params);
    defer pg_result.deinit();

    if (try pg_result.next()) |row| {
        return try row.get(i64, 0);
    }

    return 0;
}

/// Execute an exists query
pub fn executeExists(
    pool: *pg.Pool,
    sql_str: []const u8,
    params: anytype,
) !bool {
    var pg_result = try pool.query(sql_str, params);
    defer pg_result.deinit();

    return (try pg_result.next()) != null;
}

// ============================================================================
// Tests
// ============================================================================

test "QueryResult basic" {
    var result = QueryResult(i32).init(std.testing.allocator);
    defer result.deinit();

    try std.testing.expect(result.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), result.len());
}

test "SingleResult basic" {
    var result = SingleResult(i32).init(std.testing.allocator);
    defer result.deinit();

    try std.testing.expect(!result.exists());
    try std.testing.expectError(error.NotFound, result.unwrap());
}
