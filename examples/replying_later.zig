//! The "Replying later" example from README.md.
//!
//! Compiled by `zig build check-readme` and in CI. Keep this and the README
//! in step.

const std = @import("std");
const reverb = @import("reverb");
const Context = reverb.Context;

const gpa = std.heap.smp_allocator;

const Job = struct {
    reply: *reverb.Reply,
    source: []u8, // owned by the job
};

fn runBuild(job: Job) void {
    defer gpa.free(job.source);
    // The slow part: a child process, an outbound API call...
    job.reply.send(200, "text/plain", "built");
}

var builds: reverb.Workers(Job, runBuild) = undefined;

fn build(ctx: *Context) !void {
    const source = try gpa.dupe(u8, ctx.body()); // the job owns its input
    errdefer gpa.free(source);
    const reply = try ctx.deferReply(); // last fallible step
    builds.submit(.{ .reply = reply, .source = source }) catch {
        gpa.free(source);
        reply.send(503, "text/plain", "busy");
    };
}

const Config = struct {
    port: u16 = 8080,
    max: usize = 1024,
    max_body_size: usize = 1024 * 1024 * 10,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var server: reverb.Server(Config) = undefined;
    try server.new(.{}, arena.allocator());
    defer server.deinit(); // last: frees replies left without a connection

    var threaded: std.Io.Threaded = .init_single_threaded;
    try builds.init(gpa, threaded.io(), .{ .threads = 2, .queue = 16 });
    defer builds.deinit(); // after `listen` returns, before `server.deinit`

    try server.installSignalHandlers();
    try server.post("/build", build, &.{});
    try server.listen();
}
