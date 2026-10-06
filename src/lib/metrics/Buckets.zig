const std = @import("std");
const Treehouse = @import("../treehouse.zig");
const tether = @import("../server.zig");
const Bucket = struct {
    start_ts: i64, // e.g. truncated to the second
    req_count: u64,
    total_latency: u64 = 0, // for avg latency if you want
};
pub var req_count: u64 = 0;
var start_ts: i64 = 0;
var flush_start_ts: i64 = 0;
var buckets: std.AutoHashMap(i64, Bucket) = undefined;
var th_client: *Treehouse = undefined;
var local_allocator: *std.mem.Allocator = undefined;

pub fn init(allocator: *std.mem.Allocator) void {
    start_ts = std.time.timestamp();
    flush_start_ts = std.time.timestamp();
    buckets = std.AutoHashMap(i64, Bucket).init(allocator.*);
    const treehouse: *Treehouse = allocator.create(Treehouse) catch |err| {
        std.log.err("{any}", .{err});
        @panic("Failed to create Treehouse struct");
    };
    treehouse.* = Treehouse.createClient(6401, allocator) catch |err| {
        std.log.err("{any}", .{err});
        @panic("Failed to create client");
    };
    th_client = treehouse;
    local_allocator = allocator;
}

pub fn deinit() void {
    buckets.deinit();
}

fn sleep(minutes: u64) void {
    std.Thread.sleep(minutes * 60 * 1_000_000_000);
}

pub fn loop() void {
    while (true) {
        sleep(1);
        if (req_count <= 0) continue;
        tether.instance.logger.info("Request Count: {any}", .{req_count}, null) catch return;
        const current_ts = std.time.timestamp();
        const diff = current_ts - start_ts;
        const ttl = @divTrunc(@as(u64, @intCast(diff)), req_count);
        const bucket = Bucket{
            .start_ts = start_ts,
            .req_count = req_count,
            .total_latency = ttl,
        };
        buckets.put(start_ts, bucket) catch |err| {
            tether.instance.logger.err("Failed to add to buckets: {any}", .{err}) catch return;
            return;
        };
        start_ts = std.time.timestamp();
        req_count = 0;
        const timestamp_key = std.fmt.allocPrint(local_allocator.*, "metrics:req:min:1{any}", .{bucket.start_ts}) catch |err| {
            tether.instance.logger.err("Failed to Alloc {any}", .{err}) catch return;
            return;
        };
        const json_bucket = std.json.stringifyAlloc(local_allocator.*, bucket, .{}) catch |err| {
            tether.instance.logger.err("Failed to stringify {any}", .{err}) catch return;
            return;
        };
        _ = th_client.lpush(timestamp_key, .{ .json = json_bucket }) catch |err| {
            tether.instance.logger.err("Failed to set {any}", .{err}) catch return;
            return;
        };
    }
}
