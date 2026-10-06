const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Parser = @import("parser.zig");
const RESP = @import("RESP.zig").RESP;
// const utils = @import("../utils/index.zig");

// Every allocation here goes through `self.allocator`, set by
// `createClient`. These used to use `std.heap.c_allocator`, which forced a
// libc dependency on anything that linked this file and gave the caller no
// way to choose or account for the memory. Note that the returned slices
// are still the caller's to free.

const ClientError = error{
    TreehouseRequestNotSupported,
    ValueNotFound,
    FailedToSet,
    FailedToPing,
    TreehouseFailedToGet,
    TreehouseFailedToDel,
    TreehouseFailedToEcho,
    IndexOutOfBounds,
    TreehouseConnectionRefused,
    TreehouseServerError,
};

const ReturnTypes = enum {
    Success,
};

pub const ValueType = union(enum) {
    string: []const u8,
    int: i32,
    float: f32,
    json: []const u8,
};

const Conn = struct {
    fd: c_int,
};

const Self = @This();
client_addr: posix.sockaddr.in,
allocator: Allocator,
// const nw = try posix.write(client_fd, "*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$3\r\nVic\r\n");

/// Parses a dotted-quad IPv4 literal into network byte order.
fn parseIp4(text: []const u8) !u32 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    for (&octets) |*octet| {
        const part = it.next() orelse return error.InvalidIpAddress;
        octet.* = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIpAddress;
    }
    if (it.next() != null) return error.InvalidIpAddress;
    return std.mem.bigToNative(u32, @bitCast(octets));
}

pub fn createClient(port: u16, allocator: *std.mem.Allocator) !Self {
    return Self{
        .client_addr = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = try parseIp4("127.0.0.1"),
        },
        .allocator = allocator.*,
    };
}

fn createConn(self: Self) !posix.socket_t {
    const client_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(client_fd);

    var option_value: i32 = 1; // Enable the option
    const option_value_bytes = std.mem.asBytes(&option_value);
    try posix.setsockopt(client_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, option_value_bytes);
    posix.connect(
        client_fd,
        @ptrCast(&self.client_addr),
        @sizeOf(posix.sockaddr.in),
    ) catch |err| {
        if (err == error.ConnectionRefused) {
            // utils.error_print_str("Error: Cache connection not available");
            return ClientError.TreehouseConnectionRefused;
        } else {
            // utils.error_print_str("Error: Cache Internal server error");
            return ClientError.TreehouseServerError;
        }
    };
    return client_fd;
}

pub fn commandParser(cmd: []const u8, allocator: *std.mem.Allocator) ![]ValueType {
    const resp_value: RESP = try Parser.parse(cmd, allocator);
    switch (resp_value) {
        .string => |s| {
            const values = allocator.create([]ValueType) catch unreachable;
            values.* = [_]ValueType{ValueType{ .string = s }};
            return values;
        },
        .array => |arr| {
            var values = try allocator.alloc(ValueType, arr.values.len);
            for (arr.values, 0..) |e, i| {
                switch (e) {
                    .string => |s| {
                        values[i] = ValueType{
                            .string = s,
                        };
                    },
                    .json => |j| {
                        values[i] = ValueType{
                            .json = j,
                        };
                    },
                    else => {},
                }
            }
            return values;
        },
        else => {},
    }
    return error.FailedToParseCommand;
}

pub fn echo(self: Self, value: []const u8) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const req = try std.fmt.allocPrint(
        self.allocator,
        "*2\r\n$4\r\nECHO\r\n${d}\r\n{s}\r\n",
        .{ value.len, value },
    );

    const nw = try posix.write(client_fd, req);
    if (nw < 0) {
        return ClientError.TreehouseRequestNotSupported;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);

    const resp = rbuf[0..nr];
    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.TreehouseFailedToEcho;
    }
    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, rbuf[0..nr]);
    return s;
}

pub fn set(self: Self, key: []const u8, value_type: ValueType) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);

    var char: u8 = '$';
    var value: []const u8 = "";
    switch (value_type) {
        .string => |v| {
            value = v;
            char = '$';
        },
        .int => |v| {
            var buf: [32]u8 = undefined;
            const number = try std.fmt.bufPrint(&buf, "{d}", .{v});
            value = number;
            char = ':';
        },
        .float => |v| {
            var buf: [32]u8 = undefined;
            const number = try std.fmt.bufPrint(&buf, "{d}", .{v});
            value = number;
            char = ',';
        },
        .json => |v| {
            value = v;
            char = '@';
        },
    }

    const response = try std.fmt.allocPrint(
        self.allocator,
        "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n{c}{d}\r\n{s}\r\n",
        .{ key.len, key, char, value.len, value },
    );

    std.debug.print("{s}\n", .{response});
    const nw = try posix.write(client_fd, response);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);

    const resp = rbuf[0..nr];
    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.FailedToSet;
    }

    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, rbuf[0..nr]);
    return s;
    // return ClientError.Success;
}

const ErrorType = struct {
    err: ClientError,
    err_msg: []const u8,
};

const CommandResult = union(enum) {
    Ok: type,
    Err: anyerror,

    fn unwrap(self: CommandResult) !@TypeOf(self.Ok) {
        return switch (self) {
            .Ok => |value| value,
            .Err => |err| return err,
        };
    }
};

const ErrorContext = struct {
    err: anyerror,
    context: []const u8,

    fn create(err: anyerror, context: []const u8) ErrorContext {
        return .{ .err = err, .context = context };
    }
};

pub fn sendCommand(self: *Self, req: []const u8) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const nw = try posix.write(client_fd, req);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);

    const resp = rbuf[0..nr];
    // if (std.mem.startsWith(u8, resp, "-ERROR")) {
    //     // return ErrorContext.create(error.FailedToSet, resp);
    // }

    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, resp);
    return s;
}

pub fn json_set(self: Self, key: []const u8, value: []const u8) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const response = try std.fmt.allocPrint(
        self.allocator,
        "*3\r\n$7\r\nJSONSET\r\n${d}\r\n{s}\r\n@{d}\r\n{s}\r\n",
        .{ key.len, key, value.len, value },
    );

    const nw = try posix.write(client_fd, response);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);

    const resp = rbuf[0..nr];
    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.FailedToSet;
    }

    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, rbuf[0..nr]);
    return s;
}

const vec_len = 32;
const V = @Vector(vec_len, u8);
fn findIndex(haystack: []const u8, needle: u8) ?usize {
    const splt: V = @splat(@as(u8, needle));
    if (haystack.len >= vec_len) {
        var i: usize = 0;
        while (i + vec_len <= haystack.len) : (i += vec_len) {
            const v = haystack[i..][0..vec_len].*;
            const vec: V = @bitCast(v);
            const mask = vec == splt;
            const bits: u32 = @bitCast(mask);
            if (bits != 0) {
                return i + @ctz(bits);
            }
        }
    }
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }
    return null;
}

pub fn json_get(self: Self, key: []const u8) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const response = try std.fmt.allocPrint(
        self.allocator,
        "*2\r\n$7\r\nJSONGET\r\n${d}\r\n{s}\r\n",
        .{ key.len, key },
    );

    const nw = try posix.write(client_fd, response);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);
    const resp = rbuf[0..nr];

    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.TreehouseFailedToGet;
    }

    const start = findIndex(&rbuf, '{').?;
    const s = try self.allocator.alloc(u8, nr - start);
    std.mem.copyForwards(u8, s, rbuf[start..nr]);
    return s;
}

pub fn get(self: Self, key: []const u8) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const response = try std.fmt.allocPrint(
        self.allocator,
        "*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n",
        .{ key.len, key },
    );

    const nw = try posix.write(client_fd, response);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);
    const resp = rbuf[0..nr];

    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.TreehouseFailedToGet;
    }

    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, rbuf[0..nr]);
    return s;
}

pub fn getAllKeys(self: Self) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const nw = try posix.write(client_fd, "$10\r\nGETALLKEYS\r\n");
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);
    const resp = rbuf[0..nr];

    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.TreehouseFailedToGet;
    }

    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, rbuf[0..nr]);
    return s;
}

pub fn del(self: Self, key: []const u8) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const response = try std.fmt.allocPrint(
        self.allocator,
        "*2\r\n$3\r\nDEL\r\n${d}\r\n{s}\r\n",
        .{ key.len, key },
    );

    const nw = try posix.write(client_fd, response);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);
    const resp = rbuf[0..nr];

    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.TreehouseFailedToDel;
    }

    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, rbuf[0..nr]);
    return s;
}

// "*3\r\n$5\r\nLPUSH\r\n$6\r\nmylist\r\n$3\r\none\r\n";
// *4\r\n$5\r\nLPUSH\r\n$6\r\nmylist\r\n$4\r\nfive\r\n$3\r\nsix\r\n
pub fn lpush(self: Self, llname: []const u8, item_value: ValueType) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);

    var char: u8 = '$';
    var item: []const u8 = "";
    switch (item_value) {
        .string => |v| {
            item = v;
            char = '$';
        },
        .int => |v| {
            var buf: [32]u8 = undefined;
            const number = try std.fmt.bufPrint(&buf, "{d}", .{v});
            item = number;
            char = ':';
        },
        .float => |v| {
            var buf: [32]u8 = undefined;
            const number = try std.fmt.bufPrint(&buf, "{any}", .{v});
            item = number;
            char = ',';
        },
        .json => |v| {
            item = v;
            char = '@';
        },
    }

    const request = try std.fmt.allocPrint(
        self.allocator,
        "*3\r\n$5\r\nLPUSH\r\n${d}\r\n{s}\r\n{c}{d}\r\n{s}\r\n",
        .{ llname.len, llname, char, item.len, item },
    );
    // _ = try posix.write(self.client_fd, "*3\r\n$5\r\nLPUSH\r\n$6\r\nmylist\r\n$4\r\nfive\r\n");
    const nw = try posix.write(client_fd, request);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);
    const resp = rbuf[0..nr];

    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.ValueNotFound;
    }

    const s = try self.allocator.alloc(u8, nr - 1);
    std.mem.copyForwards(u8, s, rbuf[1..nr]);
    return s;
}

/// "*4\r\n$6\r\nLRANGE\r\n$6\r\nmylist\r\n$1\r\n0\r\n$2\r\n-1\r\n"
pub fn lrange(self: Self, ll_name: []const u8, start: []const u8, end: []const u8) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const req = try std.fmt.allocPrint(
        self.allocator,
        "*4\r\n$6\r\nLRANGE\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n",
        .{ ll_name.len, ll_name, start.len, start, end.len, end },
    );
    const nw = try posix.write(client_fd, req);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);
    const resp = rbuf[0..nr];

    if (std.mem.eql(u8, resp, "-ERROR INDEX RANGE")) {
        return ClientError.IndexOutOfBounds;
    }

    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.ValueNotFound;
    }

    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, rbuf[0..nr]);
    return s;
}

pub fn delElem(self: Self, ll_name: []const u8, index: []const u8) ![]const u8 {
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const req = try std.fmt.allocPrint(
        self.allocator,
        "*3\r\n$7\r\nDELELEM\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n",
        .{ ll_name.len, ll_name, index.len, index },
    );
    const nw = try posix.write(client_fd, req);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);
    const resp = rbuf[0..nr];

    if (std.mem.eql(u8, resp, "-ERROR INDEX RANGE")) {
        return ClientError.IndexOutOfBounds;
    }

    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.ValueNotFound;
    }

    const s = try self.allocator.alloc(u8, nr);
    std.mem.copyForwards(u8, s, rbuf[0..nr]);
    return s;
}

// "*3\r\n$5\r\nLPUSH\r\n$6\r\nmylist\r\n$3\r\none\r\n";
// *4\r\n$5\r\nLPUSH\r\n$6\r\nmylist\r\n$4\r\nfive\r\n$3\r\nsix\r\n
pub fn lpushmany(self: Self, llname: []const u8, items: []const ValueType) ![]const u8 {
    const allocator = self.allocator;
    const client_fd = try self.createConn();
    defer posix.close(client_fd);
    const precursor = try std.fmt.allocPrint(
        allocator,
        "*{d}\r\n$9\r\nLPUSHMANY\r\n${d}\r\n{s}\r\n",
        .{ items.len + 2, llname.len, llname },
    );
    defer allocator.free(precursor);
    var input: []u8 = undefined;
    var str_arr_v = try allocator.alloc([]const u8, items.len);

    for (items, 0..) |item, i| {
        switch (item) {
            .string => |v| {
                const response = try std.fmt.allocPrint(
                    allocator,
                    "${d}\r\n{s}\r\n",
                    .{ v.len, v },
                );

                str_arr_v[i] = response;
            },
            .int => |v| {
                const response = try std.fmt.allocPrint(
                    allocator,
                    ":{d}\r\n",
                    .{v},
                );

                str_arr_v[i] = response;
            },
            .float => |v| {
                const response = try std.fmt.allocPrint(
                    allocator,
                    ",{d}\r\n",
                    .{v},
                );

                str_arr_v[i] = response;
            },
            .json => |v| {
                const response = try std.fmt.allocPrint(
                    allocator,
                    "@{d}\r\n{s}\r\n",
                    .{ v.len, v },
                );

                str_arr_v[i] = response;
            },
        }
    }
    // defer {
    //     for (str_arr_v) |v| {
    //         allocator.free(v);
    //     }
    // }
    defer allocator.free(str_arr_v);

    input = try std.mem.join(allocator, "", str_arr_v);
    const final = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ precursor, input },
    );
    defer allocator.free(final);

    // std.debug.print("{s}", .{final});

    // _ = try posix.write(self.client_fd, "*5\r\n$5\r\nLPUSH\r\n$6\r\nmylist\r\n$4\r\nfive\r\n$3\r\nsix\r\n$4\r\nfour\r\n");
    const nw = try posix.write(client_fd, final);
    if (nw < 0) {
        return;
    }
    var rbuf: [65535]u8 = undefined;
    const nr = try posix.read(client_fd, &rbuf);
    const resp = rbuf[0..nr];

    if (std.mem.eql(u8, resp, "-ERROR")) {
        return ClientError.ValueNotFound;
    }

    const s = try allocator.alloc(u8, nr - 1);
    std.mem.copyForwards(u8, s, rbuf[1..nr]);
    return s;
}
