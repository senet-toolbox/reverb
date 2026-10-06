const std = @import("std");
pub const Google = @import("Google.zig");
pub const Github = @import("Github.zig");
const Context = @import("../context.zig");
const Cookie = @import("../core/Cookie.zig");
const QueryBuilder = @import("QueryBuilder.zig");
const JWT = @import("../core/JWT.zig");
const JWTRoot = @import("../core/root.zig");
pub const JWT_SECRET = "37fe35bd1e029d247251b560c2d2cf2866834577d0166c221e2852bab8e5f3710dc055fe2b413b52a6e3d8f017711f7bf652e462be5dbbd041e7237748b3f267";
const loompkg = @import("loom");
const Time = loompkg.Time;

pub const Secrets = struct {
    github: ?[]const u8 = null,
    google: ?[]const u8 = null,
    apple: ?[]const u8 = null,
    azure: ?[]const u8 = null,
};

pub const ClientIds = struct {
    github: ?[]const u8 = null,
    google: ?[]const u8 = null,
    apple: ?[]const u8 = null,
    azure: ?[]const u8 = null,
};

pub const Config = struct {
    pub const Providers = struct {
        google: ?Google.Options = null,
        github: ?Github.Options = null,
    };

    // New preferred API
    providers: Providers = .{},
    // Legacy API (still supported)
    client_ids: ClientIds = .{},
    secrets: Secrets = .{},
    google_config: ?Google.Options = null,
    github_config: ?Github.Options = null,
    session_secret: ?[]const u8 = null,
    session_ttl_seconds: i64 = 60 * 60 * 24 * 7,
    session_cookie_name: []const u8 = "keystone_session_token",
    refresh_cookie_name: []const u8 = "keystone_refresh_token",
    oauth_state_cookie_name: []const u8 = "keystone_oauth_state",
    oauth_nonce_cookie_name: []const u8 = "keystone_oauth_nonce",
    secure_cookies: bool = false,
    http_only_cookies: bool = true,
};

pub const ClientConfig = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: ?[]const u8 = null,
    grant_type: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

pub const Clients = struct {
    google: ?ClientConfig = null,
    github: ?ClientConfig = null,
};

pub const InitConfig = struct {
    clients: Clients,
    hook_path: []const u8 = "/auth/callback",
    backend_url: []const u8 = "http://localhost:8080",
    origin: []const u8 = "http://localhost:5173",
    session_secret: ?[]const u8 = null,
    session_ttl_seconds: i64 = 60 * 60 * 24 * 7,
    session_cookie_name: []const u8 = "keystone_session_token",
    refresh_cookie_name: []const u8 = "keystone_refresh_token",
    oauth_state_cookie_name: []const u8 = "keystone_oauth_state",
    oauth_nonce_cookie_name: []const u8 = "keystone_oauth_nonce",
    secure_cookies: bool = false,
    http_only_cookies: bool = true,
};

const KeyStone = @This();
pub var keystone_config: Config = undefined;
pub var api_config: InitConfig = .{ .clients = .{} };
var google_options: Google.Options = undefined;
var google_provider: Google.Provider = undefined;
var github_options: Github.Options = undefined;
var github_provider: Github.Provider = undefined;
var google_initialized = false;
var github_initialized = false;

pub fn init(config: Config, allocator: std.mem.Allocator) !void {
    keystone_config = config;
    google_initialized = false;
    github_initialized = false;

    if (keystone_config.providers.google) |provider_google| {
        google_options = provider_google;
        try google_provider.init(google_options, allocator);
        google_initialized = true;
    } else if (keystone_config.google_config) |legacy_google_options| {
        google_options = legacy_google_options;
        try google_provider.init(google_options, allocator);
        google_initialized = true;
    } else if (keystone_config.client_ids.google != null and keystone_config.secrets.google != null) {
        const client_id = keystone_config.client_ids.google orelse return error.ClientIdNull;
        const secret = keystone_config.secrets.google orelse return error.ClientSecretNull;
        google_options = Google.Options{
            .client_id = client_id,
            .client_secret = secret,
            .redirect_uri = "http://localhost:5173/auth/callback",
            .grant_type = "authorization_code",
        };
        try google_provider.init(google_options, allocator);
        google_initialized = true;
    }

    if (keystone_config.providers.github) |provider_github| {
        github_options = provider_github;
        try github_provider.init(github_options, allocator);
        github_initialized = true;
    } else if (keystone_config.github_config) |legacy_github_options| {
        github_options = legacy_github_options;
        try github_provider.init(github_options, allocator);
        github_initialized = true;
    } else if (keystone_config.client_ids.github != null and keystone_config.secrets.github != null) {
        const client_id = keystone_config.client_ids.github orelse return error.ClientIdNull;
        const secret = keystone_config.secrets.github orelse return error.ClientSecretNull;
        github_options = Github.Options{
            .client_id = client_id,
            .client_secret = secret,
            .redirect_uri = "http://localhost:5173/nightwatch/auth",
        };
        try github_provider.init(github_options, allocator);
        github_initialized = true;
    }
}

pub fn install(server: anytype, cfg: InitConfig, allocator: std.mem.Allocator) !void {
    api_config = cfg;
    try init(try buildConfig(cfg, allocator), allocator);
    try registerRoutes(server);
}

pub fn registerRoutes(server: anytype) !void {
    if (google_initialized) {
        try server.post("/exchange/google/token", routeGoogleExchange, &.{});
        try server.post("/auth/validate/google/session", routeValidateSession, &.{});
    }

    if (github_initialized) {
        try server.post("/exchange/github/token", routeGithubExchange, &.{});
    }

    if (google_initialized or github_initialized) {
        try server.post("/auth/session/bootstrap", routeBootstrapSession, &.{});
        try server.post("/auth/session/refresh", routeRefreshSession, &.{});
        try server.post("/auth/session/signout", routeSignoutSession, &.{});
    }
}

pub const OauthProvider = enum {
    google,
    apple,
    github,
    azure,
};

pub fn refreshToken(provider: OauthProvider, refresh_token: []const u8) ![]const u8 {
    switch (provider) {
        .google => {
            if (!google_initialized) return error.ProviderNotConfigured;
            return try google_provider.refreshToken(refresh_token);
        },
        .github => {
            if (!github_initialized) return error.ProviderNotConfigured;
            return try github_provider.refreshToken(refresh_token);
        },
        else => {},
    }
    return error.InValidProvider;
}

pub fn getUserInfo(provider: OauthProvider, access_token: []const u8) ![]const u8 {
    switch (provider) {
        .google => {
            if (!google_initialized) return error.ProviderNotConfigured;
            return try google_provider.getUserInfo(access_token);
        },
        .github => {
            if (!github_initialized) return error.ProviderNotConfigured;
            return try github_provider.getUserInfo(access_token);
        },
        else => {},
    }
    return error.InValidProvider;
}

pub const AuthState = enum {
    loading,
    signed_out,
    signed_in,
};

pub const AuthUser = struct {
    id: []const u8,
    email: []const u8,
    name: []const u8,
    picture: ?[]const u8 = null,
};

pub const SessionInfo = struct {
    token: []const u8,
    user: AuthUser,
    provider: OauthProvider,
    issued_at: i64,
    expires_at: i64,
};

pub const AuthSessionResponse = struct {
    success: bool,
    state: AuthState,
    session: ?SessionInfo = null,
    err: ?[]const u8 = null,
};

pub const ExchangeSessionResponse = struct {
    success: bool,
    state: AuthState,
    token: []const u8,
    issued_at: i64,
    expires_at: i64,
    user: struct {
        id: []const u8,
        email: []const u8,
        name: []const u8,
        picture: ?[]const u8 = null,
    },
};

// Login with google
// send auth-code
// receive code and exchange for access and refresh token
// store refresh token in db hashed
// set cookie with refresh token
// compare with cookie token on request
pub fn exchangeGoogleToken(ctx: *Context) !*Google.TokenResp {
    ctx.parseForm() catch |err| {
        std.log.err("{any}\n", .{err});
        return err;
    };
    validateCallbackPayload(ctx) catch |err| {
        std.log.err("{any}\n", .{err});
        return err;
    };
    const auth_code = ctx.form_params.get("auth-code") orelse return error.AuthCodeNull;
    if (!google_initialized) return error.ProviderNotConfigured;
    const body: []const u8 = try google_provider.tokenExchange(auth_code);
    const resp: *Google.TokenResp = try Google.parseResp(Google.TokenResp, body, ctx.arena);
    return resp;
}

// Login with github
// send auth-code
// receive code and exchange for access and refresh token
// store refresh token in db hashed
// set cookie with refresh token
// compare with cookie token on request
pub fn exchangeGithubToken(ctx: *Context) ![]const u8 {
    try ctx.parseForm();
    try validateCallbackPayload(ctx);
    const auth_code = ctx.form_params.get("auth-code").?;

    if (!github_initialized) return error.ProviderNotConfigured;
    const body: []const u8 = github_provider.tokenExchange(auth_code) catch return error.TokenExchangeGithub;

    const map = try QueryBuilder.parseParams(body, &ctx.arena) orelse return error.ParsingParams;
    const access_token = map.get("access_token") orelse return error.GetAccessToken;
    return access_token;

    // const resp: *GithubTokenResp = try parseResp(GithubTokenResp, body, ctx.arena);
}

// Google's id_token claims
pub const GoogleClaims = struct {
    iss: []const u8, // "https://accounts.google.com"
    azp: []const u8,
    aud: []const u8, // your client_id
    sub: []const u8, // unique google user id
    email: []const u8,
    email_verified: bool,
    name: ?[]const u8 = null,
    picture: ?[]const u8 = null,
    given_name: ?[]const u8 = null,
    family_name: ?[]const u8 = null,
    iat: i64,
    exp: i64,
};

pub fn handleGoogleCallback(allocator: std.mem.Allocator, google_id_token: []const u8) !JWT.JWT(GoogleClaims) {
    // Decode Google's id_token (skip signature verification since it came direct from Google)
    const google_jwt = try JWT.decode(
        allocator,
        GoogleClaims,
        google_id_token,
        .{ .secret = "" }, // not used when skipping
        .{ .skip_secret = true }, // skip RS256 verification
    );
    return google_jwt;
}

const GoogleAuthResponse = struct {
    tokens: Google.TokenResp,
    session: []const u8,
    user: GoogleClaims,
    jwt: JWT.JWT(GoogleClaims),
};

pub fn handleGoogleAuthFlow(ctx: *Context) !GoogleAuthResponse {
    const resp = KeyStone.exchangeGoogleToken(ctx) catch return error.ExchangeGoogleToken;

    if (resp.id_token) |token| {
        const google_jwt = try handleGoogleCallback(ctx.arena, token);
        const google_user = google_jwt.claims;
        const issued_at = Time.timestamp();
        const expires_at = issued_at + keystone_config.session_ttl_seconds;
        const session_claims = SessionClaims{
            .sub = google_user.sub,
            .email = google_user.email,
            .name = google_user.name orelse "User",
            .iat = issued_at,
            .exp = expires_at,
        };
        const session_token = try encodeSessionToken(ctx.arena, session_claims);
        try persistSessionCookies(ctx, session_token, resp.refresh_token);
        try clearCallbackCookies(ctx);

        return GoogleAuthResponse{
            .tokens = resp.*,
            .session = session_token,
            .user = google_user,
            .jwt = google_jwt,
        };
    } else {
        return error.GoogleAuthFlow;
        // try ctx.ERROR(404, "Could not aquire google id token");
    }
}

pub const SessionClaims = struct {
    sub: []const u8,
    email: []const u8,
    name: []const u8,
    exp: i64,
    iat: i64,
};

pub fn exchangeGoogleCodeToSession(ctx: *Context) !AuthSessionResponse {
    const flow = try handleGoogleAuthFlow(ctx);
    const session_claims = try decodeSessionToken(ctx.arena, flow.session) orelse return error.InvalidSession;
    return .{
        .success = true,
        .state = .signed_in,
        .session = .{
            .token = flow.session,
            .provider = .google,
            .issued_at = session_claims.iat,
            .expires_at = session_claims.exp,
            .user = .{
                .id = flow.user.sub,
                .email = flow.user.email,
                .name = flow.user.name orelse "User",
                .picture = flow.user.picture,
            },
        },
    };
}

pub fn bootstrapSession(ctx: *Context) !AuthSessionResponse {
    const claims = try validateSession(ctx) orelse {
        return .{
            .success = true,
            .state = .signed_out,
        };
    };

    return .{
        .success = true,
        .state = .signed_in,
        .session = .{
            .token = sessionTokenFromRequest(ctx) orelse "",
            .provider = .google,
            .issued_at = claims.iat,
            .expires_at = claims.exp,
            .user = .{
                .id = claims.sub,
                .email = claims.email,
                .name = claims.name,
            },
        },
    };
}

pub fn refreshSession(ctx: *Context) !AuthSessionResponse {
    const refresh_token = try getRefreshToken(ctx) orelse return .{
        .success = false,
        .state = .signed_out,
        .err = "refresh_token_missing",
    };

    const body = try refreshToken(.google, refresh_token);
    const refreshed = try Google.parseResp(Google.RefreshTokenResp, body, ctx.arena);
    const id_token = refreshed.id_token orelse return .{
        .success = false,
        .state = .signed_out,
        .err = "refresh_id_token_missing",
    };

    const google_jwt = try handleGoogleCallback(ctx.arena, id_token);
    const claims = google_jwt.claims;

    const issued_at = Time.timestamp();
    const expires_at = issued_at + keystone_config.session_ttl_seconds;
    const session_claims = SessionClaims{
        .sub = claims.sub,
        .email = claims.email,
        .name = claims.name orelse "User",
        .iat = issued_at,
        .exp = expires_at,
    };
    const session_token = try encodeSessionToken(ctx.arena, session_claims);
    try persistSessionCookies(ctx, session_token, null);

    return .{
        .success = true,
        .state = .signed_in,
        .session = .{
            .token = session_token,
            .provider = .google,
            .issued_at = issued_at,
            .expires_at = expires_at,
            .user = .{
                .id = claims.sub,
                .email = claims.email,
                .name = claims.name orelse "User",
                .picture = claims.picture,
            },
        },
    };
}

pub fn signOutSession(ctx: *Context, _: bool) !AuthSessionResponse {
    try clearSessionCookies(ctx);
    return .{
        .success = true,
        .state = .signed_out,
    };
}

fn validateSession(ctx: *Context) !?SessionClaims {
    const token = sessionTokenFromRequest(ctx) orelse return null;
    return decodeSessionToken(ctx.arena, token);
}

fn decodeSessionToken(allocator: std.mem.Allocator, token: []const u8) !?SessionClaims {
    if (token.len == 0) return null;
    var jwt = JWT.decode(
        allocator,
        SessionClaims,
        token,
        .{ .secret = sessionSecret() },
        .{},
    ) catch return null;
    defer jwt.deinit();

    const now = Time.timestamp();
    if (jwt.claims.exp < now) return null;

    return SessionClaims{
        .sub = try allocator.dupe(u8, jwt.claims.sub),
        .email = try allocator.dupe(u8, jwt.claims.email),
        .name = try allocator.dupe(u8, jwt.claims.name),
        .exp = jwt.claims.exp,
        .iat = jwt.claims.iat,
    };
}

fn sessionTokenFromRequest(ctx: *Context) ?[]const u8 {
    const auth_header = std.mem.trim(u8, ctx.http_header.authorization, " \t\r\n");
    if (auth_header.len > 7 and std.ascii.startsWithIgnoreCase(auth_header, "Bearer ")) {
        const token = std.mem.trim(u8, auth_header[7..], " \t\r\n");
        if (token.len > 0) return token;
    }

    const cookie_name = keystone_config.session_cookie_name;
    if (ctx.getCookie(cookie_name)) |cookie| {
        if (cookie.value.len > 0) return cookie.value;
    }
    return null;
}

fn sessionSecret() []const u8 {
    return keystone_config.session_secret orelse JWT_SECRET;
}

fn encodeSessionToken(allocator: std.mem.Allocator, claims: SessionClaims) ![]const u8 {
    return JWT.encode(
        allocator,
        JWTRoot.Header{
            .alg = .HS256,
            .typ = "JWT",
        },
        claims,
        .{ .secret = sessionSecret() },
    );
}

fn persistSessionCookies(ctx: *Context, session_token: []const u8, refresh_token: ?[]const u8) !void {
    try ctx.addCookie(Cookie.Self{
        .name = keystone_config.session_cookie_name,
        .value = session_token,
        .expires = keystone_config.session_ttl_seconds,
        .http_only = keystone_config.http_only_cookies,
        .secure = keystone_config.secure_cookies,
    });

    if (refresh_token) |token| {
        try ctx.addCookie(Cookie.Self{
            .name = keystone_config.refresh_cookie_name,
            .value = token,
            .expires = 60 * 60 * 24 * 30,
            .http_only = keystone_config.http_only_cookies,
            .secure = keystone_config.secure_cookies,
        });
    }
}

fn getRefreshToken(ctx: *Context) !?[]const u8 {
    if (ctx.http_header.content_type == .Form) {
        ctx.parseForm() catch {};
        if (ctx.form_params.get("refresh-token")) |token| {
            if (token.len > 0) return token;
        }
    }
    if (ctx.getCookie(keystone_config.refresh_cookie_name)) |cookie| {
        if (cookie.value.len > 0) return cookie.value;
    }
    return null;
}

fn validateCallbackPayload(ctx: *Context) !void {
    if (ctx.form_params.get("error") != null) return error.OauthCallbackError;

    const expected_state_cookie = ctx.getCookie(keystone_config.oauth_state_cookie_name);
    const incoming_state = ctx.form_params.get("state");
    if (expected_state_cookie) |state_cookie| {
        if (state_cookie.value.len > 0) {
            const state = incoming_state orelse return error.InvalidOauthState;
            if (!std.mem.eql(u8, state, state_cookie.value)) return error.InvalidOauthState;
        }
    }

    const expected_nonce_cookie = ctx.getCookie(keystone_config.oauth_nonce_cookie_name);
    const incoming_nonce = ctx.form_params.get("nonce");
    if (expected_nonce_cookie) |nonce_cookie| {
        if (nonce_cookie.value.len > 0) {
            const nonce = incoming_nonce orelse return error.InvalidOauthNonce;
            if (!std.mem.eql(u8, nonce, nonce_cookie.value)) return error.InvalidOauthNonce;
        }
    }
}

fn clearCallbackCookies(ctx: *Context) !void {
    try ctx.removeCookie(keystone_config.oauth_state_cookie_name);
    try ctx.removeCookie(keystone_config.oauth_nonce_cookie_name);
}

fn clearSessionCookies(ctx: *Context) !void {
    try ctx.removeCookie(keystone_config.session_cookie_name);
    try ctx.removeCookie(keystone_config.refresh_cookie_name);
    try clearCallbackCookies(ctx);
}

fn buildConfig(init_cfg: InitConfig, allocator: std.mem.Allocator) !Config {
    var cfg: Config = .{
        .session_secret = init_cfg.session_secret,
        .session_ttl_seconds = init_cfg.session_ttl_seconds,
        .session_cookie_name = init_cfg.session_cookie_name,
        .refresh_cookie_name = init_cfg.refresh_cookie_name,
        .oauth_state_cookie_name = init_cfg.oauth_state_cookie_name,
        .oauth_nonce_cookie_name = init_cfg.oauth_nonce_cookie_name,
        .secure_cookies = init_cfg.secure_cookies,
        .http_only_cookies = init_cfg.http_only_cookies,
    };

    if (init_cfg.clients.google) |google_client| {
        const redirect_uri = google_client.redirect_uri orelse try defaultRedirectUri(allocator, init_cfg);
        cfg.providers.google = .{
            .client_id = google_client.client_id,
            .client_secret = google_client.client_secret,
            .redirect_uri = redirect_uri,
            .grant_type = google_client.grant_type orelse "authorization_code",
        };
    }

    if (init_cfg.clients.github) |github_client| {
        const redirect_uri = github_client.redirect_uri orelse try defaultRedirectUri(allocator, init_cfg);
        cfg.providers.github = .{
            .client_id = github_client.client_id,
            .client_secret = github_client.client_secret,
            .redirect_uri = redirect_uri,
            .state = github_client.state orelse "keystone_csrf",
        };
    }

    return cfg;
}

fn defaultRedirectUri(allocator: std.mem.Allocator, init_cfg: InitConfig) ![]const u8 {
    if (std.mem.startsWith(u8, init_cfg.hook_path, "http://") or std.mem.startsWith(u8, init_cfg.hook_path, "https://")) {
        return allocator.dupe(u8, init_cfg.hook_path);
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ init_cfg.origin, init_cfg.hook_path });
}

fn routeGoogleExchange(ctx: *Context) !void {
    const auth_resp = exchangeGoogleCodeToSession(ctx) catch |err| {
        std.log.err("Error: {any}", .{err});
        try ctx.ERROR(500, "Internal Server Error");
        return;
    };
    const session = auth_resp.session orelse return error.InvalidSession;
    try ctx.JSON(ExchangeSessionResponse, .{
        .success = auth_resp.success,
        .state = auth_resp.state,
        .token = session.token,
        .issued_at = session.issued_at,
        .expires_at = session.expires_at,
        .user = .{
            .id = session.user.id,
            .email = session.user.email,
            .name = session.user.name,
            .picture = session.user.picture,
        },
    });
}

fn routeGithubExchange(ctx: *Context) !void {
    const token = try exchangeGithubToken(ctx);
    const Resp = struct {
        success: bool,
        token: []const u8,
    };
    try ctx.JSON(Resp, .{
        .success = true,
        .token = token,
    });
}

fn routeBootstrapSession(ctx: *Context) !void {
    const resp = try bootstrapSession(ctx);
    try ctx.JSON(AuthSessionResponse, resp);
}

fn routeRefreshSession(ctx: *Context) !void {
    const resp = try refreshSession(ctx);
    try ctx.JSON(AuthSessionResponse, resp);
}

fn routeSignoutSession(ctx: *Context) !void {
    var revoke_remote = false;
    if (ctx.http_header.content_type == .Form) {
        ctx.parseForm() catch {};
        if (ctx.form_params.get("revoke_remote")) |flag| {
            revoke_remote = std.mem.eql(u8, flag, "1") or std.ascii.eqlIgnoreCase(flag, "true");
        }
    }

    const resp = try signOutSession(ctx, revoke_remote);
    try ctx.JSON(AuthSessionResponse, resp);
}

fn routeValidateSession(ctx: *Context) !void {
    const user = try requireAuth(ctx);
    const UserResp = struct {
        email: []const u8,
        name: []const u8,
    };
    try ctx.JSON(UserResp, .{
        .email = user.email,
        .name = user.name,
    });
}

// Simple middleware-style function
pub fn requireAuth(ctx: *Context) !SessionClaims {
    return validateSession(ctx) catch {
        try ctx.ERROR(401, "Auth Header Invalid");
        return error.AuthHeaderInvalid;
    } orelse {
        try ctx.ERROR(401, "Invalid or expired session");
        return error.Unauthorized;
    };
}
