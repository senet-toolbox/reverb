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

## 2. Current state (verified 2026-10-05)

```
23,604 lines of Zig across 71 files
    84 test blocks, all of which run
    52 tests pass (37 unit, 15 integration)
```

- `zig build` succeeds. `zig build test` passes. `zig fmt --check` clean.
- No leaks: unit tests run under `std.testing.allocator`.
- CI on Linux and macOS, Debug and ReleaseSafe, plus a `zig fmt` check
  and a SIGTERM smoke test (`.github/workflows/ci.yml`).
- Builds standalone — verified by cloning to a directory with no sibling
  `../loom` and running the suite there.
- Graceful shutdown works: serves a request, exits 0 on SIGTERM, in both
  Debug and ReleaseSafe.
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

Method that worked, reused from Loom: **prove every regression test
fails.** The split-packet and parser fixes were each verified by
re-introducing the bug and confirming the test went red. Both did.

Also worth repeating: `timeout` does not exist on macOS. A command using
it exits 127 and looks like a pass.

---

## 4. Remaining work

1. **Pipelining is untested.** `expectedHttpRequestLength` returns only
   the first request's length and a unit test covers that, but nothing
   drives two requests in one `write()` over a socket and asserts two
   responses come back. The most likely remaining framing bug.
2. **Chunked transfer-encoding is not implemented.** `Content-Length` is
   the only body framing. A `Transfer-Encoding: chunked` request is
   currently mis-framed rather than rejected — worth at least a 411.
3. **The modules below have no tests**, and were never compiled until
   this branch: `src/lib/auth/` (KeyStone, Github, Google), `src/lib/payment/Stripe.zig`,
   `src/lib/claude/`, `src/pg/` (4,357 lines). `src/pg/` has 29 test
   blocks of its own that are still not wired into any test step.
4. **These files are reachable from nothing** (verified): `src/lib/core/Url.zig`,
   `src/lib/payment/Stripe.zig`, `src/lib/claude/{API,VERTEX}.zig`,
   `src/lib/core/Providers.zig`, `src/error_index.zig`,
   `src/assembler/api.zig`, `src/sample/sample.zig`. Unlike the files
   deleted on this branch, these look like standalone features rather
   than stale duplicates, so they were left alone. Decide which are
   wanted.
5. **`Cluster` for multi-worker throughput.** Loom measured 5.16× at 8
   workers. Do this last: the handler is per-worker, so `*Reverb` shared
   across workers needs a thread-safety audit — `arena`, `routes`,
   `logger`, `end_points` and the context pool are all shared today, and
   `Server.use_cors` / `signal_target` are statics.
6. **`src/lib/core/simdjson/` (7,551 lines) is vendored.** Its two test
   files were deleted here as dead; if it is a copy of simdjzon it should
   be a dependency instead.

---

## 5. Dead code removed on this branch

Ten files, ~6,100 lines, unreachable from every build root. Eight were
untracked, so commit `dbb7235` snapshots them before `98713bb` deletes
them — recover with `git show dbb7235:<path>`.

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

## 6. Commands

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
