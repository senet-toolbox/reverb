const std = @import("std");
const http = std.http;
const json = std.json;
const Client = http.Client;

pub const Backend = union(enum) {
    anthropic: struct {
        api_key: []const u8,
        anthropic_version: []const u8 = "2023-06-01",
    },
    vertex: struct {
        project_id: []const u8,
        access_token: []const u8,
        region: []const u8 = "us-central1",
        anthropic_version: []const u8 = "vertex-2023-10-16",
    },
};

pub const Options = struct {
    backend: Backend,
    model: []const u8,
    max_tokens: u32 = 1024,
};

pub const Role = enum {
    user,
    assistant,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
};

pub const Usage = struct {
    input_tokens: i64,
    output_tokens: i64,
};

pub const MessageResponse = struct {
    id: []const u8,
    type: []const u8,
    role: []const u8,
    content: []ContentBlock,
    model: []const u8,
    stop_reason: ?[]const u8 = null,
    usage: ?Usage = null,
};

pub const Provider = struct {
    const Self = @This();

    options: Options,
    arena: std.mem.Allocator,

    pub fn init(target: *Self, options: Options, allocator: std.mem.Allocator) void {
        target.* = .{
            .options = options,
            .arena = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn buildUrl(self: *Self, endpoint: []const u8) ![]const u8 {
        return switch (self.options.backend) {
            .anthropic => try std.fmt.allocPrint(
                self.arena,
                "https://api.anthropic.com/v1{s}",
                .{endpoint},
            ),
            .vertex => |v| try std.fmt.allocPrint(
                self.arena,
                "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/anthropic/models/{s}:rawPredict",
                .{ v.region, v.project_id, v.region, self.options.model },
            ),
        };
    }

    fn request(
        self: *Self,
        method: http.Method,
        endpoint: []const u8,
        payload: ?[]const u8,
    ) ![]const u8 {
        const url = try self.buildUrl(endpoint);
        defer self.arena.free(url);

        const uri = std.Uri.parse(url) catch return error.InvalidUri;

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        var client = Client{
            .allocator = self.arena,
            .io = io,
        };
        defer client.deinit();

        var body = std.Io.Writer.Allocating.init(self.arena);

        const extra_headers: []const http.Header = switch (self.options.backend) {
            .anthropic => |a| &.{
                .{ .name = "x-api-key", .value = a.api_key },
                .{ .name = "anthropic-version", .value = a.anthropic_version },
            },
            .vertex => |v| &.{
                .{
                    .name = "Authorization",
                    .value = try std.fmt.allocPrint(self.arena, "Bearer {s}", .{v.access_token}),
                },
            },
        };

        std.debug.print("URL: {s}\n", .{url});
        std.debug.print("Payload: {s}\n", .{payload orelse "(null)"});
        for (extra_headers) |h| {
            std.debug.print("Header: {s}: {s}\n", .{ h.name, h.value });
        }

        const resp = try client.fetch(.{
            .method = method,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = extra_headers,
            .location = .{ .uri = uri },
            .payload = payload,
            .response_writer = &body.writer,
        });

        if (resp.status != .ok) {
            std.debug.print("API error ({d}): {s}\n", .{
                @intFromEnum(resp.status),
                body.written(),
            });
            return error.WrongStatusResponse;
        }

        return body.written();
    }

    pub const CreateMessageParams = struct {
        messages: []const Message,
        model: ?[]const u8 = null,
        max_tokens: ?u32 = null,
        system: ?[]const u8 = null,
        temperature: ?f64 = null,
    };

    pub fn createMessage(self: *Self, params: CreateMessageParams) !MessageResponse {
        const model = params.model orelse self.options.model;
        const max_tokens = params.max_tokens orelse self.options.max_tokens;

        var out = std.Io.Writer.Allocating.init(self.arena);
        defer out.deinit();

        var jw = std.json.Stringify{
            .writer = &out.writer,
            .options = .{},
        };

        try jw.beginObject();

        switch (self.options.backend) {
            .anthropic => {
                try jw.objectField("model");
                try jw.write(model);
            },
            .vertex => |v| {
                try jw.objectField("anthropic_version");
                try jw.write(v.anthropic_version);
            },
        }

        try jw.objectField("max_tokens");
        try jw.write(max_tokens);

        if (params.system) |sys| {
            try jw.objectField("system");
            try jw.write(sys);
        }

        if (params.temperature) |temp| {
            try jw.objectField("temperature");
            try jw.write(temp);
        }

        try jw.objectField("messages");
        try jw.beginArray();
        for (params.messages) |msg| {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write(switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
            });
            try jw.objectField("content");
            try jw.write(msg.content);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.endObject();

        const payload = try out.toOwnedSlice();
        defer self.arena.free(payload);

        const endpoint = switch (self.options.backend) {
            .anthropic => "/messages",
            .vertex => "",
        };

        std.debug.print("endpoint: {s}\n", .{endpoint});
        std.debug.print("payload: {s}\n", .{payload});
        const body = try self.request(.POST, endpoint, payload);
        return try parseResp(MessageResponse, body, self.arena);
    }

    /// Convenience: send a single user message and get back the text response.
    pub fn chat(self: *Self, user_message: []const u8) ![]const u8 {
        const msgs = [_]Message{
            .{ .role = .user, .content = user_message },
        };

        const resp = try self.createMessage(.{
            .messages = &msgs,
            // .system = @embedFile("context_v2.txt"),
            .temperature = 0.5,
        });

        // Return the first text block
        for (resp.content) |block| {
            if (block.text) |text| {
                return text;
            }
        }

        return error.NoTextInResponse;
    }
};

pub fn parseResp(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !T {
    const parsed = json.parseFromSlice(
        T,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.MalformedJson;

    return parsed.value;
}
