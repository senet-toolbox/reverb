const std = @import("std");

/// SQL comparison operators
pub const Op = enum {
    eq, // =
    neq, // != / <>
    gt, // >
    gte, // >=
    lt, // <
    lte, // <=
    like, // LIKE
    ilike, // ILIKE (case-insensitive)
    in, // IN (...)
    not_in, // NOT IN (...)
    is_null, // IS NULL
    is_not_null, // IS NOT NULL

    /// Convert operator to SQL string
    pub fn toSql(self: Op) []const u8 {
        return switch (self) {
            .eq => "=",
            .neq => "<>",
            .gt => ">",
            .gte => ">=",
            .lt => "<",
            .lte => "<=",
            .like => "LIKE",
            .ilike => "ILIKE",
            .in => "IN",
            .not_in => "NOT IN",
            .is_null => "IS NULL",
            .is_not_null => "IS NOT NULL",
        };
    }

    /// Check if operator requires a value
    pub fn requiresValue(self: Op) bool {
        return switch (self) {
            .is_null, .is_not_null => false,
            else => true,
        };
    }

    /// Check if operator uses array syntax IN (...)
    pub fn isArrayOp(self: Op) bool {
        return switch (self) {
            .in, .not_in => true,
            else => false,
        };
    }
};

/// Sort order for ORDER BY clauses
pub const Order = enum {
    asc,
    desc,

    pub fn toSql(self: Order) []const u8 {
        return switch (self) {
            .asc => "ASC",
            .desc => "DESC",
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Op toSql" {
    try std.testing.expectEqualStrings("=", Op.eq.toSql());
    try std.testing.expectEqualStrings("<>", Op.neq.toSql());
    try std.testing.expectEqualStrings("LIKE", Op.like.toSql());
    try std.testing.expectEqualStrings("IS NULL", Op.is_null.toSql());
}

test "Op requiresValue" {
    try std.testing.expect(Op.eq.requiresValue());
    try std.testing.expect(Op.like.requiresValue());
    try std.testing.expect(!Op.is_null.requiresValue());
    try std.testing.expect(!Op.is_not_null.requiresValue());
}

test "Order toSql" {
    try std.testing.expectEqualStrings("ASC", Order.asc.toSql());
    try std.testing.expectEqualStrings("DESC", Order.desc.toSql());
}
