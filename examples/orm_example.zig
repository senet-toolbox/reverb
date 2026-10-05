//! orm_example — end-to-end demo of the typed ORM.
//!
//! Run with:
//!   zig build orm-example
//!
//! Reads connection settings from these env vars (defaults shown):
//!   PG_HOST=127.0.0.1
//!   PG_PORT=5432
//!   PG_USER=postgres
//!   PG_PASSWORD=postgres
//!   PG_DB=postgres
//!   PG_POOL_SIZE=5
//!
//! Assumes a `users` table already exists. Set RUN_DDL=1 to let the example
//! exec the generated CREATE TABLE first (DDL is printed unconditionally so
//! you can copy-paste into psql).

const std = @import("std");
const pg = @import("pg");
const orm = @import("pg_orm");

const Connection = orm.Connection;
const schema = orm.schema;

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

const User = struct {
    id: i32,
    name: []const u8,
    email: []const u8,
    power: i32,

    pub const orm = .{
        .table = "users",
        .primary_key = .id,
        .schema = .{
            .id = .{ .type = .serial, .primary_key = true },
            .name = .{ .type = .text, .not_null = true },
            .email = .{ .type = .varchar, .length = 255, .unique = true, .not_null = true },
            .power = .{ .type = .int, .default = "0" },
        },
    };
};

// ---------------------------------------------------------------------------
// Tiny env lookup that wraps std.process.getEnvVarOwned + a backing arena.
// ---------------------------------------------------------------------------

const Env = struct {
    arena: std.heap.ArenaAllocator,

    fn init(parent: std.mem.Allocator) Env {
        return .{ .arena = std.heap.ArenaAllocator.init(parent) };
    }

    fn deinit(self: *Env) void {
        self.arena.deinit();
    }

    fn get(self: *Env, key: []const u8) ?[]const u8 {
        const a = self.arena.allocator();
        const key_z = std.fmt.allocPrintSentinel(a, "{s}", .{key}, 0) catch return null;
        const value_z = std.c.getenv(key_z.ptr) orelse return null;
        return a.dupe(u8, std.mem.span(value_z)) catch null;
    }
};

fn envLookup(env: *Env, key: []const u8) ?[]const u8 {
    return env.get(key);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    // ---- 1. Show the comptime-generated DDL ---------------------------------
    const ddl = comptime schema.createTableSql(User);
    std.debug.print("== DDL (generated at comptime) ==\n{s};\n\n", .{ddl});

    // ---- 2. Connect ---------------------------------------------------------
    const cfg = Connection.Config.fromEnv(&env, envLookup);
    var conn = try Connection.init(allocator, cfg);
    defer conn.deinit();

    orm.init(allocator);

    try conn.ping();
    std.debug.print("== Connected to {s}@{s}:{d}/{s} ==\n\n", .{
        cfg.username, cfg.host, cfg.port, cfg.database,
    });

    // Optional: actually run the DDL when RUN_DDL is set.
    if (env.get("RUN_DDL")) |_| {
        _ = try orm.rawExec(conn.pool(), ddl, .{});
        std.debug.print("(applied CREATE TABLE)\n\n", .{});
    }

    // ---- 3. INSERT ----------------------------------------------------------
    {
        std.debug.print("== INSERT ==\n", .{});
        var ib = orm.insert(User);
        defer ib.deinit();

        var res = try ib
            .values(.{ .name = "Goku", .email = "goku@cc.com", .power = 9001 })
            .values(.{ .name = "Vegeta", .email = "vegeta@cc.com", .power = 8500 })
            .returning(.{ .id, .name })
            .exec(conn.pool());
        defer res.deinit();

        std.debug.print("inserted {d} rows\n", .{res.affected_count});
        for (res.rows.items) |u| {
            std.debug.print("  id={d} name={s}\n", .{ u.id, u.name });
        }
        std.debug.print("\n", .{});
    }

    // ---- 4. SELECT ----------------------------------------------------------
    {
        std.debug.print("== SELECT power > 8000 ==\n", .{});
        var qb = orm.query(User);
        defer qb.deinit();

        var users = try qb
            .select(.{ .id, .name, .power })
            .where(.power, .gt, 8000)
            .orderBy(.power, .desc)
            .limit(10)
            .fetchAll(conn.pool());
        defer users.deinit();

        for (users.items) |u| {
            std.debug.print("  {s}: {d}\n", .{ u.name, u.power });
        }
        std.debug.print("\n", .{});
    }

    // ---- 5. fetchOne / count / exists --------------------------------------
    {
        std.debug.print("== count + exists ==\n", .{});
        var qb = orm.query(User);
        defer qb.deinit();
        const c = try qb.where(.power, .gt, 1000).count(conn.pool());
        std.debug.print("  count(power > 1000) = {d}\n", .{c});

        var qb2 = orm.query(User);
        defer qb2.deinit();
        const e = try qb2.where(.email, .eq, "goku@cc.com").exists(conn.pool());
        std.debug.print("  exists(email=goku@cc.com) = {}\n\n", .{e});
    }

    // ---- 6. UPDATE ----------------------------------------------------------
    {
        std.debug.print("== UPDATE ==\n", .{});
        var ub = orm.update(User);
        defer ub.deinit();
        const affected = try ub
            .set(.{ .power = 9500 })
            .where(.email, .eq, "goku@cc.com")
            .exec(conn.pool());
        std.debug.print("  updated {d} row(s)\n\n", .{affected});
    }

    // ---- 7. DELETE ----------------------------------------------------------
    {
        std.debug.print("== DELETE power < 9000 ==\n", .{});
        var db = orm.delete(User);
        defer db.deinit();
        const deleted = try db
            .where(.power, .lt, 9000)
            .exec(conn.pool());
        std.debug.print("  deleted {d} row(s)\n\n", .{deleted});
    }

    std.debug.print("== done ==\n", .{});
}
