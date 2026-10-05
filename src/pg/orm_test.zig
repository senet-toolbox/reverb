const std = @import("std");
const orm = @import("orm.zig");
const pg = @import("pg");

// ============================================================================
// Model Definitions
// ============================================================================

const User = struct {
    id: i32,
    name: []const u8,
    email: []const u8,
    power: i32,
    created_at: ?i64 = null,

    pub const orm_config = .{
        .table = "users",
        .primary_key = .id,
    };
};

const Post = struct {
    id: i32,
    user_id: i32,
    title: []const u8,
    body: []const u8,

    pub const orm_config = .{
        .table = "posts",
        .primary_key = .id,
        .columns = .{
            .user_id = "user_id",
        },
    };
};

// ============================================================================
// Main
// ============================================================================

pub fn init() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();
    const allocator = std.heap.page_allocator;

    // Initialize ORM with allocator
    orm.init(allocator);

    std.debug.print("Connecting to PostgreSQL...\n", .{});

    const pool = pg.Pool.init(allocator, .{
        .size = 10,
        .connect = .{
            .port = 8081,
            .host = "127.0.0.1",
        },
        .auth = .{
            .username = "postgres",
            .database = "testdb",
            .password = "postgres",
            .timeout = 10_000,
        },
    }) catch |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        return err;
    };
    defer pool.deinit();

    std.debug.print("Connected successfully!\n\n", .{});

    // Run examples
    try exampleQuery(pool);
    // try exampleInsert(pool);
    // try exampleUpdate(pool);
    // try exampleDelete(pool);
    // try exampleRaw(pool);
    try exampleDebugSql(allocator);

    std.debug.print("\nAll examples completed successfully!\n", .{});
}

// ============================================================================
// Example: SELECT queries
// ============================================================================

fn exampleQuery(pool: *pg.Pool) !void {
    std.debug.print("=== SELECT Examples ===\n", .{});

    // Fetch all users with power > 5000
    {
        var qb = orm.query(User);
        defer qb.deinit();

        var users = try qb
            .select(.{ .id, .name, .power })
            .where(.power, .gt, 5000)
            .orderBy(.power, .desc)
            .limit(10)
            .fetchAll(pool);
        defer users.deinit();

        std.debug.print("Users with power > 5000:\n", .{});
        for (users.items) |user| {
            std.debug.print("  {s}: {d}\n", .{ user.name, user.power });
        }
    }

    // Fetch single user by ID
    {
        var qb = orm.query(User);
        defer qb.deinit();

        var result = try qb.where(.id, .eq, 1).fetchOne(pool);
        defer result.deinit();

        if (result.value) |user| {
            std.debug.print("Found user: {s} ({s})\n", .{ user.name, user.email });
        } else {
            std.debug.print("User not found\n", .{});
        }
    }

    // Count users
    {
        var qb = orm.query(User);
        defer qb.deinit();

        const count = try qb.where(.power, .gt, 1000).count(pool);
        std.debug.print("Users with power > 1000: {d}\n", .{count});
    }

    // Check if exists
    {
        var qb = orm.query(User);
        defer qb.deinit();

        const exists = try qb.where(.name, .eq, "Goku").exists(pool);
        std.debug.print("Goku exists: {}\n", .{exists});
    }

    std.debug.print("\n", .{});
}

// ============================================================================
// Example: INSERT
// ============================================================================

fn exampleInsert(pool: *pg.Pool) !void {
    std.debug.print("=== INSERT Examples ===\n", .{});

    // Single insert with returning
    {
        var ib = orm.insert(User);
        defer ib.deinit();

        var result = try ib
            .values(.{
                .name = "Trunks",
                .email = "trunks@capsule.corp",
                .power = 6000,
            })
            .returning(.{ .id, .name })
            .exec(pool);
        defer result.deinit();

        std.debug.print("Inserted {d} row(s)\n", .{result.affected_count});
        for (result.rows.items) |user| {
            std.debug.print("  New user ID: {d}, Name: {s}\n", .{ user.id, user.name });
        }
    }

    // Batch insert
    {
        var ib = orm.insert(User);
        defer ib.deinit();

        var result = try ib
            .values(.{ .name = "Android 17", .email = "a17@rr.army", .power = 5000 })
            .values(.{ .name = "Android 18", .email = "a18@rr.army", .power = 5000 })
            .exec(pool);
        defer result.deinit();

        std.debug.print("Batch inserted {d} row(s)\n", .{result.affected_count});
    }

    // Upsert
    {
        var ib = orm.insert(User);
        defer ib.deinit();

        var result = try ib
            .values(.{ .name = "Goku Updated", .email = "goku@capsule.corp", .power = 9500 })
            .onConflict(.{.email})
            .doUpdate(.{ .name, .power })
            .returning(.{.id})
            .exec(pool);
        defer result.deinit();

        std.debug.print("Upserted {d} row(s)\n", .{result.affected_count});
    }

    std.debug.print("\n", .{});
}

// ============================================================================
// Example: UPDATE
// ============================================================================

fn exampleUpdate(pool: *pg.Pool) !void {
    std.debug.print("=== UPDATE Examples ===\n", .{});

    var ub = orm.update(User);
    defer ub.deinit();

    const affected = try ub
        .set(.{ .power = 9001 })
        .where(.name, .eq, "Goku")
        .exec(pool);

    std.debug.print("Updated {d} row(s)\n\n", .{affected});
}

// ============================================================================
// Example: DELETE
// ============================================================================

fn exampleDelete(pool: *pg.Pool) !void {
    std.debug.print("=== DELETE Examples ===\n", .{});

    var db = orm.delete(User);
    defer db.deinit();

    const deleted = try db
        .where(.power, .lt, 100)
        .exec(pool);

    std.debug.print("Deleted {d} row(s)\n\n", .{deleted});
}

// ============================================================================
// Example: Raw SQL
// ============================================================================

fn exampleRaw(pool: *pg.Pool) !void {
    std.debug.print("=== Raw SQL Examples ===\n", .{});

    // Typed raw query
    {
        var rb = orm.raw(User, "SELECT * FROM users WHERE power > $1 ORDER BY power DESC LIMIT $2", .{ 5000, 5 });

        var users = try rb.fetchAll(pool);
        defer users.deinit();

        std.debug.print("Raw query returned {d} users\n", .{users.len()});
    }

    // Raw exec (no results)
    {
        const affected = try orm.rawExec(pool, "UPDATE users SET power = power + 1 WHERE name = $1", .{"Goku"});
        std.debug.print("Raw exec affected {?d} row(s)\n", .{affected});
    }

    std.debug.print("\n", .{});
}

// ============================================================================
// Example: Debug SQL (no execution)
// ============================================================================

fn exampleDebugSql(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Debug SQL Examples ===\n", .{});

    // Query
    {
        var qb = orm.queryWith(User, allocator);
        defer qb.deinit();

        _ = qb
            .select(.{ .id, .name })
            .where(.power, .gt, 9000)
            .where(.name, .like, "G%")
            .orderBy(.power, .desc)
            .limit(10);

        var debug = try qb.toSql();
        defer debug.deinit();

        std.debug.print("Query SQL: {s}\n", .{debug.sql_str});
        std.debug.print("Param count: {d}\n", .{debug.param_count});
    }

    // Insert
    {
        var ib = orm.insertWith(User, allocator);
        defer ib.deinit();

        _ = ib
            .values(.{ .name = "Test", .email = "test@test.com", .power = 100 })
            .returning(.{.id});

        var debug = try ib.toSql();
        defer debug.deinit();

        std.debug.print("Insert SQL: {s}\n", .{debug.sql_str});
    }

    // Update
    {
        var ub = orm.updateWith(User, allocator);
        defer ub.deinit();

        _ = ub
            .set(.{ .power = 9500 })
            .where(.id, .eq, 1);

        var debug = try ub.toSql();
        defer debug.deinit();

        std.debug.print("Update SQL: {s}\n", .{debug.sql_str});
    }

    // Delete
    {
        var db = orm.deleteWith(User, allocator);
        defer db.deinit();

        _ = db.where(.power, .lt, 1000);

        var debug = try db.toSql();
        defer debug.deinit();

        std.debug.print("Delete SQL: {s}\n", .{debug.sql_str});
    }

    std.debug.print("\n", .{});
}
