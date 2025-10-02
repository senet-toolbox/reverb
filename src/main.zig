//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const loompkg = @import("loom");
const Loom = loompkg.Loom;
const Client = loompkg.Client;
const Server = @import("lib/server.zig");
const Context = @import("lib/context.zig");

fn ping(ctx: *Context) !void {
    try ctx.STRING("SUCCESS");
}

const resp = "HTTP/1.1 200 OK\r\nDate: Tue, 19 Aug 2025 18:37:36 GMT\r\nContent-Length: 7\r\nContent-Type: text/plain charset=utf-8\r\n\r\nSUCCESS";
fn handle(client: *Client, _: []const u8) !void {
    try client.fillWriteBuffer(resp);
    _ = client.writeMessage() catch |err| {
        std.debug.print("Client Write Error: {any}\n", .{err});
    };
}

pub fn main() !void {
    var server: Server = undefined;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("Memmory leak...");
    var allocator = gpa.allocator();

    const loom_config = Server.Config{
        .max = 1024,
    };

    try server.new(loom_config, &allocator, null);
    try server.get("/ping", ping, &.{});
    try server.listen();
}
