const std = @import("std");
const http = std.http;
const json = std.json;
const Client = http.Client;

pub const Options = struct {
    api_key: []const u8,
    anthropic_version: []const u8 = "2023-06-01",
    // model: []const u8 = "claude-sonnet-4-20250514",
    model: []const u8 = "claude-haiku-4-5-20251001",
    max_tokens: u32 = 1024,
};

// ============ Request Types ============

pub const Role = enum {
    user,
    assistant,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

// ============ Response Types ============

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

pub const ClaudeError = struct {
    type: []const u8,
    message: []const u8,
};

pub const ErrorResponse = struct {
    type: []const u8,
    @"error": ClaudeError,
};

// ============ Provider ============

pub const Provider = struct {
    const Self = @This();
    const base_url = "https://api.anthropic.com/v1";

    options: Options,
    arena: std.mem.Allocator,

    pub fn init(target: *Provider, options: Options, allocator: std.mem.Allocator) void {
        target.* = .{
            .options = options,
            .arena = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    // Core request method — sends JSON body with required Anthropic headers
    fn request(
        self: *Self,
        method: http.Method,
        endpoint: []const u8,
        payload: ?[]const u8,
    ) ![]const u8 {
        const url = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ base_url, endpoint });
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

        const resp = try client.fetch(.{
            .method = method,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &.{
                .{ .name = "x-api-key", .value = self.options.api_key },
                .{ .name = "anthropic-version", .value = self.options.anthropic_version },
            },
            .location = .{ .uri = uri },
            .payload = payload,
            .response_writer = &body.writer,
        });

        if (resp.status != .ok) {
            std.debug.print("Claude API error ({d}): {s}\n", .{ @intFromEnum(resp.status), body.written() });
            return error.WrongStatusResponse;
        }

        return body.written();
    }

    // ============ Messages API ============

    pub const CreateMessageParams = struct {
        messages: []const Message,
        model: ?[]const u8 = null, // override default model
        max_tokens: ?u32 = null, // override default max_tokens
        system: ?[]const u8 = null, // system prompt
        temperature: ?f64 = null,
    };

    /// Send a list of messages and get a response.
    pub fn createMessage(self: *Self, params: CreateMessageParams) !MessageResponse {
        const model = params.model orelse self.options.model;
        const max_tokens = params.max_tokens orelse self.options.max_tokens;

        // Build JSON payload using the 0.16 allocating writer.
        var out = std.Io.Writer.Allocating.init(self.arena);
        defer out.deinit();

        var jw = std.json.Stringify{
            .writer = &out.writer,
            .options = .{},
        };

        try jw.beginObject();

        try jw.objectField("model");
        try jw.write(model);

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

        const body = try self.request(.POST, "/messages", payload);
        return try parseResp(MessageResponse, body, self.arena);
    }

    /// Convenience: send a single user message and get back the text response.
    pub fn chat(self: *Self, user_message: []const u8) ![]const u8 {
        const msgs = [_]Message{
            .{ .role = .user, .content = user_message },
        };

        const resp = try self.createMessage(.{
            .messages = &msgs,
            .system = @embedFile("context_v2.txt"),
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

    /// Multi-turn conversation helper.
    /// Pass in the full conversation history and get the assistant's reply.
    pub fn conversation(self: *Self, messages: []const Message, system: ?[]const u8) !MessageResponse {
        return try self.createMessage(.{
            .messages = messages,
            .system = system,
        });
    }
};

// ============ Generic JSON Response Parser ============

pub fn parseResp(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !T {
    const parsed = json.parseFromSlice(
        T,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.MalformedJson;

    // NOTE: Do NOT deinit parsed — the returned value's slices ([]const u8, []ContentBlock, etc.)
    // point into memory owned by the parsed result. The caller's arena will free everything.
    return parsed.value;
}

// ============ Usage Example / Test ============

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const api_key = std.posix.getenv("ANTHROPIC_API_KEY") orelse {
        std.log.err("ANTHROPIC_API_KEY not set", .{});
        return error.MissingApiKey;
    };

    var claude: Provider = undefined;
    Provider.init(&claude, .{ .api_key = api_key }, allocator);
    defer claude.deinit();

    // ---- Test 1: Simple one-shot chat ----
    std.log.info("Sending simple message...", .{});
    const reply = try claude.chat("Hello! What's 2+2?");
    std.log.info("Claude says: {s}", .{reply});

    // ---- Test 2: Full message with system prompt ----
    std.log.info("Sending message with system prompt...", .{});
    const msgs = [_]Message{
        .{ .role = .user, .content = "Explain monads in one sentence." },
    };
    const resp = try claude.createMessage(.{
        .messages = &msgs,
        .system = "You are a concise programming tutor. Keep answers under 50 words.",
        .temperature = 0.3,
    });
    for (resp.content) |block| {
        if (block.text) |text| {
            std.log.info("Response: {s}", .{text});
        }
    }
    if (resp.usage) |usage| {
        std.log.info("Tokens — in: {d}, out: {d}", .{ usage.input_tokens, usage.output_tokens });
    }

    // ---- Test 3: Multi-turn conversation ----
    std.log.info("Starting multi-turn conversation...", .{});
    const convo = [_]Message{
        .{ .role = .user, .content = "My name is Alice." },
        .{ .role = .assistant, .content = "Hello Alice! Nice to meet you." },
        .{ .role = .user, .content = "What's my name?" },
    };
    const convo_resp = try claude.conversation(&convo, null);
    for (convo_resp.content) |block| {
        if (block.text) |text| {
            std.log.info("Claude remembers: {s}", .{text});
        }
    }
}
