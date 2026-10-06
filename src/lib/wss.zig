const std = @import("std");
const Allocator = std.mem.Allocator;
const Reverb = @import("server.zig").Reverb;
const Websocket = @import("loom").WebSocket;
const Context = @import("context.zig");

pub const Config = struct {
    max_body_size: usize,
    onConnection: *const fn (*Websocket, ctx: *Context) anyerror!void,
    onMessage: *const fn (*Websocket, Websocket.Message, ctx: *Context) anyerror!void,
};

pub const WSS = @This();
config: Config,

pub fn init(config: Config) !WSS {
    return WSS{
        .config = config,
    };
}

pub fn onConnection(wss: *WSS, ws: *Websocket, ctx: *Context) !void {
    return try wss.config.onConnection(ws, ctx);
}

pub fn onMessage(wss: *WSS, ws: *Websocket, msg: Websocket.Message, ctx: *Context) !void {
    return try wss.config.onMessage(ws, msg, ctx);
}
