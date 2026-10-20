const std = @import("std");

pub const Self = @This();
name: []const u8,
value: []const u8,
expires: ?i64 = null,
http_only: bool = false,
secure: bool = false,
/// Whether the browser sends the cookie on requests that another site
/// started. Unset, browsers treat it as `lax`. `none` is honoured only
/// together with `secure`.
same_site: ?SameSite = null,

pub const SameSite = enum {
    strict,
    lax,
    none,

    /// The attribute's value as it appears in `Set-Cookie`.
    pub fn text(self: SameSite) []const u8 {
        return switch (self) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
    }
};

pub fn init(name: []const u8, value: []const u8, expires: i64) Self {
    return Self{
        .name = name,
        .value = value,
        .expires = expires,
    };
}
