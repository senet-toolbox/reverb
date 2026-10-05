const std = @import("std");
const QueryBuilder = @import("QueryBuilder.zig");
const http = std.http;
const json = std.json;
const Client = http.Client;

pub const Options = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8 = "http://localhost:5173",
    grant_type: []const u8 = "authorization_code",
};

pub const GoogleUserInfo = struct {
    sub: []const u8,
    name: []const u8,
    given_name: []const u8,
    family_name: []const u8,
    picture: []const u8,
    email: []const u8,
    email_verified: bool,
};

pub const Provider = struct {
    const Self = @This();
    options: Options,
    query: QueryBuilder,
    arena: std.mem.Allocator,

    pub fn init(
        target: *Provider,
        options: Options,
        allocator: std.mem.Allocator,
    ) !void {
        var query: QueryBuilder = undefined;
        try query.init(allocator);
        target.* = .{
            .options = options,
            .query = query,
            .arena = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        self.query.deinit();
    }

    pub fn tokenExchange(google_prov: *Self, auth_code: []const u8) ![]const u8 {
        const allocator = google_prov.arena;

        try google_prov.query.add("code", auth_code);
        try google_prov.query.add("client_id", google_prov.options.client_id);
        try google_prov.query.add("client_secret", google_prov.options.client_secret);
        try google_prov.query.add("redirect_uri", google_prov.options.redirect_uri);
        try google_prov.query.add("grant_type", google_prov.options.grant_type);
        defer google_prov.query.clear();

        try google_prov.query.queryStrEncode();
        const payload = google_prov.query.str;

        const uri = try std.Uri.parse("https://oauth2.googleapis.com/token");

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        var client = Client{
            .allocator = allocator,
            .io = io,
            .write_buffer_size = 8192,
        };
        defer client.deinit(); // <-- Make sure this is here

        var body = std.Io.Writer.Allocating.init(allocator);
        // defer body.deinit();

        const resp = try client.fetch(.{
            .method = .POST,
            .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
            .location = .{ .uri = uri },
            .payload = payload,
            .response_writer = &body.writer,
        });

        if (resp.status != .ok) {
            std.debug.print("Response body: {s}\n", .{body.written()});
            std.debug.print("Response status: {s}\n", .{payload});
            return error.WrongStatusResponse;
        }

        return body.written();
    }

    pub fn getUserInfo(google_prov: *Self, access_token: []const u8) ![]const u8 {
        const allocator = google_prov.arena;
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
        defer allocator.free(authorization);
        const uri = try std.Uri.parse("https://openidconnect.googleapis.com/v1/userinfo");

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        var client = Client{
            .allocator = allocator,
            .io = io,
            .write_buffer_size = 8192,
        };
        defer client.deinit();

        var body = std.Io.Writer.Allocating.init(allocator);
        const resp = try client.fetch(.{
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = authorization },
                .user_agent = .{ .override = "Nightwatch" },
            },
            .location = .{ .uri = uri },
            .response_writer = &body.writer,
        });

        if (resp.status != .ok) {
            std.debug.print("\nBody: {s}\n", .{body.written()});
            std.debug.print("\nStatus: {any}\n", .{resp.status});

            const ErrorStruct = struct {
                @"error": []const u8,
                error_description: []const u8,
            };

            _ = try parseResp(ErrorStruct, body.written(), allocator);

            return error.WrongStatusResponse;
        }
        return body.written();
    }

    // Opening up a a http.Client.open cause slower compile time
    pub fn refreshToken(google_prov: *Self, refresh_token: []const u8) ![]const u8 {
        const allocator = google_prov.arena;
        try google_prov.query.add("client_id", google_prov.options.client_id);
        try google_prov.query.add("client_secret", google_prov.options.client_secret);
        try google_prov.query.add("refresh_token", refresh_token); // or your actual callback URL
        try google_prov.query.add("grant_type", "refresh_token");
        defer google_prov.query.clear();
        try google_prov.query.queryStrEncode();
        const payload = google_prov.query.str;
        const uri = try std.Uri.parse("https://oauth2.googleapis.com/token");

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        var client = Client{
            .allocator = allocator,
            .io = io,
            .write_buffer_size = 8192,
        };
        defer client.deinit();

        var body = std.Io.Writer.Allocating.init(allocator);
        const resp = try client.fetch(.{
            .method = .POST,
            .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
            .location = .{ .uri = uri },
            .payload = payload,
            .response_writer = &body.writer,
        });

        if (resp.status != .ok) {
            std.debug.print("Response body: {s}\n", .{body.written()});
            std.debug.print("Response status: {s}\n", .{payload});
            return error.WrongStatusResponse;
        }

        return body.written();
    }
};

pub const TokenResp = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    refresh_token: ?[]const u8,
    scope: ?[]const u8,
    id_token: ?[]const u8,
};

pub const RefreshTokenResp = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    scope: ?[]const u8,
    id_token: ?[]const u8,
};

pub fn parseResp(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !*T {
    const index = std.mem.indexOf(u8, body, "{").?;
    const binded_value: *T = try allocator.create(T);
    const parsed = json.parseFromSlice(
        T,
        allocator,
        body[index..body.len],
        .{},
    ) catch return error.MalformedJson;
    defer parsed.deinit();

    binded_value.* = parsed.value;
    return binded_value;
}

pub const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    refresh_token: ?[]const u8,
    scope: ?[]const u8,
    id_token: ?[]const u8,

    pub fn deinit(self: *const TokenResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.token_type);
        if (self.refresh_token) |rt| allocator.free(rt);
        if (self.scope) |s| allocator.free(s);
        if (self.id_token) |it| allocator.free(it);
    }
};
