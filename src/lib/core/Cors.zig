const std = @import("std");
const ReplyBuilder = @import("ReplyBuilder.zig");
const String = @import("builders.zig").String;

pub const Cors = @This();
cors_headers: CorsHeaders,

pub const CorsHeaders = struct {
    methods: Value = .default,
    origin: Value = .default,
    headers: Value = .default,
    credentials: Value = .default,
    max_age: Value = .default,

    pub const Value = union(enum) {
        default,
        omit,
        override: []const u8,
    };
};

pub fn init(target: *Cors, cors_headers: CorsHeaders) void {
    target.* = .{ .cors_headers = cors_headers };
}

pub fn checkHeadersStr(cors: *Cors, builder: *String) !void {
    if (try emitOverridableHeader(
        "Access-Control-Allow-Methods: ",
        cors.cors_headers.methods,
        builder,
    )) {
        builder.append_str("Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS, PATCH");
        builder.append_str("\r\n");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
    if (try emitOverridableHeader(
        "Access-Control-Allow-Origin: ",
        cors.cors_headers.origin,
        builder,
    )) {
        builder.append_str("Access-Control-Allow-Origin: http://localhost:5173");
        builder.append_str("\r\n");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
    // if (try emitOverridableHeader(
    //     "Access-Control-Allow-Headers: ",
    //     cors.cors_headers.headers,
    //     builder,
    // )) {
    //     builder.append_str("Access-Control-Allow-Headers: Content-Type, Authorization");
    //     builder.append_str("\r\n");
    //     // The default is to omit content-type if not provided because
    //     // "application/octet-stream" is redundant.
    // }
    if (try emitOverridableHeader(
        "Access-Control-Allow-Credentials: ",
        cors.cors_headers.credentials,
        builder,
    )) {
        builder.append_str("Access-Control-Allow-Credentials: false");
        builder.append_str("\r\n");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
    if (try emitOverridableHeader(
        "Access-Control-Max-Age: ",
        cors.cors_headers.max_age,
        builder,
    )) {
        builder.append_str("Access-Control-Max-Age: 86400");
        builder.append_str("\r\n");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
}

/// Returns true if the default behavior is required, otherwise handles
/// writing (or not writing) the header.
fn emitOverridableHeader(
    prefix: []const u8,
    v: CorsHeaders.Value,
    builder: *String,
) !bool {
    switch (v) {
        .default => return true,
        .omit => return false,
        .override => |x| {
            builder.append_str(prefix);
            builder.append_str(x);
            builder.append_str("\r\n");
            return false;
        },
    }
}

pub fn checkHeaders(cors: *Cors, reply_builder: *ReplyBuilder) !void {
    if (try emitOverridableHeader_("Access-Control-Allow-Methods: ", cors.cors_headers.methods, reply_builder)) {
        try reply_builder.writeHeaderPrefix("Access-Control-Allow-Methods: ");
        try reply_builder.writeHeaderValue("GET, POST, PUT, DELETE, OPTIONS, PATCH");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
    if (try emitOverridableHeader_("Access-Control-Allow-Origin: ", cors.cors_headers.origin, reply_builder)) {
        try reply_builder.writeHeaderPrefix("Access-Control-Allow-Origin: ");
        try reply_builder.writeHeaderValue("http://localhost:5173");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
    if (try emitOverridableHeader_("Access-Control-Allow-Headers: ", cors.cors_headers.headers, reply_builder)) {
        try reply_builder.writeHeaderPrefix("Access-Control-Allow-Headers: ");
        try reply_builder.writeHeaderValue("Content-Type, Authorization");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
    if (try emitOverridableHeader_("Access-Control-Allow-Credentials: ", cors.cors_headers.credentials, reply_builder)) {
        try reply_builder.writeHeaderPrefix("Access-Control-Allow-Credentials: ");
        try reply_builder.writeHeaderValue("false");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
    if (try emitOverridableHeader_("Access-Control-Max-Age: ", cors.cors_headers.max_age, reply_builder)) {
        try reply_builder.writeHeaderPrefix("Access-Control-Max-Age: ");
        try reply_builder.writeHeaderValue("86400");
        // The default is to omit content-type if not provided because
        // "application/octet-stream" is redundant.
    }
}

/// Returns true if the default behavior is required, otherwise handles
/// writing (or not writing) the header.
fn emitOverridableHeader_(prefix: []const u8, v: CorsHeaders.Value, reply_builder: *ReplyBuilder) !bool {
    switch (v) {
        .default => return true,
        .omit => return false,
        .override => |x| {
            try reply_builder.writeHeaderPrefix(prefix);
            try reply_builder.writeHeaderValue(x);
            return false;
        },
    }
}
