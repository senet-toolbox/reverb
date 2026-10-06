//! End-to-end HTTP behaviour, exercised over real sockets.

const std = @import("std");
const testing = std.testing;
const reverb = @import("reverb");
const harness = @import("harness.zig");

const Harness = harness.Harness;
const Route = harness.Route;

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn ping(ctx: *reverb.Context) !void {
    try ctx.STRING("pong");
}

fn echoBody(ctx: *reverb.Context) !void {
    try ctx.STRING(ctx.payload);
}

fn showUser(ctx: *reverb.Context) !void {
    const id = if (ctx.param("id")) |p| p.value else "none";
    try ctx.STRING(id);
}

const routes = [_]Route{
    .{ .method = .GET, .path = "/ping", .handler = ping },
    .{ .method = .POST, .path = "/echo", .handler = echoBody },
    .{ .method = .GET, .path = "/users/:id", .handler = showUser },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "serves a simple GET" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    const response = try h.roundTrip("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer allocator.free(response);

    try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
    try testing.expectEqualStrings("pong", try harness.body(response));
}

test "serves a POST body back" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    const response = try h.roundTrip(
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world",
    );
    defer allocator.free(response);

    try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
    try testing.expectEqualStrings("hello world", try harness.body(response));
}

test "extracts a path parameter" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    const response = try h.roundTrip("GET /users/42 HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer allocator.free(response);

    try testing.expectEqualStrings("42", try harness.body(response));
}

// Loom hands the handler exactly what one `read()` returned, so splitting a
// request across packets is Reverb's problem to solve. This is the case that
// `readCompleteHttpRequest` exists for.
test "a request split across packets is reassembled" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var conn = try h.connect();
    defer conn.close();

    const request = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world";

    // Split mid-header, so neither piece is a valid request on its own.
    const split_at = 30;
    try conn.writeAll(request[0..split_at]);
    harness.sleepMs(20);
    try conn.writeAll(request[split_at..]);

    const response = try conn.readResponse(allocator);
    defer allocator.free(response);

    try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
    try testing.expectEqualStrings("hello world", try harness.body(response));
}

// The inverse case: one `read()` delivering a header fragment one byte at a
// time. Slow but it covers every possible split point at once.
test "a request delivered one byte at a time is reassembled" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var conn = try h.connect();
    defer conn.close();

    const request = "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n";
    for (request) |byte| {
        try conn.writeAll(&[_]u8{byte});
    }

    const response = try conn.readResponse(allocator);
    defer allocator.free(response);

    try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
}

test "a keep-alive connection serves several requests" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var conn = try h.connect();
    defer conn.close();

    for (0..3) |_| {
        try conn.writeAll("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
        const response = try conn.readResponse(allocator);
        defer allocator.free(response);

        try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
        try testing.expectEqualStrings("pong", try harness.body(response));
    }
}

test "an unknown route is refused, not crashed on" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    const response = try h.roundTrip("GET /nothing-here HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer allocator.free(response);

    try testing.expectEqual(@as(u16, 404), try harness.statusCode(response));
}

// A body larger than `max_body_size` has to be rejected before it is
// buffered, or a single client could exhaust the server's memory.
test "an oversized body is rejected" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    const request = try std.fmt.allocPrint(
        allocator,
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n",
        .{10 * 1024 * 1024},
    );
    defer allocator.free(request);

    const response = try h.roundTrip(request);
    defer allocator.free(response);

    // 413 is the specific answer; anything in the 4xx range means the
    // request was refused rather than buffered.
    const status = try harness.statusCode(response);
    try testing.expect(status >= 400 and status < 500);
}

test "an oversized header block is rejected" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);

    try request.appendSlice(allocator, "GET /ping HTTP/1.1\r\nHost: localhost\r\n");
    // Comfortably past MAX_HEADER_SIZE (16 KiB).
    for (0..1200) |i| {
        var line: [64]u8 = undefined;
        const written = try std.fmt.bufPrint(&line, "X-Pad-{d}: 0123456789abcdef\r\n", .{i});
        try request.appendSlice(allocator, written);
    }
    try request.appendSlice(allocator, "\r\n");

    var conn = try h.connect();
    defer conn.close();
    // The server may refuse and close mid-write, which surfaces as EPIPE.
    conn.writeAll(request.items) catch {};

    const response = try conn.readResponse(allocator);
    defer allocator.free(response);

    // Either an explicit rejection or a closed connection is acceptable;
    // accepting the request and allocating for it is not.
    if (response.len > 0) {
        const status = try harness.statusCode(response);
        try testing.expect(status >= 400 and status < 500);
    }
}

test "malformed requests are refused, not crashed on" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    const malformed = [_][]const u8{
        "NOTAMETHOD / HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET\r\n\r\n",
        "\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Type:\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Type: zzz/unknown\r\n\r\n",
        " \r\n\r\n",
        "\x00\x00\x00\x00\r\n\r\n",
    };

    for (malformed) |request| {
        var conn = try h.connect();
        defer conn.close();
        conn.writeAll(request) catch continue;

        const response = try conn.readResponse(allocator);
        defer allocator.free(response);
        // The assertion is implicit: the next iteration only happens if the
        // server is still alive.
    }

    // Still serving after all of that.
    const response = try h.roundTrip("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer allocator.free(response);
    try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
}

// A client that opens a connection, sends a partial header and stops is the
// classic slow-loris. Loom's idle timeout is what should reap it; what this
// test pins down is that one such connection does not wedge the loop for
// everyone else.
test "a stalled connection does not block other clients" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var stalled = try h.connect();
    defer stalled.close();
    try stalled.writeAll("GET /ping HTTP/1.1\r\nHost: localhost\r\n");
    // Deliberately no terminator.

    const response = try h.roundTrip("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer allocator.free(response);

    try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
    try testing.expectEqualStrings("pong", try harness.body(response));
}

test "many concurrent connections are all served" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    // Open every connection before reading any reply, so they are genuinely
    // in flight together rather than being served one after another.
    const count = 16;
    var conns: [count]harness.Connection = undefined;
    var opened: usize = 0;
    defer for (conns[0..opened]) |*c| c.close();

    for (&conns) |*c| {
        c.* = try h.connect();
        opened += 1;
        try c.writeAll("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    }

    for (conns[0..opened]) |*c| {
        const response = try c.readResponse(allocator);
        defer allocator.free(response);
        try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
    }
}

test "the server shuts down cleanly on request" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);

    // Prove it is serving, then stop it and prove `listen` returned.
    const response = try h.roundTrip("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    allocator.free(response);

    // `stop` joins the serve thread; reaching the next line means the event
    // loop returned rather than having to be killed.
    h.stop();
}

// Two requests arriving in a single packet. Loom hands over one read's
// worth of bytes, so after serving the first request Reverb has to notice
// the second is already in hand rather than discarding it and waiting for
// a read that never comes.
test "two pipelined requests in one packet both get answered" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var conn = try h.connect();
    defer conn.close();

    try conn.writeAll(
        "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
            "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n",
    );

    const response = try conn.readResponses(allocator, 2);
    defer allocator.free(response);

    try testing.expectEqual(@as(usize, 2), harness.countResponses(response));
    try testing.expectEqual(@as(u16, 200), try harness.statusCode(response));
    // Both bodies came back, so neither request was dropped.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, response, "pong"));
}

// A pipelined pair where the bodies differ, so a response cannot be
// mistaken for the other request's.
test "pipelined requests are answered in order" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var conn = try h.connect();
    defer conn.close();

    try conn.writeAll(
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nfirst" ++
            "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n\r\nsecond",
    );

    const response = try conn.readResponses(allocator, 2);
    defer allocator.free(response);

    try testing.expectEqual(@as(usize, 2), harness.countResponses(response));
    const first_at = std.mem.indexOf(u8, response, "first") orelse return error.FirstBodyMissing;
    const second_at = std.mem.indexOf(u8, response, "second") orelse return error.SecondBodyMissing;
    try testing.expect(first_at < second_at);
}

// The awkward combination: a packet carrying one whole request plus the
// beginning of another. The remainder must be retained, not dropped, and
// not mistaken for a complete request.
test "a whole request plus a partial one is handled correctly" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var conn = try h.connect();
    defer conn.close();

    const second = "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try conn.writeAll("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n" ++ "GET /ping HTTP/1.1\r\nHost: loc");

    // The first request is answered immediately; the fragment waits.
    const first = try conn.readResponses(allocator, 1);
    defer allocator.free(first);
    try testing.expectEqual(@as(usize, 1), harness.countResponses(first));

    // Completing the fragment produces the second answer.
    try conn.writeAll(second[second.len - 11 ..]);
    const rest = try conn.readResponses(allocator, 1);
    defer allocator.free(rest);
    try testing.expectEqual(@as(usize, 1), harness.countResponses(rest));
    try testing.expectEqual(@as(u16, 200), try harness.statusCode(rest));
}

// A chunked request must be refused, not silently framed as having no
// body. If it were, the chunk data would stay in the buffer and be read as
// the next request on the connection — request smuggling, and the
// pipelining support above makes that a live path rather than a
// theoretical one.
test "a chunked request is refused and its body is not smuggled" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    var conn = try h.connect();
    defer conn.close();

    // The chunk payload is itself a valid request line. If the server
    // mis-frames the chunked body, it would route this smuggled request.
    try conn.writeAll(
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "2c\r\nGET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n\r\n0\r\n\r\n",
    );

    const response = try conn.readResponse(allocator);
    defer allocator.free(response);

    try testing.expectEqual(@as(u16, 411), try harness.statusCode(response));
    // The smuggled request was never served.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, response, "pong"));
}

test "a request declaring both Content-Length and Transfer-Encoding is refused" {
    const allocator = testing.allocator;
    var h = try Harness.start(allocator, &routes);
    defer h.stop();

    const response = try h.roundTrip(
        "POST /echo HTTP/1.1\r\nHost: localhost\r\n" ++
            "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello",
    );
    defer allocator.free(response);

    try testing.expectEqual(@as(u16, 411), try harness.statusCode(response));
}
