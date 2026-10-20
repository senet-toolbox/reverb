# Reverb — session context

Handoff notes for work on making Reverb production grade. Everything
marked *verified* was checked by running it on 2026-10-05, on branch
`harden-production`.

---

## 1. What Reverb is

Reverb is the HTTP layer on top of [Loom](https://github.com/tether-labs/Loom),
a bare TCP event loop. The split matters and should be preserved:

- **Loom** owns sockets: accept, readiness (kqueue/epoll), reading bytes,
  draining responses asynchronously, dropping stalled connections. It
  applies **no framing** — a handler gets exactly what one `read()`
  returned.
- **Reverb** owns everything above that: accumulating bytes until a whole
  request has arrived, parsing it, routing, context, sessions, auth,
  websockets, ORM.

So "a request split across two packets" and "two pipelined requests in
one packet" are Reverb's problem, handled in `Server.handle` and
`serveBuffered` (`src/lib/server.zig`) and now covered by integration tests.

See `README.md` for the public API.

---

## 2. Current state (verified 2026-10-20)

```
18,763 lines of Zig across 54 files (src/, tests/, examples/)
      97 test blocks, all of which run
      94 tests pass (51 unit, 43 integration)
```

- Deferred responses (§8) are in: `ctx.deferReply`, `reverb.Reply`,
  `reverb.Workers`. Verified on macOS (kqueue) and on Linux (epoll, in
  Docker), Debug and ReleaseSafe; all five cross-compile targets build
  the exe and both test binaries.
- Loom is pinned by URL and hash at `8d791ac` (its `main`), the commit
  with Loom's half of this work.

- `zig build` succeeds. `zig build test` passes. `zig fmt --check` clean.
- No leaks: unit tests run under `std.testing.allocator`.
- CI on Linux and macOS, Debug and ReleaseSafe, plus a `zig fmt` check
  and a SIGTERM smoke test (`.github/workflows/ci.yml`).
- Builds standalone — verified by cloning to a directory with no sibling
  `../loom` and running the suite there.
- Graceful shutdown works: serves a request, exits 0 on SIGTERM, in both
  Debug and ReleaseSafe.
- **Linux verified by execution**, not just compilation: both suites run
  under `x86_64-linux-musl` in Docker (48 unit, 32 integration), so the
  epoll backend is genuinely exercised. All five cross-compile targets
  build both the exe and the test binaries.
- **No libc dependency.** Builds and tests clean without `link_libc` on
  every target.
- `README.md` and `LICENSE` exist. The README quickstart is a real file
  (`examples/readme_quickstart.zig`) compiled by `zig build check-readme`
  and in CI, so it cannot rot.

---

## 3. What turning the tests on found

95 test blocks existed and none of them ran, exactly as the previous
notes warned. Enabling them produced 20 compile errors in code that had
never been analysed, and fixing those exposed real defects. Ordered by
how much they mattered:

| Defect | Consequence |
| --- | --- |
| `RequestBuffer.append` keyed connection identity on `client.read_timeout` | Loom refreshes that field on **every read**, so any request arriving in more than one packet had its buffered prefix discarded and was parsed from the second fragment alone → 404. Every split request was broken. |
| `parseHeaders` computed `payload[method.len + 1 ..]` with no bounds check | Remote crash from `XYZ / HTTP/1.1`. Several more: `value[0]`/`value[12]` on an empty header value, `unreachable` on an unknown Content-Type, unbounded `payload[line_start + N]` reads. |
| `RESP.toCommand` freed the command verb it only borrowed | Freed a string literal in read-only memory → bus error. Also read `values[0].string` without checking length or tag. |
| `Metrics.end_points` was a process-global holding arena-allocated slices | A second server reallocated memory owned by the first one's freed arena. Also made the test suite crash, since each test builds a server. |
| `Context.param()` could never return a value | Nothing populated `params`; path params went only to `query_params`. Both accessors also scanned their whole backing slice rather than the written prefix, comparing against uninitialised `Param` structs. |
| `Radix` had no `deinit`, but `Server.deinit` called it | `Server.deinit` could not compile. |
| `Tripwire.recordError` wrote past `errors[1024]`; breadcrumbs stored a pointer to a stack local; counters were shared across threads unsynchronised | Buffer overrun on an error burst, which is remotely reachable. |
| `parseMap` leaked its scratch array and read `.string` off an unchecked tag | Leak plus a wrong-tag access on a malformed map. |
| `parseSimpleString` returned a borrowed slice while `parseBulkString` returned an owned one | Same `.string` tag, two ownership rules, so no correct `deinit` was possible. Now both own. |
| `client.writeMessage()` called in 5 places | No such method on `Client`. Compiled only because Zig never analysed those functions. |
| `core/builders.zig` called `std.c.realloc(self.contents, ...)` while `contents` was still `undefined` | Realloc of a garbage pointer on the very first append, every time — it worked on macOS by luck. The result was never freed either, so every CORS rebuild and every call site in `context.zig` leaked. Now appends into a caller-owned buffer, reports overflow, and allocates nothing. |

Method that worked, reused from Loom: **prove every regression test
fails.** The split-packet and parser fixes were each verified by
re-introducing the bug and confirming the test went red. Both did.

Also worth repeating: `timeout` does not exist on macOS. A command using
it exits 127 and looks like a pass.

---

## 4. Remaining work

1. **`Cluster` for multi-worker throughput.** Loom measured 5.16× at 8
   workers. The handler is per-worker, so a `*Reverb` shared across workers
   needs a thread-safety audit first: `arena`, `routes`, `logger`,
   `end_points` and the context pool are all shared today, and
   `Server.use_cors`, `signal_target` and `cors_header_buffer` are statics.
   This is the one remaining item that changes concurrency assumptions.

2. **The websocket layer and Treehouse have no tests.** `src/lib/wss.zig`
   and `src/lib/treehouse.zig` are the last substantial pieces inside
   reverb that nothing exercises. Treehouse needs a running cache server on
   port 6401, which is why its one test was removed rather than fixed.

3. **Several files are reachable from nothing** — kept deliberately, they
   are wanted later: `src/lib/core/Url.zig`, `src/lib/core/Providers.zig`,
   `src/error_index.zig`, `src/assembler/`, `src/execute/`, `src/errors/`,
   `src/sample/sample.zig`.

   Five still `@import("pg")` or `@import("pg_orm")`: `error_index.zig`,
   `assembler/crud.zig`, `execute/{handlers,queries}.zig` and
   `errors/store.zig`. That compiles only because nothing reaches them.
   Wiring any up means taking `pg-orm` as a dependency. Two also call
   `ctx.bind` / `ctx.glue`, which now exist and are tested.

4. **`src/lib/core/simdjson/` (7,551 lines) is vendored.** Left as-is by
   decision. If it is a copy of simdjzon it should eventually be a
   dependency. Note `gluev2` is the only live consumer.

5. **Request-scoped allocation is opt-in.** `Context.requestAllocator()`
   exists and the binding helpers use it, but handlers that reach for
   `ctx.arena` still allocate for the life of the process. Worth auditing
   the remaining `self.arena` uses in `context.zig` to see which should be
   request-scoped.

### Done since the first pass

- Chunked transfer-encoding is implemented: framed, decoded in place, with
  the size limit applied to the decoded length.
- `Connection: close` is honoured, every response reports its connection
  handling consistently, and a 404 no longer tears down the connection.
- `auth`, `payment`, `claude` and the `pg` ORM are separate packages (§5).
- The hand-rolled JSON parser in `context.zig` is gone, and JSON binding no
  longer leaks per request.
- No `libc` dependency, and no `std.heap.c_allocator` references remain.

## 5. What moved out of reverb

Reverb's scope is the HTTP layer. Four packages were split out, each a
repo under `senet-toolbox` with its own `build.zig`:

| Package | Lines | Depends on |
| --- | --- | --- |
| `pg-orm` | 4,357 | pg.zig |
| `reverb-auth` | ~1,700 | reverb |
| `claude-zig` | 548 | std only |
| `stripe-zig` | 376 | std only |

None of this code had ever been compiled, apart from pg-orm's tests and
the JWT tests, because none of it was reachable from a build root. Forcing
analysis with `refAllDecls` surfaced:

- `std.posix.getenv` (removed in 0.16) in Stripe and Claude, both in demo
  `main` functions that sat *inside* the library files — so a consumer
  would link a second entry point and the library read the environment.
  Those moved to `examples/`.
- `claude.chat()` hardcoded `@embedFile("context_v2.txt")` as its system
  prompt: a 20 KB prompt for an unrelated UI framework, sent on every call
  and billed as input tokens. The caller supplies it now.
- `QueryBuilder.remove` referenced `query_param_list`, a field that does
  not exist.
- **A hardcoded JWT signing secret** committed in `KeyStone.zig`, used as
  a silent fallback whenever `session_secret` was unset. Anyone with the
  source could mint a session for any user of such a deployment. Removed;
  a missing secret is now an error. **Any deployment that ran on the
  default needs its secret rotated and its sessions invalidated.**
- `std.io.fixedBufferStream` (removed in 0.16) in a pg-orm test.

`reverb-auth` depends on reverb by **path**, not a pinned URL, because
`senet-toolbox/reverb` is private and `zig fetch` cannot reach it without
credentials. It therefore needs a sibling checkout. Pin it properly once
reverb is public or CI has a token.

`reverb.JWT` and `reverb.KeyStone` are gone from the public API.

---

## 6. Dead code removed

Ten files, ~6,100 lines, unreachable from every build root. Eight were
untracked, so commit `dbb7235` snapshots them before `98713bb` deletes
them — recover with `git show dbb7235:<path>`. Both commits are on `main`,
so the snapshot survives independently of any branch.

`context_old.zig` and `server_1.zig` were stale duplicates of
`context.zig` and `server.zig`; `src/lib/Websocket.zig` and
`src/radix.zig` shadowed the live `loom.WebSocket` and
`lib/trees/radix.zig` by name. `handler.zig` was reduced to the `Ctx_pm`
type it exists for — its 250-line `handler` duplicated `Server.handle`
and had drifted from it.

Also: `.gitignore` now covers `.zig-cache/`, `zig-out/`, `zig-pkg/` and
`.env`, none of which were ignored. `.env` and a 2.3 MB binary were
tracked; both are untracked now but still on disk. `.env` never reached
git history — confirmed.

---

## 7. Commands

```
zig build                   # builds
zig build run               # serves on :8080, SIGTERM to stop
zig build test              # 94 tests
zig build test-unit
zig build test-integration
zig build check-readme      # compiles the README examples
zig fmt --check src/ tests/ examples/ build.zig
```

Running the Linux side from macOS:

```
zig test -femit-bin=/tmp/t -target x86_64-linux-musl --test-no-exec \
    --dep loom -Mroot=tests/integration.zig -Mloom=src/root.zig
docker run --rm --platform linux/amd64 -v /tmp:/w -w /w alpine:3 ./t
```

Loom, for reference: `cd ../loom && zig build test` (49 tests), and its
`TESTING.md` documents the injection matrix and known gaps.

---

## 8. Replying later (deferred responses)

**Done 2026-10-20** — see "What was built" at the end of this section.
The design notes below are kept as written. Next is assembler-backend
(last subsection).

Written 2026-10-20. Loom's half (posting back to the loop, client
generations, pausing reads, the awaiting timeout) is in
`../loom/context.md`; do that first.

### Why

Handlers run on the loop thread and the loop waits for them
(`Server.handle` → `serveRequest` → `callRoute`). assembler-backend runs
`zig build` (~5 s) and Claude API calls (seconds to minutes) in handlers,
and during either the server answers nothing else. Non-blocking sockets do
not help when the handler itself blocks. `Cluster` (§4.1) would only
divide the stall, not remove it.

### The API

```zig
// Handler, on the loop thread.
fn build(ctx: *Context) !void {
    const source = try gpa.dupe(u8, ctx.body());   // the job owns its input
    const reply = try ctx.deferReply();            // last fallible step
    builds.submit(.{ .reply = reply, .source = source }) catch {
        gpa.free(source);
        reply.send(503, "text/plain", "busy");
    };
}

// Worker thread.
fn runBuild(job: Job) void {
    defer gpa.free(job.source);
    const wasm_id = ...;
    job.reply.send(200, "text/plain", wasm_id);    // threadsafe, exactly once
}

var builds: reverb.Workers(Job, runBuild) = undefined;
try builds.init(gpa, io, .{ .threads = 2, .queue = 16 });
defer builds.deinit();                             // closes the queue, joins
```

### `ctx.deferReply() !*Reply`

Captures, from the context, everything the response will need, because the
context is pooled per slot and cleared when the handler returns
(`defer ctx.clear()` in `handle`):

- `slot`, the client's `generation`, and the `*Loom` that owns it.
- `close_requested`, the echoed `Access-Control-Allow-Headers`
  (`http_header.accept_control_request_headers`, request memory), and any
  cookies the handler set.
- A Loom `Task` node for posting back.

It marks the context deferred and the client awaiting, and pauses reads
(Loom §2.3, §2.4). It allocates from a threadsafe allocator
(`std.heap.smp_allocator` or the server's gpa); never from `ctx.arena` or
the request arena.

### `reply.send(status, content_type, body)`

Callable once, from any thread. It copies `body` and posts the reply to its
loop. Everything else happens on the loop thread, in the task:

1. `loom.clientAt(slot, generation)`; if null, the client is gone: free
   and return.
2. Build the head and write. **Build it here, not in `send`:** `httpDate()`
   writes into the global `cached_date` (`context.zig:578`), so formatting
   headers on a worker thread races the loop. The CORS block
   (`Context.cors_headers`) is read-only after `prepare`, so it is fine.
3. Clear awaiting, resume reads, honour `close_requested` the same way
   `handle` does (`closeWhenDrained`).
4. Serve any pipelined requests that were buffered behind this one: factor
   the `while (true)` loop in `handle` into `serveBuffered(slot)` and call
   it here. Stop again if one of those defers too.
5. Free the reply.

`send` should not take a Context-shaped API (`STRING`, `JSON`, `FILE`):
those write through the client directly. Extract the header building in
`buildStandardHeaders` into a function over plain parameters, used by both
`Context` and `Reply`, so the two cannot drift.

### Changes in `Server.handle` / `serveRequest`

- After `serveRequest`, if the context deferred, stop the pipelining loop
  and leave the remaining bytes in the request buffer.
- A handler that returns an error after `deferReply` must not get the
  automatic `ERROR(404, "")`: that would answer twice. Log the error and
  leave the response to the reply. (Separately, mapping every handler error
  to 404 is questionable; 500 is the honest status.)
- `deinit` order: stop the loop, `deinit` the worker pools (they finish
  their current job and `send`), then let Loom run or free the posted
  tasks, then free the context pool.

### `reverb.Workers(Job, run)`

A fixed set of `std.Thread`s reading a `std.Io.Queue(Job)`:

- `submit` is a non-blocking put (`put(io, &.{job}, 0)`); a full queue is
  `error.Busy`, so the handler can answer 503 instead of queueing without
  bound.
- `deinit` closes the queue; workers drain what is queued, see
  `error.Closed` and exit; then join.
- Separate pools per kind of work, so slow work cannot starve other work:
  in assembler-backend, builds (CPU-bound; `zig build` is already
  parallel, so 1 to 2 threads) and chat (waiting on the network, 8 or
  more).
- Plain threads and a mutex-guarded queue, not lock-free: see
  `../loom/context.md` §3.

### Tests (`tests/integration.zig`, each proven to fail)

| Test | Bug it catches |
| --- | --- |
| A deferred route whose worker sleeps 1 s; `GET /` on another connection answers in < 100 ms | work still on the loop thread |
| A deferred response's status, body and headers (CORS, `Connection`, `Content-Length`) match the same response sent directly | the two header paths drifting; captured state lost |
| Keep-alive: a second request on the connection after a deferred reply | reads never resumed |
| A deferred request and a fast one pipelined in one write come back in order | serving buffered requests before the reply |
| Client hangs up before the reply; a new connection on the same slot does not get the old body | no generation check |
| Queue full answers 503 at once | blocking submit |
| `Connection: close` honoured after a deferred reply | `close_requested` not captured |
| A handler error after `deferReply` produces exactly one response | the automatic 404 still sent |
| `deinit` with jobs queued and in flight: threads joined, no leaks under `std.testing.allocator` | shutdown order |
| Many concurrent deferred requests from several threads (`ReleaseSafe` too) | races in `send` or the post queue |

### Then, in assembler-backend

`POST /api/wasm/build`, `POST /chat` and `POST /api/vertex` become
deferred, on a build pool and a chat pool. The build cap the plan asks for
becomes the build pool's size. `WasmBuilder` already gives each build its
own folder and the shared zig cache is safe for concurrent builds; its
sweep only deletes entries older than an hour, longer than any build may
run.

### What was built (2026-10-20)

By the names above, with these differences and additions:

- `src/lib/Reply.zig` (`reverb.Reply`) and `src/lib/Workers.zig`
  (`reverb.Workers`). `send` copies into one allocation laid out as
  content type, head room, body, so the loop builds the head in front of
  the body and sends the whole response with a single `write`. A second
  `send` trips an assert; an allocation failure in `send` still posts,
  and the loop closes the connection instead of leaving it to the reply
  timeout.
- Header building is `Context.writeHead(buf, Head)` over plain values,
  used by both `Context.buildStandardHeaders` and `Reply.render`. Cookies
  render through `Context.renderCookies` into caller memory, which also
  fixes a leak: `generateCookieString` built every `Set-Cookie` block in
  the process arena and never freed it.
- `ctx.SEND(status, content_type, body)`: the in-handler counterpart of
  `reply.send`, same signature. The header-equality test compares the two.
- The context reaches its server through `Context.defer_hook`, set once
  per pooled context in `Server.new`, so `Context` stays non-generic.
- `Server.reply_allocator` (default `std.heap.smp_allocator`) is where
  replies live; the test harness sets it to `std.testing.allocator`.
  `Config.reply_timeout_ms` is optional, passed through to Loom.
- `handle` is now: append, then `serveBuffered(client)`. The websocket
  branch moved to `handleWebSocket` so `handle`'s frame no longer holds a
  `MAX_RECV_SIZE` stack buffer while `serveBuffered` holds another.
- **`RequestBuffer` identity is `client.generation`, not the socket.** The
  kernel hands a closed descriptor's number to the next accept, so a new
  connection in the same slot could inherit the old one's unserved bytes.
  That was a latent bug before this work, and a sure one with deferral (the
  bytes behind a deferred request sit buffered). Covered by the slot test.
- Handler errors answer **500**; only a missing route or method answers
  404. After `deferReply`, a handler error is logged and nothing is sent.
- `Server.deinit` now calls `loom.deinit()` first, so posted replies run
  (and free themselves) while everything they could touch still exists.
- README "Replying later" section; the example in it is a real file,
  `examples/replying_later.zig`, compiled by `zig build check-readme`.

Injection results (`tests/defer_test.zig`, each run with the bug in):

| Test | Injected bug | Result |
| --- | --- | --- |
| other connections not held up | `submit` runs the job inline | fails |
| deferred == direct response | reply drops echoed `Allow-Headers` / drops cookies | fails / fails |
| keep-alive after deferred reply | no `resumeReads` | fails |
| pipelined in order | no `if (ctx.deferred) return` / no `serveBuffered` after reply | fails / fails |
| closed connection, same slot | lookup by slot only / request buffer keyed by socket | fails / fails |
| full queue 503 at once | blocking put (`min = 1`) | fails |
| `Connection: close` after reply | `close_requested` not captured | fails |
| handler error after defer | automatic error response kept | fails (2 responses) |
| shutdown with jobs queued | pool drops queued jobs / reply not freed when client gone | fails (leak) / fails (leak) |
| many concurrent | `send` posts before copying the body | **passes** as is; fails (segfault) with a 200 µs sleep widening the window |

Known gaps, not fixed:

- The concurrency test does not catch a post-before-copy race at its
  natural width, nor a non-threadsafe `reply_allocator` (tried with the
  server arena: passed). Both are races whose window is a few
  instructions wide.
- A client that hangs up while awaiting is not noticed until the reply is
  written or `reply_timeout_ms` passes: reads are paused, so no EOF event
  arrives. The slot stays taken meanwhile.
- If an earlier response on the same connection is still draining when a
  reply arrives, `write` fails with `WriteInProgress` and the connection is
  closed. Direct pipelined responses already behaved this way; it needs a
  write queue in Loom (or "run when drained") to fix properly.
- `closeWhenDrained` leaves a still-writing connection to the idle
  timeout (unchanged; applies to deferred replies the same way).

