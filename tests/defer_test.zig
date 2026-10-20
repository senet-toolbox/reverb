//! Deferred replies: a handler hands its request to a worker thread and
//! returns, and the worker answers later with `reply.send`.
//!
//! Each test names the bug it exists to catch. Every one was proven to fail
//! with that bug re-introduced; see `context.md` §8.

const std = @import("std");
const testing = std.testing;
const reverb = @import("reverb");
const harness = @import("harness.zig");

const Harness = harness.Harness;
const Route = harness.Route;
const sleepMs = harness.sleepMs;
const milliTimestamp = reverb.Time.milliTimestamp;

// ---------------------------------------------------------------------------
// The worker pool and its jobs
// ---------------------------------------------------------------------------

const Job = struct {
    reply: *reverb.Reply,
    /// Owned by the job: the request body, echoed back as the response.
    body: []u8,
};

/// How long each job takes. Set per test, before the server starts.
var job_delay_ms: std.atomic.Value(u64) = .init(0);

fn runJob(job: Job) void {
    defer testing.allocator.free(job.body);
    const delay = job_delay_ms.load(.acquire);
    if (delay > 0) sleepMs(delay);
    job.reply.send(200, "text/plain", job.body);
}

const Pool = reverb.Workers(Job, runJob);
var pool: Pool = undefined;
var threaded: std.Io.Threaded = .init_single_threaded;

fn startPool(options: Pool.Options) !void {
    try pool.init(testing.allocator, threaded.io(), options);
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// Echoes the body back, from a worker.
fn deferredEcho(ctx: *reverb.Context) !void {
    const body = try testing.allocator.dupe(u8, ctx.body());
    const reply = ctx.deferReply() catch |err| {
        testing.allocator.free(body);
        return err;
    };
    pool.submit(.{ .reply = reply, .body = body }) catch {
        testing.allocator.free(body);
        reply.send(503, "text/plain", "busy");
    };
}

/// The same response as `deferredEcho`, sent directly.
fn directEcho(ctx: *reverb.Context) !void {
    try ctx.SEND(200, "text/plain", ctx.body());
}

fn deferredWithCookie(ctx: *reverb.Context) !void {
    try ctx.addCookie(.{ .name = "session", .value = "abc", .http_only = true });
    try deferredEcho(ctx);
}

fn directWithCookie(ctx: *reverb.Context) !void {
    try ctx.addCookie(.{ .name = "session", .value = "abc", .http_only = true });
    try directEcho(ctx);
}

/// Defers, then fails. The reply still answers; nothing else may.
fn deferThenFail(ctx: *reverb.Context) !void {
    try deferredEcho(ctx);
    return error.HandlerFailedAfterDefer;
}

fn fast(ctx: *reverb.Context) !void {
    try ctx.STRING("fast");
}

/// The connection slot this request arrived on.
fn slot(ctx: *reverb.Context) !void {
    var buf: [20]u8 = undefined;
    try ctx.STRING(try std.fmt.bufPrint(&buf, "{d}", .{ctx.client.?.slot}));
}

const routes = [_]Route{
    .{ .method = .POST, .path = "/slow", .handler = deferredEcho },
    .{ .method = .POST, .path = "/direct", .handler = directEcho },
    .{ .method = .POST, .path = "/slow-cookie", .handler = deferredWithCookie },
    .{ .method = .POST, .path = "/direct-cookie", .handler = directWithCookie },
    .{ .method = .POST, .path = "/fail", .handler = deferThenFail },
    .{ .method = .GET, .path = "/fast", .handler = fast },
    .{ .method = .GET, .path = "/slot", .handler = slot },
};

/// A server and pool, torn down in the order an application must use:
/// stop the loop, drain the pool, then free the server.
const Fixture = struct {
    h: Harness,

    fn start(delay_ms: u64, pool_options: Pool.Options, options: harness.Options) !Fixture {
        job_delay_ms.store(delay_ms, .release);
        try startPool(pool_options);
        errdefer pool.deinit();
        return .{ .h = try Harness.startWith(testing.allocator, &routes, options) };
    }

    fn stop(f: *Fixture) void {
        f.h.stopServing();
        pool.deinit();
        f.h.stop();
    }
};

fn post(comptime path: []const u8, comptime body: []const u8) *const [
    std.fmt.count(
        "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ path, body.len, body },
    )
    :
    0
]u8 {
    return comptime std.fmt.comptimePrint(
        "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ path, body.len, body },
    );
}

const get_fast = "GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\n";

/// `response` without its `Date` line, which may differ by a second
/// between two otherwise identical responses.
fn withoutDate(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    var first = true;
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Date:")) continue;
        if (!first) try out.appendSlice(allocator, "\r\n");
        first = false;
        try out.appendSlice(allocator, line);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Catches: the slow work still running on the loop thread.
test "a deferred request does not hold up other connections" {
    var f = try Fixture.start(1000, .{ .threads = 1 }, .{});
    defer f.stop();

    var slow_conn = try f.h.connect();
    defer slow_conn.close();
    try slow_conn.setTimeouts(3000);
    try slow_conn.writeAll(post("/slow", "done"));
    sleepMs(20); // let the server take the slow request first

    const started = milliTimestamp();
    const response = try f.h.roundTrip(get_fast);
    defer testing.allocator.free(response);
    const elapsed = milliTimestamp() - started;

    try testing.expectEqualStrings("fast", try harness.body(response));
    try testing.expect(elapsed < 100);

    const slow = try slow_conn.readResponse(testing.allocator);
    defer testing.allocator.free(slow);
    try testing.expectEqual(@as(u16, 200), try harness.statusCode(slow));
    try testing.expectEqualStrings("done", try harness.body(slow));
}

// Catches: the deferred and direct header paths drifting apart, and state
// captured from the request (echoed CORS headers, cookies, the connection
// decision) being lost when the context is reused.
test "a deferred response is the response a direct one would be" {
    var f = try Fixture.start(0, .{}, .{});
    defer f.stop();

    reverb.Context.cors_headers = "Access-Control-Allow-Origin: *\r\n";
    defer reverb.Context.cors_headers = null;

    const cases = [_][2][]const u8{
        .{ "/slow", "/direct" },
        .{ "/slow-cookie", "/direct-cookie" },
    };
    for (cases) |case| {
        var responses: [2][]u8 = undefined;
        for (case, 0..) |path, i| {
            var request_buf: [512]u8 = undefined;
            const request = try std.fmt.bufPrint(
                &request_buf,
                "POST {s} HTTP/1.1\r\nHost: localhost\r\n" ++
                    "Access-Control-Request-Headers: X-Token\r\n" ++
                    "Content-Length: 5\r\n\r\nhello",
                .{path},
            );
            const response = try f.h.roundTrip(request);
            defer testing.allocator.free(response);
            responses[i] = try withoutDate(testing.allocator, response);
        }
        defer for (responses) |r| testing.allocator.free(r);

        try testing.expectEqualStrings(responses[1], responses[0]);
        // And the parts that matter really are there.
        try testing.expect(std.mem.indexOf(u8, responses[0], "Connection: keep-alive\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, responses[0], "Content-Length: 5\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, responses[0], "Access-Control-Allow-Origin: *\r\n") != null);
        try testing.expect(std.mem.indexOf(u8, responses[0], "Access-Control-Allow-Headers: X-Token\r\n") != null);
    }
}

// Catches: reads never resumed after the reply, so the connection hangs.
test "a keep-alive connection serves more requests after a deferred reply" {
    var f = try Fixture.start(10, .{}, .{});
    defer f.stop();

    var conn = try f.h.connect();
    defer conn.close();

    const requests = [_][]const u8{ post("/slow", "one"), post("/slow", "two"), get_fast };
    const bodies = [_][]const u8{ "one", "two", "fast" };
    for (requests, bodies) |request, expected| {
        try conn.writeAll(request);
        const response = try conn.readResponse(testing.allocator);
        defer testing.allocator.free(response);
        try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
        try testing.expectEqualStrings(expected, try harness.body(response));
    }
}

// Catches: requests pipelined behind a deferred one served before it (out of
// order), or never served at all once it is answered.
test "a deferred request and a fast one pipelined together come back in order" {
    var f = try Fixture.start(200, .{}, .{});
    defer f.stop();

    var conn = try f.h.connect();
    defer conn.close();

    try conn.writeAll(post("/slow", "first") ++ get_fast ++ post("/slow", "third"));

    const data = try conn.readResponses(testing.allocator, 3);
    defer testing.allocator.free(data);
    try testing.expectEqual(@as(usize, 3), harness.countResponses(data));

    const first = std.mem.indexOf(u8, data, "\r\n\r\nfirst") orelse return error.MissingFirst;
    const second = std.mem.indexOf(u8, data, "\r\n\r\nfast") orelse return error.MissingSecond;
    const third = std.mem.indexOf(u8, data, "\r\n\r\nthird") orelse return error.MissingThird;
    try testing.expect(first < second and second < third);
}

// Catches: a reply addressed by slot alone, which a new connection in the
// same slot would receive; and buffered bytes kept by slot and socket, which
// a new connection in the same slot, given the same descriptor number by
// the kernel, would inherit.
test "a reply for a closed connection never reaches the next one in its slot" {
    // The reply timeout closes the first connection long before its reply.
    var f = try Fixture.start(400, .{}, .{ .reply_timeout_ms = 100 });
    defer f.stop();

    var old_slot: []u8 = undefined;
    {
        var conn = try f.h.connect();
        defer conn.close();
        try conn.writeAll("GET /slot HTTP/1.1\r\nHost: localhost\r\n\r\n");
        const response = try conn.readResponse(testing.allocator);
        defer testing.allocator.free(response);
        old_slot = try testing.allocator.dupe(u8, try harness.body(response));

        // The partial request behind it stays buffered, unserved.
        try conn.writeAll(post("/slow", "for-the-old-connection") ++ "GET /fa");
        // Closed by the server at the reply timeout, unanswered.
        try testing.expect(try conn.peerClosed(1000));
    }
    defer testing.allocator.free(old_slot);

    var conn = try f.h.connect();
    defer conn.close();
    try conn.writeAll("GET /slot HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const response = try conn.readResponse(testing.allocator);
    defer testing.allocator.free(response);
    // Otherwise the test proves nothing.
    try testing.expectEqualStrings(old_slot, try harness.body(response));

    // Wait out the old job, then check nothing arrived for it.
    sleepMs(500);
    try conn.writeAll(get_fast);
    const data = try conn.readResponses(testing.allocator, 1);
    defer testing.allocator.free(data);
    try testing.expect(std.mem.indexOf(u8, data, "for-the-old-connection") == null);
    try testing.expectEqualStrings("fast", try harness.body(data));
}

// Catches: a blocking submit, which would stall the loop until a worker
// frees up instead of answering at once.
test "a full queue answers 503 at once" {
    var f = try Fixture.start(500, .{ .threads = 1, .queue = 1 }, .{});
    defer f.stop();

    // One for the worker, one for the queue.
    var busy: [2]harness.Connection = undefined;
    for (&busy) |*conn| {
        conn.* = try f.h.connect();
        try conn.setTimeouts(3000);
        try conn.writeAll(post("/slow", "ok"));
        sleepMs(20);
    }
    defer for (&busy) |*conn| conn.close();

    const started = milliTimestamp();
    const response = try f.h.roundTrip(post("/slow", "refused"));
    defer testing.allocator.free(response);
    const elapsed = milliTimestamp() - started;

    try testing.expectEqual(@as(u16, 503), try harness.statusCode(response));
    try testing.expectEqualStrings("busy", try harness.body(response));
    try testing.expect(elapsed < 100);

    for (&busy) |*conn| {
        const ok = try conn.readResponse(testing.allocator);
        defer testing.allocator.free(ok);
        try testing.expectEqual(@as(u16, 200), try harness.statusCode(ok));
    }
}

// Catches: `Connection: close` not captured into the reply.
test "Connection: close is honoured after a deferred reply" {
    var f = try Fixture.start(10, .{}, .{});
    defer f.stop();

    var conn = try f.h.connect();
    defer conn.close();
    try conn.writeAll("POST /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" ++
        "Content-Length: 3\r\n\r\nbye");

    const response = try conn.readResponse(testing.allocator);
    defer testing.allocator.free(response);
    try testing.expectEqualStrings("bye", try harness.body(response));
    try testing.expect(std.mem.indexOf(u8, response, "Connection: close\r\n") != null);
    try testing.expect(try conn.peerClosed(500));
}

// Catches: the automatic error response still sent for a handler that
// failed after deferring, which answers the request twice.
test "a handler error after deferReply produces exactly one response" {
    var f = try Fixture.start(50, .{}, .{});
    defer f.stop();

    var conn = try f.h.connect();
    defer conn.close();
    try conn.writeAll(post("/fail", "once"));

    // Long enough for the reply, and for anything sent after it.
    sleepMs(250);
    try conn.setTimeouts(100);
    const data = try conn.readResponses(testing.allocator, 2);
    defer testing.allocator.free(data);

    try testing.expectEqual(@as(usize, 1), harness.countResponses(data));
    try testing.expectEqual(@as(u16, 200), try harness.statusCode(data));
    try testing.expectEqualStrings("once", try harness.body(data));
}

// Catches: shutting down in the wrong order. Jobs still queued and running
// when the server stops must finish, their replies must be freed, and the
// threads joined -- `std.testing.allocator` fails the test on any leak.
test "shutting down with replies queued and in flight leaks nothing" {
    var f = try Fixture.start(100, .{ .threads = 1, .queue = 8 }, .{});
    var stopped = false;
    defer if (!stopped) f.stop();

    var conns: [4]harness.Connection = undefined;
    for (&conns) |*conn| {
        conn.* = try f.h.connect();
        try conn.writeAll(post("/slow", "late"));
    }
    defer for (&conns) |*conn| conn.close();

    // Every request has been taken; one is running, the rest queued.
    sleepMs(50);
    f.stop();
    stopped = true;

    // The connections went with the server, unanswered.
    for (&conns) |*conn| try testing.expect(try conn.peerClosed(500));
}

// Catches: races in `send` or the post queue.
test "many concurrent deferred requests are each answered with their own body" {
    var f = try Fixture.start(0, .{ .threads = 4, .queue = 64 }, .{});
    defer f.stop();

    const Client = struct {
        fn run(h: *const Harness, id: usize, failures: *std.atomic.Value(usize)) void {
            runOrFail(h, id) catch {
                _ = failures.fetchAdd(1, .acq_rel);
            };
        }

        fn runOrFail(h: *const Harness, id: usize) !void {
            var conn = try h.connect();
            defer conn.close();
            for (0..25) |n| {
                var body_buf: [32]u8 = undefined;
                const body = try std.fmt.bufPrint(&body_buf, "client-{d}-request-{d}", .{ id, n });
                var request_buf: [128]u8 = undefined;
                const request = try std.fmt.bufPrint(
                    &request_buf,
                    "POST /slow HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}",
                    .{ body.len, body },
                );
                try conn.writeAll(request);
                const response = try conn.readResponse(testing.allocator);
                defer testing.allocator.free(response);
                if (try harness.statusCode(response) != 200) return error.WrongStatus;
                if (!std.mem.eql(u8, try harness.body(response), body)) return error.WrongBody;
            }
        }
    };

    var failures: std.atomic.Value(usize) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, id| {
        thread.* = try std.Thread.spawn(.{}, Client.run, .{ &f.h, id, &failures });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(usize, 0), failures.load(.acquire));
}
