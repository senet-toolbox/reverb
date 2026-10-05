//! A real Reverb server on an ephemeral port, driven over real sockets.
//!
//! Everything here goes through the kernel rather than calling the parser
//! directly, because the defects worth catching in an HTTP server live in
//! the seams: a request split across two packets, two requests in one
//! packet, a client that stops writing halfway through. None of those are
//! reachable from a unit test that hands a complete buffer to `parseHeaders`.

const std = @import("std");
const posix = std.posix;
const system = std.posix.system;
const reverb = @import("reverb");

pub const Config = struct {
    /// 0 asks the kernel for an unused port, so tests never collide with
    /// each other or with anything already running on the machine.
    port: u16 = 0,
    max: usize = 64,
    max_body_size: usize = 64 * 1024,
};

const Server = reverb.Server(Config);

/// `std.Thread.sleep` is gone in Zig 0.16, so this goes straight to the
/// syscall.
pub fn sleepMs(ms: u64) void {
    const req = posix.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = system.nanosleep(&req, null);
}

/// A server on its own thread plus the client helpers to talk to it.
pub const Harness = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    server: *Server,
    thread: std.Thread,
    port: u16,

    /// Starts a server with `routes` registered and waits until it is
    /// accepting connections.
    ///
    /// The listener is bound on this thread before the event loop starts,
    /// so the port is known and connectable the moment this returns —
    /// there is no sleep-and-hope.
    pub fn start(
        allocator: std.mem.Allocator,
        routes: []const Route,
    ) !Harness {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }

        const server = try allocator.create(Server);
        errdefer allocator.destroy(server);

        try server.new(.{}, arena.allocator());
        errdefer server.deinit();

        for (routes) |route| {
            switch (route.method) {
                .GET => try server.get(route.path, route.handler, &.{}),
                .POST => try server.post(route.path, route.handler, &.{}),
                .DELETE => try server.delete(route.path, route.handler, &.{}),
            }
        }

        try server.bindListener();
        const port = try server.boundPort();

        const thread = try std.Thread.spawn(.{}, serveLoop, .{server});

        return .{
            .allocator = allocator,
            .arena = arena,
            .server = server,
            .thread = thread,
            .port = port,
        };
    }

    fn serveLoop(server: *Server) void {
        server.listen() catch |err| {
            std.debug.print("harness server stopped: {any}\n", .{err});
        };
    }

    pub fn stop(h: *Harness) void {
        h.server.stop();
        h.thread.join();
        h.server.deinit();
        h.allocator.destroy(h.server);
        h.arena.deinit();
        h.allocator.destroy(h.arena);
    }

    /// Opens a TCP connection to the server, retrying while the listen
    /// backlog is full.
    pub fn connect(h: *const Harness) !Connection {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            return connectOnce(h.port) catch |err| switch (err) {
                // A refused or timed-out connect leaves the socket unusable
                // on BSD, so each retry starts from a fresh one.
                error.ConnectBackpressure => {
                    if (attempt >= 400) return error.ConnectFailed;
                    sleepMs(5);
                    continue;
                },
                else => return err,
            };
        }
    }

    fn connectOnce(port: u16) !Connection {
        const rc = system.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        if (@intFromEnum(posix.errno(rc)) != 0) return error.SocketFailed;
        const fd: posix.socket_t = @intCast(rc);
        errdefer _ = system.close(fd);

        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
            .zero = .{0} ** 8,
        };

        while (true) {
            const crc = system.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
            switch (posix.errno(crc)) {
                .SUCCESS => break,
                // A signal can interrupt `connect` after the handshake
                // completed, so the retry reports the socket as already
                // connected. That is success.
                .ISCONN => break,
                .INTR => continue,
                .CONNREFUSED, .TIMEDOUT, .AGAIN, .ADDRNOTAVAIL, .CONNRESET => return error.ConnectBackpressure,
                else => return error.ConnectFailed,
            }
        }

        const conn = Connection{ .fd = fd };
        // Without timeouts a server that never replies hangs the whole test
        // run instead of failing a single test.
        try conn.setTimeouts(2000);
        return conn;
    }

    /// Sends `request` on a fresh connection and returns the response.
    /// Caller owns the returned memory.
    pub fn roundTrip(h: *const Harness, request: []const u8) ![]u8 {
        var conn = try h.connect();
        defer conn.close();
        try conn.writeAll(request);
        return conn.readResponse(h.allocator);
    }
};

pub const Method = enum { GET, POST, DELETE };

pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: *const fn (*reverb.Context) anyerror!void,
};

/// A client socket, with just enough on it to express the awkward cases:
/// writing a request in pieces, or reading until the peer hangs up.
pub const Connection = struct {
    fd: posix.socket_t,

    pub fn close(c: *Connection) void {
        _ = system.close(c.fd);
    }

    pub fn setTimeouts(c: Connection, millis: i64) !void {
        const tv = std.c.timeval{
            .sec = @intCast(@divTrunc(millis, 1000)),
            .usec = @intCast(@mod(millis, 1000) * 1000),
        };
        const bytes = std.mem.asBytes(&tv);
        try posix.setsockopt(c.fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, bytes);
        try posix.setsockopt(c.fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, bytes);
    }

    pub fn writeAll(c: *const Connection, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const rc = system.write(c.fd, bytes.ptr + sent, bytes.len - sent);
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return error.SendTimeout,
                .PIPE, .CONNRESET => return error.ConnectionClosed,
                else => return error.SendFailed,
            }
            if (rc <= 0) return error.ConnectionClosed;
            sent += @intCast(rc);
        }
    }

    /// Reads until the response looks complete, the peer closes, or the
    /// read times out.
    ///
    /// Caller owns the returned memory.
    pub fn readResponse(c: *const Connection, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var chunk: [4096]u8 = undefined;
        while (true) {
            const rc = system.read(c.fd, &chunk, chunk.len);
            const n: usize = switch (posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                // Timed out, or the peer went away: return what arrived so
                // the assertion can describe what was missing.
                .AGAIN, .CONNRESET, .PIPE => break,
                else => return error.RecvFailed,
            };
            if (n == 0) break; // peer closed
            try buf.appendSlice(allocator, chunk[0..n]);

            if (responseIsComplete(buf.items)) break;
        }

        return buf.toOwnedSlice(allocator);
    }
};

/// True once `data` holds a complete HTTP response, judged by
/// `Content-Length` when present.
///
/// Reading until close would work too, but keep-alive connections never
/// close, so a length-aware check is what keeps those tests fast.
fn responseIsComplete(data: []const u8) bool {
    const head_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return false;
    const head = data[0..head_end];
    const body_len = data.len - (head_end + 4);

    if (findHeaderValue(head, "Content-Length")) |value| {
        const declared = std.fmt.parseInt(usize, value, 10) catch return true;
        return body_len >= declared;
    }

    // No Content-Length: the head alone is all this helper can be sure of.
    return true;
}

fn findHeaderValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Extracts the numeric status code from a response.
pub fn statusCode(response: []const u8) !u16 {
    // "HTTP/1.1 200 OK"
    var parts = std.mem.tokenizeScalar(u8, response, ' ');
    _ = parts.next() orelse return error.MalformedResponse;
    const code = parts.next() orelse return error.MalformedResponse;
    return std.fmt.parseInt(u16, code, 10);
}

/// The body of a response, or an error if it has no head terminator.
pub fn body(response: []const u8) ![]const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse
        return error.MalformedResponse;
    return response[head_end + 4 ..];
}

test {
    _ = @import("http_test.zig");
}
