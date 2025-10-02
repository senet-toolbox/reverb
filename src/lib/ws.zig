const std = @import("std");
const print = std.debug.print;
const posix = std.posix;
const Client = @import("loom").Client;
const net = std.net;
// WebSocket opcodes (RFC 6455 Section 5.2)
pub const Opcode = enum(u4) {
    Continuation = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
};

// Create test frame bytes
const frame = [_]u8{
    0x81, // First byte: FIN=1, RSV1-3=0, Opcode=1 (text)
    0x85, // Second byte: Mask=1, Payload len=5
    0x37, 0xfa, 0x21, 0x3d, // Masking key
    0x7f, 0x9f, 0x4d, 0x51,
    0x58, // Masked "hello" payload
};

// 10000001  (129)
// 10000000  (0x80)
// --------  (AND)
// 10000000  = 128

// 129 131 61 84 35 6 112 16 109 MDN
pub fn readFrame(_: *Client, arena: *std.mem.Allocator, msg: []const u8) !void {
    var offset: usize = 0;
    // var fr: [11]u8 = undefined;
    const header = msg[offset..2];
    offset += 2;
    print("\n0x{x:<2}", .{msg});
    // _ = try stream.readAll(&header);
    const first_byte = header[0];
    const second_byte = header[1];
    // indicates if the full message was sent
    const fin = (first_byte & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(header[0] & 0x0F);
    print("\nFin: {any}", .{fin}); // true
    print("\nOpcode: {any}", .{opcode}); // 128

    // 131: 10000011
    const mask = (second_byte & 0x80) != 0;
    var payload_length: u64 = (second_byte & 0x7F);
    print("\nLength: {any}", .{payload_length}); // true

    // The following two bytes are the length
    if (payload_length == 126) {
        print("\n2 bytes", .{}); // 128
        const len_bytes = msg[offset..4];
        offset += 2;
        // _ = try stream.readAll(&len_bytes);
        payload_length = std.mem.readVarInt(u16, len_bytes, .big);
    } else if (payload_length > 126) {
        print("\n8 bytes", .{}); // 128
        const len_bytes = msg[offset..10];
        offset += 8;
        // _ = try stream.readAll(&len_bytes);
        payload_length = std.mem.readVarInt(u16, len_bytes, .big);
    }

    print("\nMask: {any}", .{mask}); // true
    // If the mask is set then the next 4 bytes as the masking key
    var masking_key: []const u8 = undefined;
    if (mask) {
        masking_key = msg[offset .. offset + 4];
        // _ = try stream.readAll(&masking_key);
        offset += 4;
    }

    print("\nMasking key: {any}", .{masking_key}); // true

    const payload = msg[offset..];
    print("\nPayload: {any}", .{payload}); // true
    var unmasked = try arena.alloc(u8, payload_length);
    // _ = try stream.readAll(payload);

    for (payload, 0..) |c, i| {
        unmasked[i] = c ^ masking_key[i % 4];
    }
    std.debug.print("\nUnmasked text: {s}\n", .{unmasked});
}

pub fn sendFrame(client: *Client, opcode: Opcode, payload: []const u8) !void {
    var header: [2]u8 = undefined;
    header[0] = @intFromEnum(opcode); // FIN bit set
    header[0] = header[0] | 0x80;
    if (payload.len <= 125) {
        header[1] = @intCast(payload.len);
    }
    // _ = try client.writeMessage();
    try client.fillWriteBuffer(&header);
    try client.fillWriteBuffer(payload);
    _ = try client.writeMessage();
    // try stream.writeAll(&header);
    // try stream.writeAll(payload);
}
