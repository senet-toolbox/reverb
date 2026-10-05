// ============================================================================
// Example: how to wire the errors module into your main.zig
//
// This is NOT a complete main.zig — it shows only the error-related parts
// so you can see how the pieces connect.
// ============================================================================

const std = @import("std");
const pg = @import("pg");
const Server = @import("reverb").Server;
const Crud = @import("pg/crud.zig").CRUD;
const errors = @import("errors/mod.zig");
const Context = @import("reverb").Context;

// These live at module scope so handler closures can reference them
var error_handlers: errors.ErrorHandlers = undefined;

pub fn init(crud: *Crud) !void {

    // ── Error tracking ───────────────────────────────────────────────
    const error_store = errors.ErrorStore.init(crud.pool, crud, crud.allocator);
    // _ = errors.ErrorQueries.init(crud);
    error_handlers = errors.ErrorHandlers.init(error_store, crud);
}

// ── Route handler wrappers ──────────────────────────────────────────────
// These are free functions (fn(*Context)) that Reverb expects,
// which delegate to the ErrorHandlers struct.

pub fn recordError(ctx: *Context) !void {
    return error_handlers.recordError(ctx);
}

pub fn getErrorGroups(ctx: *Context) !void {
    return error_handlers.getGroups(ctx);
}

pub fn getOccurrences(ctx: *Context) !void {
    return error_handlers.getOccurrences(ctx);
}

pub fn updateGroupStatus(ctx: *Context) !void {
    return error_handlers.updateStatus(ctx);
}

pub fn getErrorStats(ctx: *Context) !void {
    return error_handlers.getStats(ctx);
}

pub fn getGroupFrames(ctx: *Context) !void {
    return error_handlers.getGroupFrames(ctx);
}

pub fn getGroupEvents(ctx: *Context) !void {
    return error_handlers.getGroupEvents(ctx);
}

pub fn getTimeSeries(ctx: *Context) !void {
    return error_handlers.getTimeSeries(ctx);
}

pub fn deleteGroup(ctx: *Context) !void {
    return error_handlers.deleteGroup(ctx);
}

pub fn deleteAllResolved(ctx: *Context) !void {
    return error_handlers.deleteAllResolved(ctx);
}


