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

pub const json_type = []const u8;

fn tlsWrite(_: i32, _: []const u8) void {
    // TLSStruct.tlsWrite(ssl, resp);
}
fn httpWrite(client: *Client, resp: []const u8) !void {
    try client.writer.fillWriteBuffer(resp);
    _ = try client.writeMessage();
    // _ = try posix.write(client.socket, resp);
}

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
http_header: *helpers.HTTPHeader = undefined,
req_params_index: usize = 0,
params: []Param = undefined, // Array of key-value pairs for URL parameters
req_query_params_index: usize = 0,
query_params: []Param = undefined, // Array of key-value pairs for query parameters
form_params: *std.StringHashMap([]const u8) = undefined, // Array of key-value pairs for form data
method: []const u8,
route: []const u8,
// headers: std.StringHashMap([]const u8) = undefined,
// setValues: std.StringHashMap([]const u8) = undefined,
payload: [524288]u8 = undefined,
// payload_str: []const u8 = undefined,
content_length: usize = 0,
http_payload: []const u8,
content_type: helpers.ContentType = helpers.ContentType.None,
client: ?*Client = null,
// ssl: ?i32 = null,
cookies: std.StringHashMap(Cookie) = undefined,
req_cookie_index: usize = 0,
req_cookies: []Cookie = undefined,
// sticky_session: ?[]const u8 = null,
// boundary: ?[]const u8 = null,
multi_form: MultiForm = undefined,
reply_builder: String = undefined,
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
    const parser = try arena.create(dom.Parser);
    parser.* = try dom.Parser.initFixedBuffer(arena, "", .{});
    var form_params = std.StringHashMap([]const u8).init(arena);
    const req_cookies = try arena.alloc(Cookie, cookie_size);
    const query_params = try arena.alloc(Param, 256);
    const params = try arena.alloc(Param, cookie_size);
    return Self{
        .arena = arena,
        .method = method,
        .route = route,
        .params = params,
        .query_params = query_params,
        .form_params = &form_params,
        // .headers = std.StringHashMap([]const u8).init(arena),
        // .setValues = std.StringHashMap([]const u8).init(arena),
        .http_payload = "",
        .content_type = content_type,
        .client = client,
        .parser = parser,
        // .ssl = ssl,
        .cookies = std.StringHashMap(Cookie).init(arena),
        .req_cookies = req_cookies,
        // .sticky_session = null,
        // .boundary = boundary,
        // .reply_builder = String.new(),
    };
}

pub fn deinit(self: *Self) !void {
    // Free the dynamically allocated memory for all hashmaps

    // Free params
    // self.params.deinit();

    // Free query_params
    // self.query_params.deinit();

    // Free form_params
    // We must add this here since we always assume value is a owned created string
    var itr = self.form_params.iterator();
    while (itr.next()) |e| {
        self.arena.free(e.value_ptr.*);
    }
    self.form_params.deinit();
    self.parser.deinit();
    self.arena.destroy(self.parser);

    // Free headers
    // self.headers.deinit();

    // Free headers
    // self.setValues.deinit();

    // Free payload if it was dynamically allocated (assuming it may be heap-allocated)
    // if (self.payload.len > 0) {
    //     self.arena.free(self.payload);
    // }
}

pub fn clear(self: *Self) void {
    self.cookies.clearRetainingCapacity();
    self.req_params_index = 0;
    self.req_query_params_index = 0;
    self.req_cookie_index = 0;
    self.header_buf = undefined;
    self.header_buf_len = 0;
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

    return buffer_cookie.toOwnedSlice();
}

// fn generateCookieString(self: *Self) ![]const u8 {
//     var buffer_cookie = std.array_list.Managed(u8).init(self.arena);
//     defer buffer_cookie.deinit();
//
//     var cookies_itr = self.cookies.iterator();
//     // var builder: std.RingBuffer = try std.RingBuffer.init(self.arena, 4096);
//     while (cookies_itr.next()) |entry| {
//         const key = entry.key_ptr.*;
//         const cookie = entry.value_ptr.*;
//         _ = try buffer_cookie.writer().write("Set-Cookie: ");
//         _ = try buffer_cookie.writer().write(key);
//         _ = try buffer_cookie.writer().write("=");
//         _ = try buffer_cookie.writer().write(cookie.value);
//         _ = try buffer_cookie.writer().write("; ");
//         if (cookie.secure) {
//             _ = try buffer_cookie.writer().write("Secure;");
//         }
//         _ = try buffer_cookie.writer().write("Path=/;");
//         if (cookie.expires) |expires| {
//             try buffer_cookie.writer().print(
//                 "Max-Age={d};",
//                 .{expires},
//             );
//         }
//
//         if (cookie.http_only) {
//             _ = try buffer_cookie.writer().write("HttpOnly");
//         }
//         if (cookies_itr.index <= self.cookies.count() - 1) {
//             _ = try buffer_cookie.writer().write(";");
//         }
//         _ = try buffer_cookie.writer().write("\r\n");
//     } else {
//         _ = try buffer_cookie.writer().write("\r\n");
//     }
//
//     const cookie_str = buffer_cookie.toOwnedSlice();
//     return cookie_str;
// }

const error_resp =
    "Vary: Origin\r\n" ++
    "Connection: close\r\n" ++
    "Content-Type: text/html; charset=utf8\r\n";

const ctnt = "Content-Length: ";
pub fn ERROR(self: *Self, status_code: u16, payload: []const u8) !void {
    // const proto_str = "HTTP/1.1 {d} NOT FOUND";
    const proto_str = "HTTP/1.1 ";
    const max_len = 4;
    var end: usize = proto_str.len;
    var start: usize = 0;

    // 0, 9
    @memcpy(buffer[start..end], proto_str);
    start += proto_str.len;

    var error_code: [max_len]u8 = undefined;
    const error_code_str = try std.fmt.bufPrint(&error_code, "{}", .{status_code});
    end += error_code_str.len;

    // 9, 13
    @memcpy(buffer[start..end], error_code_str);
    start += error_code_str.len;

    const not_found = " NOT FOUND\r\n";
    end += not_found.len;
    // 13, 25
    @memcpy(buffer[start..end], not_found);
    start += not_found.len;

    // Error Response
    end += error_resp.len;
    @memcpy(buffer[start..end], error_resp);
    start += error_resp.len;

    // Cors
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

    end += ctnt.len;
    @memcpy(buffer[start..end], ctnt);
    start += ctnt.len;

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

pub fn STATUS(self: *Self, status_code: u16, payload: []const u8) !void {
    var end: usize = 0;
    var start: usize = 0;

    // Status line: "HTTP/1.1 XXX <reason>\r\n"
    const http_version = "HTTP/1.1 ";
    end += http_version.len;
    @memcpy(buffer[start..end], http_version);
    start += http_version.len;

    var status_buf: [3]u8 = undefined;
    const status_str = try std.fmt.bufPrint(&status_buf, "{}", .{status_code});
    end += status_str.len;
    @memcpy(buffer[start..end], status_str);
    start += status_str.len;

    const reason = statusReason(status_code);
    const space = " ";
    end += space.len;
    @memcpy(buffer[start..end], space);
    start += space.len;

    end += reason.len;
    @memcpy(buffer[start..end], reason);
    start += reason.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    // Content-Type
    const content_type = self.http_header.content_type.toString();
    const content_type_header = "Content-Type: ";
    end += content_type_header.len;
    @memcpy(buffer[start..end], content_type_header);
    start += content_type_header.len;

    end += content_type.len;
    @memcpy(buffer[start..end], content_type);
    start += content_type.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    // Cors
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

    // Content-Length
    end += ctnt.len;
    @memcpy(buffer[start..end], ctnt);
    start += ctnt.len;

    var len_buf: [20]u8 = undefined;
    const numAsString = try std.fmt.bufPrint(&len_buf, "{}", .{payload.len});
    end += numAsString.len;
    @memcpy(buffer[start..end], numAsString);
    start += numAsString.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    // Cookies
    const cookie_str = try self.generateCookieString();
    end += cookie_str.len;
    @memcpy(buffer[start..end], cookie_str);
    start += cookie_str.len;

    // Body
    end += payload.len;
    @memcpy(buffer[start..end], payload);
    try stream(self.client.?, buffer[0..end]);
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
    const timestamp: u64 = @intCast(std.time.timestamp());

    // Rebuild if not initialized or day has rolled over
    if (!cached_initialized or (timestamp - cached_day_secs_base) >= 86400) {
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
    var end: usize = string_success_resp.len;
    var start: usize = 0;

    // Success Response
    @memcpy(buffer[start..end], string_success_resp);
    start = string_success_resp.len;

    const content_type = self.http_header.content_type.toString();
    const content_type_header = "Content-Type: ";
    end += content_type_header.len;
    @memcpy(buffer[start..end], content_type_header);
    start += content_type_header.len;

    end += content_type.len;
    @memcpy(buffer[start..end], content_type);
    start += content_type.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    const date_str = httpDate();

    const date_header = "Date: ";
    end += date_header.len;
    @memcpy(buffer[start..end], date_header);
    start += date_header.len;

    end += date_str.len;
    @memcpy(buffer[start..end], date_str);
    start += date_str.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    // Cors
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

    end += ctnt.len;
    @memcpy(buffer[start..end], ctnt);
    start += ctnt.len;

    const max_len = 16;
    var buf: [max_len]u8 = undefined;
    const numAsString = try std.fmt.bufPrint(&buf, "{}", .{payload.len});
    end += numAsString.len;
    @memcpy(buffer[start..end], numAsString);
    start += numAsString.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    const cookie_str = try self.generateCookieString();

    end += cookie_str.len;
    @memcpy(buffer[start..end], cookie_str);
    start += cookie_str.len;

    // self.client.?.write(buffer[0..end]) catch |err| {
    //     std.log.err("Failed to stream {any}", .{err});
    //     return error.StringStreamError;
    // };

    // now payload streaming
    end += payload.len;
    @memcpy(buffer[start..end], payload);
    stream(self.client.?, buffer[0..end]) catch |err| {
        std.log.err("Failed to stream {any}", .{err});
        return error.StringStreamError;
    };
}

const options_success_resp =
    "HTTP/1.1 200 OK\r\n" ++
    "Vary: Accept-Encoding, Origin\r\n" ++
    "Connection: Keep-Alive\r\n" ++
    "Content-Type: text/html; charset=utf8\r\n" ++
    "Content-Length: 0\r\n";

pub fn OPTIONS(self: *Self) !void {
    var end: usize = options_success_resp.len;
    var start: usize = 0;

    // Success Response
    @memcpy(buffer[start..end], options_success_resp);
    start = options_success_resp.len;

    // Cors
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

    const cookie_str = try self.generateCookieString();

    end += cookie_str.len;
    @memcpy(buffer[start..end], cookie_str);
    start += cookie_str.len;

    try stream(self.client.?, buffer[0..end]);
}

pub fn FILE(self: *Self, file: std.fs.File) !void {
    const stat = try file.stat();
    const file_success_resp =
        "HTTP/1.1 200 OK\r\n" ++
        "Vary: Origin\r\n";

    var end: usize = file_success_resp.len;
    var start: usize = 0;

    // Success Response
    @memcpy(buffer[start..end], file_success_resp);
    start = file_success_resp.len;

    const ctnt_type = "Content-Type: ";
    end += ctnt_type.len;
    @memcpy(buffer[start..end], ctnt_type);
    start += ctnt_type.len;

    const mime = mimeForPath(self.route);
    end += mime.len;
    @memcpy(buffer[start..end], mime);
    start += mime.len;

    // Add this when serving .br files
    const content_encoding = self.http_header.content_encoding;
    if (content_encoding.len > 0) {
        const encoding = "Content-Encoding: ";
        end += encoding.len;
        @memcpy(buffer[start..end], encoding);
        start += encoding.len;

        end += content_encoding.len;
        @memcpy(buffer[start..end], content_encoding);
        start += content_encoding.len;
        end += 2;
        @memcpy(buffer[start..end], "\r\n");
        start += 2;
    }

    // Cors
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

    end += ctnt.len;
    @memcpy(buffer[start..end], ctnt);
    start += ctnt.len;

    const max_len = 32;
    var buf: [max_len]u8 = undefined;
    const numAsString = try std.fmt.bufPrint(&buf, "{}", .{stat.size});
    end += numAsString.len;
    @memcpy(buffer[start..end], numAsString);
    start += numAsString.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    const cookie_str = try self.generateCookieString();

    end += cookie_str.len;
    @memcpy(buffer[start..end], cookie_str);
    start += cookie_str.len;

    const client = self.client.?;
    try client.write(buffer[0..end]);

    end += stat.size;
    try client.sendFile(file);
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

pub fn parseJson(comptime T: type, result: *T, input: []const u8) !void {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const key = std.fmt.comptimePrint("\"{s}\":", .{field.name});
        const is_optional = @typeInfo(field.type) == .optional;
        const pos_op = findKeyPos(input, key);
        if (pos_op) |pos| {
            const value_start = findValueStart(input[pos + key.len ..]) orelse return error.InvalidFormat;
            const field_value_optional = @field(result, field.name);
            const field_type: type = getUnderlyingType(@TypeOf(field_value_optional));
            if (!is_optional or (is_optional and field_value_optional != null)) {
                switch (field_type) {
                    [][]const u8, []const []const u8 => {
                        // var allocator = std.heap.c_allocator;
                        // var arr = try std.heap.c_allocator.alloc([]const u8, 2);
                        // _ = try parseStrArr(
                        //     input[pos + key.len + value_start ..],
                        //     field_type,
                        //     &allocator,
                        // );
                        // const value = parseStringArray(
                        //     input[pos + key.len + value_start ..],
                        //     field_type,
                        // );
                        const arr = try parseArr(field_type, input[pos + key.len + value_start ..]);
                        // print("{any}\n", .{value.len});
                        // for (0..value.len) |i| {
                        //     arr[i] = value[i];
                        // }
                        @field(result, field.name) = arr;
                    },
                    bool => {
                        if (input[pos + key.len + value_start] == 't') {
                            @field(result, field.name) = true;
                        } else {
                            @field(result, field.name) = false;
                        }
                    },
                    []const u8 => {
                        const value = parseString(input[pos + key.len + value_start ..]);
                        @field(result, field.name) = value;
                    },
                    i32, f32 => {
                        // print("{s}\n", .{input[pos + key.len + value_start ..]});
                        const num_str = parseInt(input[pos + key.len + value_start ..]);
                        const value = try std.fmt.parseInt(
                            field_type,
                            num_str,
                            10,
                        );
                        @field(result, field.name) = value;
                    },
                    else => {
                        switch (@typeInfo(field_type)) {
                            .@"struct" => {
                                // var value = field_value_optional;
                                const struct_value = try std.heap.c_allocator.create(field_type);
                                const offset = pos + key.len + value_start;
                                // print("{any} {any}\n", .{ field_type, field_value });
                                try parseJson(field_type, struct_value, input[offset..]);
                                @field(result, field.name) = struct_value.*;
                            },
                            else => {},
                        }
                    },
                }
            } else {
                @field(result, field.name) = null;
            }
        } else if (is_optional) {
            @field(result, field.name) = null;
        }
    }
}

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

fn parseInt(input: []const u8) []const u8 {
    var end: usize = 0;
    var in_escape = false;
    const quote: u8 = '\'';

    while (end < input.len) : (end += 1) {
        if (input[end] == '\r') break;
        if (input[end] == '\n') break;
        if (input[end] == ' ') break;
        if (input[end] == '\\') {
            in_escape = true;
            continue;
        }
        if (input[end] == quote and !in_escape) break;
        in_escape = false;
    }

    return input[0..end];
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

fn parseStrArr(input: []const u8, comptime T: type, allocator: *std.mem.Allocator) !T {
    var buffer_arr = input[1..];
    const count = countCommas(input) + 1;
    var arr = try allocator.alloc([]const u8, count);

    const start: usize = 0;
    var end: usize = 0;

    for (0..count) |i| {
        if (skipWhitespace(buffer_arr, 0)) |first| {
            buffer_arr = buffer_arr[first..];
        }
        // print("{s}\n:End\n", .{buffer_arr});
        if (findIndex(buffer_arr, '\n')) |e_n| {
            if (findIndex(buffer_arr, ',')) |e_c| {
                end = e_c + 1;
            } else {
                end = e_n;
            }

            // end = e_c + 1;
        } else if (findIndex(buffer_arr, ',')) |e_c| {
            end = e_c + 2;
        } else if (findIndex(buffer_arr, ']')) |e_c| {
            end = e_c;
        }

        if (buffer_arr[end - 1] == ',') {
            arr[i] = buffer_arr[start + 1 .. end - 2];
        } else {
            arr[i] = buffer_arr[start + 1 .. end - 1];
        }
        buffer_arr = buffer_arr[end..];
    }
    return arr;
}

fn parseStringArray(input: []const u8, comptime T: type) T {
    // Maximum expected array elements (adjust based on your use case)
    const MaxElements = 16;
    var elements: [MaxElements][]const u8 = undefined;
    var count: usize = 0;

    var i: usize = 0;
    if (input.len > 0 and input[i] == '[') i += 1;

    while (i < input.len and count < MaxElements) : (i += 1) {
        // Skip whitespace
        // i += mem.indexOfNonePos(u8, input, i, " \t\n\r") orelse break;

        if (input[i] == ' ') continue;
        if (input[i] == ']') break;

        // Parse string value directly from input
        const str_start = i + 1; // Skip opening quote
        const str_end = mem.indexOfPos(u8, input, str_start, "\"") orelse input.len;
        elements[count] = input[str_start..str_end];
        count += 1;

        // Jump to next element
        i = mem.indexOfPos(u8, input, str_end, ",") orelse input.len;
        i += 1; // Skip comma
    }

    // Return slice of populated elements
    return elements[0..count];
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

fn parseValue(comptime T: type, input: []const u8) !T {
    switch (T) {
        [][]const u8, []const []const u8 => {
            return parseArr(T, input);
        },

        []const u8 => {
            return parseString(input);
        },
        []u8 => {
            return parseSlice(input);
        },
        else => {
            // Parsing ints
            return try parseInt(T, input);
        },
    }
}

fn parseSlice(input: []const u8) []u8 {
    const end: usize = input.len - 1;
    var slice = try std.heap.c_allocator.alloc(u8, input.len - 2);
    @memcpy(&slice, input[1..end]);
    return slice;
}

fn parseString(input: []const u8) []const u8 {
    var end: usize = 0;
    var in_escape = false;
    var quote: u8 = 0;

    if (input[0] == '"') {
        quote = '"';
    } else {
        quote = '\'';
    }

    end = 1;
    while (end < input.len) : (end += 1) {
        if (input[end] == '"') break;
        if (input[end] == '\\') {
            in_escape = true;
            continue;
        }
        if (input[end] == quote and !in_escape) break;
        in_escape = false;
    }

    return input[1..end];
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

fn parseArr(comptime T: type, input: []const u8) !T {
    const ElemT = @typeInfo(T).pointer.child;
    const count = subArrCount(input);
    if (count > 0) {}
    const end_bracket = getEndArr(input);
    var buffer_input = input[1..end_bracket];

    const commas = countChar(buffer_input, ',') + 1;
    var arr = try std.heap.c_allocator.alloc(ElemT, commas);

    const start: usize = 0;
    var end: usize = 0;
    for (0..commas) |i| {
        if (skipWhitespace(buffer_input, 0)) |first| {
            buffer_input = buffer_input[first..];
        }
        if (findIndex(buffer_input, '\n')) |e_n| {
            if (findIndex(buffer_input, ',')) |e_c| {
                end = e_c + 1;
            } else {
                end = e_n;
            }

            // end = e_c + 1;
        } else if (findIndex(buffer_input, ',')) |e_c| {
            end = e_c + 2;
        } else if (findIndex(buffer_input, ']')) |e_c| {
            end = e_c;
        }

        if (buffer_input.len < 1) return arr;
        if (buffer_input[end - 1] == ',') {
            arr[i] = try parseValue(ElemT, buffer_input[start .. end - 1]);
        } else {
            arr[i] = try parseValue(ElemT, buffer_input[start..end]);
        }
        buffer_input = buffer_input[end..];
    }
    return arr;
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

    // const payload = writer.contents[0..writer.len];

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

// When testing with wrk remove connection close
const html_success_resp =
    "HTTP/1.1 200 OK\r\n" ++
    "Vary: Origin\r\n" ++
    "Content-Type: text/html; charset=utf8\r\n";

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
    var end: usize = html_success_resp.len;
    var start: usize = 0;

    // Success Response
    @memcpy(buffer[start..end], html_success_resp);
    start = html_success_resp.len;

    // Cors
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

    end += ctnt.len;
    @memcpy(buffer[start..end], ctnt);
    start += ctnt.len;

    const max_len = 4;
    var buf: [max_len]u8 = undefined;
    const numAsString = try std.fmt.bufPrint(&buf, "{}", .{payload.len});
    end += numAsString.len;
    @memcpy(buffer[start..end], numAsString);
    start += numAsString.len;

    end += 2;
    @memcpy(buffer[start..end], "\r\n");
    start += 2;

    const cookie_str = try self.generateCookieString();

    end += cookie_str.len;
    @memcpy(buffer[start..end], cookie_str);
    start += cookie_str.len;

    end += payload.len;
    @memcpy(buffer[start..end], payload);
    _ = try posix.write(self.client.?.socket, buffer[0..end]);
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

pub fn queryParam(self: *Self, name: []const u8) ?Param {
    for (self.query_params) |param_elem| {
        if (std.mem.eql(u8, param_elem.name, name)) {
            return param_elem;
        }
    }

    return null;
}

pub fn param(self: *Self, name: []const u8) ?Param {
    for (self.params) |param_elem| {
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
    if (self.content_type != helpers.ContentType.Form) return CtxError.MalformedFormContentType;

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
    self.multi_form = multi_form;
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
        self.arena,
        self.payload[0..self.content_length],
        .{},
    ) catch return error.MalformedJson;

    // we need to parse the struct []const u8 into []u8 to store in the hashmap
    inline for (fields) |f| {
        if (f.type == []const u8) {
            const field_value = @field(parsed.value, f.name);
            @field(parsed.value, f.name) = try helpers.convertStringToSlice(field_value, std.heap.c_allocator);
        }
    }
    value.* = parsed.value;
}

pub fn glue(self: *Self, comptime T: type, value: *T) !void {
    // assert_cm(@intFromEnum(self.content_type) == @intFromEnum(helpers.ContentType.JSON), "Http Payload must be JSON to Bind");
    const fields = @typeInfo(T).@"struct".fields;
    var parsed = std.json.parseFromSlice(
        T,
        self.arena,
        self.payload[0..self.content_length],
        .{},
    ) catch |err| {
        return err;
    };

    // we need to parse the struct []const u8 into []u8 to store in the hashmap
    inline for (fields) |f| {
        if (f.type == []const u8) {
            const field_value = @field(parsed.value, f.name);
            @field(parsed.value, f.name) = try helpers.convertStringToSlice(field_value, std.heap.c_allocator);
        }
    }
    value.* = parsed.value;
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
    self.parser.element().get_alloc(self.arena, data) catch |err| {
        print("Failed to alloc\n", .{});
        return err;
    };

    // try parseJson(
    //     T,
    //     data,
    //     self.payload[0..self.content_length],
    // );
}
