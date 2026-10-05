# Reverb

An HTTP server for Zig, built on [Loom](https://github.com/tether-labs/Loom).

Loom is a bare TCP event loop. Reverb is everything above it: request
framing, parsing, routing, context, sessions, auth, websockets.

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
zig fetch --save git+https://github.com/vic-Rokx/tether.git
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
handled in `readCompleteHttpRequest` (`src/lib/server.zig`) and covered by
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
| `ctx.ERROR(code, body)` | the given status |
| `ctx.RAW(bytes)` | written verbatim, headers included |

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
zig build test-unit         # parsers, routing, JWT, allocators
zig build test-integration  # a real server over real sockets
```

The integration suite starts a server on an ephemeral port and drives it
over real connections: requests split across packets, keep-alive reuse,
oversized headers and bodies, malformed request lines, stalled
connections, concurrent clients, clean shutdown. See `tests/harness.zig`.

CI runs both suites on Linux and macOS, in `Debug` and `ReleaseSafe`, plus
a `zig fmt` check and a smoke test that serves a request and shuts down on
`SIGTERM`.

## Status

Pre-1.0 and the API moves. What is covered by tests is listed above; the
auth, payment and ORM modules under `src/lib/` and `src/pg/` are not yet,
and should be treated as less settled than the HTTP core.

## License

MIT. See [LICENSE](LICENSE).
