# Reverb

An HTTP server for Zig, built on [Loom](https://github.com/tether-labs/Loom).

Loom is a bare TCP event loop. Reverb is everything above it: request
framing, parsing, routing, context, cookies, websockets.

```zig
const std = @import("std");
const Server = @import("reverb").Server;
const Context = @import("reverb").Context;

fn ping(ctx: *Context) !void {
    try ctx.STRING("SUCCESS");
}

const Config = struct {
    port: u16 = 8080,
    max: usize = 1024,
    max_body_size: usize = 1024 * 1024 * 10,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var server: Server(Config) = undefined;
    try server.new(.{}, arena.allocator());
    defer server.deinit();

    try server.installSignalHandlers();
    try server.get("/", ping, &.{});
    try server.listen();
}
```

## Requirements

Zig 0.16.0. Linux and macOS.

## Install

```sh
zig fetch --save git+https://github.com/senet-toolbox/reverb.git
```

Then in `build.zig`:

```zig
const reverb = b.dependency("reverb", .{ .target = target, .optimize = optimize });
exe_mod.addImport("reverb", reverb.module("reverb"));
```

## The division of labour with Loom

Worth understanding, because it determines which layer a bug belongs to.

**Loom owns sockets.** Accept, readiness (kqueue on macOS, epoll on
Linux), reading bytes, draining responses asynchronously, dropping stalled
connections. It applies **no framing**: a handler receives exactly what one
`read()` returned.

**Reverb owns everything above that.** So "a request split across two
packets" and "two pipelined requests in one packet" are Reverb's problem,
handled in `Server.handle` and `serveBuffered` (`src/lib/server.zig`) and covered by
the integration tests.

Two consequences worth knowing:

- `client.slot` is a dense index in `0..max`, unique among live
  connections, and safe to key per-connection state by.
- `client.write()` copies its payload, so writing from a per-request arena
  is safe. `writeBorrowed()` does not copy and requires the memory to
  outlive the send.

## Routing

```zig
try server.get("/users/:id", showUser, &.{});
try server.post("/users", createUser, &.{});
try server.delete("/users/:id", deleteUser, &.{});
```

Routes live in a radix tree, one per method. Path parameters are read with
`ctx.param("id")`:

```zig
fn showUser(ctx: *Context) !void {
    const id = if (ctx.param("id")) |p| p.value else return ctx.ERROR(400, "");
    try ctx.STRING(id);
}
```

Query-string parameters come from `ctx.queryParam(...)`. Middleware is
passed per route as the third argument.

## Responses

| Method | Sends |
| --- | --- |
| `ctx.STRING(bytes)` | `text/plain` |
| `ctx.JSON(T, value)` | `application/json` |
| `ctx.FILE(file)` | streamed, content type by extension |
| `ctx.SEND(code, content_type, body)` | the given status and content type |
| `ctx.ERROR(code, body)` | the given status |
| `ctx.RAW(bytes)` | written verbatim, headers included |

A handler that returns an error gets a `500`; a route that does not exist,
a `404`.

## Replying later

Handlers run on the event loop's thread, and the loop waits for them. A
handler that waits on something slow -- a child process, an outbound API
call -- stalls every other connection until it returns.

Instead, hand the work to a worker thread and answer when it is done:

```zig
const Job = struct {
    reply: *reverb.Reply,
    source: []u8, // owned by the job
};

fn runBuild(job: Job) void {
    defer gpa.free(job.source);
    // The slow part: a child process, an outbound API call...
    job.reply.send(200, "text/plain", "built");
}

var builds: reverb.Workers(Job, runBuild) = undefined;

fn build(ctx: *Context) !void {
    const source = try gpa.dupe(u8, ctx.body()); // the job owns its input
    errdefer gpa.free(source);
    const reply = try ctx.deferReply(); // last fallible step
    builds.submit(.{ .reply = reply, .source = source }) catch {
        gpa.free(source);
        reply.send(503, "text/plain", "busy");
    };
}
```

```zig
var server: reverb.Server(Config) = undefined;
try server.new(.{}, arena.allocator());
defer server.deinit(); // last: frees replies left without a connection

var threaded: std.Io.Threaded = .init_single_threaded;
try builds.init(gpa, threaded.io(), .{ .threads = 2, .queue = 16 });
defer builds.deinit(); // after `listen` returns, before `server.deinit`
```

The whole program is `examples/replying_later.zig`, compiled by
`zig build check-readme`.

- **`ctx.deferReply()`** takes the response over from the handler. The
  context is reused as soon as the handler returns, so copy whatever the
  job needs first. Requests pipelined behind this one wait until it is
  answered, and the connection is held for up to `reply_timeout_ms`
  (a `Config` field, default five minutes) instead of the idle timeout.
- **`reply.send(status, content_type, body)`** is threadsafe and must be
  called exactly once, failure included. It copies its arguments. The
  response it produces is the one `ctx.SEND` would have; CORS headers,
  cookies set before deferring and `Connection: close` are all carried
  over. A handler error after `deferReply` is logged, not answered.
- **`reply.sendWithCookies(status, content_type, body, cookies)`** also
  sets cookies the work decided, such as the session a sign-in issues.
  They follow any the handler set before deferring.
- **`reverb.Workers(Job, run)`** is a fixed set of threads reading a
  bounded queue. `submit` never blocks: a full queue is `error.Busy`, so
  the handler can answer 503. Use one pool per kind of work, so slow work
  cannot starve other work.
- Replies are allocated from `server.reply_allocator`, which must be
  threadsafe (default `std.heap.smp_allocator`).

If the client goes away first the reply is dropped, never sent to a later
connection that reuses the slot.

**Shutdown order:** `listen` returns, then `deinit` every pool (queued jobs
still run and send), then `server.deinit()`.

## Shutdown

`installSignalHandlers` makes `SIGTERM` and `SIGINT` return from `listen`,
so a deferred `deinit` runs instead of the process being killed part-way
through a response. It also ignores `SIGPIPE`, so a client disconnecting
mid-response surfaces as a write error rather than killing the process.

`stop()` is callable from any thread, or from a signal handler. For
binding without entering the loop — which is how the tests get a
kernel-assigned port — use `bindListener()` and `boundPort()`.

## Tests

```sh
zig build test              # everything
zig build test-unit         # parsers, routing, allocators
zig build test-integration  # a real server over real sockets
```

The integration suite starts a server on an ephemeral port and drives it
over real connections: requests split across packets, keep-alive reuse,
oversized headers and bodies, malformed request lines, stalled
connections, concurrent clients, clean shutdown, and deferred replies
(`tests/defer_test.zig`). See `tests/harness.zig`.

CI runs both suites on Linux and macOS, in `Debug` and `ReleaseSafe`, plus
a `zig fmt` check and a smoke test that serves a request and shuts down on
`SIGTERM`.

## Status

Pre-1.0 and the API moves. What is covered by tests is listed above. The
websocket layer (`src/lib/wss.zig`) and the Treehouse cache client are
not, and should be treated as less settled than the HTTP core.

Reverb's scope is the HTTP layer. Everything that was not that now lives
in its own package:

| Package | What moved |
| --- | --- |
| [reverb-auth](https://github.com/senet-toolbox/reverb-auth) | OAuth (Google, GitHub), sessions, JWT |
| [pg-orm](https://github.com/senet-toolbox/pg-orm) | the Postgres query builder and ORM |
| [stripe-zig](https://github.com/senet-toolbox/stripe-zig) | the Stripe client |
| [claude-zig](https://github.com/senet-toolbox/claude-zig) | the Claude and Vertex AI clients |

Note that `reverb.JWT` and `reverb.KeyStone` are gone; they are
`reverb_auth.JWT` and `reverb_auth.KeyStone` now.

## License

MIT. See [LICENSE](LICENSE).
