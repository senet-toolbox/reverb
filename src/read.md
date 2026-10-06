# Error Tracking Module — Architecture

## Problem

The original `recorder.zig` was a single 280-line file that mixed:
- Data types
- SHA-256 fingerprinting
- HTTP handler logic
- 4 separate SQL INSERT operations with manual parameter tuples
- Dashboard query helpers

This caused `BindWrongType` errors that were impossible to debug because
pg.zig's tuple-based binding gives no indication of *which* parameter failed.

## Solution

Split into 5 focused files with clear boundaries:

```
errors/
├── mod.zig            Public API + re-exports
├── types.zig          Pure data types (no deps on pg or reverb)
├── fingerprint.zig    SHA-256 grouping (pure functions, fully testable)
├── store.zig          DB writes via pg.zig Stmt API (prepare → bind → execute)
├── queries.zig        DB reads for dashboard (delegates to CRUD layer)
├── handlers.zig       HTTP handlers (thin glue: parse request → call store/queries → send response)
└── migrations/
    └── 001_create_error_tables.sql
```

## Key Design Decisions

### 1. Stmt API instead of tuple binding

The original code used `pool.query(sql, .{ param1, param2, ... })` which
requires the Zig tuple types to exactly match what pg.zig expects at compile
time. This is the root cause of `BindWrongType`.

The new `store.zig` uses `conn.prepare()` → `stmt.bind()` × N → `stmt.execute()`,
which binds parameters one at a time. Each `bind()` call gets a single concrete
type, so pg.zig can handle coercion without ambiguity.

### 2. CrashFields helper

Instead of repeating the `if (crash) |cs| if (cs.line) |l| ...` pattern
9 times across the insert functions, `types.CrashFields.extract()` does it
once and returns a flat struct of nullable fields.

### 3. Queries go through CRUD

The dashboard reads (`listGroups`, `groupOccurrences`, etc.) delegate to
the existing `CRUD` layer which already handles:
- Acquiring/releasing connections
- PgError extraction
- OID → Value mapping
- JSON serialization

### 4. Handlers are stateless glue

Each handler does exactly 3 things:
1. Parse the request (bind JSON body or extract params)
2. Call store or queries
3. Send the response (JSON or error)

No business logic lives in handlers.

## Wiring (in main.zig)

```zig
const errors = @import("errors/mod.zig");

// Create the three layers:
var store    = errors.ErrorStore.init(pool);
var queries  = errors.ErrorQueries.init(&crud);
var handlers = errors.ErrorHandlers.init(store, queries);

// Register routes:
try server.post("/recordError",                   handlers.recordError);
try server.get ("/errors/groups",                 handlers.getGroups);
try server.get ("/errors/groups/:id/occurrences", handlers.getOccurrences);
try server.post("/errors/groups/:id/status",      handlers.updateStatus);
try server.get ("/errors/stats",                  handlers.getStats);
```

## Timestamp Binding

pg.zig natively binds `i64` to `timestamptz` columns as microseconds since
epoch. The client already sends timestamps in this format (e.g. `1771447143432000`),
so we pass them through directly — no `to_timestamp()` SQL cast needed.
