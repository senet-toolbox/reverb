const std = @import("std");
const http = std.http;
const json = std.json;
const Client = http.Client;

pub const Options = struct {
    secret_key: []const u8,
    api_version: []const u8 = "2024-12-18.acacia",
};

// Response types
pub const PaymentIntent = struct {
    id: []const u8,
    object: []const u8,
    amount: i64,
    currency: []const u8,
    status: []const u8,
    client_secret: ?[]const u8 = null,
    created: ?i64 = null,
    metadata: ?json.Value = null,
};

pub const Customer = struct {
    id: []const u8,
    object: []const u8,
    email: ?[]const u8 = null,
    name: ?[]const u8 = null,
    created: ?i64 = null,
};

pub const Charge = struct {
    id: []const u8,
    object: []const u8,
    amount: i64,
    currency: []const u8,
    status: []const u8,
    paid: bool,
};

pub const StripeError = struct {
    type: []const u8,
    message: []const u8,
    code: ?[]const u8 = null,
    param: ?[]const u8 = null,
};

pub const ErrorResponse = struct {
    @"error": StripeError,
};

pub const Provider = struct {
    const Self = @This();
    const base_url = "https://api.stripe.com/v1";

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

    // Core request method
    fn request(
        self: *Self,
        method: http.Method,
        endpoint: []const u8,
        payload: ?[]const u8,
    ) ![]const u8 {
        const url = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ base_url, endpoint });
        defer self.arena.free(url);

        const authorization = try std.fmt.allocPrint(self.arena, "Bearer {s}", .{self.options.secret_key});
        defer self.arena.free(authorization);

        const uri = std.Uri.parse(url) catch return error.InvalidUri;

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        var client = Client{
            .allocator = self.arena,
            .io = io,
            .write_buffer_size = 8192,
        };
        defer client.deinit(); // <-- Make sure this is here

        var body = std.Io.Writer.Allocating.init(self.arena);

        const resp = try client.fetch(.{
            .method = method,
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = .{ .override = "application/x-www-form-urlencoded" },
            },
            .location = .{ .uri = uri },
            .payload = payload,
            .response_writer = &body.writer,
        });

        if (resp.status != .ok) {
            std.debug.print("Response body: {s}\n", .{body.written()});
            return error.WrongStatusResponse;
        }

        return body.written();
    }

    // ============ Payment Intents ============

    pub const CreatePaymentIntentParams = struct {
        amount: i64,
        currency: []const u8,
        customer: ?[]const u8 = null,
        description: ?[]const u8 = null,
        automatic_payment_methods: bool = true,
    };

    pub fn createPaymentIntent(self: *Self, params: CreatePaymentIntentParams) !*PaymentIntent {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        try writer.print("amount={d}&currency={s}", .{ params.amount, params.currency });

        if (params.automatic_payment_methods) {
            try writer.writeAll("&automatic_payment_methods[enabled]=true");
        }
        if (params.customer) |c| {
            try writer.print("&customer={s}", .{c});
        }
        if (params.description) |d| {
            try writer.print("&description={s}", .{d});
        }

        const payload = writer.buffered();
        const body = try self.request(.POST, "/payment_intents", payload);

        return try parseResp(PaymentIntent, body, self.arena);
    }

    pub fn getPaymentIntent(self: *Self, id: []const u8) !*PaymentIntent {
        const endpoint = try std.fmt.allocPrint(self.arena, "/payment_intents/{s}", .{id});
        defer self.arena.free(endpoint);

        const body = try self.request(.GET, endpoint, null);
        return try parseResp(PaymentIntent, body, self.arena);
    }

    pub fn confirmPaymentIntent(self: *Self, id: []const u8, payment_method: ?[]const u8) !*PaymentIntent {
        const endpoint = try std.fmt.allocPrint(self.arena, "/payment_intents/{s}/confirm", .{id});
        defer self.arena.free(endpoint);

        var payload_buf: [256]u8 = undefined;
        var payload: ?[]const u8 = null;

        if (payment_method) |pm| {
            var writer: std.Io.Writer = .fixed(&payload_buf);
            try writer.print("payment_method={s}", .{pm});
            payload = writer.buffered();
        }

        const body = try self.request(.POST, endpoint, payload);
        return try parseResp(PaymentIntent, body, self.arena);
    }

    // ============ Customers ============

    pub const CreateCustomerParams = struct {
        email: ?[]const u8 = null,
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
    };

    pub fn createCustomer(self: *Self, params: CreateCustomerParams) !*Customer {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        var first = true;
        if (params.email) |e| {
            try writer.print("email={s}", .{e});
            first = false;
        }
        if (params.name) |n| {
            if (!first) try writer.writeByte('&');
            try writer.print("name={s}", .{n});
            first = false;
        }
        if (params.description) |d| {
            if (!first) try writer.writeByte('&');
            try writer.print("description={s}", .{d});
        }

        const payload = writer.buffered();
        const body = try self.request(.POST, "/customers", if (payload.len > 0) payload else null);

        return try parseResp(Customer, body, self.arena);
    }

    pub fn getCustomer(self: *Self, id: []const u8) !*Customer {
        const endpoint = try std.fmt.allocPrint(self.arena, "/customers/{s}", .{id});
        defer self.arena.free(endpoint);

        const body = try self.request(.GET, endpoint, null);
        return try parseResp(Customer, body, self.arena);
    }

    // ============ Charges (legacy but useful for testing) ============

    pub fn getCharge(self: *Self, id: []const u8) !*Charge {
        const endpoint = try std.fmt.allocPrint(self.arena, "/charges/{s}", .{id});
        defer self.arena.free(endpoint);

        const body = try self.request(.GET, endpoint, null);
        return try parseResp(Charge, body, self.arena);
    }

    // ============ Balance (good for testing API connection) ============

    pub const Balance = struct {
        object: []const u8,
        available: []BalanceAmount,
        pending: []BalanceAmount,
    };

    pub const BalanceAmount = struct {
        amount: i64,
        currency: []const u8,
    };

    pub fn getBalance(self: *Self) !*Balance {
        const body = try self.request(.GET, "/balance", null);
        return try parseResp(Balance, body, self.arena);
    }

    pub const CheckoutSession = struct {
        id: []const u8,
        object: []const u8,
        url: ?[]const u8 = null,
        status: ?[]const u8 = null,
        payment_status: ?[]const u8 = null,
        customer: ?[]const u8 = null,
        subscription: ?[]const u8 = null,
    };

    pub const CreateCheckoutParams = struct {
        amount: ?i64 = null, // For one-time payments (in cents)
        currency: []const u8 = "usd",
        product_name: []const u8 = "Order",
        success_url: []const u8,
        cancel_url: []const u8,
        mode: []const u8 = "payment", // "payment" or "subscription"
        price_id: ?[]const u8 = null, // For subscriptions (pre-created in Stripe dashboard)
        customer_email: ?[]const u8 = null,
    };

    pub fn createCheckoutSession(self: *Self, params: CreateCheckoutParams) !*CheckoutSession {
        var buf: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        try writer.print("mode={s}&success_url={s}&cancel_url={s}", .{
            params.mode,
            params.success_url,
            params.cancel_url,
        });

        // For subscriptions with existing price
        if (params.price_id) |price_id| {
            try writer.print("&line_items[0][price]={s}&line_items[0][quantity]=1", .{price_id});
        } else if (params.amount) |amount| {
            // For one-time payments with dynamic amount
            try writer.print(
                "&line_items[0][price_data][currency]={s}&line_items[0][price_data][product_data][name]={s}&line_items[0][price_data][unit_amount]={d}&line_items[0][quantity]=1",
                .{ params.currency, params.product_name, amount },
            );
        }

        if (params.customer_email) |email| {
            try writer.print("&customer_email={s}", .{email});
        }

        const body = try self.request(.POST, "/checkout/sessions", writer.buffered());
        return try parseResp(CheckoutSession, body, self.arena);
    }

    // Add to Stripe.zig

    pub const WebhookEvent = struct {
        id: []const u8,
        type: []const u8,
        data: struct {
            object: std.json.Value,
        },
    };

    pub const CheckoutSessionEvent = struct {
        id: []const u8,
        customer: ?[]const u8 = null,
        customer_email: ?[]const u8 = null,
        payment_status: []const u8,
        status: []const u8,
        subscription: ?[]const u8 = null,
        metadata: ?std.json.Value = null,
    };
};

// Generic response parser (matches your OAuth pattern)
pub fn parseResp(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !*T {
    const result: *T = try allocator.create(T);

    const parsed = json.parseFromSlice(
        T,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return error.MalformedJson;
    defer parsed.deinit();

    result.* = parsed.value;
    return result;
}

// ============ Tests / Usage Example ============

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const secret_key = std.posix.getenv("STRIPE_SECRET_KEY") orelse {
        std.log.err("STRIPE_SECRET_KEY not set", .{});
        return error.MissingApiKey;
    };

    var stripe: Provider = undefined;
    Provider.init(&stripe, .{ .secret_key = secret_key }, allocator);
    defer stripe.deinit();

    // Test 1: Check balance (verifies API connection)
    std.log.info("Testing Stripe connection...", .{});
    const balance = try stripe.getBalance();
    std.log.info("Balance retrieved! Available: {d} {s}", .{
        balance.available[0].amount,
        balance.available[0].currency,
    });

    // Test 2: Create a customer
    std.log.info("Creating customer...", .{});
    const customer = try stripe.createCustomer(.{
        .email = "test@example.com",
        .name = "Test User",
    });
    std.log.info("Customer created: {s}", .{customer.id});

    // Test 3: Create a payment intent
    std.log.info("Creating payment intent...", .{});
    const pi = try stripe.createPaymentIntent(.{
        .amount = 2000, // $20.00
        .currency = "usd",
        .customer = customer.id,
        .description = "Test payment",
    });
    std.log.info("PaymentIntent created: {s}", .{pi.id});
    std.log.info("Client secret: {s}", .{pi.client_secret orelse "none"});
    std.log.info("Status: {s}", .{pi.status});

    // Test 4: Retrieve the payment intent
    std.log.info("Retrieving payment intent...", .{});
    const retrieved = try stripe.getPaymentIntent(pi.id);
    std.log.info("Retrieved PI status: {s}", .{retrieved.status});
}
