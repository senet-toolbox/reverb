const std = @import("std");
const Context = @import("reverb").Context;
const Crud = @import("../pg/crud.zig").CRUD;
const pg = @import("pg");
const types = @import("../errors/types.zig");
const ErrorStoreDB = @import("../errors/store.zig").ErrorStore;

pub const ErrorHandlers = struct {
    store: ErrorStoreDB,
    crud: *Crud,

    pub fn init(store: ErrorStoreDB, crud: *Crud) ErrorHandlers {
        return .{ .store = store, .crud = crud };
    }

    // POST /recordError
    pub fn recordError(self: *ErrorHandlers, ctx: *Context) !void {
        var report: types.ErrorReport = undefined;
        ctx.bind(types.ErrorReport, &report) catch |err| {
            std.log.err("[errors] Failed to bind report: {any}", .{err});
            return ctx.ERROR(400, "Invalid error report payload");
        };

        _ = self.store.record(report) catch |err| {
            std.log.err("[errors] Failed to record: {any}", .{err});
            return ctx.ERROR(500, "Failed to record error");
        };

        try ctx.STRING("OK");
    }

    // GET /errors/groups
    pub fn getGroups(self: *ErrorHandlers, ctx: *Context) !void {
        const status_param = if (ctx.queryParam("status")) |p| p.value else null;
        const response = self.crud.getErrorGroups(status_param, 100) catch {
            return ctx.ERROR(500, "Internal server error");
        };
        try sendResponse(ctx, response);
    }

    // GET /errors/groups/:id/occurrences
    pub fn getOccurrences(self: *ErrorHandlers, ctx: *Context) !void {
        const id = (ctx.queryParam("id") orelse return ctx.ERROR(400, "Missing group id")).value;
        const response = self.crud.getErrorGroupOccurrences(id, 50) catch {
            return ctx.ERROR(500, "Internal server error");
        };
        try sendResponse(ctx, response);
    }

    // GET /errors/groups/:id/frames
    pub fn getGroupFrames(self: *ErrorHandlers, ctx: *Context) !void {
        const id = (ctx.queryParam("id") orelse return ctx.ERROR(400, "Missing group id")).value;
        const response = self.store.getGroupStackFrames(id) catch {
            return ctx.ERROR(500, "Internal server error");
        };
        try sendResponse(ctx, response);
    }

    // GET /errors/groups/:id/events
    pub fn getGroupEvents(self: *ErrorHandlers, ctx: *Context) !void {
        const id = (ctx.queryParam("id") orelse return ctx.ERROR(400, "Missing group id")).value;
        const response = self.store.getGroupTraceEvents(id) catch {
            return ctx.ERROR(500, "Internal server error");
        };
        try sendResponse(ctx, response);
    }

    // GET /errors/timeseries
    pub fn getTimeSeries(self: *ErrorHandlers, ctx: *Context) !void {
        const response = self.store.getErrorTimeSeries() catch {
            return ctx.ERROR(500, "Internal server error");
        };
        try sendResponse(ctx, response);
    }

    // GET /errors/stats
    pub fn getStats(self: *ErrorHandlers, ctx: *Context) !void {
        const response = self.crud.rawQuery(
            \\SELECT
            \\  COUNT(*) FILTER (WHERE status = 'unresolved')  AS unresolved,
            \\  COUNT(*) FILTER (WHERE status = 'regressed')   AS regressed,
            \\  COUNT(*) FILTER (WHERE status = 'resolved')    AS resolved,
            \\  COUNT(*) FILTER (WHERE status = 'ignored')     AS ignored,
            \\  SUM(occurrence_count)                           AS total_occurrences,
            \\  COUNT(*) FILTER (WHERE last_seen > now() - interval '24 hours') AS active_24h
            \\FROM error_groups
        ) catch {
            return ctx.ERROR(500, "Internal server error");
        };
        try sendResponse(ctx, response);
    }

    // POST /errors/groups/:id/status?status=resolved
    pub fn updateStatus(self: *ErrorHandlers, ctx: *Context) !void {
        const id = (ctx.queryParam("id") orelse return ctx.ERROR(400, "Missing group id")).value;
        const new_status = (ctx.queryParam("status") orelse return ctx.ERROR(400, "Missing status param")).value;

        const response = self.crud.updateGroupStatus(id, new_status) catch {
            return ctx.ERROR(500, "Internal server error");
        };
        switch (response) {
            .ok => try ctx.STRING("OK"),
            .err => |pg_err| try sendPgError(ctx, pg_err),
        }
    }

    // DELETE /errors/groups/:id
    pub fn deleteGroup(self: *ErrorHandlers, ctx: *Context) !void {
        const id = (ctx.queryParam("id") orelse return ctx.ERROR(400, "Missing group id")).value;
        const response = self.store.deleteGroup(id) catch {
            return ctx.ERROR(500, "Internal server error");
        };
        switch (response) {
            .ok => try ctx.STRING("OK"),
            .err => |pg_err| try sendPgError(ctx, pg_err),
        }
    }

    // DELETE /errors/groups/resolved
    pub fn deleteAllResolved(self: *ErrorHandlers, ctx: *Context) !void {
        const response = self.store.deleteAllResolved() catch {
            return ctx.ERROR(500, "Internal server error");
        };
        try sendResponse(ctx, response);
    }
};

// ────────────────────────────────────────────────────────────────────

fn sendResponse(ctx: *Context, response: Crud.QueryResponse) !void {
    switch (response) {
        .ok => |result| {
            const json = try result.toObjectsJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            try ctx.STRING(json);
        },
        .err => |pg_err| try sendPgError(ctx, pg_err),
    }
}

fn sendPgError(ctx: *Context, pg_err: Crud.PgError) !void {
    const json = try pg_err.toJson(ctx.arena);
    ctx.http_header.content_type = .JSON;
    const status: u16 = if (pg_err.isUnique())
        409
    else if (pg_err.isForeignKey() or pg_err.isNotNull())
        422
    else if (pg_err.isSyntax() or pg_err.isUndefinedTable())
        400
    else
        500;
    try ctx.STATUS(status, json);
}
