const std = @import("std");
const print = std.debug.print;
const Tether = @import("server.zig");
const Radix = @import("trees/radix.zig");
const Context = @import("context.zig");

pub const Metrics = @This();
tether: *Tether,

/// The registered route paths, grouped by method, for the
/// `/metrics/allroutes` endpoint.
///
/// One of these belongs to each server instance rather than the process:
/// the lists are allocated from that server's arena, so a global would
/// outlive the memory backing it and a second server would reallocate a
/// slice owned by the first one's freed arena.
pub const EndPoints = struct {
    GET: ?[][]const u8 = null,
    POST: ?[][]const u8 = null,
    PATCH: ?[][]const u8 = null,
    DELETE: ?[][]const u8 = null,
    UPDATE: ?[][]const u8 = null,
    HEAD: ?[][]const u8 = null,
    OPTIONS: ?[][]const u8 = null,
    CONNECT: ?[][]const u8 = null,
    TRACE: ?[][]const u8 = null,
};

/// The endpoint lists `getAllRoutes` reports on.
///
/// `getAllRoutes` is an ordinary handler and so only receives a `*Context`,
/// with no route back to its server — hence this pointer, which `Server.new`
/// sets and `Server.deinit` clears. A process running two servers at once
/// reports whichever registered last; it no longer reads freed memory.
pub var active_end_points: ?*EndPoints = null;

const Methods = enum {
    GET,
    POST,
    PATCH,
    DELETE,
    UPDATE,
};

const methods = [5][]const u8{
    "GET",
    "POST",
    "PATCH",
    "DELETE",
    "UPDATE",
};

pub fn init(target: *Metrics, tether: *Tether) void {
    target.* = .{
        .tether = tether,
    };
}

fn allocateRoute(
    node: Radix.Node,
    buffer: *std.array_list.Managed(u8),
    all_routes: *std.array_list.Managed([]const u8),
    allocator: *std.mem.Allocator,
) !void {
    // Save current buffer length to backtrack later
    const original_len = buffer.items.len;

    // Append this node's prefix to the buffer
    if (node.prefix.len > 0) {
        try buffer.appendSlice(node.prefix);
    }

    // print("\n{s}", .{node.prefix});
    // If this node marks the end of a word, print the accumulated buffer
    if (node.is_end) {
        try buffer.append('/');
        print("{s}\n", .{buffer.items});
        const route = try std.fmt.allocPrint(allocator.*, "{s}", .{buffer.items});
        try all_routes.append(route);
    }

    // Recursively process all children
    var children_itr = node.children.iterator();
    while (children_itr.next()) |child| {
        try allocateRoute(child.value_ptr.*.*, buffer, all_routes, allocator);
    }

    if (node.param_child) |child| {
        if (child.is_end) {
            try buffer.appendSlice(child.prefix);
            print("{s}\n", .{buffer.items});
        }
    }

    // Backtrack: remove this node's prefix to prepare for sibling paths
    buffer.shrinkRetainingCapacity(original_len);
}

// This maps all teh routes the system hhas
pub fn mapRoutes(metrics: *Metrics, end_points: *EndPoints) !void {
    const radix_itr = metrics.tether.routes;
    for (radix_itr, 0..) |route, idx| {
        var all_routes = std.array_list.Managed([]const u8).init(metrics.tether.arena.*);
        const node = route.root.*;
        var buffer = std.array_list.Managed(u8).init(metrics.tether.arena.*);
        try allocateRoute(node, &buffer, &all_routes, metrics.tether.arena);
        const method_str = methods[idx];
        const method = std.meta.stringToEnum(Methods, method_str) orelse return error.Null;
        switch (method) {
            .GET => end_points.GET = try all_routes.toOwnedSlice(),
            .POST => end_points.POST = try all_routes.toOwnedSlice(),
            .DELETE => end_points.DELETE = try all_routes.toOwnedSlice(),
            .PATCH => end_points.PATCH = try all_routes.toOwnedSlice(),
            .UPDATE => end_points.UPDATE = try all_routes.toOwnedSlice(),
        }
    }
}

pub fn getAllRoutes(ctx: *Context) !void {
    const end_points = active_end_points orelse return ctx.ERROR(503, "metrics unavailable");
    try ctx.JSON(EndPoints, end_points.*);
}

pub fn healthCheck(ctx: *Context) !void {
    try ctx.STRING("Success");
}
