const std = @import("std");
const Op = @import("operators.zig").Op;
const Order = @import("operators.zig").Order;
const sql = @import("sql.zig");
const Value = sql.Value;

/// Logical connector for WHERE clauses
pub const Connector = enum {
    @"and",
    @"or",

    pub fn toSql(self: Connector) []const u8 {
        return switch (self) {
            .@"and" => " AND ",
            .@"or" => " OR ",
        };
    }
};

/// A single WHERE condition
pub const WhereCondition = struct {
    column: []const u8,
    op: Op,
    value: Value,
    connector: Connector,

    pub fn init(column: []const u8, op: Op, value: anytype, connector: Connector) WhereCondition {
        return .{
            .column = column,
            .op = op,
            .value = Value.from(value),
            .connector = connector,
        };
    }
};

/// A raw WHERE condition (user-provided SQL)
pub const RawWhereCondition = struct {
    sql_fragment: []const u8,
    values: []const Value,
    connector: Connector,
};

/// WHERE clause builder
pub const WhereClause = struct {
    conditions: std.array_list.Managed(WhereCondition),
    raw_conditions: std.array_list.Managed(RawWhereCondition),
    raw_values_storage: std.array_list.Managed(Value),

    pub fn init(allocator: std.mem.Allocator) WhereClause {
        return .{
            .conditions = std.array_list.Managed(WhereCondition).init(allocator),
            .raw_conditions = std.array_list.Managed(RawWhereCondition).init(allocator),
            .raw_values_storage = std.array_list.Managed(Value).init(allocator),
        };
    }

    pub fn deinit(self: *WhereClause) void {
        self.conditions.deinit();
        self.raw_conditions.deinit();
        self.raw_values_storage.deinit();
    }

    pub fn add(self: *WhereClause, column: []const u8, op: Op, value: anytype, connector: Connector) !void {
        try self.conditions.append(WhereCondition.init(column, op, value, connector));
    }

    pub fn addRaw(self: *WhereClause, sql_fragment: []const u8, values: anytype, connector: Connector) !void {
        const start_idx = self.raw_values_storage.items.len;

        // Store the values
        inline for (std.meta.fields(@TypeOf(values))) |field| {
            try self.raw_values_storage.append(Value.from(@field(values, field.name)));
        }

        const end_idx = self.raw_values_storage.items.len;

        try self.raw_conditions.append(.{
            .sql_fragment = sql_fragment,
            .values = self.raw_values_storage.items[start_idx..end_idx],
            .connector = connector,
        });
    }

    pub fn isEmpty(self: *const WhereClause) bool {
        return self.conditions.items.len == 0 and self.raw_conditions.items.len == 0;
    }

    /// Build the WHERE clause SQL
    pub fn build(self: *const WhereClause, builder: *sql.SqlBuilder) !void {
        if (self.isEmpty()) return;

        try builder.append(" WHERE ");

        var first = true;

        // Regular conditions
        for (self.conditions.items) |cond| {
            if (!first) {
                try builder.append(cond.connector.toSql());
            }
            first = false;

            try builder.append(cond.column);
            try builder.appendChar(' ');
            try builder.append(cond.op.toSql());

            if (cond.op.requiresValue()) {
                try builder.appendChar(' ');
                try builder.addParam(cond.value);
            }
        }

        // Raw conditions
        for (self.raw_conditions.items) |raw| {
            if (!first) {
                try builder.append(raw.connector.toSql());
            }
            first = false;

            // Parse the raw SQL and replace $1, $2, etc. with new param numbers
            try self.appendRawWithParams(builder, raw.sql_fragment, raw.values);
        }
    }

    fn appendRawWithParams(self: *const WhereClause, builder: *sql.SqlBuilder, fragment: []const u8, values: []const Value) !void {
        _ = self;
        var i: usize = 0;
        var param_idx: usize = 0;

        while (i < fragment.len) {
            if (fragment[i] == '$' and i + 1 < fragment.len and std.ascii.isDigit(fragment[i + 1])) {
                // Found a parameter placeholder
                if (param_idx < values.len) {
                    try builder.storeParam(values[param_idx]);
                    try builder.appendFmt("${d}", .{builder.paramCount()});
                    param_idx += 1;
                }
                // Skip the original $N
                i += 1;
                while (i < fragment.len and std.ascii.isDigit(fragment[i])) {
                    i += 1;
                }
            } else {
                try builder.appendChar(fragment[i]);
                i += 1;
            }
        }
    }
};

/// ORDER BY clause
pub const OrderByClause = struct {
    orders: std.array_list.Managed(OrderBy),

    const OrderBy = struct {
        column: []const u8,
        order: Order,
    };

    pub fn init(allocator: std.mem.Allocator) OrderByClause {
        return .{
            .orders = std.array_list.Managed(OrderBy).init(allocator),
        };
    }

    pub fn deinit(self: *OrderByClause) void {
        self.orders.deinit();
    }

    pub fn add(self: *OrderByClause, column: []const u8, order: Order) !void {
        try self.orders.append(.{ .column = column, .order = order });
    }

    pub fn isEmpty(self: *const OrderByClause) bool {
        return self.orders.items.len == 0;
    }

    pub fn build(self: *const OrderByClause, builder: *sql.SqlBuilder) !void {
        if (self.isEmpty()) return;

        try builder.append(" ORDER BY ");

        for (self.orders.items, 0..) |ord, i| {
            if (i > 0) try builder.append(", ");
            try builder.append(ord.column);
            try builder.appendChar(' ');
            try builder.append(ord.order.toSql());
        }
    }
};

/// LIMIT and OFFSET
pub const LimitClause = struct {
    limit: ?i64 = null,
    offset: ?i64 = null,

    pub fn build(self: *const LimitClause, builder: *sql.SqlBuilder) !void {
        if (self.limit) |l| {
            try builder.append(" LIMIT ");
            try builder.addParam(l);
        }
        if (self.offset) |o| {
            try builder.append(" OFFSET ");
            try builder.addParam(o);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "WhereClause build" {
    var where = WhereClause.init(std.testing.allocator);
    defer where.deinit();

    try where.add("power", .gt, 9000, .@"and");
    try where.add("name", .like, "G%", .@"and");

    var builder = sql.SqlBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try where.build(&builder);

    try std.testing.expectEqualStrings(" WHERE power > $1 AND name LIKE $2", builder.toSql());
}

test "OrderByClause build" {
    var order_by = OrderByClause.init(std.testing.allocator);
    defer order_by.deinit();

    try order_by.add("power", .desc);
    try order_by.add("name", .asc);

    var builder = sql.SqlBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try order_by.build(&builder);

    try std.testing.expectEqualStrings(" ORDER BY power DESC, name ASC", builder.toSql());
}

test "LimitClause build" {
    var builder = sql.SqlBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const limit_clause = LimitClause{ .limit = 10, .offset = 20 };
    try limit_clause.build(&builder);

    try std.testing.expectEqualStrings(" LIMIT $1 OFFSET $2", builder.toSql());
}
