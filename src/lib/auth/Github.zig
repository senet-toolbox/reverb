const std = @import("std");
const QueryBuilder = @import("QueryBuilder.zig");
const http = std.http;
const json = std.json;
const Client = http.Client;

pub const User = struct {
    login: []const u8,
    id: u64,
    node_id: []const u8,
    avatar_url: []const u8,
    gravatar_id: []const u8,
    url: []const u8,
    html_url: []const u8,
    followers_url: []const u8,
    following_url: []const u8,
    gists_url: []const u8,
    starred_url: []const u8,
    subscriptions_url: []const u8,
    organizations_url: []const u8,
    repos_url: []const u8,
    events_url: []const u8,
    received_events_url: []const u8,
    type: []const u8,
    user_view_type: []const u8,
    site_admin: bool,
    name: ?[]const u8,
    company: ?[]const u8,
    blog: []const u8,
    location: ?[]const u8,
    email: ?[]const u8,
    hireable: ?bool,
    bio: ?[]const u8,
    twitter_username: ?[]const u8,
    notification_email: ?[]const u8,
    public_repos: u32,
    public_gists: u32,
    followers: u32,
    following: u32,
    created_at: []const u8,
    updated_at: []const u8,
    private_gists: u32,
    total_private_repos: u32,
    owned_private_repos: u32,
    disk_usage: u64,
    collaborators: u32,
    two_factor_authentication: bool,
    plan: Plan,

    pub const Plan = struct {
        name: []const u8,
        space: u64,
        collaborators: u32,
        private_repos: u32,
    };
};

pub const Options = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8 = "http://localhost:5173/auth",
    state: []const u8 = "random_csrf_token",
};

pub const Provider = struct {
    const Self = @This();
    options: Options,
    query: QueryBuilder,
    arena: std.mem.Allocator,
    access_token: ?[]const u8 = null,

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

    pub fn tokenExchange(github_prov: *Self, auth_code: []const u8) ![]const u8 {
        const allocator = github_prov.arena;
        try github_prov.query.add("client_id", github_prov.options.client_id);
        try github_prov.query.add("client_secret", github_prov.options.client_secret);
        try github_prov.query.add("code", auth_code);
        try github_prov.query.add("redirect_uri", github_prov.options.redirect_uri); // or your actual callback URL
        try github_prov.query.add("state", github_prov.options.state);
        defer github_prov.query.clear();
        try github_prov.query.queryStrEncode();
        const payload = github_prov.query.str;
        const uri = try std.Uri.parse("https://github.com/login/oauth/access_token");

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
            .headers = .{
                .content_type = .{ .override = "application/x-www-form-urlencoded" },
            },
            .location = .{ .uri = uri },
            .payload = payload,
            .response_writer = &body.writer,
        });

        if (resp.status != .ok) {
            std.debug.print("\nBody: {s}\n", .{body.written()});
            std.debug.print("\nStatus: {any}\n", .{resp.status});

            const ErrorStruct = struct {
                @"error": []const u8,
                error_description: []const u8,
            };

            _ = parseResp(ErrorStruct, body.written(), allocator) catch {};

            return error.WrongStatusResponse;
        }
        return body.written();
    }

    pub fn getUserInfo(github_prov: *Self, access_token: []const u8) ![]const u8 {
        const allocator = github_prov.arena;
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
        defer allocator.free(authorization);
        const uri = try std.Uri.parse("https://api.github.com/user");

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

            _ = parseResp(ErrorStruct, body.written(), allocator) catch {};

            return error.WrongStatusResponse;
        }
        return body.written();
    }

    pub fn refreshToken(github_prov: *Self, refresh_token: []const u8) ![]const u8 {
        const allocator = github_prov.arena;
        try github_prov.query.add("client_id", github_prov.options.client_id);
        try github_prov.query.add("client_secret", github_prov.options.client_secret);
        try github_prov.query.add("refresh_token", refresh_token); // or your actual callback URL
        try github_prov.query.add("redirect_uri", github_prov.options.redirect_uri); // or your actual callback URL
        try github_prov.query.add("state", github_prov.options.state);
        defer github_prov.query.clear();
        try github_prov.query.queryStrEncode();
        const payload = github_prov.query.str;
        const uri = try std.Uri.parse("https://oauth2.githubapis.com/token");

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
            .headers = .{
                .content_type = .{ .override = "application/x-www-form-urlencoded" },
            },
            .location = .{ .uri = uri },
            .payload = payload,
            .response_writer = &body.writer,
        });

        if (resp.status != .ok) {
            return error.WrongStatusResponse;
        }

        return body.written();
    }
};

pub const TokenResp = struct {
    access_token: []const u8,
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
