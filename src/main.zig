//! A minimal Reverb server.
//!
//! Run with `zig build run`, then `curl http://127.0.0.1:8080/`.

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
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();

    // Everything the server allocates lives as long as the server does, so
    // one arena is freed in a single step at shutdown.
    var arena = std.heap.ArenaAllocator.init(gpa_state.allocator());
    defer arena.deinit();

    var server: Server(Config) = undefined;
    try server.new(.{}, arena.allocator());
    defer server.deinit();

    // Lets SIGTERM and SIGINT return from `listen` so the deferred
    // `deinit` above actually runs, instead of the process being killed
    // part-way through a response.
    try server.installSignalHandlers();

    try server.get("/", ping, &.{});

    std.log.info("listening on http://127.0.0.1:8080/", .{});
    try server.listen();
    std.log.info("shut down cleanly", .{});
}
