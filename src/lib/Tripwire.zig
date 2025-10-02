const std = @import("std");
const Treehouse = @import("treehouse.zig");
const DateTime = @import("DateTime.zig");

const Event = enum {
    HTTP,
    Query,
};

const ErrorType = enum {
    HTTP,
    Query,
    EventLoop,
    RouteCall,
    JsonParse,
    Response,
    StringResponse,
    JsonResponse,
};

const BreadCrumb = struct { event: Event };
pub const Error = struct {
    timestamp: i64 = 0,
    error_name: []const u8 = "",
    line: u32 = 0,
    file: []const u8 = "",
    request: []const u8 = "",
    function: []const u8 = "",
};

// ANSI color codes for prettier output
const Colors = struct {
    const RED = "\x1b[31m";
    const GREEN = "\x1b[32m";
    const YELLOW = "\x1b[33m";
    const BLUE = "\x1b[34m";
    const MAGENTA = "\x1b[35m";
    const CYAN = "\x1b[36m";
    const WHITE = "\x1b[37m";
    const BOLD = "\x1b[1m";
    const DIM = "\x1b[2m";
    const RESET = "\x1b[0m";
};

const BreadCrumbList = std.SinglyLinkedList;
const BreadCrumbNode = struct {
    node: BreadCrumbList.Node = .{},
    data: BreadCrumb = .{},
};

const Tripwire = @This();
var errors_count: usize = 0;
var recorded_error: bool = false;
breadcrumbs: BreadCrumbList = .{},
errors: []Error = undefined,
payloads: []Treehouse.ValueType,
client: *Treehouse,
allocator: *std.mem.Allocator = undefined,
thread: std.Thread = undefined,

pub fn init(tw: *Tripwire, allocator: *std.mem.Allocator) void {
    const errors = allocator.alloc(Error, 1024) catch return;

    const payloads = allocator.alloc(Treehouse.ValueType, 1024) catch |err| {
        std.log.err("Could not alloc payloads Details: {any}\n", .{err});
        return;
    };
    const treehouse: *Treehouse = allocator.create(Treehouse) catch |err| {
        std.log.err("{any}", .{err});
        @panic("Failed to create Treehouse struct");
    };
    treehouse.* = Treehouse.createClient(6401, allocator) catch |err| {
        std.log.err("{any}", .{err});
        @panic("Failed to create client");
    };

    tw.* = .{
        .allocator = allocator,
        .errors = errors,
        .client = treehouse,
        .payloads = payloads,
    };

    tw.thread = std.Thread.spawn(.{}, loopRecordErrors, .{tw}) catch |err| {
        std.log.err("Could not spawn tripwire thread Details: {any}\n", .{err});
        return;
    };
    tw.thread.detach();
}

pub fn deinit(tw: *Tripwire) void {
    tw.allocator.free(tw.errors);
    for (tw.payloads) |p| {
        switch (p) {
            .json => |data| tw.allocator.free(data),
            .string => |data| tw.allocator.free(data),
            else => {},
        }
    }
    tw.allocator.free(tw.payloads);
}

fn formatTimestamp(timestamp: i64, allocator: std.mem.Allocator) ![]const u8 {
    const dt = DateTime.fromTimestamp(timestamp);
    return try dt.format(allocator);
}

fn getBasename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            return path[i + 1 ..];
        }
    }
    return path;
}

fn prettyPrintError(err: Error, allocator: std.mem.Allocator) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var writer = &stdout_writer.interface;

    // Header with error symbol
    try writer.print("\n{s}{s}╭─ 🚨 ERROR DETAILS {s}\n", .{ Colors.RED, Colors.BOLD, Colors.RESET });

    // Error name (most prominent)
    if (err.error_name.len > 0) {
        try writer.print("{s}├─ {s}{s}Error:{s} {s}{s}{s}\n", .{ Colors.RED, Colors.BOLD, Colors.WHITE, Colors.RESET, Colors.RED, err.error_name, Colors.RESET });
    }

    // // Location information
    // if (err.file.len > 0 or err.line > 0) {
    //     const filename = if (err.file.len > 0) getBasename(err.file) else "unknown";
    //     try writer.print("{s}├─ {s}Location:{s} {s}{s}:{d}{s}\n", .{ Colors.RED, Colors.CYAN, Colors.RESET, Colors.WHITE, filename, err.line, Colors.RESET });
    // }

    // Module and function context
    if (err.request.len > 0 or err.function.len > 0) {
        try writer.print("{s}├─ {s}Context:{s} ", .{ Colors.RED, Colors.YELLOW, Colors.RESET });

        if (err.request.len > 0) {
            try writer.print("{s}{s}{s}", .{ Colors.MAGENTA, err.request, Colors.RESET });
        }

        if (err.request.len > 0 and err.function.len > 0) {
            try writer.print("{s}::{s}", .{ Colors.DIM, Colors.RESET });
        }

        if (err.function.len > 0) {
            try writer.print("{s}{s}{s}", .{ Colors.GREEN, err.function, Colors.RESET });
        }

        _ = try writer.write("\n");
    }

    // Timestamp
    if (err.timestamp > 0) {
        const time_str = try formatTimestamp(err.timestamp, allocator);
        defer allocator.free(time_str);
        try writer.print("{s}├─ {s}Time:{s} {s}{s}{s}\n", .{ Colors.RED, Colors.BLUE, Colors.RESET, Colors.WHITE, time_str, Colors.RESET });
    }

    // Footer
    try writer.print("{s}╰─────────────────────────────{s}\n\n", .{ Colors.RED, Colors.RESET });
}

// Alternative compact version
fn prettyPrintErrorCompact(err: Error) void {
    const writer = std.io.getStdOut().writer();

    writer.print("{s}[ERROR]{s} ", .{ Colors.RED + Colors.BOLD, Colors.RESET }) catch return;

    if (err.error_name.len > 0) {
        writer.print("{s}{s}{s} ", .{ Colors.RED, err.error_name, Colors.RESET }) catch return;
    }

    if (err.file.len > 0) {
        const filename = getBasename(err.file);
        writer.print("at {s}{s}:{d}{s} ", .{ Colors.CYAN, filename, err.line, Colors.RESET }) catch return;
    }

    if (err.function.len > 0) {
        writer.print("in {s}{s}(){s} ", .{ Colors.GREEN, err.function, Colors.RESET }) catch return;
    }

    if (err.request.len > 0) {
        writer.print("({s}{s}{s})", .{ Colors.MAGENTA, err.request, Colors.RESET }) catch return;
    }

    _ = writer.write("\n") catch return;
}

pub fn loopRecordErrors(tw: *Tripwire) void {
    while (true) {
        std.Thread.sleep(5_000_000_000);
        if (recorded_error and tw.errors.len > errors_count - 1) {
            prettyPrintError(tw.errors[errors_count - 1], tw.allocator.*) catch return;
            recorded_error = false;
            tw.sendErrors();
        }
        // if (errors_count == 512) {
        //     tw.sendErrors();
        // }
    }
}

// Change this to inlcude and use the printFromSource within debug
// std.debug.printSourceAtAddress(debug_info: *SelfInfo, out_stream: anytype, address: usize, tty_config: io.tty.Config)
pub fn recordError(tw: *Tripwire, err: Error) void {
    tw.errors[errors_count] = err;
    errors_count += 1;
    recorded_error = true;
}

fn sendErrors(tw: *Tripwire) void {
    for (0..errors_count) |i| {
        const err_struct = tw.errors[i];
        defer tw.allocator.free(err_struct.error_name);
        defer tw.allocator.free(err_struct.function);
        const payload = std.json.Stringify.valueAlloc(tw.allocator.*, err_struct, .{}) catch {
            std.log.err("Could not stringify the payload for the errors", .{});
            return;
        };
        tw.payloads[i] = Treehouse.ValueType{
            .json = payload[0..],
        };
    }
    defer {
        for (0..errors_count) |i| {
            const payload = tw.payloads[i];
            tw.allocator.free(payload.json);
        }
        errors_count = 0;
    }
    _ = tw.client.lpushmany(
        "tripwire_error_logs",
        tw.payloads[0..errors_count],
    ) catch return;
}

pub fn getErrors(tw: *Tripwire) ![]Error {
    const resp = try tw.client.lrange("tripwire_error_logs", "0", "-1");
    const values = try Treehouse.commandParser(resp, tw.allocator);
    var errors = try tw.allocator.alloc(Error, values.len);
    for (values, 0..) |value, i| {
        const parsed = try std.json.parseFromSlice(Error, tw.allocator.*, value.json, .{});
        errors[i] = parsed.value;
    }
    return errors;
}

pub fn recordBreadCrumb(tw: *Tripwire) void {
    var bread_crumb = BreadCrumbNode{
        .data = .{ .event = .HTTP },
    };
    tw.breadcrumbs.prepend(&bread_crumb.node);
}

test "lpushmanyAny" {
    var allocator = std.testing.allocator;
    var treehouse = try Treehouse.createClient(6401);
    var _payloads = try allocator.alloc(Treehouse.ValueType, 1);
    defer {
        for (_payloads) |p| {
            allocator.free(p.json);
        }
        allocator.free(_payloads);
    }

    for (0..1) |i| {
        const err_struct = Error{
            .line = 120,
            .error_name = "HTTP",
            .request = "/api/test",
            .function = "createClient",
            .timestamp = 101020201,
            .file = "main.zig",
        };
        const payload = std.json.stringifyAlloc(allocator, err_struct, .{
            .whitespace = .indent_1,
        }) catch {
            std.log.err("Could not stringify the payload for the errors", .{});
            return;
        };
        _payloads[i] = Treehouse.ValueType{
            .json = payload,
        };
    }

    // const resp = try treehouse.set("user:123", .{ .string = "content-1" });
    // const resp = try treehouse.get("user:123");
    const resp = try treehouse.del("user:123");
    std.debug.print("{s}\n", .{resp});
}
