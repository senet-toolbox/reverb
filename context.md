# Reverb — session context

Handoff notes for picking up work on making Reverb production grade.
Written after a long stint hardening **Loom**, the event loop Reverb sits
on. Everything below marked *verified* was checked by running it on
2026-09-01; everything else is flagged as needing confirmation.

---

## 1. What Reverb is

Reverb is the HTTP layer on top of [Loom](../loom), which is a bare TCP
event loop. The split matters and should be preserved:

- **Loom** owns sockets: accept, readiness (kqueue/epoll), reading bytes,
  draining responses asynchronously, dropping stalled connections. It
  applies **no framing** — a handler gets exactly what one `read()`
  returned.
- **Reverb** owns everything above that: accumulating bytes until a whole
  request has arrived, parsing it, routing, context, sessions, auth,
  websockets, ORM.

So "a request split across two packets" and "two pipelined requests in
one packet" are Reverb's problem, and Reverb already handles them in
`readCompleteHttpRequest` (`src/lib/server.zig`).

Loom now has: CI on Linux and macOS, 49 tests (40 end-to-end, 9 unit), a `TESTING.md`, and a
README that documents its contract. Reverb has none of that yet. That gap
is most of the work.

---

## 2. Loom changed underneath you — read this first

Loom was substantially reworked. Reverb has already been updated for the
breaking parts (and builds — *verified*), but the semantics changed in
ways worth knowing:

| Change | What it means for Reverb |
| --- | --- |
| `client.fiber_index` → **`client.slot`** | Already renamed at all 8 call sites. Still a dense index in `0..max`, still unique per live connection, still safe to key `context_slots` / `request_buffers` by — **including across cluster workers**, which get disjoint ranges. |
| **`write()` now copies** | The payload no longer has to outlive the call. Previously anything over 64 KiB was parked as a *borrowed slice*, so writing from a per-request arena that got reset would corrupt responses intermittently under load. That footgun is gone. |
| **`writeBorrowed()`** added | Zero-copy, caller guarantees the memory outlives the send. Only for literals / genuinely stable buffers. |
| **`max_body_size` is now enforced** | It used to be config that nothing read. Oversized writes get `error.ResponseTooLarge`. Reverb passes `reverb.loom.config.max_body_size` around — check nothing now trips the limit. |
| **`idle_timeout_ms`** works | Connections making no progress are dropped (default 60s). Previously the timeout code was commented out entirely. |
| **Per-connection read buffers** | The slice handed to `process` is now valid until the next read *on that connection* (was: on **any** connection). Reverb copies out immediately anyway, so this is strictly safer. |
| **`stop()` / `bindListener()` / `boundPort()` / `serve()`** | Graceful shutdown exists. `serve()` returns when `stop()` is called; `stop()` is safe from a signal handler. Reverb currently calls `reverb.loom.listen()` and has no shutdown path. |
| **`Cluster(Handler)`** | Multi-worker: N event loops over one shared listener, one handler instance per worker. Measured 5.16× throughput at 8 workers. Reverb is single-`Loom` today. |
| **epoll backend** | Loom builds and its suite runs on Linux as well as macOS. |
| **`File` / `fs` exports removed** | Loom's vendored `std` copies were deleted. Reverb's `pub const fs = @import("loom").fs;` was removed — it was never used. |

If you take one thing from this table: **the `write()` copy change
removes a real production corruption risk that Reverb was exposed to.**

---

## 3. Current state (verified 2026-09-01)

```
30,151 lines of Zig across 81 files
23,626 reachable from the three build roots
 6,525 lines in 13 files reachable from nothing
```

**Builds:** `zig build` succeeds.

**Tests: 95 test blocks exist and none of them run.** `build.zig` defines
only `install`, `uninstall`, `run` and `orm-example` — there is no test
step. Note Zig only collects `test` blocks from the *root* file of a test
binary, so even adding a step is not enough; each file carrying tests has
to be pulled in explicitly (`_ = @import("...")` inside a `test {}` block
in the root). This exact trap was hiding broken tests in Loom.

**No CI.** No `.github/` at all.

**No LICENSE.** `README.md` is one line: `# tether`.

**Loom is a path dependency**: `.loom = .{ .path = "../loom" }`. Nobody
can build this repo without the sibling checkout — a blocker if it is
going in front of anyone. Wants a `git+https://...#<commit>` dependency
like the `pg` one already uses.

### Dead code (reachable from no build root)

| File | Lines |
| --- | --- |
| `src/lib/context_old.zig` | 2,273 |
| `src/lib/core/simdjson/tests.zig` | 951 |
| `src/lib/server_1.zig` | 904 |
| `src/lib/Websocket.zig` | 558 |
| `src/radix.zig` | 481 |
| `src/errors/recorder.zig` | 338 |
| `src/lib/auth/FrontendKeyStoneApi.zig` | 335 |
| `src/lib/wss_deflate.zig` | 233 |
| 5 smaller files | ~450 |

`context_old.zig` and `server_1.zig` are stale duplicates of
`context.zig` and `server.zig` — a reader cannot tell which is live
without tracing imports, and neither can `grep`. Note `src/lib/Websocket.zig`
is dead while Loom's `WebSocket` is the live one; `src/radix.zig` is dead
while `src/lib/trees/radix.zig` is live. Duplicated names for
live/dead pairs are actively misleading.

### Confirmed bug: calls to a method that does not exist

`client.writeMessage()` is called in five places. **`Client` has no such
method** — only the private `Writer` does. These compile solely because
Zig never analyses the enclosing functions:

- `src/lib/context.zig:29` — in `fn httpWrite`, which nothing calls
- `src/lib/handler.zig:198`
- `src/lib/Websocket.zig:341` (dead file)
- `src/lib/context_old.zig:28` (dead file)
- `src/lib/server_1.zig:844` (commented out)

The live send path is `client.chunked(payload)` at
`src/lib/context.zig:724` (`chunked` is an alias for `write`). So these
are dead paths that turn into compile errors the moment anything calls
them. Either wire them to the real API or delete them.

### Parser

`src/lib/helpers.zig:552 parseHeaders` looks reasonably defensive —
bounds-checked, `orelse return error.MalformedRequest`, only 1
`unreachable` and 8 `.?` unwraps in the file. Worth auditing those 9 sites
against hostile input, but this is **not** the minefield Loom's old
abandoned parser was. Fuzzing it would be high value and cheap
(`std.testing.fuzz`).

---

## 4. Suggested plan

Roughly the order that worked for Loom: make the thing verifiable, then
fix what verification exposes.

1. **Test step + make the existing 95 tests actually run.** Add `test`,
   `test-unit`, `test-integration` steps and root-level `_ = @import(...)`
   references. Expect some of those tests to be broken — in Loom, turning
   the never-run tests on surfaced a test with the wrong arity and a file
   that did not compile at all.
2. **CI** on Linux and macOS, mirroring Loom's `.github/workflows/ci.yml`.
   Build, unit, integration, `zig fmt --check`, and a smoke test that
   starts the server and makes a real request.
3. **Integration tests over real sockets.** This is where the value is
   for an HTTP server: request split across packets, pipelined requests,
   oversized headers/body, malformed request line, missing
   `Content-Length`, chunked encoding, keep-alive reuse, slow-loris,
   100-continue. Loom's `tests/harness.zig` is a working model to copy —
   raw-syscall client, ephemeral ports, server on its own thread.
4. **Delete or quarantine the dead 6,525 lines**, especially the
   `_old`/`_1` duplicates.
5. **Fix `client.writeMessage()`** (§3).
6. **Publish the Loom dependency by URL** so the repo builds standalone.
7. **Graceful shutdown**: adopt Loom's `stop()` and a `SIGTERM` handler.
   Loom's `examples/echo_server.zig` shows the pattern.
8. **README + LICENSE.**
9. **Then** consider `Cluster` for multi-worker throughput. Do this last —
   it changes concurrency assumptions and wants the test suite in place
   first. Note the handler is per-worker, so `*Reverb` shared across
   workers would need auditing for thread safety (`arena`, `routes`,
   `logger`, metrics are all shared today).

---

## 5. Method that worked on Loom

Worth reusing, because it caught things that ordinary review did not.

**Prove every regression test fails.** Write the test, re-introduce the
bug, confirm it goes red, restore. A test that passes against broken code
is worse than no test. On Loom this exposed several tests that asserted
nothing — and the fixes for those found real bugs.

**Measure instead of assuming.** Loom's multi-worker design was planned
around `SO_REUSEPORT` load balancing; a 20-line probe showed Darwin sends
every connection to the last-bound socket, and the whole design changed.
Two benchmarks also lied outright — one because LLVM constant-folded the
work away, one because the load generator was the bottleneck.

**Distrust the harness.** A bug-injection run used `timeout`, which does
not exist on macOS; every invocation exited 127 and got scored as both
"suite broken" and "bug caught". Sanity-check tooling before trusting
what it reports.

**Verify claims before writing them down.** Several confident statements
in this file's first draft were wrong until checked against the code.

---

## 6. Commands

```
zig build                 # builds today
zig build run
zig build orm-example

# Loom, for reference:
cd ../loom
zig build test            # 49 tests, Linux + macOS
cat TESTING.md            # method, injection matrix, known gaps
```

Running the Linux side from macOS, which is how Loom's epoll backend was
tested:

```
zig test -femit-bin=/tmp/t -target x86_64-linux-musl --test-no-exec \
    --dep loom -Mroot=tests/integration.zig -Mloom=src/root.zig
docker run --rm --platform linux/amd64 -v /tmp:/w -w /w alpine:3 ./t
```

---

## 7. Open questions for the next session

- Is the `pg/` ORM (4,357 lines) in scope for Reverb, or should it be
  its own package? It is a large fraction of the repo and unrelated to
  serving HTTP.
- Same for `lib/core/simdjson` (7,551 lines) — vendored or written here?
  If vendored, it should be a dependency.
- Is `src/example.zig` (881 lines) a build root by intent, or leftover?
- Which of the dead 6,525 lines is wanted later, and which is genuinely
  finished with?
