const std = @import("std");
const BoundedArray = @import("BoundedArray.zig").BoundedArray;

/// Maximum number of parameters supported in a single query
pub const MAX_PARAMS = 64;

/// A value that can be bound to a SQL parameter
pub const Value = union(enum) {
    int32: i64,
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytea: []const u8,
    jsonb: []const u8,
    timestamp: i64, // microseconds since epoch
    uuid: [16]u8,
    null: void,

    pub fn from(val: anytype) Value {
        const T = @TypeOf(val);
        const info = @typeInfo(T);

        // If already a Value, return as-is
        if (T == Value) {
            return val;
        }

        // Handle optionals
        if (info == .optional) {
            if (val) |v| {
                return Value.from(v);
            } else {
                return .null;
            }
        }

        // Handle specific types
        if (T == []const u8 or T == []u8) {
            return .{ .string = val };
        }

        if (comptime isStringLiteral(T)) {
            return .{ .string = val };
        }

        switch (info) {
            .int, .comptime_int => return .{ .int = @intCast(val) },
            .float, .comptime_float => return .{ .float = @floatCast(val) },
            .bool => return .{ .bool = val },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    return .{ .string = val };
                }
                @compileError("Unsupported pointer type for SQL value");
            },
            else => @compileError("Unsupported type for SQL value: " ++ @typeName(T)),
        }
    }
};

fn isStringLiteral(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size != .one) return false;
    const child_info = @typeInfo(ptr.child);
    if (child_info != .array) return false;
    return child_info.array.child == u8;
}

/// SQL builder that accumulates query parts and parameters
pub const SqlBuilder = struct {
    buffer: std.array_list.Managed(u8),
    params: BoundedArray(Value, MAX_PARAMS),

    pub fn init(allocator: std.mem.Allocator) SqlBuilder {
        return .{
            .buffer = std.array_list.Managed(u8).init(allocator),
            .params = BoundedArray(Value, MAX_PARAMS){},
        };
    }

    pub fn deinit(self: *SqlBuilder) void {
        self.buffer.deinit();
    }

    /// Append raw SQL string
    pub fn append(self: *SqlBuilder, sql: []const u8) !void {
        try self.buffer.appendSlice(sql);
    }

    /// Append a single character
    pub fn appendChar(self: *SqlBuilder, char: u8) !void {
        try self.buffer.append(char);
    }

    /// Append formatted SQL
    pub fn appendFmt(self: *SqlBuilder, comptime fmt: []const u8, args: anytype) !void {
        try self.buffer.print(fmt, args);
    }

    /// Add a parameter and return its placeholder ($1, $2, etc.)
    pub fn addParam(self: *SqlBuilder, value: anytype) !void {
        const param_num = self.params.len + 1;
        try self.appendFmt("${d}", .{param_num});
        try self.params.append(Value.from(value));
    }

    /// Add parameter placeholder without the value (for comptime building)
    pub fn addParamPlaceholder(self: *SqlBuilder) !usize {
        const param_num = self.params.len + 1;
        try self.appendFmt("${d}", .{param_num});
        return param_num;
    }

    /// Store a parameter value
    pub fn storeParam(self: *SqlBuilder, value: anytype) !void {
        try self.params.append(Value.from(value));
    }

    /// Get the current SQL string
    pub fn toSql(self: *const SqlBuilder) []const u8 {
        return self.buffer.items;
    }

    /// Get parameter count
    pub fn paramCount(self: *const SqlBuilder) usize {
        return self.params.len;
    }

    /// Clear the builder for reuse
    pub fn reset(self: *SqlBuilder) void {
        self.buffer.clearRetainingCapacity();
        self.params.len = 0;
    }
};

/// Format an identifier (table name, column name) - escapes if needed
pub fn formatIdentifier(writer: anytype, identifier: []const u8) !void {
    // Check if identifier needs quoting
    var needs_quote = false;
    for (identifier) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            needs_quote = true;
            break;
        }
    }

    if (needs_quote) {
        try writer.writeByte('"');
        for (identifier) |c| {
            if (c == '"') {
                try writer.writeAll("\"\"");
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeByte('"');
    } else {
        try writer.writeAll(identifier);
    }
}

/// Escape a string literal for SQL (for debugging only - use params in real queries!)
pub fn escapeString(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    try result.append('\'');
    for (str) |c| {
        if (c == '\'') {
            try result.appendSlice("''");
        } else {
            try result.append(c);
        }
    }
    try result.append('\'');

    return result.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "Value.from" {
    const int_val = Value.from(42);
    try std.testing.expectEqual(Value{ .int = 42 }, int_val);

    const str_val = Value.from("hello");
    try std.testing.expectEqualStrings("hello", str_val.string);

    const bool_val = Value.from(true);
    try std.testing.expectEqual(Value{ .bool = true }, bool_val);

    const null_val = Value.from(@as(?i32, null));
    try std.testing.expectEqual(Value.null, null_val);
}

test "SqlBuilder basic" {
    var builder = SqlBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.append("SELECT * FROM users WHERE id = ");
    try builder.addParam(42);
    try builder.append(" AND name = ");
    try builder.addParam("Goku");

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = $1 AND name = $2", builder.toSql());
    try std.testing.expectEqual(@as(usize, 2), builder.paramCount());
}

test "formatIdentifier" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try formatIdentifier(fbs.writer(), "users");
    try std.testing.expectEqualStrings("users", fbs.getWritten());

    fbs.reset();
    try formatIdentifier(fbs.writer(), "user-table");
    try std.testing.expectEqualStrings("\"user-table\"", fbs.getWritten());
}
