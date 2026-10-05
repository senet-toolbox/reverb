const std = @import("std");
const loompkg = @import("loom");
const Server = @import("reverb").Server;
const Context = @import("reverb").Context;
const Websocket = loompkg.WebSocket;
const KeyStone = @import("reverb").KeyStone;
const Crud = @import("pg/crud.zig").CRUD;
const PgConnection = @import("pg/Connection.zig");
const orm = @import("pg/orm.zig");
const pg = @import("pg");
const Sample = @import("sample/sample.zig");
const Errors = @import("error_index.zig");
const orm_test = @import("pg/orm_test.zig");
const Assembler = @import("assembler/crud.zig");
const AssemblerApi = @import("assembler/api.zig");

var connections: std.StringHashMap(*std.array_list.Managed(Connection)) = undefined;
var connected: std.StringHashMap(bool) = undefined;
var websocket_allocator = std.heap.c_allocator;

fn ping(ctx: *Context) !void {
    try ctx.STRING("SUCCESS");
}

fn onConnection(ws: *Websocket, ctx: *Context) !void {
    ctx.parseParams() catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return err;
    };
    const id_param = ctx.param("user_id") orelse return error.NoId;
    const name_param = ctx.param("name") orelse return error.NoId;
    // const chat_param = ctx.param("chat_id") orelse return error.NoId;
    var websockets = connections.get("chat") orelse {
        ws.sendText("Failed to get chat") catch |err| {
            std.debug.print("Error: {any}\n", .{err});
            return err;
        };
        return;
    };

    const id = websocket_allocator.dupe(u8, id_param.value) catch unreachable;

    if (connected.get(id)) |_| {
        ws.sendText("Already connected") catch |err| {
            std.debug.print("Error: {any}\n", .{err});
            return err;
        };
        return;
    }

    const name = websocket_allocator.dupe(u8, name_param.value) catch unreachable;
    std.debug.print("id: {s}\n", .{id});
    std.debug.print("name: {s}\n", .{name});

    websockets.append(Connection{
        .id = id,
        .name = name,
        .websocket = ws,
    }) catch |err| {
        ws.sendText("failed to append") catch |_err| {
            std.debug.print("Error: {any}\n", .{_err});
            return err;
        };
        return;
    };

    connected.put(id, true) catch unreachable;

    ws.sendText("Connected to chat") catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return err;
    };
}

fn broadcast(ws: *Websocket, message: WebSocketMessage, ctx: *Context) !void {
    const websockets = connections.get("chat") orelse {
        ws.sendText("Failed to get chat") catch |err| {
            std.debug.print("Error: {any}\n", .{err});
            return err;
        };
        return;
    };
    for (websockets.items) |conn| {
        const new_message = WebSocketMessage{
            .id = message.id,
            .conversation_id = message.conversation_id,
            .sender_id = message.sender_id,
            .content = message.content,
            .timestamp = message.timestamp,
            .msg_type = message.msg_type,
        };
        const data = std.json.Stringify.valueAlloc(ctx.arena, new_message, .{}) catch |err| {
            std.debug.print("Error: {any}\n", .{err});
            return err;
        };
        try conn.websocket.sendText(data);
    }
}

pub const WebSocketMessage = struct {
    id: []const u8,
    conversation_id: []const u8,
    sender_id: []const u8,
    content: []const u8,
    timestamp: i64,
    msg_type: []const u8 = "message", // message, typing, read_receipt, ack
};

const Connection = struct {
    id: []const u8,
    name: []const u8,
    websocket: *Websocket,
};

fn onMessage(ws: *Websocket, message: Websocket.Message, ctx: *Context) !void {
    const allocator = std.heap.c_allocator;

    switch (message) {
        .Text => |text| {
            var parsed = std.json.parseFromSlice(WebSocketMessage, allocator, text, .{}) catch return error.MalformedJson;
            defer parsed.deinit();
            try broadcast(ws, parsed.value, ctx);
        },
        .Binary => |binary| {
            std.debug.print("Binary: {any}\n", .{binary});
        },
        .Pong => |pong| {
            std.debug.print("Pong: {any}\n", .{pong});
        },
        .Close => |close| {
            std.debug.print("Close: {any}\n", .{close});
        },
        else => {},
    }
}

// In your Keystone.zig or similar
const Stripe = @import("lib/payment/Stripe.zig");

var stripe_provider: Stripe.Provider = undefined;

pub fn initStripe(secret_key: []const u8, allocator: std.mem.Allocator) void {
    Stripe.Provider.init(&stripe_provider, .{
        .secret_key = secret_key,
    }, allocator);
}

const Claude = @import("lib/claude/API.zig");
const VERTEX = @import("lib/claude/VERTEX.zig");

var vertex_provider: VERTEX.Provider = undefined;

var claude_provider: Claude.Provider = undefined;

pub fn initClaude(api_key: []const u8, allocator: std.mem.Allocator) void {
    Claude.Provider.init(&claude_provider, .{
        .api_key = api_key,
        .max_tokens = 4096,
    }, allocator);
}

const project_id = "assembler-492301";
const access_token = "ya29.a0Aa7MYioEDWm4r9cHg_xrV8pCUTHxbCCbyxRl8XEMOU2tBerMDM0_9zt3lYPa1T4yaFS6AiEdEsk9PDvbvQ6enY_-cLlCrLsy4a0TqhmUU1VK3e_GlxWxLcIX5eJV7rS3hDUDO2BICMOG_2-cCBD3AipAumeOqU8zq-WfLD2etGkP-MmQ7M4-AdEibNQVp6Oz6piRhsxBXWN4aCgYKAWYSARMSFQHGX2MiveMAlsOoBGg16H_F0jkexg0211";

pub fn initVertex(allocator: std.mem.Allocator) void {
    VERTEX.Provider.init(&vertex_provider, .{
        .backend = .{
            .vertex = .{
                .project_id = project_id,
                .access_token = access_token,
                .region = "us-east5",
            },
            // .vertex = .{
            //     .project_id = project_id,
            //     .access_token = access_token,
            //     .region = "global",
            // },
        },
        .model = "claude-sonnet-4",
        .max_tokens = 64,
    }, allocator);
}

const PayloadClaude = struct {
    query: []const u8,
};

var API_GOOGLE_CLIENT_ID: []const u8 = "";
var API_GOOGLE_SECRET: []const u8 = "";
var CLAUDE_API_SECRET: []const u8 = "";
var STRIPE_TEST_KEY: []const u8 = "";

pub fn handleClaude(ctx: *Context) !void {
    var payload_claude: PayloadClaude = undefined;
    try ctx.bind(PayloadClaude, &payload_claude);

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var claude: Claude.Provider = undefined;
    Claude.Provider.init(&claude, .{ .api_key = CLAUDE_API_SECRET, .max_tokens = 4096 }, allocator);
    defer claude.deinit();

    // ---- Test 1: Simple one-shot chat ----
    const reply = try claude.chat(payload_claude.query);
    // std.log.info("reply: {d}", .{reply.len});

    try ctx.STRING(reply);
}

const vertexai: []const u8 = "AQ.Ab8RN6JToFIoLQKcQm-KNFrUrVulJvKTiHseQo627Ob1Y03slQ";

// Example handler
pub fn handleCreatePayment(ctx: *Context) !void {
    // Test 2: Create a customer
    std.log.info("Creating customer...", .{});
    const customer = try stripe_provider.createCustomer(.{
        .email = "test@example.com",
        .name = "Test User",
    });
    std.log.info("Customer created: {s}", .{customer.id});

    const pi = try stripe_provider.createPaymentIntent(.{
        .amount = 2000, // $20.00
        .currency = "usd",
        .customer = customer.id,
        .description = "Test payment",
    });
    std.log.info("PaymentIntent created: {s}", .{pi.id});
    std.log.info("Client secret: {s}", .{pi.client_secret orelse "none"});
    std.log.info("Status: {s}", .{pi.status});

    std.debug.print("PaymentIntent created: {any} {s} {s}\n", .{ pi.amount, pi.currency, pi.status });

    try ctx.STRING("SUCCESS");
}

pub fn handleCheckout(ctx: *Context) !void {
    try ctx.parseForm();
    const amount = ctx.form_params.get("amount") orelse return error.AmountNull;
    const currency = ctx.form_params.get("currency") orelse return error.CurrencyNull;
    std.log.info("Amount: {s}", .{amount});
    std.log.info("Currency: {s}", .{currency});
    // try ctx.STRING("SUCCESS");
    const amount_float = std.fmt.parseInt(i64, amount, 10) catch return error.AmountInvalid;
    const session = try stripe_provider.createCheckoutSession(.{
        .amount = amount_float, // $20.00
        .currency = currency,
        .product_name = "Pro Plan",
        .success_url = "http://localhost:5173/success?session_id={CHECKOUT_SESSION_ID}",
        .cancel_url = "http://localhost:5173/cancel",
        .mode = "payment",
    });

    // std.log.info("Checkout URL: {s}", .{session.url orelse "no url"});

    // // Redirect user to Stripe
    // try ctx.REDIRECT(session.url orelse return error.NoCheckoutUrl);

    // // Return JSON with the URL
    // var buf: [2048]u8 = undefined;
    // const json_response = try std.fmt.bufPrint(&buf, "{{\"url\": \"{s}\"}}", .{session.url});

    const url = session.url orelse return error.NoCheckoutUrl;
    try ctx.STRING(url);
}

// In your routes/handlers
pub fn handleStripeWebhook(ctx: *Context) !void {
    const payload = ctx.payload[0..ctx.content_length];

    // Parse the event
    const parsed = std.json.parseFromSlice(
        struct {
            id: []const u8,
            type: []const u8,
        },
        ctx.arena,
        payload,
        .{ .ignore_unknown_fields = true },
    ) catch {
        std.log.err("Failed to parse webhook", .{});
        try ctx.ERROR(400, "Invalid payload");
        return;
    };
    defer parsed.deinit();

    const event_type = parsed.value.type;
    std.log.info("Webhook received: {s}", .{event_type});

    // Handle different events
    if (std.mem.eql(u8, event_type, "checkout.session.completed")) {
        // Payment successful!
        std.log.info("Payment completed!", .{});

        // TODO: Parse the full event to get customer email, etc.
        // TODO: Update your database - mark user as paid
        // Example: db.updateUser(email, .{ .plan = "pro" });

    } else if (std.mem.eql(u8, event_type, "customer.subscription.deleted")) {
        // Subscription cancelled
        std.log.info("Subscription cancelled", .{});

        // TODO: Downgrade user in your database

    } else if (std.mem.eql(u8, event_type, "invoice.payment_failed")) {
        // Payment failed (card expired, etc)
        std.log.info("Payment failed", .{});

        // TODO: Notify user, maybe send email
    }

    // Always return 200 to acknowledge receipt
    try ctx.STRING("ok");
}

fn createUser(ctx: *Context) !void {
    std.debug.print("createUser {s}\n", .{ctx.payload});
    try ctx.STRING("createUser");
}

fn getErrorCallbackArgs(ctx: *Context) !void {
    const payload = std.mem.trim(u8, ctx.http_payload, &.{ 0, ' ', '\n', '\r', '\t' });
    if (payload.len == 0) {
        return ctx.ERROR(400, "Empty query");
    }

    const response = crud.rawQuery(payload) catch {
        return ctx.ERROR(500, "Internal server error");
    };

    switch (response) {
        .ok => |result| {
            const json = try result.toObjectsJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            try ctx.STRING(json);
        },
        .err => |pg_err| {
            const json = try pg_err.toJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            // Map PG error codes to HTTP status codes
            const status: u16 = if (pg_err.isUnique())
                409
            else if (pg_err.isForeignKey() or pg_err.isNotNull())
                422
            else if (pg_err.isSyntax() or pg_err.isUndefinedTable())
                400
            else
                500;
            ctx.http_header.content_type = .JSON;
            try ctx.STATUS(status, json);
        },
    }
}

fn rawSQL(ctx: *Context) !void {
    const payload = std.mem.trim(u8, ctx.http_payload, &.{ 0, ' ', '\n', '\r', '\t' });
    if (payload.len == 0) {
        return ctx.ERROR(400, "Empty query");
    }

    const response = crud.rawQuery(payload) catch {
        return ctx.ERROR(500, "Internal server error");
    };

    switch (response) {
        .ok => |result| {
            const json = try result.toJson(ctx.arena);
            // const object = try result.toObjectsJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            try ctx.STRING(json);
        },
        .err => |pg_err| {
            const json = try pg_err.toJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            // Map PG error codes to HTTP status codes
            const status: u16 = if (pg_err.isUnique())
                409
            else if (pg_err.isForeignKey() or pg_err.isNotNull())
                422
            else if (pg_err.isSyntax() or pg_err.isUndefinedTable())
                400
            else
                500;
            ctx.http_header.content_type = .JSON;
            try ctx.STATUS(status, json);
        },
    }
}

fn getDashboardOverview(ctx: *Context) !void {
    const req =
        \\SELECT
        \\  t.table_name,
        \\  pg_stat.n_live_tup AS estimated_row_count,
        \\  pg_size.total_size,
        \\  pg_size.table_size,
        \\  pg_size.index_size,
        \\  t.column_count,
        \\  t.nullable_columns,
        \\  idx.index_count,
        \\  fk.fk_count
        \\FROM (
        \\  SELECT table_name,
        \\         COUNT(*) AS column_count,
        \\         COUNT(*) FILTER (WHERE is_nullable = 'YES') AS nullable_columns
        \\  FROM information_schema.columns
        \\  WHERE table_schema = 'public'
        \\  GROUP BY table_name
        \\) t
        \\LEFT JOIN pg_stat_user_tables pg_stat
        \\  ON pg_stat.relname = t.table_name
        \\LEFT JOIN LATERAL (
        \\  SELECT pg_total_relation_size(pg_stat.relid) AS total_size,
        \\         pg_table_size(pg_stat.relid) AS table_size,
        \\         pg_indexes_size(pg_stat.relid) AS index_size
        \\) pg_size ON true
        \\LEFT JOIN (
        \\  SELECT tablename, COUNT(*) AS index_count
        \\  FROM pg_indexes
        \\  WHERE schemaname = 'public'
        \\  GROUP BY tablename
        \\) idx ON idx.tablename = t.table_name
        \\LEFT JOIN (
        \\  SELECT tc.table_name, COUNT(*) AS fk_count
        \\  FROM information_schema.table_constraints tc
        \\  WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
        \\  GROUP BY tc.table_name
        \\) fk ON fk.table_name = t.table_name
        \\ORDER BY pg_stat.n_live_tup DESC NULLS LAST
    ;

    const response = crud.rawQuery(req) catch {
        return ctx.ERROR(500, "Internal server error");
    };

    switch (response) {
        .ok => |result| {
            const json = try result.toJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            try ctx.STRING(json);
        },
        .err => |pg_err| {
            const json = try pg_err.toJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            // Map PG error codes to HTTP status codes
            const status: u16 = if (pg_err.isUnique())
                409
            else if (pg_err.isForeignKey() or pg_err.isNotNull())
                422
            else if (pg_err.isSyntax() or pg_err.isUndefinedTable())
                400
            else
                500;
            ctx.http_header.content_type = .JSON;
            try ctx.STATUS(status, json);
        },
    }
}

fn getSchemas(ctx: *Context) !void {
    const req =
        \\SELECT table_name, column_name, data_type, is_nullable, column_default
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\ORDER BY table_name, ordinal_position
    ;

    const response = crud.rawQuery(req) catch {
        return ctx.ERROR(500, "Internal server error");
    };

    switch (response) {
        .ok => |result| {
            const json = try result.toJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            try ctx.STRING(json);
        },
        .err => |pg_err| {
            const json = try pg_err.toJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            // Map PG error codes to HTTP status codes
            const status: u16 = if (pg_err.isUnique())
                409
            else if (pg_err.isForeignKey() or pg_err.isNotNull())
                422
            else if (pg_err.isSyntax() or pg_err.isUndefinedTable())
                400
            else
                500;
            ctx.http_header.content_type = .JSON;
            try ctx.STATUS(status, json);
        },
    }
}

fn explainAnalyze(ctx: *Context) !void {
    const payload = std.mem.trim(u8, ctx.http_payload, &.{ 0, ' ', '\n', '\r', '\t' });
    if (payload.len == 0) return ctx.ERROR(400, "Empty query");

    const response = crud.rawQuery(payload) catch {
        return ctx.ERROR(500, "Internal server error");
    };

    switch (response) {
        .ok => |result| {
            // Use flat format for EXPLAIN results
            const json = try result.toFlatStringsJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            try ctx.STRING(json);
        },
        .err => |pg_err| try sendPgError(ctx, pg_err),
    }
}

// Extract the shared error handling
fn sendPgError(ctx: *Context, pg_err: Crud.PgError) !void {
    const json = try pg_err.toJson(ctx.arena);
    ctx.http_header.content_type = .JSON;
    const status: u16 = if (pg_err.isUnique()) 409 else if (pg_err.isForeignKey() or pg_err.isNotNull()) 422 else if (pg_err.isSyntax() or pg_err.isUndefinedTable()) 400 else 500;
    try ctx.STATUS(status, json);
}

fn getErrorGroups(ctx: *Context) !void {
    const response = crud.getErrorGroups(null, 10) catch {
        return ctx.ERROR(500, "Internal server error");
    };

    switch (response) {
        .ok => |result| {
            const json = try result.toObjectsJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            try ctx.STRING(json);
        },
        .err => |pg_err| {
            const json = try pg_err.toJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            // Map PG error codes to HTTP status codes
            const status: u16 = if (pg_err.isUnique())
                409
            else if (pg_err.isForeignKey() or pg_err.isNotNull())
                422
            else if (pg_err.isSyntax() or pg_err.isUndefinedTable())
                400
            else
                500;
            ctx.http_header.content_type = .JSON;
            try ctx.STATUS(status, json);
        },
    }
}

fn updateGroupStatus(ctx: *Context) !void {
    const id_param = ctx.queryParam("id") orelse return error.NoId;
    const status_param = ctx.queryParam("status") orelse return error.NoStatus;
    const response = crud.updateGroupStatus(id_param.value, status_param.value) catch {
        return ctx.ERROR(500, "Internal server error");
    };

    switch (response) {
        .ok => {
            try ctx.STRING("OK");
        },
        .err => |pg_err| {
            const json = try pg_err.toJson(ctx.arena);
            ctx.http_header.content_type = .JSON;
            // Map PG error codes to HTTP status codes
            const status: u16 = if (pg_err.isUnique())
                409
            else if (pg_err.isForeignKey() or pg_err.isNotNull())
                422
            else if (pg_err.isSyntax() or pg_err.isUndefinedTable())
                400
            else
                500;
            ctx.http_header.content_type = .JSON;
            try ctx.STATUS(status, json);
        },
    }
}

pub var crud: Crud = undefined;
pub var pg_conn: PgConnection = undefined;

const Config = struct {
    port: u16 = 8080,
    max: usize = 1024,
    max_body_size: usize = 1024 * 1024 * 10,
};

fn dotenvLookup(env: *DotEnv, key: []const u8) ?[]const u8 {
    return env.get(key);
}

fn initPool(allocator: std.mem.Allocator, env: *DotEnv) !void {
    std.debug.print("Connecting to PostgreSQL...\n", .{});

    const cfg = PgConnection.Config.fromEnv(env, dotenvLookup);
    pg_conn = try PgConnection.init(allocator, cfg);
    crud = Crud.init(pg_conn.pool(), allocator);
}

const DotEnv = struct {
    map: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DotEnv {
        var dot_env = DotEnv{
            .map = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
        dot_env.loadDotenv() catch |err| {
            std.log.err("Failed to load .env: {any}", .{err});
        };
        return dot_env;
    }

    fn get(self: *DotEnv, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    fn loadDotenv(self: *DotEnv) !void {
        const allocator = self.allocator;
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, ".env", .{}) catch |err| {
            if (err == error.FileNotFound) return; // no .env, that's fine
            return err;
        };
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);

        while (reader.interface.takeDelimiter('\n') catch null) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Strip optional "export " prefix
            const content = if (std.mem.startsWith(u8, trimmed, "export "))
                std.mem.trim(u8, trimmed["export ".len..], " \t")
            else
                trimmed;

            if (std.mem.indexOfScalar(u8, content, '=')) |sep| {
                const key = std.mem.trim(u8, content[0..sep], " \t");
                const val = std.mem.trim(u8, content[sep + 1 ..], " \t\"'");
                const key_z = try allocator.dupeZ(u8, key);
                const val_z = try allocator.dupeZ(u8, val);
                try self.map.put(key_z, val_z);
            }
        }
    }
};

var dotenv: DotEnv = undefined;
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    dotenv = DotEnv.init(allocator);
    // try initPool(allocator, &dotenv);
    // try Assembler.createTableAuth(pg_conn.pool());

    var server: Server(Config) = undefined;
    try server.new(.{}, allocator, null);

    // getEnvVarOwned allocates — you must free the result
    API_GOOGLE_CLIENT_ID = dotenv.get("API_GOOGLE_CLIENT") orelse return error.NotFound;
    API_GOOGLE_SECRET = dotenv.get("API_GOOGLE_SECRET") orelse return error.NotFound;
    STRIPE_TEST_KEY = dotenv.get("STRIPE_TEST_KEY") orelse return error.NotFound;
    CLAUDE_API_SECRET = dotenv.get("CLAUDE_API_SECRET") orelse return error.NotFound;

    try KeyStone.install(&server, .{
        .clients = .{
            .google = .{
                .client_id = API_GOOGLE_CLIENT_ID,
                .client_secret = API_GOOGLE_SECRET,
                .redirect_uri = "http://localhost:5173/auth/callback",
            },
        },
        .origin = "http://localhost:5173",
        .backend_url = "http://localhost:8080",
        .hook_path = "/auth/callback",
    }, allocator);

    const secret_key = STRIPE_TEST_KEY;
    initStripe(secret_key, allocator);

    try server.useCors(.{
        .cors_headers = .{
            .origin = .{ .override = "http://localhost:5173" },
            .headers = .{ .override = "Content-Type" },
            .credentials = .{ .override = "true" },
        },
    });

    var websockets = std.array_list.Managed(Connection).init(allocator);
    connections = std.StringHashMap(*std.array_list.Managed(Connection)).init(allocator);
    connections.put("chat", &websockets) catch unreachable;
    connected = std.StringHashMap(bool).init(server.arena);

    try server.useWss(.{
        .onConnection = onConnection,
        .onMessage = onMessage,
        .max_body_size = 1024,
    });

    Errors.init(&crud) catch |err| {
        std.log.err("Error tracking init failed: {any}", .{err});
        return err;
    };

    try server.get("/", ping, &.{});
    try server.post("/user", createUser, &.{});
    try server.get("/payment", handleCreatePayment, &.{});
    try server.post("/checkout", handleCheckout, &.{});
    try server.get("/checkout", handleCheckout, &.{});
    try server.post("/webhook", handleStripeWebhook, &.{});
    try server.post("/sql_raw", rawSQL, &.{});
    try server.post("/sql_get_callback_args", getErrorCallbackArgs, &.{});
    try server.get("/sql_schemas", getSchemas, &.{});
    try server.post("/sql_explain", explainAnalyze, &.{});

    try server.get("/dashboard/overview", getDashboardOverview, &.{});
    try server.get("/api/sample/get", Sample.getSample, &.{});
    try server.post("/api/sample/post", Sample.postSample, &.{});
    try server.delete("/api/sample/delete", Sample.deleteSample, &.{});

    try server.post("/recordError", Errors.recordError, &.{});
    try server.get("/errors/groups", Errors.getErrorGroups, &.{});
    try server.get("/errors/groups/:id/occurrences", Errors.getOccurrences, &.{});
    try server.post("/errors/groups/:id/status", Errors.updateGroupStatus, &.{});
    try server.get("/errors/stats", Errors.getErrorStats, &.{});

    try server.get("/errors/groups/:id/frames", Errors.getGroupFrames, &.{});
    try server.get("/errors/groups/:id/events", Errors.getGroupEvents, &.{});
    try server.get("/errors/timeseries", Errors.getTimeSeries, &.{});
    try server.delete("/errors/groups/:id", Errors.deleteGroup, &.{});
    try server.delete("/errors/groups/resolved", Errors.deleteAllResolved, &.{});
    try server.post("/chat", handleClaude, &.{});
    try server.post("/api/wasm/build", buildWasm, &.{});
    try server.get("/api/wasm/build", getWasmBuild, &.{});
    try server.post("/api/vertex", vertexapi, &.{});

    try server.post("/api/users", AssemblerApi.createUser, &.{});

    // Initialize ORM with allocator
    orm.init(allocator);

    std.debug.print("Connected successfully!\n\n", .{});
    try server.listen();
}

fn spawn(ctx: *Context) !void {
    const allocator = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build" },
        .cwd = .{ .path = "wasm" },
        .stdout_limit = .limited(50 * 1024),
        .stderr_limit = .limited(50 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 0) {
        try ctx.STRING("success");
    } else {
        const stderr = try cleanErrorMessage(ctx.arena, result.stderr);
        std.log.err("{s}\n", .{result.stderr});
        try ctx.ERROR(500, stderr);
    }
}

fn cleanErrorMessage(allocator: std.mem.Allocator, raw_stderr: []const u8) ![]const u8 {
    // Strip ANSI escape codes first
    var stripped = std.array_list.Managed(u8).init(allocator);
    defer stripped.deinit();

    var i: usize = 0;
    while (i < raw_stderr.len) {
        if (raw_stderr[i] == 0x1b) { // ESC character
            // Skip until we hit a letter (end of ANSI sequence)
            while (i < raw_stderr.len and raw_stderr[i] != 'm') : (i += 1) {}
            i += 1; // skip the 'm'
        } else {
            try stripped.append(raw_stderr[i]);
            i += 1;
        }
    }

    const clean = stripped.items;

    // Now extract just the "error: ..." lines
    var result = std.array_list.Managed(u8).init(allocator);

    var lines = std.mem.splitScalar(u8, clean, '\n');
    var found_error = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.indexOf(u8, trimmed, "error: ") != null) {
            // Skip the noisy "command failed" lines
            if (std.mem.indexOf(u8, trimmed, "the following command failed") != null) {
                found_error = false;
                continue;
            }
            if (std.mem.indexOf(u8, trimmed, "following build command failed") != null) {
                found_error = false;
                continue;
            }

            if (result.items.len > 0) try result.appendSlice("\n");
            try result.appendSlice(trimmed);
            found_error = true;
        } else if (found_error) {
            // Keep grabbing context lines until we hit an empty line or another section
            if (trimmed.len == 0) {
                found_error = false;
            } else {
                try result.appendSlice("\n");
                try result.appendSlice(trimmed);
            }
        }
    }

    return try result.toOwnedSlice();
}

fn buildWasm(ctx: *Context) !void {
    const payload = std.mem.trim(u8, ctx.http_payload, &.{ 0, ' ', '\n', '\r', '\t' });
    if (payload.len == 0) return ctx.ERROR(400, "Empty query");

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io, "wasm/src/main.zig", .{ .read = true }) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return err;
    };
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try file_writer.interface.writeAll(payload);
    try file_writer.interface.flush();

    const ctx_cloned = try ctx.arena.create(Context);
    ctx_cloned.* = ctx.*;
    var thread = try std.Thread.spawn(.{}, spawn, .{ctx_cloned});
    thread.join();
}

fn getWasmBuild(ctx: *Context) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, "wasm/zig-out/bin/vapor.wasm", .{}) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return err;
    };
    // defer file.close();
    try ctx.FILE(file);
}

fn vertexapi(ctx: *Context) !void {
    var payload_claude: PayloadClaude = undefined;
    try ctx.bind(PayloadClaude, &payload_claude);

    // var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    // defer arena.deinit();
    // const allocator = arena.allocator();

    // ---- Test 1: Simple one-shot chat ----
    const reply = try vertex_provider.chat(payload_claude.query);

    try ctx.STRING(reply);
}
