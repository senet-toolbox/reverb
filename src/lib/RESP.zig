const std = @import("std");
const Allocator = std.mem.Allocator;
// const DLinkedList = @import("storage/dll.zig").DLinkedList;

pub const RESP = union(enum) {
    const Self = @This();
    array: struct { values: []RESP, allocator: *Allocator },
    string: []const u8,
    json: []const u8,
    int: i32,
    // dll: *DLinkedList,
    float: f32,
    boolean: bool,
    map: *std.StringHashMap(RESP),

    /// Releases everything a parse allocated for this value, recursively.
    ///
    /// Only call this on values produced by the parser: those own their
    /// strings and child values. Hand-built `RESP`s pointing at literals do
    /// not, and freeing one is undefined behaviour.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        switch (self.*) {
            .array => |v| {
                for (v.values) |*value| value.deinit(allocator);
                allocator.free(v.values);
            },
            .string => |v| allocator.free(v),
            .json => |v| allocator.free(v),
            .map => |m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                m.deinit();
                allocator.destroy(m);
            },
            .int, .float, .boolean => {},
        }
        self.* = undefined;
    }

    /// Argument access helpers.
    ///
    /// A RESP array arrives straight off the wire, so neither its length
    /// nor the type of any element can be assumed. Every argument goes
    /// through these, which turn a malformed request into an error instead
    /// of an out-of-bounds read or a wrong-tag union access.
    const Args = struct {
        values: []const RESP,

        fn at(a: Args, i: usize) !RESP {
            if (i >= a.values.len) return error.MissingArgument;
            return a.values[i];
        }

        fn string(a: Args, i: usize) ![]const u8 {
            const v = try a.at(i);
            if (v != .string) return error.InvalidArgumentType;
            return v.string;
        }

        fn int(a: Args, i: usize) !i32 {
            const v = try a.at(i);
            if (v != .int) return error.InvalidArgumentType;
            return v.int;
        }

        /// Asserts the command carries at least `n` elements including the
        /// verb itself.
        fn arity(a: Args, n: usize) !void {
            if (a.values.len < n) return error.WrongNumberOfArguments;
        }
    };

    /// Interprets `self` as a command.
    ///
    /// The returned `Command` borrows the strings inside `self`; it does not
    /// copy them and does not take ownership. The caller keeps responsibility
    /// for freeing the parsed `RESP` and must keep it alive for as long as the
    /// `Command` is in use.
    pub fn toCommand(self: Self) !?Command {
        return switch (self) {
            .array => |v| {
                const args = Args{ .values = v.values };
                const verb = args.string(0) catch return null;

                if (std.ascii.eqlIgnoreCase(verb, "PING")) {
                    return Command{ .ping = {} };
                }
                if (std.ascii.eqlIgnoreCase(verb, "ECHO")) {
                    try args.arity(2);
                    return Command{ .echo = try args.string(1) };
                }
                if (std.ascii.eqlIgnoreCase(verb, "SET")) {
                    try args.arity(3);
                    return Command{ .set = .{
                        .key = try args.string(1),
                        .value = try args.at(2),
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "JSONSET")) {
                    try args.arity(3);
                    return Command{ .json_set = .{
                        .key = try args.string(1),
                        .value = try args.at(2),
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "JSONGET")) {
                    try args.arity(2);
                    return Command{ .json_get = .{ .key = try args.string(1) } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "GET")) {
                    try args.arity(2);
                    return Command{ .get = .{ .key = try args.string(1) } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "DEL")) {
                    try args.arity(2);
                    return Command{ .del = .{ .key = try args.string(1) } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "LPUSH")) {
                    try args.arity(3);
                    return Command{ .lpush = .{
                        .dll_name = try args.string(1),
                        .dll_new_value = try args.at(2),
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "LSET")) {
                    try args.arity(3);
                    const tag = std.meta.activeTag(try args.at(2));
                    const arr_str = try v.allocator.alloc(RESP, v.values.len - 2);
                    errdefer v.allocator.free(arr_str);

                    // Skip the verb and the list name.
                    for (v.values[2..], 0..) |value, i| {
                        if (tag != std.meta.activeTag(value)) return error.AllValuesMustBeTheSameType;
                        arr_str[i] = value;
                    }

                    return Command{ .lset = .{
                        .dll_name = try args.string(1),
                        .dll_values = arr_str,
                        .tag = tag,
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "LPUSHMANY")) {
                    try args.arity(3);
                    const tag = std.meta.activeTag(try args.at(2));
                    const arr_str = try v.allocator.alloc(RESP, v.values.len - 2);
                    errdefer v.allocator.free(arr_str);

                    // Skip the verb and the list name.
                    for (v.values[2..], 0..) |value, i| {
                        if (tag != std.meta.activeTag(value)) return error.AllValuesMustBeTheSameType;
                        arr_str[i] = value;
                    }

                    return Command{ .lpushmany = .{
                        .dll_name = try args.string(1),
                        .dll_values = arr_str,
                        .tag = tag,
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "HSET")) {
                    try args.arity(3);
                    const arr_resp = try v.allocator.alloc(RESP, v.values.len - 2);
                    errdefer v.allocator.free(arr_resp);

                    for (v.values[2..], 0..) |value, i| {
                        arr_resp[i] = value;
                    }

                    return Command{ .hset = .{
                        .map_name = try args.string(1),
                        .map_values = arr_resp,
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "HGET")) {
                    try args.arity(3);
                    return Command{ .hget = .{
                        .map_name = try args.string(1),
                        .key = try args.string(2),
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "LRANGE")) {
                    try args.arity(4);
                    return Command{ .lrange = .{
                        .dll_name = try args.string(1),
                        .start_index = try args.int(2),
                        .end_range = try args.int(3),
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "SETELEM")) {
                    try args.arity(4);
                    return Command{ .set_elem = .{
                        .dll_name = try args.string(1),
                        .index = try args.int(2),
                        .value = try args.at(3),
                    } };
                }
                if (std.ascii.eqlIgnoreCase(verb, "DELELEM")) {
                    try args.arity(3);
                    return Command{ .del_elem = .{
                        .dll_name = try args.string(1),
                        .index = try args.int(2),
                    } };
                }
                return null;
            },
            .string => |v| {
                if (std.ascii.eqlIgnoreCase(v, "PING")) {
                    return Command{ .ping = {} };
                }
                if (std.ascii.eqlIgnoreCase(v, "GETMETRICS")) {
                    return Command{ .metrics = {} };
                }
                if (std.ascii.eqlIgnoreCase(v, "GETALLKEYS")) {
                    return Command{ .get_all_keys = {} };
                }
                return null;
            },
            // .dll => {
            //     return null;
            // },
            .int =>  {
                return null;
            },
            .float => {
                return null;
            },
            .boolean => {
                return null;
            },
            .map => {
                return null;
            },
            .json => {
                return null;
            },
        };
    }
};

pub const Command = union(enum) {
    echo: []const u8,
    ping: void,
    get: struct { key: []const u8 },
    set: struct { key: []const u8, value: RESP },
    json_set: struct { key: []const u8, value: RESP },
    json_get: struct { key: []const u8 },
    del: struct { key: []const u8 },
    get_all_keys: void,
    metrics: void,
    lpush: struct {
        dll_name: []const u8,
        dll_new_value: RESP,
    },
    lset: struct {
        dll_name: []const u8,
        dll_values: []RESP,
        tag: std.meta.Tag(RESP),
    },
    lpushmany: struct {
        dll_name: []const u8,
        dll_values: []RESP,
        tag: std.meta.Tag(RESP),
    },
    lrange: struct {
        dll_name: []const u8,
        start_index: i32,
        end_range: i32,
    },
    set_elem: struct {
        dll_name: []const u8,
        index: i32,
        value: RESP,
    },
    del_elem: struct {
        dll_name: []const u8,
        index: i32,
    },
    hget: struct {
        map_name: []const u8,
        key: []const u8,
    },
    hset: struct {
        map_name: []const u8,
        map_values: []RESP,
    },
};

pub const CommandError = error{
    CommandNotFound,
};

// test "multi command" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     var allocator = gpa.allocator();
//     var arr_set = [_]RESP{
//         RESP{ .string = "SET" },
//         RESP{ .string = "age" },
//         RESP{ .int = 12 },
//         RESP{ .string = "SET" },
//         RESP{ .string = "name" },
//         RESP{ .string = "Vic" },
//         RESP{ .string = "SET" },
//         RESP{ .string = "height" },
//         RESP{ .int = 175 },
//         RESP{ .string = "LPUSH" },
//         RESP{ .string = "DLLNAME" },
//         RESP{ .string = "DLLVALUE" },
//         RESP{ .string = "GET" },
//         RESP{ .string = "name" },
//         RESP{ .string = "LRANGE" },
//         RESP{ .string = "DLLNAME" },
//         RESP{ .int = 0 },
//         RESP{ .int = 1 },
//         RESP{ .string = "LPUSHMANY" },
//         RESP{ .string = "DLLNAME" },
//         RESP{ .string = "one" },
//         RESP{ .string = "two" },
//         RESP{ .string = "three" },
//         RESP{ .string = "four" },
//     };
//     const resp = RESP{ .array = .{ .values = &arr_set, .allocator = &allocator } };
//     var cmd_values = resp;
//     const len = resp.array.values.len;
//     var pos_command: u16 = 0;
//     switch (resp) {
//         .array => {
//             while (pos_command < len) {
//                 cmd_values.array.values = resp.array.values[pos_command..];
//                 const cmd = try cmd_values.toCommand();
//                 // std.debug.print("\narray: {any}\n", .{cmd_values});
//                 // std.debug.print("\nCommand: {any}\n", .{cmd.?});
//                 // std.debug.print("\npos: {d}\n", .{pos_command});
//                 switch (cmd.?) {
//                     .ping => {
//                         pos_command += 1;
//                     },
//                     .echo => {
//                         pos_command += 2;
//                     },
//                     .set => {
//                         pos_command += 3;
//                     },
//                     .json_set => {
//                         pos_command += 3;
//                     },
//                     .get => {
//                         pos_command += 2;
//                     },
//                     .json_get => {
//                         pos_command += 2;
//                     },
//                     .get_all_keys => {
//                         pos_command += 1;
//                     },
//                     .metrics => {
//                         pos_command += 1;
//                     },
//                     .del => {
//                         pos_command += 2;
//                     },
//                     .del_elem => {
//                         pos_command += 2;
//                     },
//                     .set_elem => {
//                         pos_command += 3;
//                     },
//
//                     .lpush => {
//                         pos_command += 3;
//                     },
//                     .lset => |v| {
//                         pos_command += 2;
//                         const len_v: u16 = @intCast(v.dll_values.len);
//                         pos_command += len_v;
//                     },
//                     .lpushmany => |v| {
//                         pos_command += 2;
//                         const len_v: u16 = @intCast(v.dll_values.len);
//                         pos_command += len_v;
//                     },
//                     .lrange => {
//                         pos_command += 4;
//                     },
//                     .hset => |v| {
//                         const num_values: u16 = @intCast(v.map_values.len);
//                         pos_command += num_values + 2;
//                     },
//                     .hget => {
//                         pos_command += 3;
//                     },
//                 }
//             }
//         },
//         else => {},
//     }
// }
//
// test "test to Command" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     var allocator = gpa.allocator();
//
//     var arr_set = [_]RESP{
//         RESP{ .string = "SET" },
//         RESP{ .string = "name" },
//         RESP{ .string = "Vic" },
//     };
//     var resp = RESP{ .array = .{ .values = &arr_set, .allocator = &allocator } };
//
//     var cmd = resp.toCommand();
//     var command = Command{ .set = .{
//         .key = "name",
//         .value = RESP{ .string = "Vic" },
//     } };
//     try std.testing.expectEqualDeep(command, cmd);
//
//     var arr_get = [_]RESP{
//         RESP{ .string = "GET" },
//         RESP{ .string = "name" },
//     };
//
//     resp = RESP{ .array = .{ .values = &arr_get, .allocator = &allocator } };
//
//     cmd = resp.toCommand();
//     command = Command{ .get = .{
//         .key = "name",
//     } };
//     try std.testing.expectEqualDeep(command, cmd);
// }
