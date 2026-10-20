//! A response that will be sent later, possibly from another thread.
//!
//! Made by `Context.deferReply`. A handler that has slow work to do (a child
//! process, an outbound API call) hands the work and its `*Reply` to a
//! worker thread and returns, so the event loop keeps serving everyone
//! else. When the work is done the worker calls `send`, once.
//!
//! Only the loop thread may touch sockets, so `send` copies the response
//! and posts it back to the loop; the head is built and written there. The
//! connection is found again by slot and generation, never by pointer: if
//! it closed meanwhile, and even if a new connection has since taken its
//! slot, the reply is dropped rather than sent to the wrong peer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Task = @import("loom").Task;
const Context = @import("context.zig");
const Cookie = @import("core/Cookie.zig");

const Reply = @This();

/// Posted to the owning loop by `send`. Its `run` is the server's, which
/// writes the response and frees the reply.
task: Task,
/// Threadsafe: the reply is created on the loop thread, filled on a worker
/// and freed on the loop thread again.
allocator: Allocator,

/// The server that owns the connection, and how to post to its loop.
server: *anyopaque,
post: *const fn (server: *anyopaque, task: *Task) void,

/// The connection's identity at `deferReply` time.
slot: usize,
generation: u32,

/// Captured from the request, since its context is reused once the handler
/// returns.
close_requested: bool,
/// The request's `Access-Control-Request-Headers`, echoed back. Owned.
allow_headers: []const u8,
/// `Set-Cookie` lines for any cookies the handler set. Owned.
cookies: []const u8,

/// Guards against a second `send`.
sent: std.atomic.Value(bool) = .init(false),

/// Filled by `send`. `storage` holds the content type, the `Set-Cookie`
/// lines, room for the head, then the body, so the loop can write the head
/// in front of the body and send the whole response with one `write`.
status: u16 = 0,
storage: []u8 = &.{},
content_type_len: usize = 0,
/// The cookie lines' share of `storage`, and how much of it they use.
cookie_room: usize = 0,
cookie_len: usize = 0,
head_room: usize = 0,

pub const Captured = struct {
    server: *anyopaque,
    post: *const fn (server: *anyopaque, task: *Task) void,
    run: *const fn (task: *Task) void,
    slot: usize,
    generation: u32,
    close_requested: bool,
    allow_headers: []const u8,
    cookies: []const u8,
};

/// Copies everything in `captured` that points into request memory.
pub fn create(allocator: Allocator, captured: Captured) !*Reply {
    const reply = try allocator.create(Reply);
    errdefer allocator.destroy(reply);

    const owned = try allocator.alloc(u8, captured.allow_headers.len + captured.cookies.len);
    @memcpy(owned[0..captured.allow_headers.len], captured.allow_headers);
    @memcpy(owned[captured.allow_headers.len..], captured.cookies);

    reply.* = .{
        .task = .{ .run = captured.run },
        .allocator = allocator,
        .server = captured.server,
        .post = captured.post,
        .slot = captured.slot,
        .generation = captured.generation,
        .close_requested = captured.close_requested,
        .allow_headers = owned[0..captured.allow_headers.len],
        .cookies = owned[captured.allow_headers.len..],
    };
    return reply;
}

/// Frees the reply. Called by the server once the response is written or
/// found to have nowhere to go; a reply that was never sent must not be
/// freed by anyone else.
pub fn destroy(reply: *Reply) void {
    const allocator = reply.allocator;
    allocator.free(reply.storage);
    // `allow_headers` and `cookies` share one allocation.
    const owned_len = reply.allow_headers.len + reply.cookies.len;
    allocator.free(@constCast(reply.allow_headers.ptr)[0..owned_len]);
    allocator.destroy(reply);
}

/// Answers the request with `status`, `content_type` and `body`.
///
/// Callable from any thread, exactly once. `content_type` and `body` are
/// copied, so they may be freed as soon as this returns. The reply must not
/// be touched afterwards: it is freed on the loop thread, perhaps before
/// this returns.
///
/// Cannot fail. If the copy cannot be allocated the connection is closed
/// instead, since there is no response to send and the client would
/// otherwise wait out the reply timeout.
pub fn send(reply: *Reply, status: u16, content_type: []const u8, body: []const u8) void {
    reply.sendWithCookies(status, content_type, body, &.{});
}

/// `send`, also setting `cookies`, for work that decides them (a sign-in
/// issuing a session). They come after any cookies the handler set before
/// `deferReply`. Copied like the rest.
pub fn sendWithCookies(reply: *Reply, status: u16, content_type: []const u8, body: []const u8, cookies: []const Cookie) void {
    const already_sent = reply.sent.swap(true, .acq_rel);
    std.debug.assert(!already_sent); // `send` called twice
    if (already_sent) return;

    var cookie_room = reply.cookies.len;
    for (cookies) |cookie| cookie_room += Context.cookieCapacity(cookie);

    // Sized for the head here, but the head itself is built on the loop
    // thread: `httpDate` writes a shared cache. It repeats the cookie
    // lines, hence their room again.
    const head_room = cookie_room + Context.headCapacity(.{
        .status_line = "",
        .close = reply.close_requested,
        .content_type = content_type,
        .content_length = body.len,
        .allow_headers = reply.allow_headers,
    });

    if (reply.allocator.alloc(u8, content_type.len + cookie_room + head_room + body.len)) |storage| {
        @memcpy(storage[0..content_type.len], content_type);
        const cookie_buf = storage[content_type.len..][0..cookie_room];
        @memcpy(cookie_buf[0..reply.cookies.len], reply.cookies);
        var cookie_len = reply.cookies.len;
        for (cookies) |cookie| {
            // Cannot overflow: `cookie_room` counted each one's capacity.
            Context.renderCookie(cookie, cookie_buf, &cookie_len) catch unreachable;
        }
        @memcpy(storage[content_type.len + cookie_room + head_room ..], body);
        reply.storage = storage;
        reply.content_type_len = content_type.len;
        reply.cookie_room = cookie_room;
        reply.cookie_len = cookie_len;
        reply.head_room = head_room;
        reply.status = status;
    } else |_| {
        // `status` stays 0, which `render` reports as nothing to send.
    }

    reply.post(reply.server, &reply.task);
}

/// The complete response, head and body. Loop thread only. Null if `send`
/// could not allocate it.
pub fn render(reply: *Reply) ?[]const u8 {
    if (reply.status == 0) return null;

    const content_type = reply.storage[0..reply.content_type_len];
    const cookie_lines = reply.storage[reply.content_type_len..][0..reply.cookie_len];
    const head_start = reply.content_type_len + reply.cookie_room;
    const body_start = head_start + reply.head_room;
    const body = reply.storage[body_start..];

    var status_line_buf: [128]u8 = undefined;
    const status_line = Context.statusLine(&status_line_buf, reply.status) catch return null;

    const head_buf = reply.storage[head_start..body_start];
    const head_len = Context.writeHead(head_buf, .{
        .status_line = status_line,
        .close = reply.close_requested,
        .content_type = content_type,
        .content_length = body.len,
        .allow_headers = reply.allow_headers,
        .cookies = cookie_lines,
    }) catch return null;

    // Move the head flush against the body, so the two are contiguous.
    const response_start = body_start - head_len;
    std.mem.copyBackwards(u8, reply.storage[response_start..body_start], head_buf[0..head_len]);
    return reply.storage[response_start..];
}
