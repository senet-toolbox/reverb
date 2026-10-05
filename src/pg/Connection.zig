//! Connection — owns a pg.Pool plus its config.
//!
//! Build a Config (manually or via Config.fromEnv) then call Connection.init.
//! Pass the *Connection (or its .pool()) into ORM builders, the CRUD struct, etc.
//!
//! Example:
//! ```zig
//! var conn = try Connection.init(allocator, .{
//!     .host = "127.0.0.1",
//!     .port = 5432,
//!     .username = "postgres",
//!     .password = "postgres",
//!     .database = "app",
//!     .pool_size = 10,
//! });
//! defer conn.deinit();
//!
//! var users = try orm.query(User).fetchAll(conn.pool());
//! ```

const std = @import("std");
const pg = @import("pg");

const Connection = @This();

allocator: std.mem.Allocator,
config: Config,
_pool: *pg.Pool,

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    username: []const u8 = "postgres",
    password: []const u8 = "postgres",
    database: []const u8 = "postgres",
    pool_size: u16 = 10,
    timeout_ms: u32 = 10_000,

    /// Build a Config by reading env keys via the supplied lookup fn.
    /// `lookup` returns `?[]const u8` for a given key — pass DotEnv.get,
    /// std.process.getEnvVarOwned wrapper, etc.
    ///
    /// Recognized keys (all optional, fall back to defaults):
    ///   PG_HOST, PG_PORT, PG_USER, PG_PASSWORD, PG_DB, PG_POOL_SIZE, PG_TIMEOUT_MS
    pub fn fromEnv(ctx: anytype, lookup: fn (@TypeOf(ctx), []const u8) ?[]const u8) Config {
        var cfg: Config = .{};

        if (lookup(ctx, "PG_HOST")) |v| cfg.host = v;
        if (lookup(ctx, "PG_PORT")) |v| {
            cfg.port = std.fmt.parseInt(u16, v, 10) catch cfg.port;
        }
        if (lookup(ctx, "PG_USER")) |v| cfg.username = v;
        if (lookup(ctx, "PG_PASSWORD")) |v| cfg.password = v;
        if (lookup(ctx, "PG_DB")) |v| cfg.database = v;
        if (lookup(ctx, "PG_POOL_SIZE")) |v| {
            cfg.pool_size = std.fmt.parseInt(u16, v, 10) catch cfg.pool_size;
        }
        if (lookup(ctx, "PG_TIMEOUT_MS")) |v| {
            cfg.timeout_ms = std.fmt.parseInt(u32, v, 10) catch cfg.timeout_ms;
        }

        return cfg;
    }
};

pub fn init(allocator: std.mem.Allocator, config: Config) !Connection {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const new_pool = pg.Pool.init(io, allocator, .{
        .size = config.pool_size,
        .connect = .{
            .port = config.port,
            .host = config.host,
        },
        .auth = .{
            .username = config.username,
            .database = config.database,
            .password = config.password,
            .timeout = config.timeout_ms,
        },
    }) catch |err| {
        std.debug.print("pg.Pool.init failed: {} (host={s} port={d} db={s} user={s})\n", .{
            err, config.host, config.port, config.database, config.username,
        });
        return err;
    };

    return .{
        .allocator = allocator,
        .config = config,
        ._pool = new_pool,
    };
}

pub fn deinit(self: *Connection) void {
    self._pool.deinit();
}

pub fn pool(self: *Connection) *pg.Pool {
    return self._pool;
}

/// Quick health check — runs `SELECT 1` against the pool.
pub fn ping(self: *Connection) !void {
    var result = try self._pool.query("SELECT 1", .{});
    defer result.deinit();
    _ = try result.next();
}
