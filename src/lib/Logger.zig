// [timestamp] [log_type] [file] string
const std = @import("std");

pub const Logger = @This();
mutex: std.Io.Mutex,

const LogLevel = enum {
    DEBUG,
    WARN,
    FATAL,
    INFO,
    ERROR,

    pub fn color(log_level: LogLevel) []const u8 {
        return switch (log_level) {
            .DEBUG => "\x1b[36m", // Cyan
            .INFO => "\x1b[32m", // Green
            .WARN => "\x1b[33m", // Yellow
            .ERROR => "\x1b[31m", // Red
            .FATAL => "\x1b[35m", // Magenta
        };
    }
};

pub fn init(target: *Logger) void {
    target.* = .{
        .mutex = .{.state = .{ .raw = .unlocked }},
    };
}

fn log(
    _: *Logger,
    log_level: LogLevel,
    comptime fmt: []const u8,
    args: anytype,
    _: ?std.builtin.SourceLocation,
    _: usize,
) !void {
    // const debug_info = try std.debug.getSelfDebugInfo();
    // var buf: [512]u8 = undefined;
    // var stream = std.Io.Writer.fixed(&buf);
    // const writer = &stream;
    // const tty = std.io.tty.detectConfig(std.fs.File.stderr());
    // try std.debug.printSourceAtAddress(debug_info, writer, ret_addr, tty);
    // // 4) Grab only the bytes that were written
    // const outSlice = buf[0..stream.end];
    // const start = std.mem.indexOf(u8, outSlice, "src") orelse std.mem.indexOf(u8, outSlice, "std") orelse 0;
    // const src = buf[start..stream.end];
    // var sections = std.mem.splitScalar(u8, src, ':');
    // const file_name = sections.next() orelse return;
    // const line = sections.next() orelse return;
    // logger.mutex.lock();
    // defer logger.mutex.unlock();
    // const stderr = std.io.getStdErr().writer();
    var errbuf: [512]u8 = undefined;
    var errstream = std.Io.Writer.fixed(&errbuf);
    var stderr = &errstream;

    nosuspend try stderr.print("[{d}] ", .{std.time.timestamp()});
    nosuspend try stderr.print("[{s}{s}\x1b[0m] ", .{ log_level.color(), @tagName(log_level) });
    // if (opt_src) |src| {
    // nosuspend try stderr.print("[{s}:{s}] => ", .{ file_name, line });
    // }
    nosuspend try stderr.print(fmt, args);
    nosuspend try stderr.writeByte('\n');
    std.debug.print("{s}", .{stderr.buffer[0..stderr.end]});
    try stderr.flush();
}

pub fn warn(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    const ret_addr = @returnAddress();
    try logger.log(LogLevel.WARN, fmt, args, opt_src, ret_addr);
}
pub fn debug(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    const ret_addr = @returnAddress();
    try logger.log(LogLevel.DEBUG, fmt, args, opt_src, ret_addr);
}
pub fn fatal(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    const ret_addr = @returnAddress();
    try logger.log(LogLevel.FATAL, fmt, args, opt_src, ret_addr);
}
pub fn info(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    const ret_addr = @returnAddress();
    try logger.log(LogLevel.INFO, fmt, args, opt_src, ret_addr);
}
pub fn err(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const ret_addr = @returnAddress();
    try logger.log(LogLevel.ERROR, fmt, args, null, ret_addr);
}

// test "all logs" {
//     var logger: Logger = undefined;
//     logger.init();
//     try logger.warn("Panic in the building {s}", .{"Escape now🔥"});
//     try logger.debug("Here are the logs for age {d}", .{24});
//     try logger.info("INFO {s}", .{"accessining"});
//     try logger.err("ERROR {s}", .{"accessining"});
//     try logger.fatal("FATAL {s}", .{"accessining"});
//     const vec1: @Vector(5, i32) = .{ 1, 2, 3, 4, 5 };
//     const vec2: @Vector(5, i32) = .{ 6, 7, 8, 9, 10 };
//     try logger.info("INFO {any}", .{vec1 + vec2});
// }
