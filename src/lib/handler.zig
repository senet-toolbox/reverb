//! Types shared by the request path.
//!
//! This file previously also held a `handler` function that duplicated
//! `Server.handle` in `server.zig`. Nothing called it, it had drifted out of
//! step with the live path, and it referenced a `Client.writeMessage` method
//! that does not exist — so it only compiled because Zig never analysed it.
//! The live request path is `Server.handle`; see `server.zig`.

const std = @import("std");

/// The method and path extracted from a request line, used to look up a
/// route. Both slices point into the parsed header buffer and stay valid for
/// as long as it does.
pub const Ctx_pm = struct {
    path: []const u8 = "",
    method: []const u8 = "GET",
};
