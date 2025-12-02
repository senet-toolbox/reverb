const std = @import("std");
const Context = @import("context.zig");
const metrics_all_routes = @import("metrics.zig").getAllRoutes;
const Cookie = @import("core/Cookie.zig");
const Cors = @import("core/Cors.zig");
const Metrics = @import("metrics.zig");
const Reply = @import("core/ReplyBuilder.zig");
const Header = @import("core/Header.zig");
const Logger = @import("Logger.zig");
const Radix = @import("trees/radix.zig");
const helpers = @import("helpers.zig");
const Buckets = @import("metrics/Buckets.zig");
const Scheduler = @import("loom");
const WebSocket = @import("loom").WebSocket;
const WSS = @import("wss.zig");
// const xsuspend = Scheduler.xsuspend;
// const TLSStruct = @import("tls/tlsserver.zig");
const Reverb = @import("server.zig");
const Client = @import("loom").Client;
// const TLSServer = TLSStruct.TlsServer;
const mem = std.mem;
const Parsed = std.json.Parsed;
const print = std.debug.print;
const net = std.net;

const red = "\x1b[91m"; // ANSI escape code for red color
const yellow = "\x1b[93m"; // ANSI escape code for red color
const background = "\x1b[36m"; // ANSI escape code for red color
const reset = "\x1b[0m"; // ANSI escape code to reset color
const bold = "\x1b[1m"; // ANSI escape code to reset color
pub const Ctx_pm = struct {
    // path: [9]u8 = [9]u8{ '/', 'a', 'p', 'i', '/', 't', 'e', 's', 't' },
    // path: []const u8 = undefined,
    path: []const u8 = "",
    // method: []const u8 = undefined,
    method: []const u8 = "GET",
};

const digest_length = std.crypto.hash.Sha1.digest_length;
const Sha1 = std.crypto.hash.Sha1;
const base64 = std.base64;
pub fn generateAcceptKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    // The magic string to append (WebSocket GUID)
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    // Concatenate key + magic
    var concat = try allocator.alloc(u8, key.len + magic.len);
    defer allocator.free(concat);

    @memcpy(concat[0..key.len], key);
    @memcpy(concat[key.len..], magic);

    // Calculate SHA1 hash
    var hash: [digest_length]u8 = undefined;
    Sha1.hash(concat, &hash, .{});

    // Base64 encode
    const base64_size = base64.standard.Encoder.calcSize(hash.len);
    const encoded = try allocator.alloc(u8, base64_size);

    _ = base64.standard.Encoder.encode(encoded, &hash);

    return encoded;
}

var buf: [4096]u8 = undefined;
pub fn handle(
    // _: *Reverb,
    new_client: *Client,
    new_recv_data: []const u8,
    // ctx: *Context,
) !void {
    const client = new_client;
    const recv_data = new_recv_data;
    // Buckets.req_count += 1;
    // defer ctx.clear();
    var ctx_pm = Ctx_pm{};
    if (recv_data.len == 0) {
        // Browsers (or firefox?) attempt to optimize for speed
        // by opening a connection to the server once a user highlights
        // a link, but doesn't start sending the request until it's
        // clicked. The request eventually times out so we just
        // go agane.
        // try Reverb.instance.logger.warn("Got connection but no header!", .{}, @src());
        return;
    }

    const ctx = Reverb.ctx;
    defer ctx.clear();

    ctx.client = client;

    @memcpy(buf[0..recv_data.len], recv_data[0..]);

    ctx.client.?.msg = buf[0..recv_data.len];
    if (client.client_type == .WebSocket) {
        var ws = client.ws orelse {
            print("Parser not found\n", .{});
            return;
        };
        ws.parser.feed(client.msg) catch |err| {
            print("Error: {any}\n", .{err});
            return;
        };
        const message = ws.parser.nextMessage(true) catch |err| {
            print("Error: {any}\n", .{err});
            return;
        };
        // switch (message) {
        //     .Text => |text| {
        //         print("Text: {s}\n", .{text});
        //     },
        //     .Binary => |binary| {
        //         print("Binary: {any}\n", .{binary});
        //     },
        //     .Ping => |ping| {
        //         print("Ping: {any}\n", .{ping});
        //     },
        //     .Pong => |pong| {
        //         print("Pong: {any}\n", .{pong});
        //     },
        //     .Close => |close| {
        //         print("Close: {any}\n", .{close});
        //     },
        // }

        var wss: WSS = Reverb.instance.wss orelse {
            std.debug.print("No wss\n", .{});
            return;
        };

        try wss.onMessage(ws, message);
        return;
    }

    if (recv_data.len < 14 or
        !std.mem.startsWith(u8, recv_data, "GET ") and
            !std.mem.startsWith(u8, recv_data, "POST ") and
            !std.mem.startsWith(u8, recv_data, "PUT ") and
            !std.mem.startsWith(u8, recv_data, "DELETE ") and
            !std.mem.startsWith(u8, recv_data, "OPTIONS "))
    {
        const resp = "HTTP/1.1 404 MALFORMED REQUEST\r\n" ++
            "Content-Type: text/html\r\n" ++
            "Content-Length: 0\r\n\r\n";

        ctx.RAW(resp) catch |write_err| {
            return write_err;
        };
        return error.MalformedRequest;
    }

    const http_header = helpers.parseHeaders(buf[0..recv_data.len], &ctx_pm) catch |err| {
        print("Malformed Request: {any} {any}\n", .{ err, error.ParsingHeaders });
        const resp = "HTTP/1.1 404 MALFORMED REQUEST\r\n" ++
            "Content-Type: text/html\r\n" ++
            "Content-Length: 0\r\n\r\n";
        ctx.RAW(resp) catch |write_err| {
            print("Client Write Error: {any}\n", .{write_err});
        };
        return error.MalformedRequest;
    };

    // we need to consider this;
    ctx.method = ctx_pm.method;
    ctx.route = ctx_pm.path;
    ctx.content_type = http_header.content_type;
    ctx.http_header = http_header;
    ctx.http_header.path = ctx_pm.path;
    ctx.http_header.method = ctx_pm.method;
    ctx.http_header.accept_encoding = http_header.accept_encoding;

    if (http_header.content_length > Reverb.instance.loom.config.max_body_size) {
        Reverb.instance.logger.err("Request body too large", .{}) catch |log_err| {
            std.log.err("-----{any}", .{log_err});
        };
        const resp = "HTTP/1.1 413 Request body too large\r\n" ++
            "Content-Type: text/html\r\n" ++
            "Content-Length: 0\r\n";
        ctx.RAW(resp) catch |write_err| {
            print("Client Write Error: {any}\n", .{write_err});
        };
        return;
    }

    if (http_header.content_length > 0) {
        ctx.content_length = http_header.content_length;
        @memcpy(
            ctx.payload[0..http_header.content_length],
            buf[recv_data.len - http_header.content_length .. recv_data.len],
        );
        ctx.http_payload = ctx.payload[0..http_header.content_length];
    }
    // try Reverb.instance.logger.info("\n{s}", .{buf[0..recv_data.len]}, @src());

    if (recv_data[0] == 'O') {
        const success_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "Vary: Accept-Encoding, Origin\r\n" ++
            "Connection: Keep-Alive\r\n" ++
            "Content-Type: text/html; charset=utf8\r\n" ++
            "Content-Length: 0\r\n";
        try ctx.RAW(success_resp);
        return;
    }

    if (helpers.findIndex(http_header.connection, 'U') != null) {
        const accept_key = try generateAcceptKey(Reverb.instance.arena.*, http_header.ws_client_key);
        try client.fillWriteBuffer("HTTP/1.1 101 Switching Protocols\r\n");
        try client.fillWriteBuffer("Upgrade: websocket\r\n");
        try client.fillWriteBuffer("Connection: Upgrade\r\n");
        try client.fillWriteBuffer("Sec-WebSocket-Accept: ");
        try client.fillWriteBuffer(accept_key);
        try client.fillWriteBuffer("\r\n");

        // Handle permessage-deflate extension if needed
        try client.fillWriteBuffer("Sec-WebSocket-Extensions: permessage-deflate\r\n");

        // End headers
        try client.fillWriteBuffer("\r\n");
        _ = try client.writeMessage();

        const ws: *WebSocket = Reverb.instance.arena.create(WebSocket) catch unreachable;
        ws.* = WebSocket.init(client, Reverb.instance.arena, Reverb.instance.loom.config.max_body_size) catch |err| {
            print("Error: {any}\n", .{err});
            return;
        };

        client.state = .Idle;
        client.client_type = .WebSocket;
        client.ws = ws;

        var wss: WSS = Reverb.instance.wss orelse {
            std.debug.print("No wss\n", .{});
            return;
        };

        try wss.onConnection(client.ws.?);
        return;
    }

    if (http_header.cookie_str.len > 0) {
        helpers.parseCookies(ctx, http_header.cookie_str) catch {
            // Reverb.instance.logger.err("Cookie parsing {any}\n", .{ err }) catch |log_err| {
            //     std.log.err("Cookie {any}", .{log_err});
            // };
        };
    }

    const lookup_route_op = blk: {
        break :blk helpers.parseParams(ctx, ctx_pm.path) catch |err| {
            Reverb.instance.logger.err("Params parsing error: {any}", .{err}) catch |log_err| {
                std.log.err("Lookup {any}", .{log_err});
            };
            break :blk null; // or some default ParamDetails value
        };
    };
    if (lookup_route_op) |lookup_route| {
        ctx_pm.path = lookup_route;
    }

    ctx.http_header = http_header;

    // std.debug.print("*******Path: {s}--\n", .{ctx.http_header.path});
    // std.debug.print("*******Accept Encoding: {s}--\n", .{recv_data[0..]});
    Reverb.instance.callRoute(ctx_pm, ctx) catch |err| {
        Reverb.instance.logger.err("{any} Method: {s} Path: {s}", .{ err, ctx_pm.method, ctx_pm.path }) catch |log_err| {
            std.log.err("Logger Error: {any}", .{log_err});
        };
        const resp = "HTTP/1.1 404 NOT FOUND\r\n" ++
            "Content-Type: text/html\r\n" ++
            "Content-Length: 0\r\n\r\n";
        ctx.RAW(resp) catch |write_err| {
            return write_err;
        };
        return error.BrokenPipe;

        // switch (err) {
        //     error.ParsingMiddleware, error.AppendQueryParam, error.SearchRoute => {
        //         const resp = "HTTP/1.1 404 ERROR\r\n" ++
        //             "Content-Type: text/html\r\n" ++
        //             "Content-Length: 0\r\n\r\n";
        //         ctx.RAW(resp) catch |write_err| {
        //             print("Client Write Error: {any}\n", .{write_err});
        //             return write_err;
        //         };
        //     },
        //     error.RouteNotSupported => {
        //         const resp = "HTTP/1.1 404 Route not supported\r\n" ++
        //             "Content-Type: text/html\r\n" ++
        //             "Content-Length: 0\r\n\r\n";
        //         ctx.RAW(resp) catch |write_err| {
        //             print("Client Write Error: {any}\n", .{write_err});
        //             return write_err;
        //         };
        //         return;
        //     },
        //     error.MethodNotSupported => {
        //         const resp = "HTTP/1.1 404 Method not supported\r\n" ++
        //             "Content-Type: text/html\r\n" ++
        //             "Content-Length: 0\r\n\r\n";
        //         ctx.RAW(resp) catch |write_err| {
        //             print("Client Write Error: {any}\n", .{write_err});
        //             return write_err;
        //         };
        //         return;
        //     },
        //     error.RequestNotSupported => {
        //         const resp = "HTTP/1.1 404 Request not supported\r\n" ++
        //             "Content-Type: text/html\r\n" ++
        //             "Content-Length: 0\r\n\r\n";
        //         ctx.RAW(resp) catch |write_err| {
        //             print("Client Write Error: {any}\n", .{write_err});
        //             return write_err;
        //         };
        //     },
        //     // We need to record the errors
        //     else => {
        //         const resp = "HTTP/1.1 404 Request not supported\r\n" ++
        //             "Content-Type: text/html\r\n" ++
        //             "Content-Length: 0\r\n\r\n";
        //         ctx.RAW(resp) catch |write_err| {
        //             print("Client Write Error: {any}\n", .{write_err});
        //             return write_err;
        //         };
        //     },
        // }
        // xsuspend();
    };
    // const resp = "HTTP/1.1 200 OK\r\nDate: Tue, 19 Aug 2025 18:37:36 GMT\r\nContent-Length: 7\r\nContent-Type: text/plain charset=utf-8\r\n\r\nSUCCESS";
    // ctx.RAW(resp) catch |write_err| {
    //     print("Client Write Error: {any}\n", .{write_err});
    // };
    // xsuspend();
}
