// This is the frontend module dep for the client side of the app.
const std = @import("std");
const Vapor = @import("../Vapor.zig");
const Kit = Vapor.Kit;
const JWT = @import("JWT.zig");

pub const Provider = enum {
    google,
    github,
    apple,
    azure,
};

pub const ClientConfig = struct {
    client_id: []const u8,
    redirect_uri: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

/// Backward-compatible alias.
pub const Config = ClientConfig;

pub const Clients = struct {
    google: ?ClientConfig = null,
    github: ?ClientConfig = null,
    azure: ?ClientConfig = null,
    apple: ?ClientConfig = null,
};

pub const InitConfig = struct {
    clients: Clients,
    hook_path: []const u8 = "/auth/callback",
    backend_url: []const u8 = "http://localhost:8080",
    session_storage_key: []const u8 = "keystone_session_token",
    oauth_cookie_name: []const u8 = "oauth_provider",
};

const AuthorizeConfig = struct {
    base_url: []const u8,
    response_type: ?[]const u8 = null,
    default_scope: ?[]const u8 = null,
    access_type: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    response_mode: ?[]const u8 = null,
    include_state: bool = false,
    include_nonce: bool = false,
};

const TokenExchangeResponse = struct {
    token: []const u8,
};

const provider_tags = std.meta.tags(Provider);
const provider_count = provider_tags.len;

const KeyStone = @This();
var on_auth_change: ?*const fn (Kit.Response) void = null;
var configured_provider_cache: [provider_count]Provider = undefined;
var configured_provider_count: usize = 0;

pub var keystone: KeyStone = .{
    .clients = .{},
    .hook_path = "/auth/callback",
    .backend_url = "http://localhost:8080",
    .session_storage_key = "keystone_session_token",
    .oauth_cookie_name = "oauth_provider",
    .hook_registered = false,
};

clients: Clients,
hook_path: []const u8,
backend_url: []const u8,
session_storage_key: []const u8,
oauth_cookie_name: []const u8,
hook_registered: bool,

pub fn init(ks_config: InitConfig) void {
    keystone.clients = ks_config.clients;
    keystone.hook_path = ks_config.hook_path;
    keystone.backend_url = ks_config.backend_url;
    keystone.session_storage_key = ks_config.session_storage_key;
    keystone.oauth_cookie_name = ks_config.oauth_cookie_name;
    keystone.initHooks();
    rebuildConfiguredProviderCache();
}

pub fn onAuthChange(cb: *const fn (Kit.Response) void) void {
    on_auth_change = cb;
}

/// Returns configured providers to help frontend render auth buttons dynamically.
pub fn configuredProviders() []const Provider {
    return configured_provider_cache[0..configured_provider_count];
}

pub fn hasProvider(provider: Provider) bool {
    return keystone.getClient(provider) != null;
}

/// Returns the provider authorization URL so UI can open it manually if needed.
pub fn oauthUrl(provider: Provider) ?[]const u8 {
    const client = keystone.getClient(provider) orelse return null;
    return buildAuthorizeUrl(provider, client) catch null;
}

pub fn signIn(provider: Provider) void {
    signInWithOauth(provider);
}

pub fn signInWithOauth(provider: Provider) void {
    const client = keystone.getClient(provider) orelse return;
    keystone.setProviderCookie(provider);
    const url = buildAuthorizeUrl(provider, client) catch return;
    defer Vapor.allocator_global.free(url);
    Kit.setWindowLocation(url);
}

pub fn handleAuthExchanges() void {
    _ = maybeHandleAuthExchange();
}

/// Helper for route hooks or pages to explicitly consume oauth callback.
pub fn maybeHandleAuthExchange() bool {
    const code = getAuthCode() orelse return false;
    const provider = getProviderFromCookie() orelse return false;
    exchangeCode(provider, code);
    return true;
}

pub fn isAuthenticated() bool {
    const token = getSession() orelse return false;
    return !JWT.isExpired(token);
}

pub fn getSession() ?[]const u8 {
    return Vapor.getStore([]const u8, keystone.session_storage_key);
}

pub fn clearSession() void {
    Vapor.store(keystone.session_storage_key, "");
}

pub fn signOut() void {
    clearSession();
    const clear_cookie = Vapor.frame.fmt("{s}=; Path=/; Max-Age=0; SameSite=Lax", .{keystone.oauth_cookie_name});
    Vapor.setCookie(clear_cookie);
}

/// Backward-compatible alias.
pub fn signout() void {
    signOut();
}

/// Optional generic validation helper for backends exposing:
/// `{backend_url}/auth/validate/{provider}/session`.
pub fn validateSession(provider: Provider, cb: fn (Kit.Response) void) void {
    const token = getSession() orelse return;
    const url = Vapor.frame.fmt("{s}/auth/validate/{s}/session", .{ keystone.backend_url, @tagName(provider) });
    const auth_header = Vapor.frame.fmt("Bearer {s}", .{token});
    Kit.Fetch.fetch(url, .{
        .method = .POST,
        .credentials = "include",
        .headers = .{ .authorization = auth_header },
    }).handle(cb);
}

fn initHooks(self: *KeyStone) void {
    if (self.hook_registered) return;
    _ = Vapor.registerHook(self.hook_path, exchangeHook, .before);
    self.hook_registered = true;
}

fn exchangeHook(_: Vapor.HookContext) void {
    _ = maybeHandleAuthExchange();
}

fn rebuildConfiguredProviderCache() void {
    configured_provider_count = 0;
    inline for (provider_tags) |provider| {
        if (keystone.getClient(provider) != null) {
            configured_provider_cache[configured_provider_count] = provider;
            configured_provider_count += 1;
        }
    }
}

fn getAuthCode() ?[]const u8 {
    const params = Kit.Window.params() orelse return null;
    return params.get("code");
}

fn getProviderFromCookie() ?Provider {
    const provider_str = Vapor.getCookie(keystone.oauth_cookie_name) orelse return null;
    return std.meta.stringToEnum(Provider, provider_str);
}

fn providerDefaults(provider: Provider) AuthorizeConfig {
    return switch (provider) {
        .google => .{
            .base_url = "https://accounts.google.com/o/oauth2/v2/auth",
            .response_type = "code",
            .default_scope = "openid email profile",
            .access_type = "offline",
            .prompt = "consent",
        },
        .github => .{
            .base_url = "https://github.com/login/oauth/authorize",
            .default_scope = "read:user user:email",
            .include_state = true,
        },
        .apple => .{
            .base_url = "https://appleid.apple.com/auth/authorize",
            .response_type = "code id_token",
            .default_scope = "name email",
            .response_mode = "form_post",
            .include_state = true,
            .include_nonce = true,
        },
        .azure => .{
            .base_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            .response_type = "code",
            .default_scope = "openid email profile",
            .include_state = true,
        },
    };
}

fn callbackUrl() []const u8 {
    if (std.mem.startsWith(u8, keystone.hook_path, "http://") or std.mem.startsWith(u8, keystone.hook_path, "https://")) {
        return keystone.hook_path;
    }
    const origin = Kit.Window.origin() orelse return keystone.hook_path;
    return Vapor.frame.fmt("{s}{s}", .{ origin, keystone.hook_path });
}

fn resolveRedirectUri(client: ClientConfig) []const u8 {
    return client.redirect_uri orelse callbackUrl();
}

fn buildAuthorizeUrl(provider: Provider, client: ClientConfig) ![]const u8 {
    const cfg = providerDefaults(provider);
    var query: Kit.QueryBuilder = undefined;
    try query.init(Vapor.allocator_global);
    defer query.deinit();

    try query.add("client_id", client.client_id);
    try query.add("redirect_uri", resolveRedirectUri(client));

    if (cfg.response_type) |response_type| {
        try query.add("response_type", response_type);
    }

    if (client.scope) |scope| {
        try query.add("scope", scope);
    } else if (cfg.default_scope) |scope| {
        try query.add("scope", scope);
    }

    if (cfg.access_type) |access_type| {
        try query.add("access_type", access_type);
    }

    if (cfg.prompt) |prompt| {
        try query.add("prompt", prompt);
    }

    if (cfg.response_mode) |response_mode| {
        try query.add("response_mode", response_mode);
    }

    if (cfg.include_state) {
        try query.add("state", defaultState(provider));
    }

    if (cfg.include_nonce) {
        try query.add("nonce", defaultNonce(provider));
    }

    try query.queryStrEncode();
    return query.generateUrl(cfg.base_url, query.str);
}

fn defaultState(provider: Provider) []const u8 {
    return Vapor.frame.fmt("keystone-{s}-{d}", .{ @tagName(provider), std.time.timestamp() });
}

fn defaultNonce(provider: Provider) []const u8 {
    return Vapor.frame.fmt("nonce-{s}-{d}", .{ @tagName(provider), std.time.timestamp() });
}

fn exchangeCode(provider: Provider, code: []const u8) void {
    const body = Vapor.frame.fmt("auth-code={s}", .{code});
    const url = Vapor.frame.fmt("{s}/exchange/{s}/token", .{ keystone.backend_url, @tagName(provider) });
    Kit.Fetch.fetch(url, .{
        .method = .POST,
        .body = body,
        .credentials = "include",
        .headers = .{
            .content_type = "application/x-www-form-urlencoded",
        },
        .body_type = .string,
    }).handle(handleToken);
}

fn handleToken(resp: Kit.Response) void {
    switch (resp) {
        .Ok => |ok| {
            const exchange_resp: TokenExchangeResponse = Kit.Json.parse(TokenExchangeResponse, ok.body, .frame) catch |err| {
                Vapor.printlnSrcErr("Could not parse oauth response: {any} body={s}\n", .{ err, ok.body }, @src());
                if (on_auth_change) |cb| cb(resp);
                return;
            };
            Vapor.store(keystone.session_storage_key, exchange_resp.token);
        },
        else => {},
    }

    if (on_auth_change) |cb| {
        cb(resp);
    }
}

fn getClient(self: *const KeyStone, provider: Provider) ?ClientConfig {
    return switch (provider) {
        .google => self.clients.google,
        .github => self.clients.github,
        .apple => self.clients.apple,
        .azure => self.clients.azure,
    };
}

fn setProviderCookie(self: *const KeyStone, provider: Provider) void {
    const cookie = Vapor.frame.fmt("{s}={s}; Path=/; SameSite=Lax", .{ self.oauth_cookie_name, @tagName(provider) });
    Vapor.setCookie(cookie);
}
