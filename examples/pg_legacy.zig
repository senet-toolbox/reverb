// Reference-only example. Kept for historical context — see orm_example.zig
// for the maintained walkthrough. Imports go through the `pg_orm` module
// declared in build.zig.

const std = @import("std");
const pg = @import("pg");
const orm = @import("pg_orm");
const Insert = orm.insert_builder;
const query_mod = orm.query_builder;
const sql = orm.sql;

// ============================================================================
// Model Definitions
// ============================================================================

//-- Create a sample users table
const create_table =
    \\CREATE TABLE IF NOT EXISTS users (
    \\    id SERIAL PRIMARY KEY,
    \\    name VARCHAR(100) NOT NULL,
    \\    email VARCHAR(255) UNIQUE NOT NULL,
    \\    power INT DEFAULT 0,
    \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    \\);
;

// -- Insert some sample data
// \\INSERT INTO users (name, email, power) VALUES
// \\    ('Goku', 'goku@capsule.corp', 9001),
// \\    ('Vegeta', 'vegeta@capsule.corp', 8500),
// \\    ('Piccolo', 'piccolo@namek.org', 3500),
// \\    ('Gohan', 'gohan@orange.edu', 7000),
// \\    ('Krillin', 'krillin@kame.house', 1500);

const User = struct {
    id: i32,
    name: []const u8,
    email: []const u8,
    power: i32,
    created_at: ?i64 = null,

    pub const orm = .{
        .table = "users",
        .primary_key = .id,
    };
};

const Post = struct {
    id: i32,
    user_id: i32,
    title: []const u8,
    body: []const u8,

    pub const orm = .{
        .table = "posts",
        .primary_key = .id,
        .columns = .{
            .user_id = "user_id",
        },
    };
};

pub fn init() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize ORM with allocator
    orm.init(allocator);

    std.debug.print("Connecting to PostgreSQL...\n", .{});

    // Initialize connection pool
    var pool = pg.Pool.init(allocator, .{
        .size = 5,
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

    // insertRow(pool) catch |err| {
    //     std.debug.print("Failed to insert row: {}\n", .{err});
    //     return err;
    // };
}

const Value = sql.Value;

const ReturnedRow = struct {
    values: []Value,
};

const Type = enum {
    int,
    float,
    bool,
    string,
};

fn insertRow(pool: *pg.Pool) !void {
    const Row: struct {
        table: []const u8 = "users",
        columns: []const []const u8 = &.{ "id", "name", "email", "power" },
        column_types: []const Type = &.{ .int, .string, .string, .int },
        values: []const []const []const u8 = &.{&.{ "10", "Vic Rokx", "v.rokx.nellemann@gmail.com", "1000" }},
        returning: ?[]const []const u8 = &.{ "id", "name", "email" },
    } = .{};
    var builder = try orm.insertViaColumns(
        "users",
        Row.columns,
        Row.values,
        Row.returning,
    );
    defer builder.deinit();

    const sql_str = builder.toSql();
    const params = builder.params.slice();

    // Just execute, return count
    if (Row.returning == null) {
        const affected = try query_mod.executeRawExec(pool, sql_str, params) orelse 0;
        std.debug.print("Affected: {d}\n", .{affected});
        
    } else if (Row.returning) |ret_cols| {
        var pg_result = try query_mod.executeRawQuery(pool, sql_str, params);
        defer pg_result.deinit();

        var arena = std.heap.ArenaAllocator.init(orm.getAllocator(null));
        defer arena.deinit();
        const allocator = arena.allocator();

        var rows: std.array_list.Managed(ReturnedRow) = .init(allocator);
        var len: usize = Row.columns.len;

        len = ret_cols.len;

        var columns: []const []const u8 = Row.columns;
        columns = ret_cols;

        while (try pg_result.next()) |row| {
            var returned_row: ReturnedRow = .{ .values = try allocator.alloc(Value, len) };
            for (columns, 0..) |_, i| {
                switch (Row.column_types[i]) {
                    .int => {
                        const value = row.get(i32, i);
                        returned_row.values[i] = Value.from(value);
                    },
                    .float => {
                        const value = row.get(f32, i);
                        returned_row.values[i] = Value.from(value);
                    },
                    .bool => {
                        const value = row.get(bool, i);
                        returned_row.values[i] = Value.from(value);
                    },
                    .string => {
                        const value = row.get([]const u8, i);
                        returned_row.values[i] = Value.from(value);
                    },
                }
            }
            rows.append(returned_row) catch unreachable;
        }
    }
}

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
                .name = "Rokc",
                .email = "rokx@capsule.corp",
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

fn queryPowerfulUsers(pool: *pg.Pool) !void {
    var result = try pool.query("SELECT id, name, power FROM users WHERE power > $1 ORDER BY power DESC", .{5000});
    defer result.deinit();

    while (try result.next()) |row| {
        const id = row.get(i32, 0);
        const name = row.get([]const u8, 1);
        const power = row.get(i32, 2);
        std.debug.print("  ID: {}, Name: {s}, Power: {}\n", .{ id, name, power });
    }
}

fn getUserById(pool: *pg.Pool, user_id: i32) !void {
    const row = try pool.row("SELECT id, name, email, power FROM users WHERE id = $1", .{user_id});

    if (row) |r| {
        defer r.deinit();
        const id = r.get(i32, 0);
        const name = r.get([]const u8, 1);
        const email = r.get([]const u8, 2);
        const power = r.get(i32, 3);
        std.debug.print("  Found user: ID={}, Name={s}, Email={s}, Power={}\n", .{ id, name, email, power });
    } else {
        std.debug.print("  User with ID {} not found\n", .{user_id});
    }
}

fn insertUser(pool: *pg.Pool, name: []const u8, email: []const u8, power: i32) !void {
    // Check if user already exists
    var existing: ?pg.QueryRow = undefined;
    existing = try pool.row("SELECT id FROM users WHERE email = $1", .{email});
    if (existing) |*r| {
        try r.deinit();
        std.debug.print("  User with email {s} already exists, skipping insert\n", .{email});
        return;
    }

    const rows_affected = try pool.exec(
        "INSERT INTO users (name, email, power) VALUES ($1, $2, $3)",
        .{ name, email, power },
    );

    if (rows_affected) |count| {
        std.debug.print("  Inserted {} row(s) - Name: {s}, Email: {s}, Power: {}\n", .{ count, name, email, power });
    }
}

fn updateUserPower(pool: *pg.Pool, name: []const u8, new_power: i32) !void {
    const rows_affected = try pool.exec(
        "UPDATE users SET power = $1 WHERE name = $2",
        .{ new_power, name },
    );

    if (rows_affected) |count| {
        std.debug.print("  Updated {} row(s) - Set {s}'s power to {}\n", .{ count, name, new_power });
    }
}

fn countUsers(pool: *pg.Pool) !void {
    var row: ?pg.QueryRow = undefined;
    row = try pool.row("SELECT COUNT(*) FROM users", .{});

    if (row) |*r| {
        defer r.deinit() catch {};
        const count = r.get(i64, 0);
        std.debug.print("  Total users: {}\n", .{count});
    }
}

fn getAllUsers(pool: *pg.Pool) !void {
    var result = try pool.query("SELECT id, name, email, power FROM users ORDER BY id", .{});
    defer result.deinit();

    while (try result.next()) |row| {
        const id = row.get(i32, 0);
        const name = row.get([]const u8, 1);
        const email = row.get([]const u8, 2);
        const power = row.get(i32, 3);
        std.debug.print("  [{d:>2}] {s:<10} | {s:<25} | Power: {d:>5}\n", .{ id, name, email, power });
    }
}
