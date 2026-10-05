//! # Error Tracking Module
//!
//! A self-contained error tracking system for WASM/JS applications.
//!
//! ## Architecture
//!
//! ```
//! errors/
//! ├── mod.zig          ← this file (public API)
//! ├── types.zig        ← data types (ErrorReport, StackFrame, etc.)
//! ├── fingerprint.zig  ← SHA-256 grouping logic (pure, testable)
//! ├── store.zig        ← DB writes (upsert group → insert report → frames → events)
//! ├── queries.zig      ← DB reads for dashboard (wraps CRUD layer)
//! └── handlers.zig     ← HTTP handlers (thin glue between Reverb and store/queries)
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const errors = @import("errors/mod.zig");
//!
//! // In main.zig init:
//! var error_store  = errors.ErrorStore.init(pool);
//! var error_queries = errors.ErrorQueries.init(&crud);
//! var error_handlers = errors.ErrorHandlers.init(error_store, error_queries);
//!
//! // Register routes:
//! try server.post("/recordError",                   error_handlers.recordError);
//! try server.get ("/errors/groups",                 error_handlers.getGroups);
//! try server.get ("/errors/groups/:id/occurrences", error_handlers.getOccurrences);
//! try server.post("/errors/groups/:id/status",      error_handlers.updateStatus);
//! try server.get ("/errors/stats",                  error_handlers.getStats);
//! ```

// Re-export public types
pub const types = @import("types.zig");
pub const fingerprint = @import("fingerprint.zig");
pub const ErrorStore = @import("store.zig").ErrorStore;
pub const ErrorQueries = @import("../execute/queries.zig").ErrorQueries;
pub const ErrorHandlers = @import("../execute/handlers.zig").ErrorHandlers;

// Convenience type aliases
pub const ErrorReport = types.ErrorReport;
pub const StackFrame = types.StackFrame;
pub const WasmError = types.WasmError;
pub const TraceEvent = types.TraceEvent;
pub const CrashFields = types.CrashFields;
