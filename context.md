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
one packet" are Reverb's problem, handled in `readCompleteHttpRequest`
(`src/lib/server.zig`) and now covered by integration tests.

See `README.md` for the public API.

---

## 2. Current state (verified 2026-10-07)

```
16,528 lines of Zig across 46 files (after the package splits)
      83 test blocks, all of which run
      80 tests pass (48 unit, 32 integration)
```

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
zig build test              # 52 tests
zig build test-unit
zig build test-integration
zig build check-readme      # compiles the README quickstart
zig fmt --check src/ tests/ examples/readme_quickstart.zig build.zig
```

Running the Linux side from macOS:

```
zig test -femit-bin=/tmp/t -target x86_64-linux-musl --test-no-exec \
    --dep loom -Mroot=tests/integration.zig -Mloom=src/root.zig
docker run --rm --platform linux/amd64 -v /tmp:/w -w /w alpine:3 ./t
```

Loom, for reference: `cd ../loom && zig build test` (49 tests), and its
`TESTING.md` documents the injection matrix and known gaps.
