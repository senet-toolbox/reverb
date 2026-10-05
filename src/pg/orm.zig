//! # Zig ORM
//!
//! A type-safe ORM for PostgreSQL built on top of pg.zig.
//!
//! ## Example
//!
//! ```zig
//! const User = struct {
//!     id: i32,
//!     name: []const u8,
//!     email: []const u8,
//!     power: i32,
//!
//!     pub const orm = .{
//!         .table = "users",
//!         .primary_key = .id,
//!     };
//! };
//!
//! // Query
//! var users = try orm.query(User)
//!     .where(.power, .gt, 9000)
//!     .orderBy(.name, .asc)
//!     .limit(10)
//!     .fetchAll(pool);
//! defer users.deinit();
//!
//! // Insert
//! var inserted = try orm.insert(User)
//!     .values(.{ .name = "Goku", .email = "goku@cc.com", .power = 9001 })
//!     .returning(.{ .id })
//!     .exec(pool);
//! defer inserted.deinit();
//!
//! // Update
//! const affected = try orm.update(User)
//!     .set(.{ .power = 9500 })
//!     .where(.id, .eq, 1)
//!     .exec(pool);
//!
//! // Delete
//! const deleted = try orm.delete(User)
//!     .where(.power, .lt, 1000)
//!     .exec(pool);
//! ```

const std = @import("std");
pub const pg = @import("pg");

// Re-export submodules
pub const meta = @import("meta.zig");
pub const operators = @import("operators.zig");
pub const sql = @import("sql.zig");
pub const clause = @import("clause.zig");
pub const result = @import("result.zig");
pub const query_builder = @import("query.zig");
pub const insert_builder = @import("insert.zig");
pub const update_builder = @import("update.zig");
pub const delete_builder = @import("delete.zig");
pub const raw_module = @import("raw.zig");
pub const schema = @import("schema.zig");
pub const Connection = @import("Connection.zig");

// Re-export commonly used types
pub const Op = operators.Op;
pub const Order = operators.Order;
pub const QueryResult = result.QueryResult;
pub const SingleResult = result.SingleResult;

// ============================================================================
// Public API
// ============================================================================

/// Global allocator for ORM operations
/// Set this before using the ORM, or pass allocator to individual builders
var global_allocator: ?std.mem.Allocator = null;

/// Initialize the ORM with a default allocator
pub fn init(allocator: std.mem.Allocator) void {
    global_allocator = allocator;
}

/// Get the current allocator (global or provided)
pub fn getAllocator(maybe_allocator: ?std.mem.Allocator) std.mem.Allocator {
    return maybe_allocator orelse global_allocator orelse @panic("ORM not initialized. Call orm.init(allocator) first.");
}

// ============================================================================
// Query Builder (SELECT)
// ============================================================================

/// Create a new SELECT query builder for the given model
pub fn query(comptime T: type) query_builder.QueryBuilder(T) {
    return query_builder.QueryBuilder(T).init(getAllocator(null));
}

/// Create a new SELECT query builder with a specific allocator
pub fn queryWith(comptime T: type, allocator: std.mem.Allocator) query_builder.QueryBuilder(T) {
    return query_builder.QueryBuilder(T).init(allocator);
}

// ============================================================================
// Insert Builder
// ============================================================================

/// Create a new INSERT builder for the given model
pub fn insert(comptime T: type) insert_builder.InsertBuilder(T) {
    return insert_builder.InsertBuilder(T).init(getAllocator(null));
}

pub fn insertViaColumns(
    table: []const u8,
    columns: []const []const u8,
    values: []const []const []const u8,
    returning: ?[]const []const u8,
) !sql.SqlBuilder {
    return try insert_builder.buildSqlFromColumns(
        getAllocator(null),
        table,
        columns,
        values,
        returning,
    );
}

/// Create a new INSERT builder with a specific allocator
pub fn insertWith(comptime T: type, allocator: std.mem.Allocator) insert_builder.InsertBuilder(T) {
    return insert_builder.InsertBuilder(T).init(allocator);
}

// ============================================================================
// Update Builder
// ============================================================================

/// Create a new UPDATE builder for the given model
pub fn update(comptime T: type) update_builder.UpdateBuilder(T) {
    return update_builder.UpdateBuilder(T).init(getAllocator(null));
}

/// Create a new UPDATE builder with a specific allocator
pub fn updateWith(comptime T: type, allocator: std.mem.Allocator) update_builder.UpdateBuilder(T) {
    return update_builder.UpdateBuilder(T).init(allocator);
}

// ============================================================================
// Delete Builder
// ============================================================================

/// Create a new DELETE builder for the given model
pub fn delete(comptime T: type) delete_builder.DeleteBuilder(T) {
    return delete_builder.DeleteBuilder(T).init(getAllocator(null));
}

/// Create a new DELETE builder with a specific allocator
pub fn deleteWith(comptime T: type, allocator: std.mem.Allocator) delete_builder.DeleteBuilder(T) {
    return delete_builder.DeleteBuilder(T).init(allocator);
}

// ============================================================================
// Raw SQL
// ============================================================================

/// Execute raw SQL with typed results
pub fn raw(comptime T: type, sql_str: []const u8, params: anytype) raw_module.RawBuilder(T) {
    return raw_module.RawBuilder(T).init(getAllocator(null), sql_str, params);
}

/// Execute raw SQL with typed results and specific allocator
pub fn rawWith(comptime T: type, allocator: std.mem.Allocator, sql_str: []const u8, params: anytype) raw_module.RawBuilder(T) {
    return raw_module.RawBuilder(T).init(allocator, sql_str, params);
}

/// Execute raw SQL without typed results (DDL, etc.)
pub fn rawExec(pool: *pg.Pool, sql_str: []const u8, params: anytype) !?usize {
    return raw_module.rawExec(pool, sql_str, params);
}

/// Execute raw SQL and get pg.Result directly. Caller owns and must deinit.
pub fn rawQuery(pool: *pg.Pool, sql_str: []const u8, params: anytype) !*pg.Result {
    return raw_module.rawQuery(pool, sql_str, params);
}

// ============================================================================
// Convenience functions
// ============================================================================

/// Find a single record by primary key
pub fn find(comptime T: type, pool: *pg.Pool, id: anytype) !SingleResult(T) {
    const Meta = meta.ModelMeta(T);
    const pk = comptime Meta.primaryKey() orelse @compileError("Model has no primary key defined");
    _ = pk;

    var qb = query(T);
    defer qb.deinit();

    return qb.where(.id, .eq, id).fetchOne(pool);
}

/// Find all records (no filter)
pub fn findAll(comptime T: type, pool: *pg.Pool) !QueryResult(T) {
    var qb = query(T);
    defer qb.deinit();

    return qb.fetchAll(pool);
}

/// Count all records
pub fn countAll(comptime T: type, pool: *pg.Pool) !i64 {
    var qb = query(T);
    defer qb.deinit();

    return qb.count(pool);
}

// ============================================================================
// Error types
// ============================================================================

pub const OrmError = error{
    NotFound,
    MultipleRowsFound,
    InvalidModel,
    MissingPrimaryKey,
    NoValuesToInsert,
    NoColumnsToUpdate,
    TooManyParameters,
};

// ============================================================================
// Tests
// ============================================================================

test "orm API compiles" {
    const User = struct {
        id: i32,
        name: []const u8,
        power: i32,

        pub const orm = .{
            .table = "users",
            .primary_key = .id,
        };
    };

    // Test that types compile
    _ = query_builder.QueryBuilder(User);
    _ = insert_builder.InsertBuilder(User);
    _ = update_builder.UpdateBuilder(User);
    _ = delete_builder.DeleteBuilder(User);
}
