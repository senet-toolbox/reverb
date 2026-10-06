const std = @import("std");
const print = std.debug.print;

pub const JWT2 = struct {
    header: []const u8,
    payload: []const u8,
    signature: []const u8,
};

pub const JwtError = error{
    InvalidFormat,
    InvalidBase64,
    InvalidJson,
    InvalidSignature,
};

pub const JwtHeader = struct {
    alg: []const u8,
    typ: []const u8,
};

// Define the Header struct
pub const Header = struct {
    alg: []const u8, // Algorithm (e.g., "RS256")
    kid: []const u8, // Key ID
    typ: []const u8, // Type (e.g., "JWT")
};

// Define the Payload struct
pub const Payload = struct {
    iss: []const u8, // Issuer
    azp: []const u8, // Authorized party
    aud: []const u8, // Audience
    sub: []const u8, // Subject
    email: []const u8, // Email
    email_verified: bool, // Email verified status
    at_hash: []const u8, // Access token hash
    name: []const u8, // Full name
    picture: []const u8, // Profile picture URL
    given_name: []const u8, // Given name
    family_name: []const u8, // Family name
    iat: i64, // Issued at (timestamp)
    exp: i64, // Expiration time (timestamp)
};

pub fn decodev2(token: []const u8, allocator: std.mem.Allocator) !JWT2 {
    var jwt_itr = std.mem.splitScalar(u8, token, '.');

    const header = jwt_itr.next().?;
    const payload = jwt_itr.next().?;
    const signature = jwt_itr.next().?;

    // Initialize the Base64Url decoder
    var decoder = std.base64.Base64Decoder.init(
        std.base64.url_safe_alphabet_chars,
        null, // Use '=' as pad_char if padding is present, otherwise use null
    );

    // Decode the header
    var header_decoded: [256]u8 = undefined;
    decoder.decode(header_decoded[0..], header) catch |err| {
        std.debug.print("Failed to decode header: {}\n", .{err});
        return err;
    };

    const header_len = try decoder.calcSizeForSlice(header);

    // Decode the payload
    var payload_decoded: [1024]u8 = undefined;
    decoder.decode(payload_decoded[0..], payload) catch |err| {
        std.debug.print("Failed to decode payload: {}\n", .{err});
        return err;
    };

    const payload_len = try decoder.calcSizeForSlice(payload);

    // Decode the signature
    var signature_decoded: [1024]u8 = undefined;
    decoder.decode(signature_decoded[0..], signature) catch |err| {
        std.debug.print("Failed to decode signature: {}\n", .{err});
        return err;
    };

    const signature_len = try decoder.calcSizeForSlice(signature);

    // // Print the signature as raw bytes (hex format for readability)
    // std.debug.print("\nSignature (hex): ", .{});
    // for (signature_decoded[0..signature_len]) |byte| {
    //     std.debug.print("{x:0>2} ", .{byte});
    // }

    const alloc_header = try std.fmt.allocPrint(allocator, "{s}", .{header_decoded[0..header_len]});
    const alloc_payload = try std.fmt.allocPrint(allocator, "{s}", .{payload_decoded[0..payload_len]});
    const alloc_signature = try std.fmt.allocPrint(allocator, "{s}", .{signature_decoded[0..signature_len]});

    return JWT2{
        .header = alloc_header,
        .payload = alloc_payload,
        .signature = alloc_signature,
    };
}

const Time = @import("loom").Time;
const Algorithm = @import("root.zig").Algorithm;
const HeaderRoot = @import("root.zig").Header;
const Validation = @import("root.zig").Validation;

/// Key used for decoding JWT tokens
pub const DecodingKey = union(enum) {
    secret: []const u8,
    edsa: std.crypto.sign.Ed25519.PublicKey,
    es256: std.crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey,
    es384: std.crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey,
    //rsa: std.crypto.Certificate.rsa.PublicKey,

    fn fromSecret(secret: []const u8) @This() {
        return .{ .secret = secret };
    }

    fn fromEdsaBytes(bytes: [std.crypto.sign.Ed25519.PublicKey]u8) !@This() {
        return .{ .edsa = try std.crypto.sign.Ed25519.PublicKey.fromBytes(bytes) };
    }

    pub fn fromEs256Bytes(bytes: [std.crypto.ecdsa.EcdsaP256Sha256.PublicKey.encoded_length]u8) !@This() {
        return .{ .es256 = try std.crypto.sign.ecdsa.EcdsaP256Sha256.PublicKey.fromBytes(bytes) };
    }

    pub fn fromEs384Bytes(bytes: [std.crypto.ecdsa.EcdsaP384Sha384.PublicKey.encoded_length]u8) !@This() {
        return .{ .es384 = try std.crypto.sign.ecdsa.EcdsaP384Sha384.PublicKey.fromBytes(bytes) };
    }
};

fn decodePart(allocator: std.mem.Allocator, comptime T: type, encoded: []const u8) !T {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const dest = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    _ = try decoder.decode(dest, encoded);
    return try std.json.parseFromSliceLeaky(T, allocator, dest, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

pub fn JWT(comptime ClaimSet: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        header: HeaderRoot,
        claims: ClaimSet,

        pub fn deinit(self: *@This()) void {
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
        }
    };
}

pub fn decode(
    allocator: std.mem.Allocator,
    comptime ClaimSet: type,
    str: []const u8,
    key: DecodingKey,
    validation: Validation,
) !JWT(ClaimSet) {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    if (std.mem.count(u8, str, ".") == 2) {
        const sigSplit = std.mem.lastIndexOfScalar(u8, str, '.').?;
        const messageEnc, const signatureEnc = .{ str[0..sigSplit], str[sigSplit + 1 ..] };

        const header = try decodePart(arena.allocator(), HeaderRoot, messageEnc[0..std.mem.indexOfScalar(u8, messageEnc, '.').?]);
        const claims = try verify(arena.allocator(), header.alg, key, ClaimSet, messageEnc, signatureEnc, validation);

        return .{
            .arena = arena,
            .header = header,
            .claims = claims,
        };
    }
    return error.MalformedJWT;
}

pub fn verify(
    allocator: std.mem.Allocator,
    algo: Algorithm,
    key: DecodingKey,
    comptime ClaimSet: type,
    msg: []const u8,
    sigEnc: []const u8,
    validation: Validation,
) !ClaimSet {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const sig = try allocator.alloc(u8, try decoder.calcSizeForSlice(sigEnc));
    _ = try decoder.decode(sig, sigEnc);

    if (!validation.skip_secret) {
        switch (algo) {
            .HS256 => {
                var dest: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
                var src: [dest.len]u8 = undefined;
                std.crypto.auth.hmac.sha2.HmacSha256.create(&dest, msg, switch (key) {
                    .secret => |v| v,
                    else => return error.InvalidDecodingKey,
                });
                @memcpy(&src, sig);
                if (!std.crypto.timing_safe.eql([dest.len]u8, src, dest)) {
                    return error.InvalidSignature;
                }
            },
            .HS384 => {
                var dest: [std.crypto.auth.hmac.sha2.HmacSha384.mac_length]u8 = undefined;
                var src: [dest.len]u8 = undefined;
                std.crypto.auth.hmac.sha2.HmacSha384.create(&dest, msg, switch (key) {
                    .secret => |v| v,
                    else => return error.InvalidDecodingKey,
                });
                @memcpy(&src, sig);
                if (!std.crypto.timing_safe.eql([dest.len]u8, src, dest)) {
                    return error.InvalidSignature;
                }
            },
            .HS512 => {
                var dest: [std.crypto.auth.hmac.sha2.HmacSha512.mac_length]u8 = undefined;
                var src: [dest.len]u8 = undefined;
                std.crypto.auth.hmac.sha2.HmacSha512.create(&dest, msg, switch (key) {
                    .secret => |v| v,
                    else => return error.InvalidDecodingKey,
                });
                @memcpy(&src, sig);
                if (!std.crypto.timing_safe.eql([dest.len]u8, src, dest)) {
                    return error.InvalidSignature;
                }
            },
            .ES256 => {
                var src: [std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature.encoded_length]u8 = undefined;
                @memcpy(&src, sig);
                std.crypto.sign.ecdsa.EcdsaP256Sha256.Signature.fromBytes(src).verify(msg, switch (key) {
                    .es256 => |v| v,
                    else => return error.InvalidDecodingKey,
                }) catch {
                    return error.InvalidSignature;
                };
            },
            .ES384 => {
                var src: [std.crypto.sign.ecdsa.EcdsaP384Sha384.Signature.encoded_length]u8 = undefined;
                @memcpy(&src, sig);
                std.crypto.sign.ecdsa.EcdsaP384Sha384.Signature.fromBytes(src).verify(msg, switch (key) {
                    .es384 => |v| v,
                    else => return error.InvalidDecodingKey,
                }) catch {
                    return error.InvalidSignature;
                };
            },
            // .PS256 => {
            //     const modulus_len = 256;
            //     const psSig = std.crypto.Certificate.rsa.PSSSignature.fromBytes(modulus_len, sig);
            //     std.crypto.Certificate.rsa.PSSSignature.verify(modulus_len, psSig, msg, switch (key) {
            //         .rsa => |v| v,
            //         else => return error.InvalidDecodingKey,
            //     }, std.crypto.hash.sha2.Sha256) catch {
            //         return error.InvalidSignature;
            //     };
            // },
            .EdDSA => {
                var src: [std.crypto.sign.Ed25519.Signature.encoded_length]u8 = undefined;
                @memcpy(&src, sig);
                std.crypto.sign.Ed25519.Signature.fromBytes(src).verify(msg, switch (key) {
                    .edsa => |v| v,
                    else => return error.InvalidDecodingKey,
                }) catch {
                    return error.InvalidSignature;
                };
            },

            //
            //
            else => return error.TODO,
        }
    }

    try validation.validate(
        try decodePart(allocator, Validation.RegisteredClaims, msg[std.mem.indexOfScalar(u8, msg, '.').? + 1 ..]),
    );

    const claims = try decodePart(
        allocator,
        ClaimSet,
        msg[std.mem.indexOfScalar(u8, msg, '.').? + 1 ..],
    );

    return claims;
}

/// Key used for encoding JWT token components
pub const EncodingKey = union(enum) {
    secret: []const u8,
    edsa: std.crypto.sign.Ed25519.SecretKey,
    es256: std.crypto.sign.ecdsa.EcdsaP256Sha256.SecretKey,
    es384: std.crypto.sign.ecdsa.EcdsaP384Sha384.SecretKey,

    /// create a new edsa encoding key from edsa secret key bytes
    pub fn fromEdsaBytes(bytes: [std.crypto.sign.Ed25519.SecretKey.encoded_length]u8) !@This() {
        return .{ .edsa = try std.crypto.sign.Ed25519.SecretKey.fromBytes(bytes) };
    }

    pub fn fromEs256Bytes(bytes: [std.crypto.ecdsa.EcdsaP256Sha256.SecretKey.encoded_length]u8) !@This() {
        return .{ .es256 = try std.crypto.sign.ecdsa.EcdsaP256Sha256.SecretKey.fromBytes(bytes) };
    }

    pub fn fromEs384Bytes(bytes: [std.crypto.ecdsa.EcdsaP384Sha384.SecretKey.encoded_length]u8) !@This() {
        return .{ .es384 = try std.crypto.sign.ecdsa.EcdsaP384Sha384.SecretKey.fromBytes(bytes) };
    }
};

fn encodePart(
    allocator: std.mem.Allocator,
    part: anytype,
) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const fmt = std.json.fmt(part, .{ .emit_null_optional_fields = false });

    var writer = std.Io.Writer.Allocating.init(allocator);
    try fmt.format(&writer.writer);

    const json = try writer.toOwnedSlice();
    defer allocator.free(json);
    const enc = try allocator.alloc(u8, encoder.calcSize(json.len));
    _ = encoder.encode(enc, json);
    return enc;
}

fn sign(
    allocator: std.mem.Allocator,
    msg: []const u8,
    algo: Algorithm,
    key: EncodingKey,
) ![]const u8 {
    return switch (algo) {
        .HS256 => blk: {
            var dest: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha256.create(&dest, msg, switch (key) {
                .secret => |v| v,
                else => return error.InvalidEncodingKey,
            });
            break :blk allocator.dupe(u8, &dest);
        },
        .HS384 => blk: {
            var dest: [std.crypto.auth.hmac.sha2.HmacSha384.mac_length]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha384.create(&dest, msg, switch (key) {
                .secret => |v| v,
                else => return error.InvalidEncodingKey,
            });
            break :blk allocator.dupe(u8, &dest);
        },
        .HS512 => blk: {
            var dest: [std.crypto.auth.hmac.sha2.HmacSha512.mac_length]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha512.create(&dest, msg, switch (key) {
                .secret => |v| v,
                else => return error.InvalidEncodingKey,
            });
            break :blk allocator.dupe(u8, &dest);
        },
        .ES256 => blk: {
            const pair = try std.crypto.sign.ecdsa.EcdsaP256Sha256.KeyPair.fromSecretKey(switch (key) {
                .es256 => |v| v,
                else => return error.InvalidEncodingKey,
            });
            const dest = (try pair.sign(msg, null)).toBytes();
            break :blk allocator.dupe(u8, &dest);
        },
        .ES384 => blk: {
            const pair = try std.crypto.sign.ecdsa.EcdsaP384Sha384.KeyPair.fromSecretKey(switch (key) {
                .es384 => |v| v,
                else => return error.InvalidEncodingKey,
            });
            const dest = (try pair.sign(msg, null)).toBytes();
            break :blk allocator.dupe(u8, &dest);
        },
        .EdDSA => blk: {
            const pair = try std.crypto.sign.Ed25519.KeyPair.fromSecretKey(switch (key) {
                .edsa => |v| v,
                else => return error.InvalidEncodingKey,
            });
            const dest = (try pair.sign(msg, null)).toBytes();
            break :blk allocator.dupe(u8, &dest);
        },
        else => return error.TODO,
    };
}

pub fn encode(
    allocator: std.mem.Allocator,
    header: HeaderRoot,
    claims: anytype,
    key: EncodingKey,
) ![]const u8 {
    comptime {
        if (@typeInfo(@TypeOf(claims)) != .@"struct") {
            @compileError("expected claims to be a struct but was a " ++ @typeName(@TypeOf(claims)));
        }
    }

    const encoder = std.base64.url_safe_no_pad.Encoder;

    const header_enc = try encodePart(allocator, header);
    defer allocator.free(header_enc);

    const claims_enc = try encodePart(allocator, claims);
    defer allocator.free(claims_enc);

    const msg = try std.mem.join(allocator, ".", &.{ header_enc, claims_enc });
    defer allocator.free(msg);

    const sig = try sign(allocator, msg, header.alg, key);
    defer allocator.free(sig);
    const sig_enc = try allocator.alloc(u8, encoder.calcSize(sig.len));
    defer allocator.free(sig_enc);
    _ = encoder.encode(sig_enc, sig);

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice(msg);
    try buf.append('.');
    try buf.appendSlice(sig_enc);

    return try buf.toOwnedSlice();
}

pub fn getHeader(header_str: []const u8, allocator: std.mem.Allocator) !Header {
    const header = try std.json.parseFromSlice(Header, allocator, header_str, .{});
    // defer header.deinit();
    return header.value;
}

pub fn getPayload(payload_str: []const u8, allocator: std.mem.Allocator) !Payload {
    const payload = try std.json.parseFromSlice(Payload, allocator, payload_str, .{});
    // defer payload.deinit();
    return payload.value;
}

pub const GoogleIdToken = struct {
    iss: []const u8,
    azp: []const u8,
    aud: []const u8,
    sub: []const u8,
    email: []const u8,
    email_verified: bool,
    at_hash: []const u8,
    iat: i64,
    exp: i64,
};
pub fn getRefreshPayload(payload_str: []const u8, allocator: std.mem.Allocator) !GoogleIdToken {
    const payload = try std.json.parseFromSlice(GoogleIdToken, allocator, payload_str, .{});
    // defer payload.deinit();
    return payload.value;
}

pub const SessionClaims = struct {
    sub: []const u8, // your user id
    email: []const u8,
    name: []const u8,
    iat: i64,
    exp: i64,
};

/// Signs a 7-day session token for `user_id`.
///
/// `secret` is the HMAC signing key and must come from the caller's
/// configuration — anyone holding it can mint tokens for any user, so it
/// belongs in an environment variable or secret store, never in source.
pub fn createSessionToken(
    allocator: std.mem.Allocator,
    secret: []const u8,
    user_id: []const u8,
    email: []const u8,
    name: []const u8,
) ![]const u8 {
    if (secret.len == 0) return error.MissingSigningSecret;

    const now: i64 = @intCast(Time.timestamp());

    const header = HeaderRoot{
        .alg = .HS256,
        .typ = "JWT",
    };

    const claims = SessionClaims{
        .sub = user_id,
        .email = email,
        .name = name,
        .iat = now,
        .exp = now + (60 * 60 * 24 * 7), // 7 days
    };

    return try encode(
        allocator,
        header,
        claims,
        .{ .secret = secret },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const test_secret = "test-signing-secret-not-used-anywhere-real";

// A token is only useful if it round-trips, so this is the baseline: what
// went in as claims must come back out.
test "HS256 token round-trips through encode and decode" {
    const allocator = testing.allocator;
    const now: i64 = @intCast(Time.timestamp());

    const claims = SessionClaims{
        .sub = "user-123",
        .email = "someone@example.com",
        .name = "Test User",
        .iat = now,
        .exp = now + 3600,
    };

    const token = try encode(
        allocator,
        .{ .alg = .HS256, .typ = "JWT" },
        claims,
        .{ .secret = test_secret },
    );
    defer allocator.free(token);

    var jwt = try decode(
        allocator,
        SessionClaims,
        token,
        .{ .secret = test_secret },
        .{},
    );
    defer jwt.deinit();

    try testing.expectEqual(Algorithm.HS256, jwt.header.alg);
    try testing.expectEqualStrings(claims.sub, jwt.claims.sub);
    try testing.expectEqualStrings(claims.email, jwt.claims.email);
    try testing.expectEqualStrings(claims.name, jwt.claims.name);
    try testing.expectEqual(claims.exp, jwt.claims.exp);
}

// The security property that matters most: a token signed with one key
// must not verify under another.
test "a token signed with a different secret is rejected" {
    const allocator = testing.allocator;
    const now: i64 = @intCast(Time.timestamp());

    const token = try encode(
        allocator,
        .{ .alg = .HS256, .typ = "JWT" },
        SessionClaims{
            .sub = "user-123",
            .email = "someone@example.com",
            .name = "Test User",
            .iat = now,
            .exp = now + 3600,
        },
        .{ .secret = "the-real-secret" },
    );
    defer allocator.free(token);

    try testing.expectError(error.InvalidSignature, decode(
        allocator,
        SessionClaims,
        token,
        .{ .secret = "an-attackers-guess" },
        .{},
    ));
}

// Flipping a byte of the payload must invalidate the signature, otherwise
// claims are attacker-controlled.
test "a tampered payload is rejected" {
    const allocator = testing.allocator;
    const now: i64 = @intCast(Time.timestamp());

    const token = try encode(
        allocator,
        .{ .alg = .HS256, .typ = "JWT" },
        SessionClaims{
            .sub = "user-123",
            .email = "someone@example.com",
            .name = "Test User",
            .iat = now,
            .exp = now + 3600,
        },
        .{ .secret = test_secret },
    );
    defer allocator.free(token);

    const tampered = try allocator.dupe(u8, token);
    defer allocator.free(tampered);

    // Mutate a character inside the payload segment, leaving the structure
    // intact so the failure comes from verification and not from parsing.
    const first_dot = std.mem.indexOfScalar(u8, tampered, '.').?;
    const last_dot = std.mem.lastIndexOfScalar(u8, tampered, '.').?;
    const target = first_dot + (last_dot - first_dot) / 2;
    tampered[target] = if (tampered[target] == 'A') 'B' else 'A';

    try testing.expectError(error.InvalidSignature, decode(
        allocator,
        SessionClaims,
        tampered,
        .{ .secret = test_secret },
        .{},
    ));
}

test "an expired token is rejected" {
    const allocator = testing.allocator;
    const now: i64 = @intCast(Time.timestamp());

    // Well outside the default 60s leeway.
    const token = try encode(
        allocator,
        .{ .alg = .HS256, .typ = "JWT" },
        SessionClaims{
            .sub = "user-123",
            .email = "someone@example.com",
            .name = "Test User",
            .iat = now - 7200,
            .exp = now - 3600,
        },
        .{ .secret = test_secret },
    );
    defer allocator.free(token);

    try testing.expectError(error.TokenExpired, decode(
        allocator,
        SessionClaims,
        token,
        .{ .secret = test_secret },
        .{},
    ));
}

test "malformed tokens are rejected rather than parsed" {
    const allocator = testing.allocator;

    for ([_][]const u8{
        "",
        "not-a-jwt",
        "only.two",
        "....",
        "a.b.c.d",
    }) |bad| {
        try testing.expectError(error.MalformedJWT, decode(
            allocator,
            SessionClaims,
            bad,
            .{ .secret = test_secret },
            .{},
        ));
    }
}

test "createSessionToken refuses an empty signing secret" {
    try testing.expectError(error.MissingSigningSecret, createSessionToken(
        testing.allocator,
        "",
        "user-123",
        "someone@example.com",
        "Test User",
    ));
}
