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

const BreadCrumb = struct { event: Event = .HTTP };
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

/// Upper bound on errors buffered between flushes. `recordError` drops
/// anything beyond this rather than running off the end of the buffer.
pub const max_buffered_errors: usize = 1024;

/// Upper bound on retained breadcrumbs, so a long-lived process cannot
/// grow the list without limit.
pub const max_breadcrumbs: usize = 256;

/// A minimal spinlock.
///
/// `std.Io.Mutex` needs an `Io` instance that Tripwire has no access to,
/// and the critical sections here are a handful of instructions contended
/// only by a flush that runs once every five seconds — so spinning costs
/// less than plumbing an `Io` through would.
const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(l: *SpinLock) void {
        while (l.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(l: *SpinLock) void {
        l.locked.store(false, .release);
    }
};

// `recordError` runs on request threads while the flush loop runs on its
// own thread, so everything they share sits behind this lock.
mutex: SpinLock = .{},
errors_count: usize = 0,
recorded_error: bool = false,
dropped_errors: usize = 0,
breadcrumb_count: usize = 0,
breadcrumbs: BreadCrumbList = .{},
errors: []Error = undefined,
payloads: []Treehouse.ValueType,
client: *Treehouse,
allocator: *std.mem.Allocator = undefined,
thread: std.Thread = undefined,

pub fn init(tw: *Tripwire, allocator: *std.mem.Allocator) void {
    const errors = allocator.alloc(Error, max_buffered_errors) catch return;

    const payloads = allocator.alloc(Treehouse.ValueType, max_buffered_errors) catch |err| {
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
    tw.clearBreadCrumbs();
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

        tw.mutex.lock();
        const pending = tw.errors_count;
        const has_new = tw.recorded_error;
        const most_recent: ?Error = if (pending > 0) tw.errors[pending - 1] else null;
        tw.recorded_error = false;
        tw.mutex.unlock();

        if (!has_new) continue;
        if (most_recent) |err| prettyPrintError(err, tw.allocator.*) catch {};
        tw.sendErrors();
    }
}

// Change this to inlcude and use the printFromSource within debug
// std.debug.printSourceAtAddress(debug_info: *SelfInfo, out_stream: anytype, address: usize, tty_config: io.tty.Config)
/// Buffers `err` for the next flush.
///
/// Errors arrive from request threads faster than the flush loop drains
/// them, so the buffer is bounded: once full, further errors are counted in
/// `dropped_errors` and discarded. Dropping diagnostics is preferable to
/// writing past the end of `errors`.
pub fn recordError(tw: *Tripwire, err: Error) void {
    tw.mutex.lock();
    defer tw.mutex.unlock();

    if (tw.errors_count >= tw.errors.len) {
        tw.dropped_errors += 1;
        return;
    }

    tw.errors[tw.errors_count] = err;
    tw.errors_count += 1;
    tw.recorded_error = true;
}

fn sendErrors(tw: *Tripwire) void {
    // Take the buffered errors out under the lock so request threads can
    // keep recording into a fresh buffer while this flush is in flight.
    tw.mutex.lock();
    const pending = tw.errors_count;
    tw.errors_count = 0;
    tw.mutex.unlock();

    if (pending == 0) return;

    // `built` tracks how many payloads this call actually created. Freeing
    // `pending` of them instead would free stale entries left over from an
    // earlier flush if stringifying stops short.
    var built: usize = 0;
    defer {
        for (tw.payloads[0..built]) |payload| {
            tw.allocator.free(payload.json);
        }
    }

    for (tw.errors[0..pending]) |err_struct| {
        defer tw.allocator.free(err_struct.error_name);
        defer tw.allocator.free(err_struct.function);

        const payload = std.json.Stringify.valueAlloc(tw.allocator.*, err_struct, .{}) catch {
            std.log.err("Could not stringify the payload for the errors", .{});
            break;
        };
        tw.payloads[built] = Treehouse.ValueType{ .json = payload };
        built += 1;
    }

    if (built == 0) return;
    _ = tw.client.lpushmany("tripwire_error_logs", tw.payloads[0..built]) catch return;
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

/// Records a breadcrumb for the current request.
///
/// The node is heap-allocated: the list keeps the pointer after this
/// function returns, so a stack local would dangle immediately.
pub fn recordBreadCrumb(tw: *Tripwire, event: Event) !void {
    tw.mutex.lock();
    defer tw.mutex.unlock();

    // Drop the oldest crumb once the cap is reached, so a long-running
    // process keeps a bounded trail rather than growing forever.
    if (tw.breadcrumb_count >= max_breadcrumbs) {
        if (tw.breadcrumbs.popFirst()) |oldest| {
            const node: *BreadCrumbNode = @fieldParentPtr("node", oldest);
            tw.allocator.destroy(node);
            tw.breadcrumb_count -= 1;
        }
    }

    const node = try tw.allocator.create(BreadCrumbNode);
    node.* = .{ .data = .{ .event = event } };
    tw.breadcrumbs.prepend(&node.node);
    tw.breadcrumb_count += 1;
}

/// Frees every retained breadcrumb.
fn clearBreadCrumbs(tw: *Tripwire) void {
    while (tw.breadcrumbs.popFirst()) |first| {
        const node: *BreadCrumbNode = @fieldParentPtr("node", first);
        tw.allocator.destroy(node);
    }
    tw.breadcrumb_count = 0;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

// Builds a Tripwire with its buffers but without the flush thread or the
// Treehouse connection, so the buffering logic can be exercised on its own.
fn testInstance(allocator: *std.mem.Allocator, capacity: usize) !Tripwire {
    return .{
        .allocator = allocator,
        .errors = try allocator.alloc(Error, capacity),
        .payloads = try allocator.alloc(Treehouse.ValueType, capacity),
        .client = undefined,
    };
}

fn destroyTestInstance(tw: *Tripwire) void {
    tw.clearBreadCrumbs();
    tw.allocator.free(tw.errors);
    tw.allocator.free(tw.payloads);
}

test "recordError buffers errors up to capacity" {
    var allocator = testing.allocator;
    var tw = try testInstance(&allocator, 4);
    defer destroyTestInstance(&tw);

    for (0..3) |i| {
        tw.recordError(.{ .line = @intCast(i), .error_name = "Boom" });
    }

    try testing.expectEqual(@as(usize, 3), tw.errors_count);
    try testing.expectEqual(@as(usize, 0), tw.dropped_errors);
    try testing.expect(tw.recorded_error);
    try testing.expectEqual(@as(u32, 2), tw.errors[2].line);
}

// Without a bound, the 1025th error of a burst writes past the end of the
// buffer. Errors are recorded from request handlers, so the burst is
// remotely reachable.
test "recordError drops overflow instead of writing past the buffer" {
    var allocator = testing.allocator;
    var tw = try testInstance(&allocator, 4);
    defer destroyTestInstance(&tw);

    for (0..10) |i| {
        tw.recordError(.{ .line = @intCast(i), .error_name = "Boom" });
    }

    try testing.expectEqual(@as(usize, 4), tw.errors_count);
    try testing.expectEqual(@as(usize, 6), tw.dropped_errors);
    // The retained errors are the first four, and none were corrupted.
    for (0..4) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), tw.errors[i].line);
    }
}

// The list holds each node after the recording call returns, so a
// stack-allocated node would dangle. Reading the trail back proves the
// nodes are still valid.
test "breadcrumbs stay valid after the recording call returns" {
    var allocator = testing.allocator;
    var tw = try testInstance(&allocator, 4);
    defer destroyTestInstance(&tw);

    try tw.recordBreadCrumb(.HTTP);
    try tw.recordBreadCrumb(.Query);
    try tw.recordBreadCrumb(.HTTP);

    try testing.expectEqual(@as(usize, 3), tw.breadcrumb_count);

    // Most recent first, since each crumb is prepended.
    const expected = [_]Event{ .HTTP, .Query, .HTTP };
    var i: usize = 0;
    var it = tw.breadcrumbs.first;
    while (it) |n| : (it = n.next) {
        const crumb: *BreadCrumbNode = @fieldParentPtr("node", n);
        try testing.expectEqual(expected[i], crumb.data.event);
        i += 1;
    }
    try testing.expectEqual(@as(usize, 3), i);
}

test "breadcrumb trail is bounded" {
    var allocator = testing.allocator;
    var tw = try testInstance(&allocator, 4);
    defer destroyTestInstance(&tw);

    for (0..max_breadcrumbs + 50) |_| {
        try tw.recordBreadCrumb(.HTTP);
    }

    try testing.expectEqual(max_breadcrumbs, tw.breadcrumb_count);

    var counted: usize = 0;
    var it = tw.breadcrumbs.first;
    while (it) |n| : (it = n.next) counted += 1;
    try testing.expectEqual(max_breadcrumbs, counted);
}
