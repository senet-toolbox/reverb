//     e - l - l - o
//   /
// h - a - t
//       \
//        v - e
const std = @import("std");
// const print = std.debug.print;
const mem = std.mem;

fn print(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
    // std.debug.print(fmt, args);
}

// const HandlerFunc = *const fn ([]const u8) void;
// const MiddleFunc = *const fn (HandlerFunc, []const u8) HandlerFunc;

const Context = @import("../context.zig");
const Ctx_pm = @import("../handler.zig").Ctx_pm;

const HandlerFunc = *const fn (*Context) anyerror!void;
const MiddleFunc = *const fn (HandlerFunc, *Context) anyerror!HandlerFunc;

const RouteFunc = struct {
    handler_func: HandlerFunc,
    middlewares: []const MiddleFunc,
};

const ParamInfo = struct { param: []const u8, value: []const u8 };
const RouteHandler = struct {
    route_func: ?RouteFunc,
    param_args: ?*std.array_list.Managed(ParamInfo) = null,
};

const Radix = @This();
allocator: std.mem.Allocator,
root: *Node,
universal_mode: bool = false,

fn findCommonPrefix(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) : (i += 1) {}
    return i;
}

pub fn findCommonPrefixSIMDOptimized(a: []const u8, b: []const u8) usize {
    const len = @min(a.len, b.len);
    var i: usize = 0;

    while (i + 8 <= len) : (i += 8) {
        const a_chunk = std.mem.readInt(u64, a[i..][0..8], .little);
        const b_chunk = std.mem.readInt(u64, b[i..][0..8], .little);

        if (a_chunk != b_chunk) {
            const diff = a_chunk ^ b_chunk;
            const byte_offset = @ctz(diff) / 8;
            return i + byte_offset;
        }
    }

    while (i + 4 <= len) : (i += 4) {
        const a_chunk = std.mem.readInt(u32, a[i..][0..4], .little);
        const b_chunk = std.mem.readInt(u32, b[i..][0..4], .little);

        if (a_chunk != b_chunk) {
            const diff = a_chunk ^ b_chunk;
            const byte_offset = @ctz(diff) / 8;
            return i + byte_offset;
        }
    }

    while (i < len and a[i] == b[i]) : (i += 1) {}

    return i;
}

pub const Node = struct {
    prefix: []const u8,
    value: ?RouteFunc,
    query_param: []const u8,
    is_dynamic: bool,
    children: std.StringHashMap(*Node),
    param_child: ?*Node,
    is_end: bool,

    fn findChildWithCommonPrefix(node: *Node, prefix: []const u8) ?*Node {
        var children_itr = node.children.iterator();
        var best_match: ?*Node = null;
        var max_common_len: usize = 0;

        while (children_itr.next()) |c| {
            const child_prefix = c.value_ptr.*.prefix;
            const common_len = findCommonPrefixSIMDOptimized(child_prefix, prefix);
            if (common_len > max_common_len) {
                max_common_len = common_len;
                best_match = c.value_ptr.*;
            }
        }
        return best_match;
    }

    fn splitNode(
        self: *Node,
        at: usize,
        allocator: std.mem.Allocator,
    ) !*Node {
        const new_node = try allocator.create(Node);
        new_node.* = Node{
            .prefix = self.prefix[at..],
            .value = self.value,
            .query_param = self.query_param,
            .is_dynamic = self.is_dynamic,
            .children = self.children,
            .param_child = self.param_child,
            .is_end = self.is_end,
        };

        self.prefix = self.prefix[0..at];
        self.children = std.StringHashMap(*Node).init(allocator);
        try self.children.put(new_node.prefix, new_node);
        self.value = null;
        self.is_end = false;
        self.param_child = null;
        self.query_param = "";

        return new_node;
    }
};

const V32 = @Vector(32, u8);
const V64 = @Vector(64, u8);
const V128 = @Vector(128, u8);

pub fn init(target: *Radix, arena: std.mem.Allocator) !void {
    const root_node = try arena.create(Node);
    root_node.* = Node{
        .prefix = "",
        .value = null,
        .query_param = "",
        .is_dynamic = false,
        .children = std.StringHashMap(*Node).init(arena),
        .param_child = null,
        .is_end = false,
    };
    target.* = .{
        .root = root_node,
        .allocator = arena,
    };
}

fn newNode(
    radix: *Radix,
    prefix: []const u8,
    value: ?RouteFunc,
    query_param: []const u8,
    is_end: bool,
) !*Node {
    const node = try radix.allocator.create(Node);
    node.* = Node{
        .prefix = prefix,
        .value = value,
        .query_param = query_param,
        .is_dynamic = false,
        .children = std.StringHashMap(*Node).init(radix.allocator),
        .param_child = null,
        .is_end = is_end,
    };
    return node;
}

pub fn findNeedle(slice: []const u8, needle: u8) usize {
    var j: usize = 0;
    while (j < slice.len) : (j += 1) {
        if (slice[j] == needle) return j;
    }
    return slice.len;
}

pub fn searchRoute(radix: *const Radix, path: []const u8) !?RouteHandler {
    if (radix.universal_mode) {
        return RouteHandler{
            .route_func = radix.root.value,
        };
    }
    var param_args: ?*std.array_list.Managed(ParamInfo) = null;
    var node = radix.root;
    var start: usize = 1;

    if (path.len == 1) {
        if (node.is_end) {
            return RouteHandler{
                .route_func = node.value,
            };
        }
    }

    while (start < path.len) : (start += 1) {
        if (path[start] == '/') continue;
        if (path[start] == ' ') break;
        if (path[start] == 0) break;
        if (start >= path.len) break;
        const end = findNeedle(path[start..], '/') + start;
        const segment = path[start..end];
        start = end;

        print("  [search] segment='{s}', node.prefix='{s}', node.is_end={}, node.children.count()={}, has_param_child={}\n", .{
            segment,
            node.prefix,
            node.is_end,
            node.children.count(),
            node.param_child != null,
        });

        var remaining = segment;
        var matched_fully = true;
        while (remaining.len > 0) {
            const match = node.findChildWithCommonPrefix(remaining) orelse {
                print("    [search] no child with common prefix for remaining='{s}'\n", .{remaining});
                matched_fully = false;
                break;
            };
            const common_len = findCommonPrefixSIMDOptimized(match.prefix, remaining);
            print("    [search] found child prefix='{s}', common_len={}, match.prefix.len={}\n", .{ match.prefix, common_len, match.prefix.len });
            if (common_len != match.prefix.len) {
                print("    [search] partial match only, returning null\n", .{});
                return null;
            }
            remaining = remaining[common_len..];
            node = match;
        }

        if (!matched_fully) {
            if (node.param_child) |dynamic_child| {
                print("    [search] falling back to dynamic child, query_param='{s}'\n", .{dynamic_child.query_param});
                if (param_args == null) {
                    param_args = try radix.allocator.create(std.array_list.Managed(ParamInfo));
                    param_args.?.* = std.array_list.Managed(ParamInfo).init(radix.allocator);
                }
                try param_args.?.append(.{
                    .param = dynamic_child.query_param,
                    .value = segment,
                });
                node = dynamic_child;
            } else {
                print("    [search] no param child, returning null\n", .{});
                return null;
            }
        }
    }

    print("  [search] final node: prefix='{s}', is_end={}, has_value={}\n", .{ node.prefix, node.is_end, node.value != null });

    if (node.is_end) {
        if (param_args == null) {
            return RouteHandler{
                .route_func = node.value,
            };
        }
        return RouteHandler{
            .route_func = node.value,
            .param_args = param_args.?,
        };
    }
    return null;
}

pub fn addRoute(
    radix: *Radix,
    path: []const u8,
    handler: HandlerFunc,
    middlewares: []const MiddleFunc,
) !void {
    var path_iter = mem.tokenizeScalar(u8, path, '/');
    try radix.insert(&path_iter, handler, middlewares);
}

pub fn addUniversalRoute(
    radix: *Radix,
    handler: HandlerFunc,
    middlewares: []const MiddleFunc,
) !void {
    radix.universal_mode = true;
    const route_func = RouteFunc{
        .handler_func = handler,
        .middlewares = middlewares,
    };
    radix.root.value = route_func;
}

fn insert(
    radix: *Radix,
    segments: *mem.TokenIterator(u8, .scalar),
    handler: HandlerFunc,
    middlewares: []const MiddleFunc,
) !void {
    var node = radix.root;
    const route_func = RouteFunc{
        .handler_func = handler,
        .middlewares = middlewares,
    };

    if (segments.peek() == null) {
        node.value = route_func;
        node.is_end = true;
        return;
    }

    while (segments.next()) |segment| {
        var segement_remaining = segment;
        const is_dynamic = segment[0] == ':';
        if (is_dynamic) {
            const param = segment[1..];
            print("  [insert] dynamic segment ':{s}' on node prefix='{s}'\n", .{ param, node.prefix });
            if (node.param_child == null) {
                node.param_child = try radix.newNode(":dynamic", null, param, false);
            }
            node = node.param_child.?;
            continue;
        }

        print("  [insert] static segment '{s}' on node prefix='{s}'\n", .{ segment, node.prefix });

        while (segement_remaining.len > 0) {
            const matching_child = node.findChildWithCommonPrefix(segement_remaining);
            if (matching_child) |child| {
                var i: usize = 0;
                while (i < child.prefix.len and i < segement_remaining.len and child.prefix[i] == segement_remaining[i]) : (i += 1) {}

                print("    [insert] found matching child prefix='{s}', common={}, remaining='{s}'\n", .{ child.prefix, i, segement_remaining });

                if (i < child.prefix.len) {
                    print("    [insert] SPLITTING node at {}: '{s}' -> '{s}' + '{s}'\n", .{ i, child.prefix, child.prefix[0..i], child.prefix[i..] });
                    print("    [insert] before split: child.param_child={}, child.is_end={}, child.children.count()={}\n", .{ child.param_child != null, child.is_end, child.children.count() });
                    _ = try child.splitNode(i, radix.allocator);
                    print("    [insert] after split: child.prefix='{s}', child.param_child={}, child.is_end={}, child.children.count()={}\n", .{ child.prefix, child.param_child != null, child.is_end, child.children.count() });
                    // Don't set value or clear param_child on intermediate splits
                    child.prefix = segement_remaining[0..i];
                    child.value = null;
                    child.is_end = false;
                    node = child;
                } else {
                    node = child;
                }
                segement_remaining = segement_remaining[i..];
            } else {
                print("    [insert] no matching child, creating new node for '{s}'\n", .{segement_remaining});
                const new_node = try radix.newNode(
                    segement_remaining,
                    route_func,
                    "",
                    false,
                );
                try node.children.put(segement_remaining, new_node);
                node = new_node;
                break;
            }
        }
    }
    node.value = route_func;
    node.is_end = true;
}

fn printTree(radix: *const Radix) !void {
    var buffer = std.array_list.Managed(u8).init(radix.allocator);
    defer buffer.deinit();
    try printNode(radix.root, &buffer, 0);
}

fn printNode(node: *const Node, buffer: *std.array_list.Managed(u8), depth: usize) !void {
    const original_len = buffer.items.len;
    try buffer.appendSlice(node.prefix);

    // Print indented tree structure
    var indent_buf: [256]u8 = undefined;
    var indent_len: usize = 0;
    for (0..depth) |_| {
        indent_buf[indent_len] = ' ';
        indent_buf[indent_len + 1] = ' ';
        indent_len += 2;
    }
    const indent = indent_buf[0..indent_len];

    print("{s}Node: prefix='{s}' is_end={} has_value={} has_param_child={} children={}\n", .{
        indent,
        node.prefix,
        node.is_end,
        node.value != null,
        node.param_child != null,
        node.children.count(),
    });

    if (node.is_end) {
        print("{s}  -> full path: '{s}'\n", .{ indent, buffer.items });
    }

    var children_itr = node.children.iterator();
    while (children_itr.next()) |child| {
        try printNode(child.value_ptr.*, buffer, depth + 1);
    }

    if (node.param_child) |child| {
        try buffer.appendSlice("/:param");
        print("{s}  [param_child]:\n", .{indent});
        try printNode(child, buffer, depth + 1);
        buffer.shrinkRetainingCapacity(buffer.items.len - 7);
    }

    buffer.shrinkRetainingCapacity(original_len);
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Route handlers exist only to give each route a distinct, identifiable
/// function pointer — the tests compare against these directly rather than
/// merely asserting that *some* handler was found.
fn handleUpdateGroupStatus(_: *Context) anyerror!void {}
fn handleGetErrorGroups(_: *Context) anyerror!void {}
fn handleGetErrors(_: *Context) anyerror!void {}

/// Asserts the search resolved to exactly `expected`, not just to something.
fn expectHandler(result: ?RouteHandler, expected: HandlerFunc) !void {
    const found = result orelse return error.RouteNotFound;
    const route_func = found.route_func orelse return error.RouteHasNoHandler;
    try testing.expectEqual(expected, route_func.handler_func);
}

fn expectParam(result: ?RouteHandler, name: []const u8, value: []const u8) !void {
    const found = result orelse return error.RouteNotFound;
    const args = found.param_args orelse return error.RouteHasNoParams;
    for (args.items) |arg| {
        if (std.mem.eql(u8, arg.param, name)) {
            try testing.expectEqualStrings(value, arg.value);
            return;
        }
    }
    return error.ParamNotFound;
}

test "a parameterised route and its prefix coexist in one tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var radix: Radix = undefined;
    try Radix.init(&radix, arena.allocator());

    // Inserting "/errors/groups" second must not clobber the longer route
    // that already shares its prefix.
    try radix.addRoute("/errors/groups/:id/status", handleUpdateGroupStatus, &[_]MiddleFunc{});
    try radix.addRoute("/errors/groups", handleGetErrorGroups, &[_]MiddleFunc{});

    const parameterised = try radix.searchRoute("/errors/groups/some-uuid/status");
    try expectHandler(parameterised, handleUpdateGroupStatus);
    try expectParam(parameterised, "id", "some-uuid");

    try expectHandler(try radix.searchRoute("/errors/groups"), handleGetErrorGroups);
}

test "a parameterised route resolves as the only route in a tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var radix: Radix = undefined;
    try Radix.init(&radix, arena.allocator());
    try radix.addRoute("/errors/groups/:id/status", handleUpdateGroupStatus, &[_]MiddleFunc{});

    const result = try radix.searchRoute("/errors/groups/some-uuid/status");
    try expectHandler(result, handleUpdateGroupStatus);
    try expectParam(result, "id", "some-uuid");
}

test "separate per-method trees stay independent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The server keeps one tree per HTTP method, so a route registered for
    // POST must not become reachable through the GET tree.
    var post_radix: Radix = undefined;
    try Radix.init(&post_radix, arena.allocator());
    var get_radix: Radix = undefined;
    try Radix.init(&get_radix, arena.allocator());

    try post_radix.addRoute("/errors/groups/:id/status", handleUpdateGroupStatus, &[_]MiddleFunc{});
    try get_radix.addRoute("/errors/groups", handleGetErrorGroups, &[_]MiddleFunc{});

    try expectHandler(
        try post_radix.searchRoute("/errors/groups/some-uuid/status"),
        handleUpdateGroupStatus,
    );
    try expectHandler(try get_radix.searchRoute("/errors/groups"), handleGetErrorGroups);

    // The cross-tree lookups must miss.
    try testing.expectEqual(
        @as(?RouteHandler, null),
        get_radix.searchRoute("/errors/groups/some-uuid/status") catch null,
    );
}

test "sibling routes sharing a prefix each resolve to their own handler" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var radix: Radix = undefined;
    try Radix.init(&radix, arena.allocator());

    try radix.addRoute("/errors", handleGetErrors, &[_]MiddleFunc{});
    try radix.addRoute("/errors/groups", handleGetErrorGroups, &[_]MiddleFunc{});
    try radix.addRoute("/errors/groups/:id/status", handleUpdateGroupStatus, &[_]MiddleFunc{});

    try expectHandler(try radix.searchRoute("/errors"), handleGetErrors);
    try expectHandler(try radix.searchRoute("/errors/groups"), handleGetErrorGroups);
    try expectHandler(
        try radix.searchRoute("/errors/groups/abc/status"),
        handleUpdateGroupStatus,
    );
}

test "unregistered routes do not resolve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var radix: Radix = undefined;
    try Radix.init(&radix, arena.allocator());
    try radix.addRoute("/errors/groups", handleGetErrorGroups, &[_]MiddleFunc{});

    for ([_][]const u8{ "/", "/nope", "/errors", "/errors/groupsss" }) |path| {
        const result = radix.searchRoute(path) catch continue;
        if (result) |found| {
            try testing.expect(found.route_func == null);
        }
    }
}
