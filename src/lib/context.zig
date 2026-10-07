const std = @import("std");
const net = std.net;
const mem = std.mem;
const Parsed = std.json.Parsed;
const helpers = @import("helpers.zig");
const Cookie = @import("core/Cookie.zig");
// const TLSStruct = @import("tls/tlsserver.zig");
// const TLSServer = TLSStruct.TlsServer;
const print = std.debug.print;
const Server = @import("server.zig");
const Client = @import("loom").Client;
const Header = @import("core/Header.zig");
const Reply = @import("core/ReplyBuilder.zig");
// const Validation = @import("../../core/Validation.zig");
// const assert_cm = @import("../../utils/index.zig").assert_cm;
const dom = @import("core/simdjson/dom.zig");
const posix = std.posix;
const loompkg = @import("loom");
const xsuspend = loompkg.xsuspend;
const Time = loompkg.Time;

pub const json_type = []const u8;

const CtxError = error{
    MalformedFormContentType,
    MalformedMultiFormContentType,
};

const Data = struct {
    field_name: []const u8 = "",
    filename: ?[]const u8 = null,
    content_type: []const u8 = "text",
    content: []const u8 = "",
};

const MultiForm = struct {
    form_data: std.array_list.Managed(Data),
};

pub const SSL: i32 = 0;
const crlf = "\r\n\r\n";
pub var cors_headers: ?[]const u8 = null;
// var parser: dom.Parser = undefined;

const success_resp =
    "HTTP/1.1 200 OK\r\n" ++
    "Vary: Origin\r\n" ++
    // "Connection: close\r\n" ++
    "Server: Example\r\n" ++
    "Date: Wed, 17 Apr 2013 12:00:00 GMT\r\n" ++
    // "Content-Type: application/json; charset=utf8\r\n";
    "Content-Type: application/json\r\n";

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Self = @This();
id: usize = 10000,
arena: std.mem.Allocator,
/// Scratch memory for one request, reset by `clear()`.
///
/// `arena` is the server's allocator and lives for the whole process, so
/// anything a handler allocates from it is retained until shutdown. That
/// made JSON binding cost ~38 bytes per request, permanently. Request-scoped
/// allocations belong here instead; the capacity is retained across resets,
/// so steady state costs no allocator traffic at all.
request_arena: *std.heap.ArenaAllocator,
/// The request body. Empty when the request carried none — never
/// `undefined`, because handlers read this without checking
/// `content_length` first.
payload: []const u8 = "",
http_header: helpers.HTTPHeader = .{},
req_params_index: usize = 0,
params: []Param = undefined, // Array of key-value pairs for URL parameters
req_query_params_index: usize = 0,
query_params: []Param = undefined, // Array of key-value pairs for query parameters
form_params: *std.StringHashMap([]const u8) = undefined, // Array of key-value pairs for form data
method: []const u8,
route: []const u8,
content_length: usize = 0,
/// Set when the request asked for the connection to be closed after the
/// response. `Server.handle` acts on this once the response has drained.
close_requested: bool = false,
http_payload: []const u8,
content_type: helpers.ContentType = helpers.ContentType.None,
client: ?*Client = null,
cookies: *std.StringHashMap(Cookie) = undefined,
req_cookie_index: usize = 0,
req_cookies: []Cookie = undefined,
// multi_form: MultiForm = undefined,
parser: *dom.Parser = undefined,
header_buf: [4096]u8 = undefined,
header_buf_len: usize = 0,

pub fn init(
    arena: mem.Allocator,
    method: []const u8,
    route: []const u8,
    client: ?*Client,
    _: ?i32,
    content_type: helpers.ContentType,
    _: ?[]const u8,
    cookie_size: usize,
) !Self {
    const request_arena = try arena.create(std.heap.ArenaAllocator);
    request_arena.* = std.heap.ArenaAllocator.init(arena);

    const parser = try arena.create(dom.Parser);
    parser.* = try dom.Parser.initFixedBuffer(arena, "", .{});
    const req_cookies = try arena.alloc(Cookie, cookie_size);
    const query_params = try arena.alloc(Param, 256);
    const params = try arena.alloc(Param, cookie_size);

    const form_params = try arena.create(std.StringHashMap([]const u8));
    form_params.* = std.StringHashMap([]const u8).init(arena);

    const cookies = try arena.create(std.StringHashMap(Cookie));
    cookies.* = std.StringHashMap(Cookie).init(arena);

    return Self{
        .arena = arena,
        .request_arena = request_arena,
        .method = method,
        .route = route,
        .params = params,
        .query_params = query_params,
        .form_params = form_params,
        .http_payload = "",
        .content_type = content_type,
        .client = client,
        .parser = parser,
        .cookies = cookies,
        .req_cookies = req_cookies,
    };
}

/// Releases everything `init` allocated.
///
/// `Server.deinit` calls this for every pooled context. It previously had
/// most of its body commented out and no caller at all, so a server left
/// its whole context pool behind on shutdown.
pub fn deinit(self: *Self) void {
    // Form parameter values are owned strings, so they go before the map.
    var itr = self.form_params.iterator();
    while (itr.next()) |e| {
        self.arena.free(e.value_ptr.*);
    }
    self.form_params.deinit();
    self.arena.destroy(self.form_params);

    self.cookies.deinit();
    self.arena.destroy(self.cookies);

    self.parser.deinit();
    self.arena.destroy(self.parser);

    self.request_arena.deinit();
    self.arena.destroy(self.request_arena);

    self.arena.free(self.req_cookies);
    self.arena.free(self.query_params);
    self.arena.free(self.params);
}

/// Returns the allocator whose memory is reclaimed at the end of this
/// request. Use it for anything a handler produces; `arena` lives for the
/// life of the process.
pub fn requestAllocator(self: *Self) std.mem.Allocator {
    return self.request_arena.allocator();
}

pub fn clear(self: *Self) void {
    // Reclaims everything the last request allocated. Capacity is retained,
    // so a steady request rate does no allocator work here.
    _ = self.request_arena.reset(.retain_capacity);

    var itr = self.form_params.iterator();
    while (itr.next()) |e| {
        self.arena.free(e.value_ptr.*);
    }
    self.form_params.clearRetainingCapacity();
    self.cookies.clearRetainingCapacity();
    self.req_params_index = 0;
    self.req_query_params_index = 0;
    self.req_cookie_index = 0;
    self.content_length = 0;
    self.close_requested = false;
    // Both of these must be cleared: contexts are pooled and reused per
    // connection slot, so a stale payload would otherwise be visible to the
    // next request that happens not to carry a body.
    self.payload = "";
    self.http_payload = "";
    self.content_type = helpers.ContentType.None;
    self.header_buf = undefined;
    self.header_buf_len = 0;
    self.http_header = .{};
    // self.query_params.clearRetainingCapacity();
    // self.params.clearRetainingCapacity();
}

pub fn addParam(self: *Self, name: []const u8, value: []const u8) !void {
    if (self.req_params_index >= self.params.len) return error.ParamsBufferOverflow;
    self.params[self.req_params_index] = Param{
        .name = name,
        .value = value,
    };
    self.req_params_index += 1;
}

pub fn parseParams(self: *Self) !void {
    _ = try helpers.parseParams(self, self.http_header.path);
}

pub fn body(self: *Self) []const u8 {
    return self.payload[0..self.content_length];
}

pub fn addQueryParam(self: *Self, name: []const u8, value: []const u8) !void {
    if (self.req_query_params_index >= self.query_params.len) return error.QueryParamsBufferOverflow;
    self.query_params[self.req_query_params_index] = Param{
        .name = name,
        .value = value,
    };
    self.req_query_params_index += 1;
}

pub fn addFormParam(self: *Self, key: []const u8, value: []const u8) !void {
    try self.form_params.put(key, value);
}

fn generateCookieString(self: *Self) ![]const u8 {
    if (self.cookies.count() == 0) {
        return "\r\n";
    }
    // Pre-calculate required buffer size to avoid reallocations
    var estimated_size: usize = 0;
    var cookies_itr = self.cookies.iterator();
    while (cookies_itr.next()) |entry| {
        const key = entry.key_ptr.*;
        const cookie = entry.value_ptr.*;
        // "Set-Cookie: " + key + "=" + value + "; Path=/;\r\n" + extras
        estimated_size += 12 + key.len + 1 + cookie.value.len + 10 + 2; // base components
        if (cookie.secure) estimated_size += 7; // "Secure;"
        if (cookie.expires != null) estimated_size += 20; // "Max-Age=XXXXXXX;" (rough estimate)
        if (cookie.http_only) estimated_size += 8; // "HttpOnly"
    }

    // Create array_list.Managed with pre-allocated capacity
    var buffer_cookie = try std.array_list.Managed(u8).initCapacity(self.arena, estimated_size);
    defer buffer_cookie.deinit();

    // Reset iterator
    cookies_itr = self.cookies.iterator();

    while (cookies_itr.next()) |entry| {
        const key = entry.key_ptr.*;
        const cookie = entry.value_ptr.*;

        // Use appendSlice instead of multiple write calls for better performance
        try buffer_cookie.appendSlice("Set-Cookie: ");
        try buffer_cookie.appendSlice(key);
        try buffer_cookie.appendSlice("=");
        try buffer_cookie.appendSlice(cookie.value);
        try buffer_cookie.appendSlice("; ");

        if (cookie.secure) {
            try buffer_cookie.appendSlice("Secure; ");
        }

        try buffer_cookie.appendSlice("Path=/; ");

        if (cookie.expires) |expires| {
            // Use a small buffer for number formatting to avoid writer overhead
            var num_buf: [32]u8 = undefined;
            const expires_str = try std.fmt.bufPrint(&num_buf, "Max-Age={d}; ", .{expires});
            try buffer_cookie.appendSlice(expires_str);
        }

        if (cookie.http_only) {
            try buffer_cookie.appendSlice("HttpOnly; ");
        }

        // Remove trailing "; " and add CRLF
        if (buffer_cookie.items.len >= 2 and
            std.mem.eql(u8, buffer_cookie.items[buffer_cookie.items.len - 2 ..], "; "))
        {
            buffer_cookie.shrinkRetainingCapacity(buffer_cookie.items.len - 2);
        }
        try buffer_cookie.appendSlice("\r\n");
    }

    try buffer_cookie.appendSlice("\r\n");
    return buffer_cookie.toOwnedSlice();
}

const ctnt = "Content-Length: ";

fn headerAppend(self: *Self, end: *usize, slice: []const u8) !void {
    const next = end.* + slice.len;
    if (next > self.header_buf.len) return error.HeaderBufferOverflow;
    @memcpy(self.header_buf[end.*..next], slice);
    end.* = next;
}

fn buildStandardHeaders(
    self: *Self,
    status_line: []const u8,
    content_type: []const u8,
    content_length: usize,
    include_date: bool,
    extra_header_name: ?[]const u8,
    extra_header_value: ?[]const u8,
) !usize {
    var end: usize = 0;

    try self.headerAppend(&end, status_line);

    // Emitted here rather than baked into each status line, so every
    // response -- success, error, preflight, file -- reports the same
    // connection handling the server actually performs.
    try self.headerAppend(&end, if (self.close_requested)
        "Connection: close\r\n"
    else
        "Connection: keep-alive\r\n");

    try self.headerAppend(&end, "Content-Type: ");
    try self.headerAppend(&end, content_type);
    try self.headerAppend(&end, "\r\n");

    if (include_date) {
        const date_str = httpDate();
        try self.headerAppend(&end, "Date: ");
        try self.headerAppend(&end, date_str);
        try self.headerAppend(&end, "\r\n");
    }

    if (extra_header_name) |name| {
        if (extra_header_value) |value| {
            try self.headerAppend(&end, name);
            try self.headerAppend(&end, ": ");
            try self.headerAppend(&end, value);
            try self.headerAppend(&end, "\r\n");
        }
    }

    if (cors_headers) |ch| {
        try self.headerAppend(&end, ch);
    }

    if (self.http_header.accept_control_request_headers.len > 0) {
        try self.headerAppend(&end, "Access-Control-Allow-Headers: ");
        try self.headerAppend(&end, self.http_header.accept_control_request_headers);
        try self.headerAppend(&end, "\r\n");
    }

    try self.headerAppend(&end, ctnt);
    var len_buf: [20]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{}", .{content_length});
    try self.headerAppend(&end, len_str);
    try self.headerAppend(&end, "\r\n");

    const cookie_str = try self.generateCookieString();
    try self.headerAppend(&end, cookie_str);

    self.header_buf_len = end;
    return end;
}

pub fn ERROR(self: *Self, status_code: u16, payload: []const u8) !void {
    var status_line_buf: [128]u8 = undefined;
    // An error status is not by itself a reason to drop the connection: a
    // 404 answers a perfectly well-formed request. The Connection header
    // comes from `buildStandardHeaders` like every other response.
    const status_line = try std.fmt.bufPrint(
        &status_line_buf,
        "HTTP/1.1 {d} {s}\r\nVary: Origin\r\n",
        .{ status_code, statusReason(status_code) },
    );

    var end = try self.buildStandardHeaders(
        status_line,
        "text/html; charset=utf8",
        payload.len,
        true,
        null,
        null,
    );

    if (end + payload.len <= self.header_buf.len) {
        const start = end;
        end += payload.len;
        @memcpy(self.header_buf[start..end], payload);
        try self.client.?.write(self.header_buf[0..end]);
        return;
    }

    try self.client.?.write(self.header_buf[0..end]);
    try stream(self.client.?, payload);
}

pub fn STATUS(self: *Self, status_code: u16, payload: []const u8) !void {
    var status_line_buf: [128]u8 = undefined;
    const status_line = try std.fmt.bufPrint(
        &status_line_buf,
        "HTTP/1.1 {d} {s}\r\nVary: Origin\r\n",
        .{ status_code, statusReason(status_code) },
    );

    const content_type = self.http_header.content_type.toString();
    var end = try self.buildStandardHeaders(
        status_line,
        content_type,
        payload.len,
        true,
        null,
        null,
    );

    if (end + payload.len <= self.header_buf.len) {
        const start = end;
        end += payload.len;
        @memcpy(self.header_buf[start..end], payload);
        try self.client.?.write(self.header_buf[0..end]);
        return;
    }

    try self.client.?.write(self.header_buf[0..end]);
    try stream(self.client.?, payload);
}

fn statusReason(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

// Look into redirecting users
pub fn REDIRECT(self: *Self, location: []const u8) !void {
    const cookie_str = try self.generateCookieString();

    const redirect_resp =
        "HTTP/1.1 302 Found\r\n" ++
        "Vary: Origin\r\n";

    var end: usize = redirect_resp.len;
    var start: usize = 0;

    // Status line
    @memcpy(buffer[start..end], redirect_resp);
    start = redirect_resp.len;

    // Location header
    const location_header = "Location: ";
    end += location_header.len;
    @memcpy(buffer[start..end], location_header);
    start += location_header.len;

    end += location.len;
    @memcpy(buffer[start..end], location);
    start += location.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    // CORS headers
    if (cors_headers) |ch| {
        end += ch.len;
        @memcpy(buffer[start..end], ch);
        start += ch.len;
    }

    if (self.http_header.accept_control_request_headers.len > 0) {
        const access_ctrl_req_headers = "Access-Control-Allow-Headers: ";
        end += access_ctrl_req_headers.len;
        @memcpy(buffer[start..end], access_ctrl_req_headers);
        start += access_ctrl_req_headers.len;

        end += self.http_header.accept_control_request_headers.len;
        @memcpy(buffer[start..end], self.http_header.accept_control_request_headers);
        start += self.http_header.accept_control_request_headers.len;

        end += 2;
        @memcpy(buffer[start..end], "\r\n");
        start += 2;
    }

    // Content-Length: 0
    const content_len = "Content-Length: 0\r\n";
    end += content_len.len;
    @memcpy(buffer[start..end], content_len);
    start += content_len.len;

    // Cookies
    end += cookie_str.len;
    @memcpy(buffer[start..end], cookie_str);
    start += cookie_str.len;
    std.debug.print("total: {s}\n", .{buffer[0..end]});

    try stream(self.client.?, buffer[0..end]);
}
pub const String = struct {
    start: usize,
    len: usize,
    capacity: usize,
    contents: [65535]u8 = undefined,

    pub fn new() String {
        return String{
            .start = 0,
            .len = 0,
            .capacity = 65535,
        };
    }

    pub fn init(initial: []const u8) String {
        var new_string = String.new();
        new_string.append_str(initial);
        return new_string;
    }

    pub fn append_str(self: *String, input: []const u8) void {
        const required_len = self.len + input.len;
        const required_capacity = required_len + (10 - required_len % 10);

        // Case 1: contents exists and is big enough
        if (required_capacity <= self.capacity) {
            @memcpy(self.contents[self.len .. self.len + input.len], input);
            self.len = required_len;
            // self.capacity = required_capacity;
        }
        // else { // Case 2: contents not big enough
        //     // const new_c: [*]u8 = @ptrCast(@alignCast(std.c.realloc(
        //     //     self.contents,
        //     //     required_capacity,
        //     // )));
        //     const new_c = std.heap.page_allocator.realloc(self.contents, required_capacity) catch |err| {
        //         print("{any}\n", .{err});
        //         return;
        //     };
        //     self.contents = new_c;
        //     @memcpy(self.contents[self.len .. self.len + input.len], input);
        //     self.len = required_len;
        //     self.capacity = required_capacity;
        // }
    }
};

// When testing with wrk remove connection close
const string_success_resp =
    "HTTP/1.1 200 OK\r\n" ++
    "Vary: Origin\r\n";
// "Date: Fri, 31 Oct 2025 15:59:12 GMT\r\n" ++
// "Content-Type: text/plain charset=utf-8\r\n";
// "Connection: close\r\n" ++
// "Content-Type: text/html\r\n";

// const resp = "HTTP/1.1 200 OK\r\nDate: Tue, 19 Aug 2025 18:37:36 GMT\r\nContent-Length: 7\r\nContent-Type: text/plain charset=utf-8\r\n\r\nSUCCESS";

const weekday_names = [_]*const [3]u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const month_names = [_]*const [3]u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

var cached_date: [29]u8 = undefined;
var cached_day_secs_base: u64 = 0; // timestamp of start of cached day
var cached_initialized: bool = false;

/// Positions of time digits within the 29-byte HTTP date string:
/// "Thu, 09 Apr 2026 HH:MM:SS GMT"
///  0123456789012345678901234567890
///                   ^^ ^^ ^^
/// hour=17,18  min=20,21  sec=23,24
const hour_pos = 17;
const min_pos = 20;
const sec_pos = 23;

const digits = "0123456789";

/// Call once at startup and then whenever the day rolls over.
/// Rebuilds the full date string for the current day.
fn rebuildDateBase(timestamp: u64) void {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year = year_day.year;
    const month = @intFromEnum(month_day.month); // 0-indexed
    const day: u8 = month_day.day_index + 1;

    // Day of week: Jan 1 1970 was Thursday (index 3 in Mon=0 scheme)
    // epoch_day.day is days since epoch
    const raw_day: u64 = epoch_day.day;
    const wday: u3 = @intCast((raw_day + 3) % 7); // Mon=0 .. Sun=6

    // "Thu, 09 Apr 2026 00:00:00 GMT"
    const wdn = weekday_names[wday];
    const mn = month_names[month];

    cached_date[0] = wdn[0];
    cached_date[1] = wdn[1];
    cached_date[2] = wdn[2];
    cached_date[3] = ',';
    cached_date[4] = ' ';
    cached_date[5] = digits[day / 10];
    cached_date[6] = digits[day % 10];
    cached_date[7] = ' ';
    cached_date[8] = mn[0];
    cached_date[9] = mn[1];
    cached_date[10] = mn[2];
    cached_date[11] = ' ';

    const y: u64 = @intCast(year);
    cached_date[12] = digits[y / 1000];
    cached_date[13] = digits[(y / 100) % 10];
    cached_date[14] = digits[(y / 10) % 10];
    cached_date[15] = digits[y % 10];
    cached_date[16] = ' ';

    // Placeholder time
    cached_date[17] = '0';
    cached_date[18] = '0';
    cached_date[19] = ':';
    cached_date[20] = '0';
    cached_date[21] = '0';
    cached_date[22] = ':';
    cached_date[23] = '0';
    cached_date[24] = '0';
    cached_date[25] = ' ';
    cached_date[26] = 'G';
    cached_date[27] = 'M';
    cached_date[28] = 'T';

    // Cache the start-of-day timestamp so we can check rollover cheaply
    const day_seconds = epoch_secs.getDaySeconds();
    cached_day_secs_base = timestamp - day_seconds.secs;
}

/// Returns a pointer to the 29-byte cached HTTP date string.
/// Only updates the 6 time digits on each call; rebuilds the
/// date portion only when the day rolls over.
pub fn httpDate() *const [29]u8 {
    const timestamp: u64 = @intCast(Time.timestamp());

    // Rebuild if not initialized, if the clock moved backwards, or if the day rolled over.
    if (!cached_initialized or timestamp < cached_day_secs_base or timestamp >= cached_day_secs_base + 86400) {
        rebuildDateBase(timestamp);
        cached_initialized = true;
    }

    // Stamp in the current time (6 digit writes)
    const secs_into_day: u64 = timestamp - cached_day_secs_base;
    const hour: u8 = @intCast(secs_into_day / 3600);
    const minute: u8 = @intCast((secs_into_day % 3600) / 60);
    const second: u8 = @intCast(secs_into_day % 60);

    cached_date[hour_pos] = digits[hour / 10];
    cached_date[hour_pos + 1] = digits[hour % 10];
    cached_date[min_pos] = digits[minute / 10];
    cached_date[min_pos + 1] = digits[minute % 10];
    cached_date[sec_pos] = digits[second / 10];
    cached_date[sec_pos + 1] = digits[second % 10];

    return &cached_date;
}

var buffer: [5_000_000]u8 = undefined;
pub fn STRING(self: *Self, payload: []const u8) !void {
    const content_type = self.http_header.content_type.toString();
    var end = try self.buildStandardHeaders(
        string_success_resp,
        content_type,
        payload.len,
        true,
        null,
        null,
    );

    // Fast path: coalesce headers + payload if they both fit in header_buf.
    if (end + payload.len <= self.header_buf.len) {
        const start = end;
        end += payload.len;
        @memcpy(self.header_buf[start..end], payload);
        self.client.?.write(self.header_buf[0..end]) catch |err| {
            std.log.err("Failed to write coalesced STRING response: {any}", .{err});
            return error.StringStreamError;
        };
        return;
    }

    // Large payload path: write headers first, then stream body bytes.
    self.client.?.write(self.header_buf[0..end]) catch |err| {
        std.log.err("Failed to write STRING headers: {any}", .{err});
        return error.StringStreamError;
    };

    stream(self.client.?, payload) catch |err| {
        std.log.err("Failed to stream STRING payload: {any}", .{err});
        return error.StringStreamError;
    };
}

pub fn OPTIONS(self: *Self) !void {
    const status_line =
        "HTTP/1.1 200 OK\r\n" ++
        "Vary: Accept-Encoding, Origin\r\n";

    const end = try self.buildStandardHeaders(
        status_line,
        "text/html; charset=utf8",
        0,
        true,
        null,
        null,
    );

    try self.client.?.write(self.header_buf[0..end]);
}

pub fn FILE(self: *Self, file: std.Io.File) !void {
    const stat = try file.stat(self.client.?.io);
    const file_success_resp =
        "HTTP/1.1 200 OK\r\n" ++
        "Vary: Origin\r\n";
    const mime_raw = mimeForPath(self.route);
    const mime = std.mem.trimEnd(u8, mime_raw, "\r\n");
    const content_encoding = self.http_header.content_encoding;

    const end = try self.buildStandardHeaders(
        file_success_resp,
        mime,
        @intCast(stat.size),
        true,
        if (content_encoding.len > 0) "Content-Encoding" else null,
        if (content_encoding.len > 0) content_encoding else null,
    );

    try self.client.?.write(self.header_buf[0..end]);
    try self.client.?.sendFile(file);
}

fn stream(client: *Client, payload: []const u8) !void {
    client.chunked(payload) catch |err| {
        std.log.err("Failed to chunk {any}", .{err});
        return err;
    };
}
pub fn RAW(self: *Self, raw: []const u8) !void {
    try stream(self.client.?, raw);
}

fn getUnderlyingType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => std.meta.Child(T),
        else => T,
    };
}

fn getUnderlyingValue(comptime T: type, comptime OT: type, v: OT) T {
    return switch (@typeInfo(OT)) {
        .optional => v.?,
        else => v,
    };
}

fn fastJson(comptime T: type, data: T, writer: *String) !void {
    const fields = @typeInfo(T).@"struct".fields;
    writer.append_str("{");
    inline for (fields, 0..) |f, j| {
        const field_value_optional = @field(data, f.name);
        const is_optional = @typeInfo(f.type) == .optional;
        const field_type: type = getUnderlyingType(@TypeOf(field_value_optional));
        if (!is_optional or (is_optional and field_value_optional != null)) {
            const field_value = getUnderlyingValue(field_type, @TypeOf(field_value_optional), field_value_optional);
            writer.append_str("\"");
            writer.append_str(f.name);
            writer.append_str("\"");
            writer.append_str(": ");
            switch (field_type) {
                i8, i16, i32, i64, i128, f16, f32, f64, f128 => {
                    const max_len = 20;
                    var buf: [max_len]u8 = undefined;
                    const value = try std.fmt.bufPrint(&buf, "{any}", .{field_value});
                    writer.append_str(value);
                },
                bool => {
                    if (field_value) {
                        writer.append_str("true");
                    } else {
                        writer.append_str("false");
                    }
                },
                [][]const u8, []const []const u8 => {
                    writer.append_str("[");
                    for (field_value, 0..) |e, i| {
                        writer.append_str("\"");
                        writer.append_str(e);
                        writer.append_str("\"");
                        if (i < field_value.len - 1) writer.append_str(",");
                    }
                    writer.append_str("]");
                },
                []i8, []i16, []i32, []i64, []i128, []f16, []f32, []f64, []f128 => {
                    writer.append_str("[");
                    for (field_value, 0..) |e, i| {
                        const max_len = 4;
                        var buf: [max_len]u8 = undefined;
                        const value = try std.fmt.bufPrint(&buf, "{any}", .{e});
                        writer.append_str(value);
                        if (i > 0) writer.append_str(",");
                    }
                    writer.append_str("]");
                },
                []const u8 => {
                    writer.append_str("\"");
                    writer.append_str(field_value);
                    writer.append_str("\"");
                },
                else => {
                    switch (@typeInfo(field_type)) {
                        .@"struct" => {
                            var inner_writer = String.new();
                            try fastJson(field_type, field_value, &inner_writer);
                            const payload = inner_writer.contents[0..inner_writer.len];
                            writer.append_str(payload);
                        },
                        else => {},
                    }
                },
            }
            if (j < fields.len - 1) writer.append_str(", ");
        }
    }
    writer.append_str("}");
}

// fn fastJsonParse(comptime T: type, data: []const u8) void {
//     // const vec_size = 16;
//     // var a: @Vector(vec_size, i32) = [_]i32{0} ** vec_size;
//     const fields = @typeInfo(T).@"struct".fields;
//     inline for (fields) |f| {
//         const haystack = f.name;
//         // const v: @Vector(haystack.len, u8) = @splat(' ');
//
//         const V = @Vector(32, u8);
//         var i: usize = 0;
//         while (i + 32 <= haystack.len) : (i += 32) {
//             const h = haystack[i..][0..8].*;
//             const hec: V = @bitCast(h);
//
//             const c = slice[i..][0..8].*;
//             const cep: V = @bitCast(c);
//             const splt: V = @splat(@as(u8, '\r'));
//             const mask = vec == splt;
//         }
//
//         // const field_value_optional = @field(data, f.name);
//         // const is_optional = @typeInfo(f.type) == .optional;
//         // const field_type: type = getUnderlyingType(@TypeOf(field_value_optional));
//         // if (!is_optional or (is_optional and field_value_optional != null)) {
//         // const field_value = getUnderlyingValue(field_type, @TypeOf(field_value_optional), field_value_optional);
//         // }
//     }
// }

fn findKeyPos(input: []const u8, comptime key: []const u8) ?usize {
    const key_len = key.len;
    if (key_len == 0) return null;

    const vec_len = 16;
    const key_vec = initKeyVec(key, key_len);
    const mask = initMask(key_len, key_len);
    const falses: @Vector(key_len, bool) = @splat(false);

    var i: usize = 0;
    while (i < input.len) {
        // Find next potential key start (quote)
        const quote_pos = mem.indexOfPos(u8, input, i, "\"") orelse break;
        i = quote_pos;

        // Ensure we have enough space for the full key
        if (i + key_len > input.len) return null;

        // Prepare SIMD chunk (handle end-of-input padding)
        const chunk = if (i + vec_len <= input.len)
            input[i..][0..key_len]
        else
            &padChunk(input[i..], key_len);

        // Perform SIMD comparison
        const chunk_vec: @Vector(key_len, u8) = chunk.*;
        const cmp = chunk_vec == key_vec;
        const masked = @select(bool, mask, cmp, falses);
        // return null;

        if (@reduce(.And, masked)) {
            return i; // Found match at correct quote position
        }

        // Advance to next character after quote
        i += 1;
    }
    return null;
}

fn initKeyVec(comptime key: []const u8, comptime vec_len: usize) @Vector(vec_len, u8) {
    var vec: [vec_len]u8 = undefined;
    for (0..key.len) |i| vec[i] = key[i];
    for (key.len..vec_len) |i| vec[i] = 0;
    return vec;
}

fn initMask(comptime key_len: usize, comptime vec_len: usize) @Vector(vec_len, bool) {
    var mask: [vec_len]bool = undefined;
    for (&mask, 0..) |*b, i| b.* = i < key_len;
    return mask;
}

fn padChunk(chunk: []const u8, comptime vec_len: usize) [vec_len]u8 {
    var padded: [vec_len]u8 = undefined;
    for (0..vec_len) |i| padded[i] = if (i < chunk.len) chunk[i] else 0;
    return padded;
}

fn findValueStart(input: []const u8) ?usize {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            ' ', '\t', '\n', '\r' => continue,
            else => return i,
        }
    }
    return null;
}

// fn parseString(input: []const u8) []const u8 {
//     var end: usize = 0;
//     var in_escape = false;
//     var quote: u8 = 0;
//
//     if (input[0] == '"') {
//         quote = '"';
//     } else {
//         quote = '\'';
//     }
//
//     end = 1;
//     while (end < input.len) : (end += 1) {
//         if (input[end] == '"') break;
//         if (input[end] == '\\') {
//             in_escape = true;
//             continue;
//         }
//         if (input[end] == quote and !in_escape) break;
//         in_escape = false;
//     }
//
//     return input[1..end];
// }

pub fn countCommas(text: []const u8) usize {
    const Vec32 = @Vector(16, u8);
    const comma_val: Vec32 = @splat(@as(u8, ','));
    const nulls: Vec32 = @splat(@as(u8, 1));
    const zeros: Vec32 = @splat(@as(u8, 0));

    var count: usize = 0;
    var i: usize = 0;

    // Process 16 bytes at a time
    while (i + 16 <= text.len) {
        const chunk: Vec32 = text[i..][0..16].*;
        const matches = chunk == comma_val;

        // Convert boolean vector to integer vector (true → 1, false → 0)
        const count_vec = @select(u8, matches, nulls, zeros);

        // Sum all elements
        count += @reduce(.Add, count_vec);

        i += 16;
    }

    // Handle remaining bytes
    while (i < text.len) {
        if (text[i] == ',') {
            count += 1;
        }
        i += 1;
    }

    return count;
}

/// Skips whitespace characters (space, tab, newline, carriage return) in a string using SIMD.
/// Returns the index of the first non-whitespace character, or text.len if none found.
pub fn skipWhitespace(text: []const u8, start_idx: usize) ?usize {
    const Vec16 = @Vector(16, u8);

    // Create masks for all whitespace characters
    const space_val: Vec16 = @splat(@as(u8, ' '));
    const tab_val: Vec16 = @splat(@as(u8, '\t'));
    const nl_val: Vec16 = @splat(@as(u8, '\n'));
    const cr_val: Vec16 = @splat(@as(u8, '\r'));

    var i: usize = start_idx;

    // Handle unaligned prefix bytes individually
    while (i < text.len and i % @alignOf(Vec16) != 0) {
        const c = text[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
            return i;
        }
        i += 1;
    }

    // Process 16 bytes at a time with proper alignment
    while (i + 16 <= text.len) {
        const chunk: Vec16 = text[i..][0..16].*;

        // Each comparison returns a vector of booleans
        const is_space = chunk == space_val;
        const is_tab = chunk == tab_val;
        const is_nl = chunk == nl_val;
        const is_cr = chunk == cr_val;

        // Instead of using logical 'or' on vectors, convert each to u16 and combine bitwise.
        const space_mask: u16 = @bitCast(is_space);
        const tab_mask: u16 = @bitCast(is_tab);
        const nl_mask: u16 = @bitCast(is_nl);
        const cr_mask: u16 = @bitCast(is_cr);

        const whitespace_mask = space_mask | tab_mask | nl_mask | cr_mask;

        // If not all bits are set (0xFFFF means all 16 bytes were whitespace)
        if (whitespace_mask != 0xFFFF) {
            // Invert the mask to find the first non-whitespace bit.
            const non_ws_mask = ~whitespace_mask;
            // Count trailing zeros to find the first non-whitespace position.
            const non_ws_pos = @ctz(non_ws_mask);
            return i + non_ws_pos;
        }

        i += 16;
    }

    // Handle remaining bytes
    while (i < text.len) {
        const c = text[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') {
            return i;
        }
        i += 1;
    }

    return text.len;
}

fn findIndex(haystack: []const u8, needle: u8) ?usize {
    const vec_len = 16;
    const Vec16 = @Vector(16, u8);
    const splt: Vec16 = @splat(@as(u8, needle));
    if (haystack.len >= vec_len) {
        var i: usize = 0;
        while (i + vec_len <= haystack.len) : (i += vec_len) {
            const v = haystack[i..][0..vec_len].*;
            const vec: Vec16 = @bitCast(v);
            const mask = vec == splt;
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

pub fn countChar(text: []const u8, needle: u8) usize {
    const Vec32 = @Vector(16, u8);
    const comma_val: Vec32 = @splat(@as(u8, needle));
    const nulls: Vec32 = @splat(@as(u8, 1));
    const zeros: Vec32 = @splat(@as(u8, 0));

    var count: usize = 0;
    var i: usize = 0;

    // Process 16 bytes at a time
    while (i + 16 <= text.len) {
        const chunk: Vec32 = text[i..][0..16].*;
        const matches = chunk == comma_val;

        // Convert boolean vector to integer vector (true → 1, false → 0)
        const count_vec = @select(u8, matches, nulls, zeros);

        // Sum all elements
        count += @reduce(.Add, count_vec);

        i += 16;
    }

    // Handle remaining bytes
    while (i < text.len) {
        if (text[i] == needle) {
            count += 1;
        }
        i += 1;
    }

    return count;
}

fn getEndArr(text: []const u8) usize {
    var i: usize = 0;
    var end: usize = 0;
    var depth: i32 = 0;
    while (i + 16 <= text.len) {
        const open_i = findIndex(text[i..][0..16], '[') orelse 0;
        const close_i = findIndex(text[i..][0..16], ']') orelse 16;

        const current_start_count: i32 = @intCast(countChar(text[i..][0..16], '['));
        const current_end_count: i32 = @intCast(countChar(text[i..][0..16], ']'));

        if (current_start_count == current_end_count) {} else if (close_i > open_i) {
            depth += current_start_count;
            depth -= current_end_count;
        } else if (close_i < open_i) {
            depth -= current_end_count;
            depth += current_start_count;
        }
        if (depth <= 0) {
            end += findIndex(text[i..][0..16], ',') orelse 16;
            return end;
        }
        end += 16;
        i += 16;
    }

    // Handle remaining bytes
    while (i < text.len) {
        if (text[i] == '[') {
            depth += 1;
        } else if (text[i] == ']') {
            depth -= 1;
        } else if (text[i] == ',' and depth == 1) {
            end += 1;
        }
        i += 1;
    }

    if (end == 0) {
        end = text.len;
    }

    return end;
}

fn subArrCount(text: []const u8) usize {
    var i: usize = 0;
    var start_count: usize = 0;
    while (i + 16 <= text.len) {
        const current_start_count = countChar(text[i..][0..16], '[');
        const current_end_count = countChar(text[i..][0..16], ']');
        if (current_end_count > 0) {
            if (start_count == 0) {
                start_count = current_start_count;
            }
            return start_count - 1;
        } else {
            start_count += current_start_count;
        }
        i += 16;
    }
    return 0;
}

pub fn stringifyArray(comptime T: type, data: T, writer: *String) !void {
    const ElemT = @typeInfo(T).pointer.child;

    writer.append_str("[");
    switch (ElemT) {
        i8, i16, i32, i64, i128, f16, f32, f64, f128 => {
            for (data, 0..) |elem, i| {
                const max_len = 20;
                var buf: [max_len]u8 = undefined;
                const value = try std.fmt.bufPrint(&buf, "{any}", .{elem});
                writer.append_str(value);
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        bool => {
            for (data, 0..) |elem, i| {
                if (elem) {
                    writer.append_str("true");
                } else {
                    writer.append_str("false");
                }
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        [][]const u8, []const []const u8 => {
            for (data, 0..) |elem, i| {
                writer.append_str("[");
                for (elem, 0..) |e, j| {
                    writer.append_str("\"");
                    writer.append_str(e);
                    writer.append_str("\"");
                    if (j < elem.len - 1) writer.append_str(", ");
                }
                writer.append_str("]");
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        []i8, []i16, []i32, []i64, []i128, []f16, []f32, []f64, []f128 => {
            for (data, 0..) |elem, i| {
                writer.append_str("[");
                for (elem, 0..) |e, j| {
                    const max_len = 4;
                    var buf: [max_len]u8 = undefined;
                    const value = try std.fmt.bufPrint(&buf, "{any}", .{e});
                    writer.append_str(value);
                    if (j > 0) writer.append_str(", ");
                }
                writer.append_str("]");
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        []const u8 => {
            for (data, 0..) |elem, i| {
                writer.append_str("\"");
                writer.append_str(elem);
                writer.append_str("\"");
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        else => {
            switch (@typeInfo(ElemT)) {
                .@"struct" => {
                    for (data, 0..) |elem, i| {
                        var inner_writer = String.new();
                        try fastJson(ElemT, elem, &inner_writer);
                        const payload = inner_writer.contents[0..inner_writer.len];
                        writer.append_str(payload);
                        if (i < data.len - 1) writer.append_str(", ");
                    }
                },
                .pointer => {
                    for (data, 0..) |elem, i| {
                        var inner_writer = String.new();
                        try stringifyArray(ElemT, elem, &inner_writer);
                        const payload = inner_writer.contents[0..inner_writer.len];
                        writer.append_str(payload);
                        if (i < data.len - 1) writer.append_str(", ");
                    }
                },
                else => {},
            }
        },
    }
    writer.append_str("]");
}

pub fn ARRAY(self: *Self, comptime T: type, data: T) !void {
    var writer = String.new();
    const ElemT = @typeInfo(T).pointer.child;

    writer.append_str("[");
    switch (ElemT) {
        i8, i16, i32, i64, i128, f16, f32, f64, f128 => {
            for (data, 0..) |elem, i| {
                const max_len = 20;
                var buf: [max_len]u8 = undefined;
                const value = try std.fmt.bufPrint(&buf, "{any}", .{elem});
                writer.append_str(value);
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        bool => {
            for (data, 0..) |elem, i| {
                if (elem) {
                    writer.append_str("true");
                } else {
                    writer.append_str("false");
                }
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        [][]const u8, []const []const u8 => {
            for (data, 0..) |elem, i| {
                writer.append_str("[");
                for (elem, 0..) |e, j| {
                    writer.append_str("\"");
                    writer.append_str(e);
                    writer.append_str("\"");
                    if (j < elem.len - 1) writer.append_str(", ");
                }
                writer.append_str("]");
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        []i8, []i16, []i32, []i64, []i128, []f16, []f32, []f64, []f128 => {
            for (data, 0..) |elem, i| {
                writer.append_str("[");
                for (elem, 0..) |e, j| {
                    const max_len = 4;
                    var buf: [max_len]u8 = undefined;
                    const value = try std.fmt.bufPrint(&buf, "{any}", .{e});
                    writer.append_str(value);
                    if (j > 0) writer.append_str(", ");
                }
                writer.append_str("]");
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        []const u8 => {
            for (data, 0..) |elem, i| {
                writer.append_str("\"");
                writer.append_str(elem);
                writer.append_str("\"");
                if (i < data.len - 1) writer.append_str(", ");
            }
        },
        else => {
            switch (@typeInfo(ElemT)) {
                .@"struct" => {
                    for (data, 0..) |elem, i| {
                        var inner_writer = String.new();
                        try fastJson(ElemT, elem, &inner_writer);
                        const payload = inner_writer.contents[0..inner_writer.len];
                        writer.append_str(payload);
                        if (i < data.len - 1) writer.append_str(", ");
                    }
                },
                .pointer => {
                    for (data, 0..) |elem, i| {
                        var inner_writer = String.new();
                        try stringifyArray(ElemT, elem, &inner_writer);
                        const payload = inner_writer.contents[0..inner_writer.len];
                        writer.append_str(payload);
                        if (i < data.len - 1) writer.append_str(", ");
                    }
                },
                else => {},
            }
        },
    }
    writer.append_str("]");

    const payload = writer.contents[0..writer.len];
    // const payload = try payload_arr.toOwnedSlice();

    var end: usize = success_resp.len;
    var start: usize = 0;

    // Success Response
    @memcpy(buffer[start..end], success_resp);
    start = success_resp.len;

    // Cors
    if (cors_headers) |ch| {
        end += ch.len;
        @memcpy(buffer[start..end], ch);
        start += ch.len;
    }

    const access_ctrl_req_headers = "Access-Control-Allow-Headers: ";
    end += access_ctrl_req_headers.len;
    @memcpy(buffer[start..end], access_ctrl_req_headers);
    start += access_ctrl_req_headers.len;

    end += self.http_header.accept_control_request_headers.len;
    @memcpy(buffer[start..end], self.http_header.accept_control_request_headers);
    start += self.http_header.accept_control_request_headers.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    end += ctnt.len;
    @memcpy(buffer[start..end], ctnt);
    start += ctnt.len;

    const max_len = 20;
    var buf: [max_len]u8 = undefined;
    const numAsString = try std.fmt.bufPrint(&buf, "{}", .{payload.len});
    end += numAsString.len;
    @memcpy(buffer[start..end], numAsString);
    start += numAsString.len;

    end += crlf.len;
    @memcpy(buffer[start..end], crlf);
    start += crlf.len;
    end += payload.len;
    @memcpy(buffer[start..end], payload);
    _ = try posix.write(self.client.?.socket, buffer[0..end]);
}

pub fn JSON(self: *Self, comptime T: type, data: T) !void {
    const fmt = std.json.fmt(data, .{ .whitespace = .indent_2 });

    var writer = std.Io.Writer.Allocating.init(self.arena);
    try fmt.format(&writer.writer);

    const payload = try writer.toOwnedSlice();
    var end = try self.buildStandardHeaders(
        string_success_resp,
        helpers.ContentType.JSON.toString(),
        payload.len,
        true,
        null,
        null,
    );

    if (end + payload.len <= self.header_buf.len) {
        const start = end;
        end += payload.len;
        @memcpy(self.header_buf[start..end], payload);
        try self.client.?.write(self.header_buf[0..end]);
        return;
    }

    try self.client.?.write(self.header_buf[0..end]);
    try stream(self.client.?, payload);
}

// When testing with wrk remove connection close
const html_success_resp =
    "HTTP/1.1 200 OK\r\n" ++
    "Vary: Origin\r\n";

const mimeTypes = .{
    .{ ".html", "text/html; charset=utf8\r\n" },
    .{ ".js", "application/javascript\r\n" },
    .{ ".wasm", "application/wasm\r\n" },
    .{ ".css", "text/css\r\n" },
    .{ ".png", "image/png\r\n" },
    .{ ".jpg", "image/jpeg\r\n" },
    .{ ".webp", "image/webp\r\n" },
    .{ ".gif", "image/gif\r\n" },
    .{ ".svg", "image/svg+xml\r\n" },
    .{ ".txt", "text/html; charset=utf8\r\n" },
    .{ ".woff", "font/woff\r\n" },
    .{ ".woff2", "font/woff2\r\n" },
};

pub fn mimeForPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    inline for (mimeTypes) |kv| {
        if (std.mem.eql(u8, extension, kv[0])) {
            return kv[1];
        }
    }
    return "text/html; charset=utf8\r\n";
}

pub fn HTML(self: *Self, payload: []const u8) !void {
    var end = try self.buildStandardHeaders(
        html_success_resp,
        "text/html; charset=utf8",
        payload.len,
        true,
        null,
        null,
    );

    if (end + payload.len <= self.header_buf.len) {
        const start = end;
        end += payload.len;
        @memcpy(self.header_buf[start..end], payload);
        try self.client.?.write(self.header_buf[0..end]);
        return;
    }

    try self.client.?.write(self.header_buf[0..end]);
    try stream(self.client.?, payload);
}

pub fn SET(self: *Self, key: []const u8, comptime T: type, data: T) !void {
    var json = std.array_list.Managed(u8).init(self.arena);
    defer json.deinit();
    try std.json.stringify(data, .{}, json.writer());
    const json_str = json.toOwnedSlice();
    self.setValues.put(key, json_str);
}

pub fn addCookie(self: *Self, cookie: Cookie) !void {
    try self.cookies.put(cookie.name, cookie);
}

pub fn removeCookie(self: *Self, name: []const u8) !void {
    try self.cookies.put(name, Cookie{
        .value = "",
        .name = name,
        .expires = 0,
        .secure = true,
        .http_only = true,
    });
}

pub fn getCookie(self: *Self, cookie_name: []const u8) ?Cookie {
    for (self.req_cookies) |cookie| {
        if (std.mem.eql(u8, cookie_name, cookie.name)) {
            return cookie;
        }
    }
    return null;
}

/// Looks up a query-string parameter by name.
///
/// Only the entries written for this request are scanned: the backing
/// slice is allocated once and reused, so everything past
/// `req_query_params_index` is left over from an earlier request or never
/// initialised at all, and comparing against it would read garbage
/// pointers.
pub fn queryParam(self: *Self, name: []const u8) ?Param {
    for (self.query_params[0..self.req_query_params_index]) |param_elem| {
        if (std.mem.eql(u8, param_elem.name, name)) {
            return param_elem;
        }
    }

    return null;
}

/// Looks up a path parameter by name — the `:id` in `/users/:id`.
///
/// Bounded to the entries written for this request, for the same reason as
/// `queryParam`.
pub fn param(self: *Self, name: []const u8) ?Param {
    for (self.params[0..self.req_params_index]) |param_elem| {
        if (std.mem.eql(u8, param_elem.name, name)) {
            return param_elem;
        }
    }

    return null;
}

// We need to check and sanitize the payload
// pub fn parseSetPayload(self: *Self, haystack: []const u8) !void {
//     var v: Validation = undefined;
//     v.init(&self.arena);
//     const payload_start = std.mem.indexOf(u8, haystack, "\r\n\r\n") orelse {
//         print("Failed to find payload start.\n", .{});
//         return error.PostFailed;
//     } + 4; // Skip the "\r\n\r\n"
//     const payload = haystack[payload_start..];
//
//     // weird error when payload is empty
//     // const sanitized_payload = try v.sanitizeHtml(payload);
//     // v.detectSqlInjection(sanitized_payload) catch |err| {
//     //     return err;
//     // };
//     // v.validateShellSafe(sanitized_payload) catch |err| {
//     //     return err;
//     // };
//     self.http_payload = payload;
// }

fn decoder(encoded: []const u8, decoded: *std.array_list.Managed(u8)) !void {
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] == '%') {
            // Ensure there's enough room for two hex characters
            if (i + 2 >= encoded.len) {
                return error.InvalidInput;
            }

            const hex = encoded[i + 1 .. i + 3];
            const decodedByte = try std.fmt.parseInt(u8, hex, 16);
            try decoded.append(decodedByte);
            i += 2; // Skip over the two hex characters
        } else if (encoded[i] == '+') {
            // Replace '+' with a space
            try decoded.append(' ');
        } else {
            try decoded.append(encoded[i]);
        }
    }
}

pub fn parseForm(self: *Self) !void {
    if (self.http_header.content_type != helpers.ContentType.Form) return CtxError.MalformedFormContentType;

    // "username=johndoe&password=secret123&remember=true&redirect=%2Fdashboard";
    const payload = self.payload[0..self.content_length];
    const sentinal = helpers.findCRLF(payload);
    var pos: usize = 0;
    while (pos < sentinal) {
        if (findIndex(payload[pos..], '=')) |ki| {
            const form_key = payload[pos .. ki + pos];
            pos += ki + 1;
            if (findIndex(payload[pos..], '&')) |vi| {
                const form_value = payload[pos .. vi + pos];
                pos += vi + 1;
                var decoded = std.array_list.Managed(u8).init(self.arena);
                try decoder(form_value, &decoded);
                const resp = try decoded.toOwnedSlice();
                try self.addFormParam(form_key, resp);
            } else {
                const form_value = payload[pos..];
                pos = sentinal;
                var decoded = std.array_list.Managed(u8).init(self.arena);
                try decoder(form_value, &decoded);
                const resp = try decoded.toOwnedSlice();
                try self.addFormParam(form_key, resp);
            }
        }
    }
}

pub fn parseMulti(self: *Self) !void {
    if (self.content_type != helpers.ContentType.MultiForm) return CtxError.MalformedFormContentType;
    const payload = self.payload[0..self.content_length];
    const boundary_terminator = helpers.findCRLF(payload);
    const boundary = payload[0..boundary_terminator];
    // var pos: usize = 0;
    // while (pos < sentinal) {
    // }
    var multi_form: MultiForm = MultiForm{
        .form_data = std.array_list.Managed(Data).init(self.arena),
    };
    var boundary_itr = mem.tokenizeSequence(u8, payload, boundary);
    _ = boundary_itr.next();
    while (boundary_itr.next()) |boundary_section| {
        // we do this since the last boundary contains --;
        _ = boundary_itr.peek() orelse continue;
        var data: Data = Data{};
        var field_name: []const u8 = undefined;
        var content: []const u8 = undefined;
        var content_type: []const u8 = undefined;
        var filename: ?[]const u8 = null;
        var form_itr = mem.tokenizeSequence(u8, boundary_section, "\n");
        while (form_itr.next()) |form_data| {
            // name="username"
            if (mem.startsWith(u8, form_data, "Content-Disposition: form-data; name=")) {
                var form_key_itr = mem.splitSequence(u8, form_data[37..], "; ");
                // "username"
                field_name = form_key_itr.next().?;
                field_name = field_name[1 .. field_name.len - 1];
                data.field_name = field_name;
                if (form_key_itr.next()) |form_key_type| {
                    // filename="avatar.jpg"
                    const idx = (mem.sliceTo(form_key_type, '"')).len + 1;
                    filename = form_key_type[idx .. form_key_type.len - 1];
                    data.filename = filename;
                }
            } else {
                if (mem.startsWith(u8, form_data, "Content-Type: ")) {
                    const idx = (mem.sliceTo(form_data, ':')).len + 2;
                    content_type = form_data[idx..form_data.len];
                    data.content_type = content_type;
                } else {
                    content = form_data;
                    data.content = content;
                }
            }
        }
        try multi_form.form_data.append(data);
    }
    return multi_form;
    // self.multi_form = multi_form;
}

// TODO figure what the hell is wrong with struct fields set to []const u8,
// but then to store it it needs to a []u8 field and then to stringify the struct field needs to []const u8
/// This function takes the Struct Type and outputs the parsed json payload into the struct.
///
/// # Parameters:
/// - `Context`: *Context.
/// - `T`: StructType.
/// - `value`: *T.
///
/// # Returns:
/// Struct.
///
/// # Example:
/// try ctx.bind(CredentialsReq)
/// # Returns:
/// CredentialsReq { name: "Vic", password: "password" }.
pub fn bind(self: *Self, comptime T: type, value: *T) !void {
    // assert_cm(@intFromEnum(self.content_type) == @intFromEnum(helpers.ContentType.JSON), "Http Payload must be JSON to Bind");
    const fields = @typeInfo(T).@"struct".fields;
    // print("{s}\n", .{self.payload[0..self.content_length]});
    var parsed = std.json.parseFromSlice(
        T,
        self.requestAllocator(),
        self.payload[0..self.content_length],
        .{ .ignore_unknown_fields = true },
    ) catch return error.MalformedJson;

    // we need to parse the struct []const u8 into []u8 to store in the hashmap
    inline for (fields) |f| {
        if (f.type == []const u8) {
            const field_value = @field(parsed.value, f.name);
            @field(parsed.value, f.name) = try helpers.convertStringToSlice(field_value, self.requestAllocator());
        }
    }
    value.* = parsed.value;
}

pub fn glue(self: *Self, comptime T: type) !T {
    const fields = @typeInfo(T).@"struct".fields;
    var parsed = try std.json.parseFromSlice(
        T,
        self.requestAllocator(),
        self.payload[0..self.content_length],
        .{ .ignore_unknown_fields = true },
    );

    // we need to parse the struct []const u8 into []u8 to store in the hashmap
    inline for (fields) |f| {
        if (f.type == []const u8) {
            const field_value = @field(parsed.value, f.name);
            @field(parsed.value, f.name) = try helpers.convertStringToSlice(field_value, self.requestAllocator());
        }
    }
    return parsed.value;
}

pub fn gluev2(self: *Self, comptime T: type, data: *T) !void {
    dom.Parser.initExisting(self.parser, self.payload[0..self.content_length], .{}) catch {
        print("Failed to reinit\n", .{});
    };
    // defer parser.deinit();
    self.parser.parse() catch |err| {
        print("Failed to parse parser\n", .{});
        return err;
    };
    self.parser.element().get_alloc(self.requestAllocator(), data) catch |err| {
        print("Failed to alloc\n", .{});
        return err;
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const TrackingAllocator = @import("TrackingAllocator.zig");

/// A Context wired up enough to exercise the JSON binding helpers, without
/// a socket or an event loop.
fn testContext(arena: std.mem.Allocator) !Self {
    return Self.init(
        arena,
        "POST",
        "/",
        null,
        null,
        helpers.ContentType.JSON,
        null,
        20,
    );
}

const BindTarget = struct {
    name: []const u8,
    count: i64,
};

test "bind deserialises a JSON json_body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = try testContext(arena.allocator());
    const json_body = "{\"name\":\"reverb\",\"count\":7}";
    ctx.payload = json_body;
    ctx.content_length = json_body.len;

    var out: BindTarget = undefined;
    try ctx.bind(BindTarget, &out);

    try testing.expectEqualStrings("reverb", out.name);
    try testing.expectEqual(@as(i64, 7), out.count);
}

test "glue returns the deserialised value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = try testContext(arena.allocator());
    const json_body = "{\"name\":\"glue\",\"count\":1}";
    ctx.payload = json_body;
    ctx.content_length = json_body.len;

    const out = try ctx.glue(BindTarget);
    try testing.expectEqualStrings("glue", out.name);
    try testing.expectEqual(@as(i64, 1), out.count);
}

test "bind rejects malformed JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = try testContext(arena.allocator());

    for ([_][]const u8{ "", "{", "not json", "{\"name\":}", "[]" }) |json_body| {
        ctx.payload = json_body;
        ctx.content_length = json_body.len;
        var out: BindTarget = undefined;
        try testing.expectError(error.MalformedJson, ctx.bind(BindTarget, &out));
    }
}

// Contexts are pooled for the life of the process and their allocator is the
// server's arena, which nothing resets, so anything bind allocates is held
// until shutdown: a request-rate leak rather than a one-off.
//
// The allocator is handed to the Context directly, with no ArenaAllocator in
// between. An arena serves small allocations out of chunks it already holds,
// so measuring its backing allocator hides exactly the growth this looks for.
test "repeated binds do not grow memory without bound" {
    var ta: TrackingAllocator = undefined;
    const tracked = ta.init(testing.allocator);
    defer ta.deinit();

    var ctx = try testContext(tracked);
    defer ctx.deinit();
    const json_body = "{\"name\":\"reverb\",\"count\":7}";

    // Warm up, so one-time setup is not counted as growth.
    for (0..16) |_| {
        ctx.payload = json_body;
        ctx.content_length = json_body.len;
        var out: BindTarget = undefined;
        try ctx.bind(BindTarget, &out);
        ctx.clear();
    }
    const after_warmup = ta.bytesAllocated();

    const iterations: usize = 256;
    for (0..iterations) |_| {
        ctx.payload = json_body;
        ctx.content_length = json_body.len;
        var out: BindTarget = undefined;
        try ctx.bind(BindTarget, &out);
        ctx.clear();
    }
    const growth = ta.bytesAllocated() -| after_warmup;

    // Per-request retention shows up as growth proportional to the request
    // count; a bounded implementation stays flat.
    testing.expect(growth < iterations) catch {
        std.debug.print(
            "bind retained {d} bytes across {d} calls ({d} per call)\n",
            .{ growth, iterations, growth / iterations },
        );
        return error.BindRetainsMemoryPerRequest;
    };
}
