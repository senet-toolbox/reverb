const std = @import("std");
const Cookie = @import("core/Cookie.zig");
const Context = @import("context.zig");
const mem = std.mem;
const testing = std.testing;
const crypto = std.crypto;
const fmt = std.fmt;
const print = std.debug.print;
const Server = @import("server.zig");
const Ctx_pm = @import("handler.zig").Ctx_pm;
const HttpHeader = @import("core/Header.zig");
const Reply = @import("core/ReplyBuilder.zig");

const ServerError = error{
    HeaderMalformed,
    RequestNotSupported,
    ProtoNotSupported,
    InternalServerError,
    MalformedFormContentType,
};

const CookieTypes = enum {
    // Authorization,
    Session,
};

const RequestTypes = enum {
    OPTIONS,
    GET,
    POST,
    PATCH,
    PUT,
    DELETE,
};

pub const ConnectionTypes = enum {
    Upgrade,
    Keep_Alive,
};

const Header = enum {
    Host,
    @"User-Agent",
    Cookie,
    Accept,
    Upgrade,
    @"Content-Type",
    @"Accept-Language",
    @"Accept-Encoding",
    @"Access-Control-Request-Method",
    @"Access-Control-Request-Headers",
    @"Sec-WebSocket-Key",
    @"Sec-WebSocket-Version",
};

const HeaderCookie = enum {
    Cookie,
};

pub const ContentType = enum {
    None,
    Text,
    Form,
    MultiForm,
    JSON,
    WASM,

    pub fn toString(self: ContentType) []const u8 {
        return switch (self) {
            .None => "",
            .Text => "text/plain; charset=utf-8",
            .Form => "application/x-www-form-urlencoded",
            .MultiForm => "multipart/form-data",
            .JSON => "application/json",
            .WASM => "application/wasm",
        };
    }
};

pub const MAX_HEADER_SIZE: usize = 16 * 1024;

pub const HTTPHeader = struct {
    request_line: []const u8 = "",
    origin: []const u8 = "",
    host: []const u8 = "",
    accept: []const u8 = "",
    upgrade: []const u8 = "",
    user_agent: []const u8 = "",
    cookie: []const u8 = "",
    cookie_str: []const u8 = "",
    content_type: ContentType = ContentType.Text,
    content_encoding: []const u8 = "",
    content_length: usize = 0,
    connection: []const u8 = "",
    path: []const u8 = "",
    body: []const u8 = "",
    // cookies: std.ArrayList([]const u8),
    method: []const u8 = "",
    authorization: []const u8 = "",
    accept_language: []const u8 = "",
    accept_encoding: []const u8 = "",
    accept_control_request_method: []const u8 = "",
    accept_control_request_headers: []const u8 = "",
    sec_websocket_extensions: []const u8 = "",
    boundary: ?[]const u8 = "",
    ws_version: []const u8 = "",
    ws_client_key: []const u8 = "",
    referer: []const u8 = "",
    _buffer: [MAX_HEADER_SIZE]u8 = undefined,

    pub fn init(_: *std.mem.Allocator) !HTTPHeader {
        return HTTPHeader{
            .request_line = "",
            .host = "",
            .upgrade = "",
            .accept = "",
            .user_agent = "",
            .cookie = "",
            // .cookies = std.ArrayList([]const u8).init(arena.*),
            .method = "",
            .content_type = ContentType.None,
            .content_encoding = "",
            .authorization = "",
            .accept_language = "",
            .accept_encoding = "",
            .accept_control_request_method = null,
            .accept_control_request_headers = "",
            .boundary = null,
            .ws_version = "",
            .ws_client_key = "",
        };
    }

    pub fn deinit(http_header_: *HTTPHeader) void {
        http_header_.cookies.deinit();
    }

    pub fn print(self: HTTPHeader) !void {
        std.debug.print("Req: {s}\nUser: {s}\nHost: {s}\n", .{
            self.request_line,
            self.user_agent,
            self.host,
            self.method,
        });
    }
};

/// Generates a random session id. Caller owns the returned memory.
///
/// Takes an allocator rather than reaching for `std.heap.c_allocator`,
/// which forced a libc dependency and left every id it produced leaked.
pub fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    var uuid_buf: [36]u8 = undefined;
    newV4().to_string(&uuid_buf);

    return convertStringToSlice(&uuid_buf, allocator);
}

/// Returns the session id from the request's cookies, or a freshly
/// generated one. Only the generated case allocates, from `allocator`.
pub fn parseSession(allocator: std.mem.Allocator, recv_data: []const u8) ![]const u8 {
    const cookie = parseCookie(recv_data);
    if (cookie != null) {
        var cookie_itr = std.mem.splitSequence(u8, cookie.?, "=");
        while (cookie_itr.next()) |line| {
            const cookie_type = std.meta.stringToEnum(CookieTypes, line) orelse continue;
            switch (cookie_type) {
                // .Authorization => {
                //     return convertStringTo16Slice(cookie_itr.peek().?);
                // },
                .Session => {
                    return cookie_itr.peek().?;
                },
            }
            cookie_itr.next();
        }
    }
    return generateSessionId(allocator);
}

fn parseCookie(header: []const u8) ?[]const u8 {
    var header_itr = std.mem.tokenizeSequence(u8, header, "\r\n");
    while (header_itr.next()) |line| {
        const name_slice = std.mem.sliceTo(line, ':');
        const header_name = std.meta.stringToEnum(HeaderCookie, name_slice) orelse continue;
        const header_value = std.mem.trimLeft(u8, line[name_slice.len + 1 ..], " ");
        switch (header_name) {
            .Cookie => return header_value,
        }
    }

    return null;
}

fn convertStringTo16Slice(haystack: []const u8) [16]u8 {
    var result: [16]u8 = [_]u8{0} ** 16; // Initialize with zeroes.
    std.mem.copyForwards(u8, result[0..16], haystack[0..16]);
    return result;
}

pub fn parseMethod(request_line: []const u8) ![]const u8 {
    var path_iter = mem.tokenizeScalar(u8, request_line, ' ');
    const method = try matchMethod(&path_iter);
    return method;
}

pub fn parsePath(request_line: []const u8) ![]const u8 {
    var path_iter = mem.tokenizeScalar(u8, request_line, ' ');
    _ = path_iter.next().?;
    const path = path_iter.next().?;
    if (path.len <= 0) return error.NoPath;
    const proto = path_iter.next().?;
    if (!mem.eql(u8, proto, "HTTP/1.1")) return ServerError.ProtoNotSupported;
    return path;
}

pub fn findIndex(haystack: []const u8, needle: u8) ?usize {
    const vec_len = 16;
    const Vec16 = @Vector(16, u8);
    const splt_16: Vec16 = @splat(@as(u8, needle));
    if (haystack.len >= vec_len) {
        var i: usize = 0;
        while (i + vec_len <= haystack.len) : (i += vec_len) {
            const v = haystack[i..][0..vec_len].*;
            const vec: Vec16 = @bitCast(v);
            const mask = vec == splt_16;
            const bits: u16 = @bitCast(mask);
            if (bits != 0) {
                return i + @ctz(bits);
            }
        }
    }
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }
    return null;
}

pub fn isSupportedHttpMethodPrefix(payload: []const u8) bool {
    if (payload.len == 0) return true;

    const methods = [_][]const u8{
        "GET ",
        "POST ",
        "PUT ",
        "DELETE ",
        "OPTIONS ",
        "HEAD ",
        "CONNECT ",
        "TRACE ",
        "PATCH ",
    };

    for (methods) |method| {
        const prefix_len = @min(payload.len, method.len);
        if (std.mem.eql(u8, payload[0..prefix_len], method[0..prefix_len])) {
            return true;
        }
    }

    return false;
}

fn parseHeaderContentLength(headers: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch return error.MalformedRequest;
    }

    return 0;
}

/// How a request's body is framed.
pub const BodyFraming = enum {
    /// `Content-Length`, or no body at all.
    length,
    /// `Transfer-Encoding: chunked`.
    chunked,
};

/// Decides how the head says the body is framed.
///
/// `identity` means "no encoding applied", so it leaves `Content-Length` in
/// charge. Anything else is rejected: a coding this server cannot decode
/// must not be treated as a zero-length body, because the undecoded bytes
/// would then be read as the next request on the connection.
fn bodyFraming(headers: []const u8) !BodyFraming {
    var framing: BodyFraming = .length;
    var saw_transfer_encoding = false;

    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // request line

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(value, "identity")) continue;
        if (!std.ascii.eqlIgnoreCase(value, "chunked")) {
            return error.UnsupportedTransferEncoding;
        }
        saw_transfer_encoding = true;
        framing = .chunked;
    }

    // Both headers together is the classic smuggling setup: two parties can
    // disagree about which one frames the body.
    if (saw_transfer_encoding and hasContentLength(headers)) {
        return error.UnsupportedTransferEncoding;
    }

    return framing;
}

fn hasContentLength(headers: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) return true;
    }
    return false;
}

/// True when the request asks for the connection to be closed once the
/// response is sent.
///
/// `Connection: close` on an HTTP/1.1 request, or the absence of
/// `Connection: keep-alive` on anything older, since keep-alive only became
/// the default in 1.1.
pub fn wantsConnectionClose(request_line: []const u8, connection: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, connection, ',');
    while (tokens.next()) |token| {
        const value = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(value, "close")) return true;
        if (std.ascii.eqlIgnoreCase(value, "keep-alive")) return false;
    }

    // No opinion stated: 1.1 and later keep the connection, older versions
    // close it.
    return std.mem.indexOf(u8, request_line, "HTTP/1.1") == null;
}

/// True when the head declares `Transfer-Encoding: chunked`.
///
/// Only meaningful on a head that `expectedHttpRequestLength` has already
/// accepted, which is where an unsupported coding is rejected.
pub fn isChunked(headers: []const u8) bool {
    return (bodyFraming(headers) catch return false) == .chunked;
}

/// Parses a chunk-size line, ignoring any `;ext=val` suffix.
fn parseChunkSize(line: []const u8) !usize {
    const end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    const digits = std.mem.trim(u8, line[0..end], " \t");
    if (digits.len == 0) return error.MalformedRequest;
    return std.fmt.parseInt(usize, digits, 16) catch error.MalformedRequest;
}

/// Measures a chunked body.
///
/// `body` starts at the first chunk-size line. Returns how many bytes the
/// whole encoded body occupies — every chunk, the terminating zero chunk,
/// any trailers and the final CRLF — along with how much data it decodes
/// to. Returns null while the body is still incomplete.
///
/// `max_body_size` is checked against the *decoded* size, because that is
/// what a handler is handed.
fn chunkedBodyExtent(body: []const u8, max_body_size: usize) !?struct {
    encoded_len: usize,
    decoded_len: usize,
} {
    var pos: usize = 0;
    var decoded: usize = 0;

    while (true) {
        // Chunk size line.
        const line_end = std.mem.indexOfPos(u8, body, pos, "\r\n") orelse {
            // Guard against a client dribbling an endless size line.
            if (body.len - pos > MAX_HEADER_SIZE) return error.HeaderTooLarge;
            return null;
        };
        const size = try parseChunkSize(body[pos..line_end]);
        pos = line_end + 2;

        if (size == 0) {
            // Terminating chunk, then optional trailers, then a blank line.
            const trailers_end = std.mem.indexOfPos(u8, body, pos, "\r\n") orelse {
                if (body.len - pos > MAX_HEADER_SIZE) return error.HeaderTooLarge;
                return null;
            };
            if (trailers_end == pos) {
                // No trailers: the CRLF just found closes the body.
                return .{ .encoded_len = pos + 2, .decoded_len = decoded };
            }
            // Trailers present; they end at a blank line.
            const end = std.mem.indexOfPos(u8, body, pos, "\r\n\r\n") orelse {
                if (body.len - pos > MAX_HEADER_SIZE) return error.HeaderTooLarge;
                return null;
            };
            return .{ .encoded_len = end + 4, .decoded_len = decoded };
        }

        // Refuse before the addition can wrap.
        if (size > max_body_size or decoded > max_body_size - size) {
            return error.BodyTooLarge;
        }
        decoded += size;

        // Chunk data, then its own CRLF.
        if (body.len < pos + size + 2) return null;
        if (!std.mem.eql(u8, body[pos + size .. pos + size + 2], "\r\n")) {
            return error.MalformedRequest;
        }
        pos += size + 2;
    }
}

/// Decodes a chunked body in place, returning the decoded length.
///
/// `body` must be exactly one complete chunked body, as measured by
/// `chunkedBodyExtent`. Decoding in place is sound because the encoding is
/// always strictly larger than what it encodes: every chunk carries a size
/// line and a trailing CRLF, so the read position stays ahead of the write
/// position throughout.
pub fn decodeChunkedBody(body: []u8) !usize {
    var read: usize = 0;
    var write: usize = 0;

    while (true) {
        const line_end = std.mem.indexOfPos(u8, body, read, "\r\n") orelse
            return error.MalformedRequest;
        const size = try parseChunkSize(body[read..line_end]);
        read = line_end + 2;

        if (size == 0) return write;

        if (body.len < read + size + 2) return error.MalformedRequest;
        std.mem.copyForwards(u8, body[write .. write + size], body[read .. read + size]);
        write += size;
        read += size + 2;
    }
}

/// How many bytes make up the first complete request in `payload`, or null
/// if it has not all arrived yet.
///
/// This is the only thing standing between one request's bytes and the
/// next, so getting it wrong either stalls a connection or lets a body be
/// read as a following request.
pub fn expectedHttpRequestLength(payload: []const u8, max_body_size: usize) !?usize {
    const headers_end = findCRLFCRLF(payload) orelse {
        if (payload.len > MAX_HEADER_SIZE) return error.HeaderTooLarge;
        return null;
    };
    const header_len = headers_end + 4;
    if (header_len > MAX_HEADER_SIZE) return error.HeaderTooLarge;

    switch (try bodyFraming(payload[0..headers_end])) {
        .chunked => {
            const extent = try chunkedBodyExtent(payload[header_len..], max_body_size) orelse
                return null;
            return header_len + extent.encoded_len;
        },
        .length => {},
    }

    const content_length = try parseHeaderContentLength(payload[0..headers_end]);
    if (content_length > max_body_size) return error.BodyTooLarge;

    const total_len = header_len + content_length;
    if (payload.len < total_len) return null;

    return total_len;
}

pub fn findCRLFCRLF(payload: []const u8) ?usize {
    if (payload.len < 4) return null;
    var i: usize = 0;
    if (payload.len >= 64) {
        // print("We check 64\n", .{});
        const V = @Vector(64, u8);
        const cr_pattern: V = @splat('\r');

        while (i + 64 <= payload.len) : (i += 64) {
            const chunk: V = payload[i..][0..64].*;
            const cr_matches = chunk == cr_pattern;
            const cr_mask: u64 = @bitCast(cr_matches);

            if (cr_mask != 0) {
                var mask = cr_mask;
                while (mask != 0) {
                    const pos = i + @ctz(mask);
                    if (pos + 3 < payload.len and
                        payload[pos + 1] == '\n' and
                        payload[pos + 2] == '\r' and
                        payload[pos + 3] == '\n')
                    {
                        return pos;
                    }
                    mask &= mask - 1;
                }
            }
        }

        // Check remaining bytes after last 64-byte chunk
        i -= 3; // Ensure we check overlapping with the last chunk's end
        while (i < payload.len - 3) : (i += 1) {
            if (payload[i] == '\r' and
                payload[i + 1] == '\n' and
                payload[i + 2] == '\r' and
                payload[i + 3] == '\n')
            {
                return i;
            }
        }
        return null;
    }

    if (payload.len >= 32) {
        const V = @Vector(32, u8);
        const cr_pattern: V = @splat('\r');

        while (i + 32 <= payload.len) : (i += 32) {
            const chunk: V = payload[i..][0..32].*;
            const cr_matches = chunk == cr_pattern;
            const cr_mask: u32 = @bitCast(cr_matches);

            if (cr_mask != 0) {
                var mask = cr_mask;
                while (mask != 0) {
                    const pos = i + @ctz(mask);
                    if (pos + 3 < payload.len and
                        payload[pos + 1] == '\n' and
                        payload[pos + 2] == '\r' and
                        payload[pos + 3] == '\n')
                    {
                        return pos;
                    }
                    mask &= mask - 1;
                }
            }
        }

        // Check remaining bytes after last 32-byte chunk
        i -= 3; // Ensure we check overlapping with the last chunk's end
        while (i < payload.len - 3) : (i += 1) {
            if (payload[i] == '\r' and
                payload[i + 1] == '\n' and
                payload[i + 2] == '\r' and
                payload[i + 3] == '\n')
            {
                return i;
            }
        }
        return null;
    }

    if (payload.len >= 16) {
        const V = @Vector(16, u8);
        const cr_pattern: V = @splat('\r');

        while (i + 16 <= payload.len) : (i += 16) {
            const chunk: V = payload[i..][0..16].*;
            const cr_matches = chunk == cr_pattern;
            const cr_mask: u16 = @bitCast(cr_matches);

            if (cr_mask != 0) {
                var mask = cr_mask;
                while (mask != 0) {
                    const pos = i + @ctz(mask);
                    if (pos + 3 < payload.len and
                        payload[pos + 1] == '\n' and
                        payload[pos + 2] == '\r' and
                        payload[pos + 3] == '\n')
                    {
                        return pos;
                    }
                    mask &= mask - 1;
                }
            }
        }

        // Check remaining bytes after last 16-byte chunk
        i -= 3; // Ensure we check overlapping with the last chunk's end
        while (i < payload.len - 3) : (i += 1) {
            if (payload[i] == '\r' and
                payload[i + 1] == '\n' and
                payload[i + 2] == '\r' and
                payload[i + 3] == '\n')
            {
                return i;
            }
        }
        return null;
    }

    // Non-SIMD path for small payloads
    var j: usize = i;
    while (j <= payload.len - 4) : (j += 1) {
        if (payload[j] == '\r' and
            payload[j + 1] == '\n' and
            payload[j + 2] == '\r' and
            payload[j + 3] == '\n')
        {
            return j;
        }
    }
    return null;
}
// Pre-computed lookup table for header types
const HeaderLookup = struct {
    // First level lookup based on first char
    first_char: [256]u8,

    pub fn init() @This() {
        var table = @This(){
            .first_char = [_]u8{0} ** 256,
        };

        // Initialize with special values for known headers
        table.first_char['G'] = 1; // GET
        table.first_char['P'] = 2; // POST/PATCH
        table.first_char['D'] = 3; // DELETE
        table.first_char['U'] = 4; // UPDATE/User-Agent
        table.first_char['H'] = 5; // Host
        table.first_char['C'] = 6; // Connection/Cookie/Content-Type/Content-Length
        table.first_char['A'] = 7; // Accept-*
        table.first_char['O'] = 8; // Origin
        table.first_char['R'] = 9; // Referer
        table.first_char['S'] = 10; // Referer
        table.first_char['s'] = 11; // sec-ch-ua

        return table;
    }
}.init();

// Pre-allocated buffer for common strings
const CommonStrings = struct {
    get: []const u8 = "GET",
    post: []const u8 = "POST",
    patch: []const u8 = "PATCH",
    delete: []const u8 = "DELETE",
    update: []const u8 = "UPDATE",
    options: []const u8 = "OPTIONS",
};
const commonStrings = CommonStrings{};

/// Find the index of '\r' in the slice. For slices 32 bytes or longer, use a SIMD‐like approach.
const V128 = @Vector(128, u8);
const splt_128: V128 = @splat(@as(u8, '\r'));

const V64 = @Vector(64, u8);
const splt_64: V64 = @splat(@as(u8, '\r'));

const V32 = @Vector(32, u8);
const splt_32: V32 = @splat(@as(u8, '\r'));
pub fn findCRLF(slice: []const u8) usize {
    var i: usize = 0;
    if (slice.len >= 128) {
        while (i + 128 <= slice.len) : (i += 128) {
            const v = slice[i..][0..128].*;
            const vec: V128 = @bitCast(v);
            const mask = vec == splt_128;
            const bits: u128 = @bitCast(mask);
            if (bits != 0) {
                return i + @ctz(bits);
            }
        }
    }
    if (slice.len >= 64) {
        while (i + 64 <= slice.len) : (i += 64) {
            const v = slice[i..][0..64].*;
            const vec: V64 = @bitCast(v);
            const mask = vec == splt_64;
            const bits: u64 = @bitCast(mask);
            if (bits != 0) {
                return i + @ctz(bits);
            }
        }
    }
    if (slice.len >= 32) {
        while (i + 32 <= slice.len) : (i += 32) {
            const v = slice[i..][0..32].*;
            const vec: V32 = @bitCast(v);
            const mask = vec == splt_32;
            const bits: u32 = @bitCast(mask);
            if (bits != 0) {
                return i + @ctz(bits);
            }
        }
    }

    var j: usize = i;
    while (j < slice.len) : (j += 1) {
        if (slice[j] == '\r') return j;
    }
    return slice.len;
}
// Precomputed method trie (compile-time)
const MethodTrie = struct {
    const masks = [4]u64{
        0x0000_0000_FFFF_FF00, // GET
        0x0000_0000_FFFF_FFFF, // POST
        0x0000_0000_FFFF_FF00, // PUT
        0x0000_0000_FFFF_FF00, // HEAD
    };
    const v1 =
        (@as(u64, 'G') << 0) |
        (@as(u64, 'E') << 8) |
        (@as(u64, 'T') << 16) |
        (@as(u64, ' ') << 24);
    const v2 =
        (@as(u64, 'P') << 0) |
        (@as(u64, 'O') << 8) |
        (@as(u64, 'S') << 16) |
        (@as(u64, 'T') << 24);
    const v3 =
        (@as(u64, 'P') << 0) |
        (@as(u64, 'U') << 8) |
        (@as(u64, 'T') << 16) |
        (@as(u64, ' ') << 24);
    const v4 =
        (@as(u64, 'H') << 0) |
        (@as(u64, 'E') << 8) |
        (@as(u64, 'A') << 16) |
        (@as(u64, 'D') << 24);
    const values = [4]u64{ v1, v2, v3, v4 };
};

//wrk test payload is
// GET /ping HTTP/1.1
// Host: 127.0.0.1:8080

/// Maps a method name to the shared constant for it, so callers comparing
/// `ctx_pm.method` can compare pointers for the common verbs. Returns null
/// for anything unrecognised, and the caller keeps the original slice.
fn canonicalMethod(method: []const u8) ?[]const u8 {
    const table = [_][]const u8{
        commonStrings.get,
        commonStrings.post,
        commonStrings.patch,
        commonStrings.delete,
        commonStrings.update,
        commonStrings.options,
    };
    for (table) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return candidate;
    }
    return null;
}

/// Classifies a Content-Type header value.
///
/// Unknown types map to `.None` rather than being treated as impossible —
/// the value comes from the client, so any byte sequence can appear here.
fn classifyContentType(value: []const u8) ContentType {
    // Compare against the media type only, ignoring any parameters such as
    // `; charset=utf-8` and any leading whitespace.
    const media_end = std.mem.indexOfAny(u8, value, "; \t") orelse value.len;
    const media = value[0..media_end];

    if (std.ascii.eqlIgnoreCase(media, "application/json")) return .JSON;
    if (std.ascii.eqlIgnoreCase(media, "application/wasm")) return .WASM;
    if (std.ascii.eqlIgnoreCase(media, "application/x-www-form-urlencoded")) return .Form;
    if (media.len >= 5 and std.ascii.eqlIgnoreCase(media[0..5], "text/")) return .Text;
    if (media.len >= 10 and std.ascii.eqlIgnoreCase(media[0..10], "multipart/")) return .MultiForm;
    return .None;
}

/// Splits a header line into its name and value.
///
/// Returns null when the line carries no colon, which makes it a malformed
/// field the caller should skip rather than a fatal error.
fn splitHeaderLine(line: []const u8) ?struct { name: []const u8, value: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return .{
        .name = std.mem.trim(u8, line[0..colon], " \t"),
        .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
    };
}

//wrk test payload is
// GET /ping HTTP/1.1
// Host: 127.0.0.1:8080

/// Parses a complete HTTP request head into `ctx_pm` and `http_header`.
///
/// `new_payload` must hold the whole head — `expectedHttpRequestLength`
/// establishes that before this is called. Everything here is driven by
/// bytes a client chose, so every field is treated as untrusted: a
/// malformed request returns an error and never reads out of bounds.
///
/// The head is copied into `http_header._buffer`, and the slices stored on
/// `ctx_pm` and `http_header` point into that buffer, so they stay valid for
/// as long as `http_header` does. `body` is the exception: it points into
/// `new_payload`.
pub fn parseHeaders(new_payload: []const u8, ctx_pm: *Ctx_pm, http_header: *HTTPHeader) !void {
    const headers_end = findCRLFCRLF(new_payload) orelse return error.MalformedRequest;
    const header_len = headers_end + 4;
    if (header_len > http_header._buffer.len) return error.HeaderTooLarge;

    @memcpy(http_header._buffer[0..header_len], new_payload[0..header_len]);
    const payload = http_header._buffer[0..header_len];

    // The body lives in the caller's payload, past the head this function copied.
    http_header.body = new_payload[header_len..];

    // ---- Request line -----------------------------------------------------
    //
    // `findCRLF` returns the slice length when there is no CR at all. That
    // cannot happen here because `findCRLFCRLF` already matched, but the
    // bound is asserted rather than assumed.
    const request_line_end = findCRLF(payload);
    if (request_line_end >= payload.len) return error.MalformedRequest;
    const request_line = payload[0..request_line_end];

    const method_end = std.mem.indexOfScalar(u8, request_line, ' ') orelse
        return error.MalformedRequest;
    const method = request_line[0..method_end];
    if (method.len == 0) return error.MalformedRequest;

    const after_method = request_line[method_end + 1 ..];
    // A missing HTTP version leaves the rest of the line as the path, which
    // keeps HTTP/0.9-style requests parseable instead of crashing.
    const path_end = std.mem.indexOfScalar(u8, after_method, ' ') orelse after_method.len;
    const path = after_method[0..path_end];
    if (path.len == 0) return error.MalformedRequest;

    ctx_pm.method = canonicalMethod(method) orelse method;
    ctx_pm.path = path;
    http_header.request_line = request_line;

    // ---- Header fields ----------------------------------------------------
    //
    // Dispatch on the first byte of the field name to avoid comparing every
    // candidate for every line, then confirm with a full case-insensitive
    // match so a truncated or unexpected name cannot be mistaken for a
    // longer one it merely shares a prefix with.
    var lines = std.mem.splitSequence(u8, payload[request_line_end + 2 .. headers_end], "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const field = splitHeaderLine(line) orelse continue;
        const name = field.name;
        const value = field.value;
        if (name.len == 0) continue;

        switch (std.ascii.toUpper(name[0])) {
            'H' => {
                if (std.ascii.eqlIgnoreCase(name, "Host")) http_header.host = value;
            },
            'U' => {
                if (std.ascii.eqlIgnoreCase(name, "User-Agent")) {
                    http_header.user_agent = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Upgrade")) {
                    http_header.upgrade = value;
                }
            },
            'C' => {
                if (std.ascii.eqlIgnoreCase(name, "Cookie")) {
                    http_header.cookie_str = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                    // A Content-Length that does not fit a usize, or is not a
                    // number at all, is a malformed request rather than a
                    // body of length zero: treating it as zero would let a
                    // request smuggle its body into the next one on a
                    // keep-alive connection.
                    http_header.content_length = std.fmt.parseInt(usize, value, 10) catch
                        return error.MalformedRequest;
                } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
                    http_header.content_type = classifyContentType(value);
                } else if (std.ascii.eqlIgnoreCase(name, "Content-Encoding")) {
                    http_header.content_encoding = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
                    http_header.connection = value;
                }
            },
            'A' => {
                if (std.ascii.eqlIgnoreCase(name, "Authorization")) {
                    http_header.authorization = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Accept")) {
                    http_header.accept = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Accept-Language")) {
                    http_header.accept_language = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Accept-Encoding")) {
                    http_header.accept_encoding = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Access-Control-Request-Method")) {
                    http_header.accept_control_request_method = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Access-Control-Request-Headers")) {
                    http_header.accept_control_request_headers = value;
                }
            },
            'O' => {
                if (std.ascii.eqlIgnoreCase(name, "Origin")) http_header.origin = value;
            },
            'R' => {
                if (std.ascii.eqlIgnoreCase(name, "Referer")) http_header.referer = value;
            },
            'S' => {
                if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Key")) {
                    http_header.ws_client_key = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Version")) {
                    http_header.ws_version = value;
                } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Extensions")) {
                    http_header.sec_websocket_extensions = value;
                }
            },
            else => {},
        }
    }
}

pub fn parseParams(ctx: *Context, url: []const u8) !?[]const u8 {
    const params_start = findIndex(url, '?') orelse return null;
    // Details
    const lookup_route = url[0..params_start];

    // Loop
    var pos = params_start + 1;
    while (pos < url.len) : (pos += 1) {
        if (ctx.req_params_index >= ctx.params.len) return error.CookieBufferOverflow;
        const param_pair_end = findIndex(url[pos..], '&') orelse {
            // We only have one pair hence we add and return
            const seperator = findIndex(url[pos..], '=') orelse return error.SeperatorNotFound;
            const name = url[pos .. seperator + pos];
            const value = url[seperator + pos + 1 .. url.len];
            ctx.params[ctx.req_params_index] = Context.Param{
                .name = name,
                .value = value,
            };
            ctx.req_params_index += 1;
            return lookup_route;
        };
        // now we find the sperator in this pair and add it to the hashmap and continue on to the next
        // id=123
        const pair = url[pos .. param_pair_end + pos];
        const seperator = findIndex(pair, '=') orelse return error.SeperatorNotFound;
        const name = pair[0..seperator];
        const value = pair[seperator + 1 ..];
        ctx.params[ctx.req_params_index] = Context.Param{
            .name = name,
            .value = value,
        };
        ctx.req_params_index += 1;
        pos += param_pair_end;
    }
    return lookup_route;
}

pub fn parseCookies(ctx: *Context, cookie_str: []const u8) !void {
    // Loop
    var pos: usize = 0;
    while (pos < cookie_str.len) : (pos += 1) {
        if (ctx.req_cookie_index >= ctx.req_cookies.len) return error.CookieBufferOverflow;
        // here we find the cookie end marked by ;
        const cookie_pair_end = findIndex(cookie_str[pos..], ';') orelse {
            // We only have one pair hence we add and return
            const seperator = findIndex(cookie_str[pos..], '=') orelse return error.SeperatorNotFound;
            // this the name of the cookie "oauth_provider=github;"
            // name "oauth_provider;"
            const name = cookie_str[pos .. seperator + pos];
            const value = cookie_str[seperator + pos + 1 .. cookie_str.len];
            ctx.req_cookies[ctx.req_cookie_index] = Cookie{
                .name = name,
                .value = value,
            };
            ctx.req_cookie_index += 1;
            return;
        };
        // now we find the sperator in this pair and add it to the hashmap and continue on to the next
        // id=123
        const pair = cookie_str[pos .. cookie_pair_end + pos];
        const seperator = findIndex(pair, '=') orelse return error.SeperatorNotFound;
        const name = pair[0..seperator];
        const value = pair[seperator + 1 ..];
        ctx.req_cookies[ctx.req_cookie_index] = Cookie{
            .name = name,
            .value = value,
        };

        ctx.req_cookie_index += 1;
        pos += cookie_pair_end;
        pos += 1;
    }
}

fn matchMethod(iter: *mem.TokenIterator(u8, .scalar)) ![]const u8 {
    const method = iter.next().?;
    const method_enum = std.meta.stringToEnum(RequestTypes, method).?;
    switch (method_enum) {
        .OPTIONS => return method,
        .GET => return method,
        .POST => return method,
        .PATCH => return method,
        .DELETE => return method,
        .PUT => return method,
        // else => return ServerError.RequestNotSupported,
    }
}

fn matchDataType(path: []const u8) ![]const u8 {
    var path_iter = mem.tokenizeSequence(u8, path, "/");
    const path_type = path_iter.next();
    if (path_type == null) return error.Null;
    return path_type.?;
}

pub fn httpCodeResponse(proto_name: []const u8, status_code: usize, msg: []const u8, arena: *std.mem.Allocator) ![]const u8 {
    const proto_str = "HTTP/1.1 {d} {s}";
    const proto = std.fmt.allocPrint(
        arena.*,
        proto_str,
        .{
            status_code,
            proto_name,
        },
    ) catch return error.MemoryFull;
    defer arena.free(proto);

    var reply: Reply = undefined;
    try reply.init(arena.*);
    defer reply.deinit();

    try reply.writeHttpProto(proto);

    const max_len = 20;
    var buf: [max_len]u8 = undefined;
    const numAsString = try std.fmt.bufPrint(&buf, "{}", .{msg.len});

    var headers: HttpHeader = undefined;
    headers.init(.{
        .content_length = .{ .override = numAsString },
        .content_type = .{ .override = "text/html; charset=utf8" },
        .connection = .{ .override = "close" },
        .vary = .{ .override = "Origin" },
    });

    var cors = Server.cors;
    try reply.writeHeaders(&headers, &cors);
    try reply.payload(msg);

    const response = try reply.getData();
    return response;
}

pub fn convertStringToSlice(haystack: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const mutable_slice = try allocator.dupe(u8, haystack);
    return mutable_slice;
}

pub const Error = error{InvalidUUID};

pub const UUID = struct {
    bytes: [16]u8,

    pub fn init() UUID {
        var uuid = UUID{ .bytes = undefined };

        crypto.random.bytes(&uuid.bytes);
        // Version 4
        uuid.bytes[6] = (uuid.bytes[6] & 0x0f) | 0x40;
        // Variant 1
        uuid.bytes[8] = (uuid.bytes[8] & 0x3f) | 0x80;
        return uuid;
    }

    pub fn to_string(self: UUID, slice: []u8) void {
        var string: [36]u8 = format_uuid(self);
        std.mem.copyForwards(u8, slice, &string);
    }

    fn format_uuid(self: UUID) [36]u8 {
        var buf: [36]u8 = undefined;
        buf[8] = '-';
        buf[13] = '-';
        buf[18] = '-';
        buf[23] = '-';
        inline for (encoded_pos, 0..) |i, j| {
            buf[i + 0] = hex[self.bytes[j] >> 4];
            buf[i + 1] = hex[self.bytes[j] & 0x0f];
        }
        return buf;
    }

    // Indices in the UUID string representation for each byte.
    const encoded_pos = [16]u8{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };

    // Hex
    const hex = "0123456789abcdef";

    // Hex to nibble mapping.
    const hex_to_nibble = [256]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };

    pub fn format(
        self: UUID,
        comptime layout: []const u8,
        options: fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options; // currently unused

        if (layout.len != 0 and layout[0] != 's')
            @compileError("Unsupported format specifier for UUID type: '" ++ layout ++ "'.");

        const buf = format_uuid(self);
        try fmt.format(writer, "{s}", .{buf});
    }

    pub fn parse(buf: []const u8) Error!UUID {
        var uuid = UUID{ .bytes = undefined };

        if (buf.len != 36 or buf[8] != '-' or buf[13] != '-' or buf[18] != '-' or buf[23] != '-')
            return Error.InvalidUUID;

        inline for (encoded_pos, 0..) |i, j| {
            const hi = hex_to_nibble[buf[i + 0]];
            const lo = hex_to_nibble[buf[i + 1]];
            if (hi == 0xff or lo == 0xff) {
                return Error.InvalidUUID;
            }
            uuid.bytes[j] = hi << 4 | lo;
        }

        return uuid;
    }
};

// Zero UUID
pub const zero: UUID = .{ .bytes = .{0} ** 16 };

// Convenience function to return a new v4 UUID.
pub fn newV4() UUID {
    return UUID.init();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// `HTTPHeader` embeds a 16 KiB buffer, which is too large to sit on the test
// stack comfortably, so parses run against a heap-allocated one.
fn parseForTest(payload: []const u8, ctx_pm: *Ctx_pm) !void {
    const header = try testing.allocator.create(HTTPHeader);
    defer testing.allocator.destroy(header);
    header.* = .{};
    return parseHeaders(payload, ctx_pm, header);
}

// Every one of these is a request a client can send. Whatever the parser
// decides to do with them, it has to be reached by `return`ing an error
// rather than by reading out of bounds or hitting `unreachable` — either of
// which takes the whole server down.
test "hostile requests are rejected rather than crashing the parser" {
    const hostile = [_][]const u8{
        // Unknown verb: the method lookup leaves `method` empty, so the
        // request-line slice is computed from a length that was never set.
        "XYZ / HTTP/1.1\r\nHost: a\r\n\r\n",
        // Request line shorter than the fallback offset used when no space
        // follows the path.
        "G\r\n\r\n",
        "GET\r\n\r\n",
        "\r\n\r\n",
        // A header line whose value is empty, indexed at [0] and [12].
        "GET / HTTP/1.1\r\nContent-Type:\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Type: \r\n\r\n",
        // Content-Type shorter than the offsets the type switch reads.
        "GET / HTTP/1.1\r\nContent-Type: a\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Type: applicat\r\n\r\n",
        // A Content-Type the switch has no arm for.
        "GET / HTTP/1.1\r\nContent-Type: zzz/unknown\r\n\r\n",
        // Truncated header names, indexed well past their end.
        "GET / HTTP/1.1\r\nC: x\r\n\r\n",
        "GET / HTTP/1.1\r\nCo: x\r\n\r\n",
        "GET / HTTP/1.1\r\nCon: x\r\n\r\n",
        "GET / HTTP/1.1\r\nA: x\r\n\r\n",
        "GET / HTTP/1.1\r\nS: x\r\n\r\n",
        "GET / HTTP/1.1\r\nSec-W: x\r\n\r\n",
        "GET / HTTP/1.1\r\nO: x\r\n\r\n",
        "GET / HTTP/1.1\r\nU: x\r\n\r\n",
        // Non-numeric and overflowing Content-Length.
        "GET / HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n",
        "GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        // No space anywhere in the request line.
        "GET\r\nHost: a\r\n\r\n",
        // Path missing entirely.
        "GET  HTTP/1.1\r\nHost: a\r\n\r\n",
        // A lone space as the whole request.
        " \r\n\r\n",
    };

    for (hostile) |payload| {
        var ctx_pm = Ctx_pm{};
        // Errors are fine. Crashes are not.
        parseForTest(payload, &ctx_pm) catch continue;
    }
}

test "a well-formed request parses into its parts" {
    var ctx_pm = Ctx_pm{};
    const header = try testing.allocator.create(HTTPHeader);
    defer testing.allocator.destroy(header);
    header.* = .{};

    const payload =
        "GET /users/42 HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "User-Agent: test-agent\r\n" ++
        "Content-Length: 5\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n" ++
        "hello";

    try parseHeaders(payload, &ctx_pm, header);

    try testing.expectEqualStrings("GET", ctx_pm.method);
    try testing.expectEqualStrings("/users/42", ctx_pm.path);
    try testing.expectEqualStrings("example.com", header.host);
    try testing.expectEqualStrings("test-agent", header.user_agent);
    try testing.expectEqual(@as(usize, 5), header.content_length);
    try testing.expectEqual(ContentType.JSON, header.content_type);
    try testing.expectEqualStrings("hello", header.body);
}

// A seeded mutation sweep. `std.testing.fuzz` needs the dedicated fuzz
// runner, so this stands in for it: deterministic, runs on every `zig build
// test`, and covers the same class of defect — a byte sequence the parser
// did not anticipate reaching an unchecked index.
test "mutated requests never crash the parser" {
    const seeds = [_][]const u8{
        "GET / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n",
        "POST /a/b?c=d HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",
        "GET /ws HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
        "OPTIONS / HTTP/1.1\r\nOrigin: http://x\r\nAccess-Control-Request-Method: GET\r\n\r\n",
        "GET / HTTP/1.1\r\nCookie: a=1; b=2\r\nReferer: http://x\r\n\r\n",
    };

    // Bytes chosen to land on the structural characters the parser keys off.
    const interesting = [_]u8{ 0, '\r', '\n', ' ', ':', '/', '?', ';', '.', 0x80, 0xff, 'A' };

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var buf: [1024]u8 = undefined;
    for (seeds) |seed| {
        for (0..2000) |_| {
            if (seed.len > buf.len) continue;
            const payload = buf[0..seed.len];
            @memcpy(payload, seed);

            // Apply a handful of single-byte edits, then truncate at a random
            // point so partial heads get exercised alongside mutated ones.
            const edits = random.uintLessThan(usize, 4) + 1;
            for (0..edits) |_| {
                const pos = random.uintLessThan(usize, payload.len);
                payload[pos] = switch (random.uintLessThan(u8, 3)) {
                    0 => interesting[random.uintLessThan(usize, interesting.len)],
                    1 => random.int(u8),
                    else => payload[pos] ^ (@as(u8, 1) << random.int(u3)),
                };
            }

            const truncated = payload[0 .. random.uintLessThan(usize, payload.len) + 1];

            var ctx_pm = Ctx_pm{};
            // Any error is acceptable; reaching this line at all is the point.
            parseForTest(truncated, &ctx_pm) catch continue;
        }
    }
}

// `expectedHttpRequestLength` decides how many bytes make up one request, so
// a wrong answer either stalls a connection or lets one request's bytes be
// read as the next one's.
test "expectedHttpRequestLength frames requests correctly" {
    const max_body = 1024;

    // Incomplete heads report "not yet".
    try testing.expectEqual(@as(?usize, null), try expectedHttpRequestLength("GET / HTTP/1.1\r\n", max_body));
    try testing.expectEqual(@as(?usize, null), try expectedHttpRequestLength("", max_body));

    // A complete head with no body is exactly its own length.
    const no_body = "GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    try testing.expectEqual(@as(?usize, no_body.len), try expectedHttpRequestLength(no_body, max_body));

    // With a body, the head plus the declared length.
    const with_body = "POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    try testing.expectEqual(@as(?usize, with_body.len), try expectedHttpRequestLength(with_body, max_body));

    // A partial body still reports "not yet".
    try testing.expectEqual(
        @as(?usize, null),
        try expectedHttpRequestLength("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel", max_body),
    );

    // Two pipelined requests report only the first, so the second is left in
    // the buffer rather than being swallowed.
    const first = "GET /a HTTP/1.1\r\nHost: a\r\n\r\n";
    const pipelined = first ++ "GET /b HTTP/1.1\r\nHost: a\r\n\r\n";
    try testing.expectEqual(@as(?usize, first.len), try expectedHttpRequestLength(pipelined, max_body));

    // Oversized bodies and heads are refused.
    try testing.expectError(
        error.BodyTooLarge,
        expectedHttpRequestLength("POST / HTTP/1.1\r\nContent-Length: 99999\r\n\r\n", max_body),
    );
    const giant = "GET / HTTP/1.1\r\n" ++ ("X-Pad: 0123456789\r\n" ** 1200);
    try testing.expectError(error.HeaderTooLarge, expectedHttpRequestLength(giant, max_body));
}

// `chunked` is supported. Any other coding is refused rather than ignored:
// treating an undecodable body as zero-length would leave its bytes in the
// buffer to be read as the next request on a keep-alive connection, which
// is request smuggling.
test "an unsupported transfer coding is refused" {
    const max_body = 1024;

    for ([_][]const u8{
        "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: deflate\r\n\r\n",
        // A chunked-plus-other list is not plain `chunked`.
        "POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
    }) |payload| {
        try testing.expectError(
            error.UnsupportedTransferEncoding,
            expectedHttpRequestLength(payload, max_body),
        );
    }

    // Casing is not significant, and `chunked` is accepted.
    const chunked = "POST / HTTP/1.1\r\ntransfer-encoding: CHUNKED\r\n\r\n0\r\n\r\n";
    try testing.expectEqual(
        @as(?usize, chunked.len),
        try expectedHttpRequestLength(chunked, max_body),
    );

    // `identity` means no encoding, so `Content-Length` still frames.
    const identity = "POST / HTTP/1.1\r\nTransfer-Encoding: identity\r\nContent-Length: 2\r\n\r\nhi";
    try testing.expectEqual(
        @as(?usize, identity.len),
        try expectedHttpRequestLength(identity, max_body),
    );
}

// Sending both headers is the classic smuggling setup: two intermediaries
// disagree about which one frames the body.
test "a request with both Transfer-Encoding and Content-Length is refused" {
    try testing.expectError(error.UnsupportedTransferEncoding, expectedHttpRequestLength(
        "POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello",
        1024,
    ));
}

// ---------------------------------------------------------------------------
// Chunked transfer-encoding
// ---------------------------------------------------------------------------

test "chunked framing reports the length of the whole encoded body" {
    const max_body = 1024;

    // One chunk, then the terminator.
    const one = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    try testing.expectEqual(@as(?usize, one.len), try expectedHttpRequestLength(one, max_body));

    // Several chunks.
    const many = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\n\r\n";
    try testing.expectEqual(@as(?usize, many.len), try expectedHttpRequestLength(many, max_body));

    // A chunk-size extension is legal and ignored.
    const ext = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5;a=b\r\nhello\r\n0\r\n\r\n";
    try testing.expectEqual(@as(?usize, ext.len), try expectedHttpRequestLength(ext, max_body));

    // Trailers after the terminating chunk are part of the request.
    const trailer = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n0\r\nX-Sum: 1\r\n\r\n";
    try testing.expectEqual(@as(?usize, trailer.len), try expectedHttpRequestLength(trailer, max_body));

    // Hex sizes, upper and lower case.
    const hex = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "A\r\n0123456789\r\nf\r\n012345678901234\r\n0\r\n\r\n";
    try testing.expectEqual(@as(?usize, hex.len), try expectedHttpRequestLength(hex, max_body));
}

test "an incomplete chunked body reports not-yet rather than a length" {
    const max_body = 1024;

    for ([_][]const u8{
        // No chunks at all yet.
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        // Chunk size line not finished.
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n",
        // Chunk data short.
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
        // Data complete but its trailing CRLF missing.
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello",
        // Terminating chunk present but the final CRLF missing.
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n",
        // Trailer section unterminated.
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Sum: 1\r\n",
    }) |payload| {
        try testing.expectEqual(
            @as(?usize, null),
            try expectedHttpRequestLength(payload, max_body),
        );
    }
}

test "malformed chunk framing is refused" {
    const max_body = 1024;

    // A chunk size that is not hex.
    try testing.expectError(error.MalformedRequest, expectedHttpRequestLength(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n0\r\n\r\n",
        max_body,
    ));

    // Chunk data not followed by CRLF.
    try testing.expectError(error.MalformedRequest, expectedHttpRequestLength(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n",
        max_body,
    ));

    // An empty chunk-size line.
    try testing.expectError(error.MalformedRequest, expectedHttpRequestLength(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n\r\nhello\r\n0\r\n\r\n",
        max_body,
    ));
}

// The decoded size is what counts against the limit, not the encoded size,
// since the decoded bytes are what a handler is handed.
test "a chunked body over the limit is refused" {
    try testing.expectError(error.BodyTooLarge, expectedHttpRequestLength(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n0123456789abcdef\r\n0\r\n\r\n",
        8,
    ));

    // A chunk size that would overflow the accumulator is refused, not wrapped.
    try testing.expectError(error.BodyTooLarge, expectedHttpRequestLength(
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\n",
        1024,
    ));
}

test "decodeChunkedBody concatenates the chunk data" {
    var buf: [64]u8 = undefined;

    const single = "5\r\nhello\r\n0\r\n\r\n";
    @memcpy(buf[0..single.len], single);
    try testing.expectEqualStrings("hello", buf[0..try decodeChunkedBody(buf[0..single.len])]);

    const multi = "5\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\n\r\n";
    @memcpy(buf[0..multi.len], multi);
    try testing.expectEqualStrings("hello world", buf[0..try decodeChunkedBody(buf[0..multi.len])]);

    // A body of nothing but the terminator decodes to zero bytes.
    const empty = "0\r\n\r\n";
    @memcpy(buf[0..empty.len], empty);
    try testing.expectEqual(@as(usize, 0), try decodeChunkedBody(buf[0..empty.len]));

    // Extensions and trailers contribute no data.
    const extras = "3;x=y\r\nabc\r\n0\r\nX-Sum: 3\r\n\r\n";
    @memcpy(buf[0..extras.len], extras);
    try testing.expectEqualStrings("abc", buf[0..try decodeChunkedBody(buf[0..extras.len])]);
}

// Decoding happens in place, which is only sound because the encoding is
// always larger than what it encodes -- every chunk carries at least a size
// line and a trailing CRLF. This pins that assumption down.
test "in-place decoding never outgrows its input" {
    var buf: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();

    for (0..500) |_| {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(testing.allocator);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(testing.allocator);

        const chunks = random.uintLessThan(usize, 5) + 1;
        for (0..chunks) |_| {
            const size = random.uintLessThan(usize, 20) + 1;
            var data: [20]u8 = undefined;
            for (data[0..size]) |*byte| byte.* = random.intRangeAtMost(u8, 'a', 'z');

            var head: [16]u8 = undefined;
            const head_str = try std.fmt.bufPrint(&head, "{x}\r\n", .{size});
            try encoded.appendSlice(testing.allocator, head_str);
            try encoded.appendSlice(testing.allocator, data[0..size]);
            try encoded.appendSlice(testing.allocator, "\r\n");
            try expected.appendSlice(testing.allocator, data[0..size]);
        }
        try encoded.appendSlice(testing.allocator, "0\r\n\r\n");

        @memcpy(buf[0..encoded.items.len], encoded.items);
        const decoded_len = try decodeChunkedBody(buf[0..encoded.items.len]);

        try testing.expect(decoded_len <= encoded.items.len);
        try testing.expectEqualStrings(expected.items, buf[0..decoded_len]);
    }
}
