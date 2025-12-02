const std = @import("std");
const Allocator = std.mem.Allocator;
const Reverb = @import("server.zig").Reverb;
const Websocket = @import("loom").WebSocket;

pub const Config = struct {
    max_body_size: usize,
    onConnection: *const fn (*Websocket) anyerror!void,
    onMessage: *const fn (*Websocket, Websocket.Message) anyerror!void,
};

pub const WSS = @This();
config: Config,

pub fn init(config: Config) !WSS {
    return WSS{
        .config = config,
    };
}

pub fn onConnection(wss: *WSS, ws: *Websocket) !void {
    return try wss.config.onConnection(ws);
}

pub fn onMessage(wss: *WSS, ws: *Websocket, msg: Websocket.Message) !void {
    return try wss.config.onMessage(ws, msg);
}
