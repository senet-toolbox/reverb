const orm = @import("../pg/orm.zig");
const schema = @import("../pg/schema.zig");
const pg = @import("pg");
const std = @import("std");

pub const Auth = struct {
    id: ?i32 = null,
    name: []const u8,
    email: []const u8,
    power: i32,

    pub const orm = .{
        .table = "users",
        .primary_key = .id,
        .schema = .{
            .id = .{ .type = .uuid, .primary_key = true, .default = .uuid_generate_v4 },
            .name = .{ .type = .text, .not_null = true },
            .email = .{ .type = .varchar, .length = 255, .unique = true, .not_null = true },
            .power = .{ .type = .int, .default = "0" },
        },
    };
};

pub fn createTableAuth(pool: *pg.Pool) !void {
    const ddl = comptime schema.createTableSql(Auth);
    std.debug.print("DDL: {s}\n", .{ddl});
    _ = pool;
}

// pub fn insertUser(pool: *pg.Pool) !void {
// }
