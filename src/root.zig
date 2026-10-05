//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
pub const Server = @import("lib/server.zig").Server; // Weird thing where if i import server.zig it works but if i import Server.zig it doesnt
// pub const Scheduler = @import("lib/engine/async/Scheduler.zig");
pub const Treehouse = @import("lib/treehouse.zig");
pub const TrackingAllocator = @import("lib/TrackingAllocator.zig");
pub const Context = @import("lib/context.zig");
pub const Tripwire = @import("lib/Tripwire.zig");
pub const utils = @import("lib/helpers.zig");
pub const Logger = @import("lib/Logger.zig");
pub const KeyStone = @import("lib/auth/KeyStone.zig");
pub const JWT = @import("lib/core/JWT.zig");
pub const Cookie = @import("lib/core/Cookie.zig");
pub const Cors = @import("lib/core/Cors.zig");
pub const WebSocket = @import("loom").WebSocket;
pub const WSS = @import("lib/wss.zig").WSS;
pub const Time = @import("loom").Time;

test {
    // Zig only collects `test` blocks from files reachable from the root of
    // the test binary, so every file carrying tests is named explicitly here.
    _ = @import("lib/helpers.zig");
    _ = @import("lib/parser.zig");
    _ = @import("lib/TrackingAllocator.zig");
    _ = @import("lib/Tripwire.zig");
    _ = @import("lib/core/JWT.zig");
    _ = @import("lib/trees/radix.zig");
    _ = @import("lib/core/simdjson/number_parsing.zig");
}
