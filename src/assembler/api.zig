const std = @import("std");
const Crud = @import("crud.zig");
const Context = @import("reverb").Context;

pub fn createUser(ctx: *Context) !void {
    const user = try ctx.glue(Crud.Auth);
    std.debug.print("user: {any}\n", .{user});
    try ctx.STRING("Inserted user");
}
