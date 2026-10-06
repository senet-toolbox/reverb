const std = @import("std");
const Types = @import("RESP.zig");
const RESP = Types.RESP;
const Command = Types.Command;
const Self = @This();
const testing = std.testing;
const Allocator = std.mem.Allocator;

input: []const u8,
position: usize = 0,
allocator: *Allocator,

pub const ParserError = error{
    EOF,
    unexpected,
    NoLengthPrefix,
    IndexOutOfBounds,
    OutOfMemory,
};

pub fn parse(buffer: []const u8, allocator: *Allocator) !RESP {
    var parser = Self{ .input = buffer, .allocator = allocator };
    return (&parser).parseReq();
}

pub fn peek(self: *Self) !u8 {
    return if (self.position >= self.input.len) ParserError.EOF else self.input[self.position];
}

test "Peek function test" {
    const req = "peek";
    var allocator = std.testing.allocator;
    var parser = Self{ .input = req, .allocator = &allocator };
    var c = try parser.peek();
    try testing.expect(c == 'p');
    parser.position += 1;
    c = try parser.peek();
    try testing.expect(c == 'e');
    parser.position += 1;
    c = try parser.peek();
    try testing.expect(c == 'e');
    parser.position += 1;
    c = try parser.peek();
    try testing.expect(c == 'k');
    parser.position += 1;
    const err = parser.peek();
    try testing.expectError(ParserError.EOF, err);
}

fn pop(self: *Self) !u8 {
    const c = try self.peek();
    self.position += 1;
    return c;
}

test "Pop function test" {
    const req = "peek";
    var allocator = std.testing.allocator;
    var parser = Self{ .input = req, .allocator = &allocator };
    var c = try parser.pop();
    try testing.expect(c == 'p');
    c = try parser.pop();
    try testing.expect(c == 'e');
    c = try parser.pop();
    try testing.expect(c == 'e');
    c = try parser.pop();
    try testing.expect(c == 'k');
    const err = parser.pop();
    try testing.expectError(ParserError.EOF, err);
}

fn parseAndConsumeLengthPrefix(self: *Self) !usize {
    var len: usize = 0;

    while (true) {
        // Here we pop the length off, position = 2
        const v = try self.pop();
        // '0' in ASCII is 48, and '9' is 57, this way we can parse char to usize
        switch (v) {
            '0'...'9' => {
                len *= 10;
                // v = '1' = 49 in ASCII and '0' = 48 so 49 - 48 = 1
                len += v - '0';
            },
            '\r' => {
                // we pop the '\n' since it follows '\r'
                _ = try self.pop();
                if (len == 0) {
                    return ParserError.NoLengthPrefix;
                }
                return len;
            },
            else => return ParserError.EOF,
        }
    }
}

test "ParseAndConsumeLengthPrefix function test" {
    const req = "*2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    var allocator = std.testing.allocator;
    var parser = Self{ .input = req, .allocator = &allocator };
    // Pop the type off the string;
    var c = try parser.pop();
    try testing.expect(c == '*');
    var len = try parser.parseAndConsumeLengthPrefix();
    try testing.expect(len == 2);
    try testing.expect(parser.position == 4);

    c = try parser.pop();
    try testing.expect(c == '$');
    len = try parser.parseAndConsumeLengthPrefix();
    try testing.expect(len == 5);
    try testing.expect(parser.position == 8);

    parser.position += 7;
    c = try parser.pop();
    try testing.expect(c == '$');
    len = try parser.parseAndConsumeLengthPrefix();
    try testing.expect(len == 5);
    try testing.expect(parser.position == 19);

    const err = parser.parseAndConsumeLengthPrefix();
    try testing.expectError(ParserError.EOF, err);
}

fn parseConsumeReturnInt(self: *Self) !i32 {
    var int: i32 = 0;

    while (true) {
        // Here we pop the length off, position = 2
        const v = try self.pop();
        // '0' in ASCII is 48, and '9' is 57, this way we can parse char to usize
        switch (v) {
            '0'...'9' => {
                int *= 10;
                // v = '1' = 49 in ASCII and '0' = 48 so 49 - 48 = 1
                int += v - '0';
            },
            '\r' => {
                // we pop the '\n' since it follows '\r'
                _ = try self.pop();
                return int;
            },
            else => return ParserError.EOF,
        }
    }
}

pub fn parseReq(self: *Self) ParserError!RESP {
    const resp_type = try self.peek();

    return switch (resp_type) {
        ':' => self.parseInt(),
        '+' => self.parseSimpleString(),
        '$' => self.parseBulkString(),
        '@' => self.parseJSON(),
        '*' => self.parseArray(),
        ',' => self.parseFloat(),
        '#' => self.parseBool(),
        '%' => self.parseMap(),
        // '~' => self.parseSet(),
        else => ParserError.unexpected,
    };
}

test "ParseReq function test" {
    var req: []const u8 = ":-232\r\n";
    var allocator = std.testing.allocator;
    var parser = Self{ .input = req, .allocator = &allocator };
    var resp = try parser.parseReq();
    try testing.expectEqualDeep(RESP{ .int = -232 }, resp);

    req = "*2\r\n$5\r\nhello\r\n$5\r\nworld\r\n";
    parser = Self{ .input = req, .allocator = &allocator };
    resp = try parser.parseReq();
    defer resp.deinit(allocator);
    var resp_arr = [_]RESP{ RESP{ .string = "hello" }, RESP{ .string = "world" } };
    try testing.expectEqualDeep(RESP{ .array = .{
        .values = &resp_arr,
        .allocator = &allocator,
    } }, resp);
}

fn parseIntSign(self: *Self) !i32 {
    // Get the sign character ('+' or '-')
    _ = try self.pop();
    const sign_char = try self.pop();
    return switch (sign_char) {
        '+' => 1,
        '-' => -1,
        else => return ParserError.unexpected,
    };
}

fn parseInt(self: *Self) ParserError!RESP {
    const sign = try self.parseIntSign();
    var integer = try self.parseConsumeReturnInt();
    integer = integer * sign;
    return RESP{ .int = integer };
}

// *<number-of-elements>\r\n<element-1>...<element-n>
// *2\r\n$5\r\nhello\r\n$5\r\nworld\r\n
fn parseArray(self: *Self) ParserError!RESP {
    // Remove the resp_type
    _ = try self.pop();
    const len = try self.parseAndConsumeLengthPrefix();
    const arr = RESP{
        .array = .{
            .allocator = self.allocator,
            .values = try self.allocator.alloc(RESP, len),
        },
    };

    // A truncated element leaves the elements already parsed unreachable,
    // so unwind them rather than leaking on malformed input.
    var filled: usize = 0;
    errdefer {
        for (arr.array.values[0..filled]) |*value| value.deinit(self.allocator.*);
        self.allocator.free(arr.array.values);
    }

    for (0..len) |i| {
        const value = try self.parseReq();
        arr.array.values[i] = value;
        filled = i + 1;
    }

    return arr;
}

fn parseSimpleString(self: *Self) ParserError!RESP {
    // Here we pop '+' => position + 1 = 1;
    _ = try self.pop();

    // Slice to the end crlf
    const simple_str: []const u8 = std.mem.sliceTo(self.input[self.position..], '\r');
    // increment the position by the len of the string;
    self.position += simple_str.len;
    // pop off the \r\n;
    _ = try self.pop();
    _ = try self.pop();

    // Copied rather than borrowed from `input`, so that every `.string` a
    // parse produces has the same ownership and `RESP.deinit` can free it
    // unconditionally. Borrowing here would also outlive the request buffer.
    const owned = try self.allocator.alloc(u8, simple_str.len);
    @memcpy(owned, simple_str);
    return RESP{ .string = owned };
}

test "ParseReq simple string test" {
    const req: []const u8 = "+NIMBUS\r\n";
    var allocator = std.testing.allocator;
    var parser = Self{ .input = req, .allocator = &allocator };
    var resp = try parser.parseReq();
    defer resp.deinit(allocator);
    try testing.expectEqualDeep(RESP{ .string = "NIMBUS" }, resp);
}

fn parseBulkString(self: *Self) ParserError!RESP {
    // Here we pop '$' => position + 1 = 1;
    _ = try self.pop();
    const len = try self.parseAndConsumeLengthPrefix();

    if (self.input.len < self.position + len) {
        return ParserError.IndexOutOfBounds;
    }
    const value = self.input[self.position..(self.position + len)];

    const integer = std.fmt.parseInt(i32, value, 10) catch {
        const s = self.allocator.alloc(u8, len) catch {
            return ParserError.OutOfMemory;
        };
        @memcpy(s, value);
        self.position += len;
        try self.popTerminator();
        return RESP{ .string = s };
    };
    self.position += len;
    try self.popTerminator();
    return RESP{ .int = integer };
}

test "parse array bulk string" {
    const req = "*2\r\n$4\r\nECHO\r\n$3\r\nhey\r\n";
    var allocator = std.testing.allocator;
    var resp = try Self.parse(req, &allocator);
    defer resp.deinit(allocator);
    try testing.expectEqualDeep(resp.toCommand(), Command{ .echo = "hey" });
}

fn parseJSON(self: *Self) ParserError!RESP {
    // Here we pop '@' => position + 1 = 1;
    _ = try self.pop();
    const len = try self.parseAndConsumeLengthPrefix();

    if (self.input.len < self.position + len) {
        return ParserError.IndexOutOfBounds;
    }
    const value = self.input[self.position..(self.position + len)];

    const integer = std.fmt.parseInt(i32, value, 10) catch {
        const s = self.allocator.alloc(u8, len) catch {
            return ParserError.OutOfMemory;
        };
        std.mem.copyForwards(u8, s, value);
        self.position += len;
        try self.popTerminator();
        return RESP{ .json = s };
    };
    self.position += len;
    try self.popTerminator();
    return RESP{ .int = integer };
}

test "parse array json string" {
    const json =
        \\{
        \\    "username": "johndoe",
        \\    "email": "john@example.com",
        \\    "preferences": {
        \\        "theme": "dark",
        \\        "notifications": true,
        \\        "music": ["Metallica", "John Mayer"]
        \\    },
        \\    "age": 26,
        \\    "tags": ["admin", "user"]
        \\}
    ;

    var allocator = std.testing.allocator;

    // Built with the testing allocator so the request itself is leak-checked
    // too; it used to come from std.heap.c_allocator, which both forced a
    // libc dependency on the test binary and was never freed.
    const req = try std.fmt.allocPrint(
        allocator,
        "*3\r\n$7\r\nJSONSET\r\n$4\r\njson\r\n@{d}\r\n{s}\r\n",
        .{ json.len, json },
    );
    defer allocator.free(req);
    var resp = try Self.parse(req, &allocator);
    defer resp.deinit(allocator);
    try testing.expectEqualDeep(resp.toCommand(), Command{
        .json_set = .{
            .value = Types.RESP{ .json = json },
            .key = "json",
        },
    });
}

fn parseFloat(self: *Self) ParserError!RESP {
    // pop ','
    _ = try self.pop();
    // iterate till '\r'
    var len: u16 = 0;
    while (true) {
        const v = try self.pop();
        switch (v) {
            '0'...'9' => {
                len += 1;
            },
            '.' => {
                len += 1;
            },
            '\r' => {
                // we pop the '\n' since it follows '\r'
                _ = try self.pop();
                break;
            },
            else => return ParserError.EOF,
        }
    }

    const float = std.fmt.parseFloat(f32, self.input[1 .. len + 1]) catch {
        return ParserError.unexpected;
    };

    return RESP{ .float = float };
}

test "ParseReq float test" {
    const req: []const u8 = ",2.32\r\n";
    var allocator = std.testing.allocator;
    var parser = Self{ .input = req, .allocator = &allocator };
    const resp = try parser.parseReq();
    try testing.expectEqualDeep(RESP{ .float = 2.32 }, resp);
}

fn parseBool(self: *Self) ParserError!RESP {
    // Here we pop '#' => position + 1 = 1;
    _ = try self.pop();
    const c = try self.pop();
    const boolean = switch (c) {
        't' => true,
        'f' => false,
        else => return ParserError.EOF,
    };
    return RESP{ .boolean = boolean };
}

test "ParseReq boolean test" {
    const req: []const u8 = "#t\r\n";
    var allocator = std.testing.allocator;
    var parser = Self{ .input = req, .allocator = &allocator };
    const resp = try parser.parseReq();
    try testing.expectEqualDeep(RESP{ .boolean = true }, resp);
}

// %2\r\n+first\r\n:+1\r\n+second\r\n:+2\r\n
fn parseMap(self: *Self) ParserError!RESP {
    // Remove the resp_type %
    _ = try self.pop();
    const len = try self.parseAndConsumeLengthPrefix();
    // Scratch space holding the flat key/value run before it is folded into
    // the map; freed on every path below, since the map takes the entries.
    const key_value_arr = try self.allocator.*.alloc(RESP, len * 2);
    defer self.allocator.free(key_value_arr);

    var filled: usize = 0;
    errdefer for (key_value_arr[0..filled]) |*value| value.deinit(self.allocator.*);

    for (0..len * 2) |i| {
        key_value_arr[i] = try self.parseReq();
        filled = i + 1;
    }

    const map_ptr = try self.allocator.*.create(std.StringHashMap(RESP));
    errdefer self.allocator.destroy(map_ptr);
    map_ptr.* = std.StringHashMap(RESP).init(self.allocator.*);
    errdefer map_ptr.deinit();

    var idx: usize = 0;
    while (idx + 1 < key_value_arr.len) : (idx += 2) {
        // Keys come off the wire, so the sender controls their type; a
        // non-string key is a malformed request, not a wrong-tag access.
        if (key_value_arr[idx] != .string) return ParserError.unexpected;
        try map_ptr.put(key_value_arr[idx].string, key_value_arr[idx + 1]);
    }

    return RESP{ .map = map_ptr };
}

fn compareHashMapContent(
    map1: *std.StringHashMap(RESP),
    map2: *std.StringHashMap(RESP),
) !bool {
    if (map1.count() != map2.count()) return false;

    var iter = map1.iterator();
    var iter2 = map2.iterator();
    while (iter.next()) |entry| {
        const entry2 = iter2.next().?;
        const value1 = entry.value_ptr.*;
        const value2 = entry2.value_ptr.*;
        try std.testing.expectEqualDeep(value1, value2);
    }

    return true;
}

test "ParseReq map test" {
    const req: []const u8 = "%2\r\n+first\r\n:+1\r\n+second\r\n:+2\r\n";
    var allocator = std.testing.allocator;
    var parser = Self{ .input = req, .allocator = &allocator };
    var resp = try parser.parseReq();
    defer resp.deinit(allocator);
    var map = std.StringHashMap(RESP).init(allocator);
    defer map.deinit();
    try map.put("first", RESP{ .int = 1 });
    try map.put("second", RESP{ .int = 2 });
    try std.testing.expect(try compareHashMapContent(&map, resp.map));
}

fn popTerminator(self: *Self) !void {
    _ = try self.pop();
    _ = try self.pop();
}

test "parse bulk string array" {
    const req = "$4\r\necho\r\n";
    var allocator = std.testing.allocator;
    var resp = try Self.parse(req, &allocator);
    defer resp.deinit(allocator);
    try testing.expectEqualDeep(resp, RESP{ .string = "echo" });
}

test "Parse bulk string array" {
    const req = "*6\r\n$3\r\nSET\r\n$3\r\nage\r\n:+12\r\n$3\r\nSET\r\n$4\r\nname\r\n+Vic\r\n";
    var allocator = std.testing.allocator;
    var resp = try Self.parse(req, &allocator);
    defer resp.deinit(allocator);
    var arr_set = [_]RESP{
        RESP{ .string = "SET" },
        RESP{ .string = "age" },
        RESP{ .int = 12 },
        RESP{ .string = "SET" },
        RESP{ .string = "name" },
        RESP{ .string = "Vic" },
    };
    const expected_resp = RESP{ .array = .{ .values = &arr_set, .allocator = &allocator } };
    try testing.expectEqualDeep(resp, expected_resp);
    try testing.expectEqualDeep(resp.toCommand(), expected_resp.toCommand());
}

test "parse and call command" {
    const req = "*2\r\n$4\r\nECHO\r\n$3\r\nVic\r\n";
    var allocator = std.testing.allocator;
    var resp = try Self.parse(req, &allocator);
    defer resp.deinit(allocator);
    try testing.expectEqualDeep(resp.toCommand(), Command{ .echo = "Vic" });
}
