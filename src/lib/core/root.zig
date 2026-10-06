const std = @import("std");
const loom = @import("loom");
const Time = loom.Time;

pub const EncodingKey = @import("JWT.zig").EncodingKey;

/// A collection of commonly used signature algorithms which
/// JWT adopted from JOSE specifications.
///
/// For a fuller list, [this list](https://www.iana.org/assignments/jose/jose.xhtml#web-signature-encryption-algorithms).
pub const Algorithm = enum {
    /// HMAC using SHA-256
    HS256,
    /// HMAC using SHA-384
    HS384,
    /// HMAC using SHA-512
    HS512,
    /// ECDSA using SHA-256
    ES256,
    /// ECDSA using SHA-384
    ES384,
    /// RSASSA-PKCS1-v1_5 using SHA-256
    RS256,
    /// RSASSA-PKCS1-v1_5 using SHA-384
    RS384,
    /// RSASSA-PKCS1-v1_5 using SHA-512
    RS512,
    /// RSASSA-PSS using SHA-256
    PS256,
    /// RSASSA-PSS using SHA-384
    PS384,
    /// RSASSA-PSS using SHA-512
    PS512,
    /// Edwards-curve Digital Signature Algorithm (EdDSA)
    EdDSA,

    pub fn jsonStringify(
        self: @This(),
        out: anytype,
    ) !void {
        try out.write(@tagName(self));
    }
};

pub const Header = struct {
    alg: Algorithm,
    typ: ?[]const u8 = null,
    cty: ?[]const u8 = null,
    jku: ?[]const u8 = null,
    jwk: ?[]const u8 = null,
    kid: ?[]const u8 = null,
    x5t: ?[]const u8 = null,
    @"x5t#S256": ?[]const u8 = null,

    // todo add others
    //
    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        var out = std.json.writeStream(writer, .{ .emit_null_optional_fields = false });
        defer out.deinit();
        try out.write(self);
    }
};

pub fn JWT(comptime ClaimSet: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        header: Header,
        claims: ClaimSet,

        pub fn deinit(self: *@This()) void {
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
        }
    };
}

/// Validation rules for registered claims
/// By default validation requires a `exp` claim to ensure the token has
/// not expired.
pub const Validation = struct {
    /// registered claims used for validation
    ///
    /// see also [rfc7519#section-4.1](https://datatracker.ietf.org/doc/html/rfc7519#section-4.1)
    pub const RegisteredClaims = struct {
        exp: ?u64 = null,
        nbf: ?u64 = null,
        sub: ?[]const u8 = null,
        iss: ?[]const u8 = null,
        aud: ?[]const u8 = null,
    };

    const RegisteredClaim = enum { exp, sub, iss, aud, nbf };

    /// list of claims expected to have been provided
    required_claims: []const RegisteredClaim = &.{.exp},
    /// amount of clockskew, in seconds, permitted
    leeway: u64 = 60,
    /// buffered amount of time to adjust timestamp to account for probably network transit time
    /// after which this token would be expired
    reject_tokens_expiring_in_less_than: u64 = 0,
    /// validate token is not past expiration time
    validate_exp: bool = true,
    /// validate token is not used not before expected time
    validate_nbf: bool = false,
    /// validate audience is as expected
    validate_aud: bool = true,
    /// validate expected audience
    aud: ?[]const []const u8 = null,
    /// validate expected issuer
    iss: ?[]const []const u8 = null,
    /// validate expected subject
    sub: ?[]const u8 = null,
    /// validate supported algoritm
    algorithms: []const Algorithm = &.{.HS256},
    // returns "now" in seconds, relative to UTC 1970-01-01
    now: *const fn () u64 = struct {
        fn func() u64 {
            return @intCast(Time.timestamp());
        }
    }.func,
    // skip verification of the secret - use this when you only want to view the claims from a token
    // that you dont have the secret key for (ie - reading claims out of a 3rd party token)
    skip_secret: bool = false,

    /// validate that token meets baseline of registered claims rules
    pub fn validate(self: @This(), claims: RegisteredClaims) anyerror!void {
        // were all required registered claims provided?
        for (self.required_claims) |c| {
            switch (c) {
                .exp => if (claims.exp == null) return error.MissingExp,
                .sub => if (claims.sub == null) return error.MissingSub,
                .iss => if (claims.iss == null) return error.MissingIss,
                .aud => if (claims.aud == null) return error.MissingAud,
                .nbf => if (claims.nbf == null) return error.MissingNbf,
            }
        }

        // is this token being used before or after its intended window of usage?
        if (self.validate_exp or self.validate_nbf) {
            const nowSec = self.now();
            if (self.validate_exp) {
                if (claims.exp) |exp| {
                    if (exp - self.reject_tokens_expiring_in_less_than < nowSec - self.leeway) {
                        return error.TokenExpired;
                    }
                }
            }

            if (self.validate_nbf) {
                if (claims.nbf) |nbf| {
                    if (nbf > nowSec - self.leeway) {
                        return error.TokenEarly;
                    }
                }
            }
        }

        // is this token intended for the expected subject?
        if (claims.sub) |actual| {
            if (self.sub) |expected| {
                if (!std.mem.eql(u8, actual, expected)) {
                    return error.InvalidSubject;
                }
            }
        }

        // was this token issued by the expected party?
        if (claims.iss) |actual| {
            if (self.iss) |expected| {
                var found = false;
                for (expected) |exp| {
                    if (std.mem.eql(u8, actual, exp)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    return error.InvalidIssuer;
                }
            }
        }

        // was this token intended for the expected audience?
        if (self.validate_aud) {
            if (claims.aud) |actual| {
                if (self.aud) |expected| {
                    var found = false;
                    for (expected) |exp| {
                        if (std.mem.eql(u8, exp, actual)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        return error.InvalidAudience;
                    }
                }
            }
        }
    }
};
