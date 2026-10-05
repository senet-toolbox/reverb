//! The quickstart from README.md.
//!
//! Compiled by `zig build check-readme` and in CI, so the first example a
//! reader runs stays working. Keep this and the README in step.

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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var server: Server(Config) = undefined;
    try server.new(.{}, arena.allocator());
    defer server.deinit();

    try server.installSignalHandlers();
    try server.get("/", ping, &.{});
    try server.listen();
}
