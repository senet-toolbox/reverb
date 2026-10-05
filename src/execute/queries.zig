const std = @import("std");
const pg = @import("pg");
const Crud = @import("../pg/crud.zig").CRUD;

/// Read-only queries for the error dashboard.
/// Delegates to the CRUD layer so results come back as QueryResponse
/// with proper PgError handling.
pub const ErrorQueries = struct {
    crud: *Crud,

    pub fn init(crud: *Crud) ErrorQueries {
        return .{ .crud = crud };
    }

    /// List error groups, optionally filtered by status.
    pub fn listGroups(self: *ErrorQueries, status: ?[]const u8, limit: i32) !Crud.QueryResponse {
        return self.crud.getErrorGroups(status, limit);
    }

    /// Get individual occurrences for a specific group.
    pub fn groupOccurrences(self: *ErrorQueries, group_id: []const u8, limit: i32) !Crud.QueryResponse {
        return self.crud.getErrorGroupOccurrences(group_id, limit);
    }

    /// Update group status (resolve, ignore, reopen).
    pub fn updateStatus(self: *ErrorQueries, group_id: []const u8, new_status: []const u8) !Crud.QueryResponse {
        return self.crud.updateGroupStatus(group_id, new_status);
    }

    /// Dashboard summary stats.
    pub fn dashboardStats(self: *ErrorQueries) !Crud.QueryResponse {
        return self.crud.rawQuery(dashboard_stats_sql);
    }

    const dashboard_stats_sql =
        \\SELECT
        \\  COUNT(*) FILTER (WHERE status = 'unresolved')  AS unresolved,
        \\  COUNT(*) FILTER (WHERE status = 'regressed')   AS regressed,
        \\  COUNT(*) FILTER (WHERE status = 'resolved')    AS resolved,
        \\  COUNT(*) FILTER (WHERE status = 'ignored')     AS ignored,
        \\  SUM(occurrence_count)                           AS total_occurrences,
        \\  COUNT(*) FILTER (WHERE last_seen > now() - interval '24 hours') AS active_24h
        \\FROM error_groups
    ;
};
