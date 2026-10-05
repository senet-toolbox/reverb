const std = @import("std");
const Server = @import("reverb").Server;
const Context = @import("reverb").Context;

fn ping(ctx: *Context) !void {
    try ctx.STRING("SUCCESS");
}

const Config = struct {
    port: u16 = 8080,
    max: usize = 1024,
    max_body_size: usize = 1024 * 1024 * 10,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var server: Server(Config) = undefined;
    try server.new(.{}, allocator);
    try server.get("/", ping, &.{});
    try server.listen();
}
