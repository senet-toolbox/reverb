//! An `std.mem.Allocator` wrapper that accounts for live bytes and
//! allocation counts.
//!
//! Wrap any allocator with `init` and use the returned `Allocator` in its
//! place; the counters underneath stay accurate through resize and remap.
//! Intended to be cheap enough to leave enabled in a running server — it
//! adds a handful of integer updates per allocation and allocates nothing
//! of its own.
//!
//! ```zig
//! var ta: TrackingAllocator = undefined;
//! const allocator = ta.init(std.heap.page_allocator);
//! defer ta.deinit();
//! ...
//! std.log.info("live: {d} bytes, peak: {d}", .{ ta.bytesAllocated(), ta.peak_bytes });
//! ```

const std = @import("std");
const Alignment = std.mem.Alignment;
const BITS_IN_BYTE = 8;
const BYTES_IN_MEGABYTE = 1_000_000;

/// Prints the size in bytes of `number` values of type `T`.
pub fn printSizeInBytes(comptime T: type, number: usize) void {
    const SIZE_IN_BYTES = @sizeOf(T) * number;
    std.debug.print("     size: {} bytes\n", .{SIZE_IN_BYTES});
}

pub const TrackingAllocator = @This();

base: std.mem.Allocator,
/// Bytes currently held by live allocations.
allocated_bytes: usize = 0,
/// High-water mark of `allocated_bytes` over the lifetime of the tracker.
peak_bytes: usize = 0,
/// Total bytes ever handed out, never decremented.
total_allocated_bytes: usize = 0,
/// Number of live allocations.
live_allocations: usize = 0,
/// Total number of `alloc` calls that succeeded.
total_allocations: usize = 0,
/// Bytes live at the moment `markStartupComplete` was called.
startup_bytes: usize = 0,
/// When set, every alloc/free is logged to stderr. Very noisy; off by default.
log: bool = false,

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .free = free,
    .resize = resize,
    .remap = remap,
};

/// Initializes `ta` in place and returns an allocator that routes through it.
/// The returned allocator borrows `ta`, so `ta` must outlive it.
pub fn init(ta: *TrackingAllocator, base: std.mem.Allocator) std.mem.Allocator {
    ta.* = .{ .base = base };
    return .{ .ptr = ta, .vtable = &vtable };
}

pub fn deinit(ta: *TrackingAllocator) void {
    ta.* = .{ .base = ta.base };
}

/// Records the current live byte count as the startup baseline, so later
/// readings can distinguish steady-state growth from start-up cost.
pub fn markStartupComplete(ta: *TrackingAllocator) void {
    ta.startup_bytes = ta.allocated_bytes;
}

fn record(ta: *TrackingAllocator, delta_add: usize, delta_sub: usize) void {
    // Saturating on the way down: a wrapped counter is worse than a
    // slightly wrong one, and an underflow here would panic the server on
    // a path that only exists to report numbers.
    ta.allocated_bytes = ta.allocated_bytes + delta_add -| delta_sub;
    if (ta.allocated_bytes > ta.peak_bytes) ta.peak_bytes = ta.allocated_bytes;
}

fn alloc(
    self: *anyopaque,
    len: usize,
    alignment: Alignment,
    ret_addr: usize,
) ?[*]u8 {
    const ta: *TrackingAllocator = @ptrCast(@alignCast(self));
    const ptr = ta.base.rawAlloc(len, alignment, ret_addr) orelse return null;

    ta.record(len, 0);
    ta.total_allocated_bytes += len;
    ta.live_allocations += 1;
    ta.total_allocations += 1;
    if (ta.log) std.debug.print("alloc {d} bytes -> {*}\n", .{ len, ptr });
    return ptr;
}

fn resize(
    self: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    const ta: *TrackingAllocator = @ptrCast(@alignCast(self));
    if (!ta.base.rawResize(memory, alignment, new_len, ret_addr)) return false;

    if (new_len >= memory.len) {
        const grown = new_len - memory.len;
        ta.record(grown, 0);
        ta.total_allocated_bytes += grown;
    } else {
        ta.record(0, memory.len - new_len);
    }
    if (ta.log) std.debug.print("resize {d} -> {d} bytes\n", .{ memory.len, new_len });
    return true;
}

fn remap(
    self: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    const ta: *TrackingAllocator = @ptrCast(@alignCast(self));
    const ptr = ta.base.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

    if (new_len >= memory.len) {
        const grown = new_len - memory.len;
        ta.record(grown, 0);
        ta.total_allocated_bytes += grown;
    } else {
        ta.record(0, memory.len - new_len);
    }
    if (ta.log) std.debug.print("remap {d} -> {d} bytes\n", .{ memory.len, new_len });
    return ptr;
}

fn free(
    self: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    ret_addr: usize,
) void {
    const ta: *TrackingAllocator = @ptrCast(@alignCast(self));
    ta.base.rawFree(memory, alignment, ret_addr);

    ta.record(0, memory.len);
    if (ta.live_allocations > 0) ta.live_allocations -= 1;
    if (ta.log) std.debug.print("free {d} bytes <- {*}\n", .{ memory.len, memory.ptr });
}

/// Bytes currently held by live allocations.
pub fn bytesAllocated(ta: *const TrackingAllocator) usize {
    return ta.allocated_bytes;
}

/// Live bytes beyond the startup baseline. Zero until
/// `markStartupComplete` has been called.
pub fn runtimeBytes(ta: *const TrackingAllocator) usize {
    return ta.allocated_bytes -| ta.startup_bytes;
}

pub fn checkAllocation(ta: *const TrackingAllocator) void {
    std.debug.print(
        \\
        \\Allocation summary
        \\------------------------------------------
        \\  live bytes      : {d}
        \\  peak bytes      : {d}
        \\  startup bytes   : {d}
        \\  runtime bytes   : {d}
        \\  live allocations: {d}
        \\  total allocs    : {d} ({d} bytes)
        \\------------------------------------------
        \\
    , .{
        ta.allocated_bytes,
        ta.peak_bytes,
        ta.startup_bytes,
        ta.runtimeBytes(),
        ta.live_allocations,
        ta.total_allocations,
        ta.total_allocated_bytes,
    });
}

pub fn printBytes(ta: *const TrackingAllocator) void {
    std.debug.print("Memory: {d} bytes\n", .{ta.allocated_bytes});
}

pub fn printBits(ta: *const TrackingAllocator) void {
    std.debug.print("     Memory: {d} bits\n", .{ta.allocated_bytes * BITS_IN_BYTE});
}

pub fn printMegaBytes(ta: *const TrackingAllocator) void {
    const bytes: f64 = @floatFromInt(ta.allocated_bytes);
    std.debug.print("     Memory: {d:.3} MB\n", .{bytes / @as(f64, BYTES_IN_MEGABYTE)});
}

const testing = std.testing;

test "alloc and free balance out" {
    var ta: TrackingAllocator = undefined;
    const allocator = ta.init(testing.allocator);
    defer ta.deinit();

    const arr = try allocator.alloc([]const u8, 10);
    try testing.expectEqual(@sizeOf([]const u8) * 10, ta.bytesAllocated());
    try testing.expectEqual(@as(usize, 1), ta.live_allocations);
    allocator.free(arr);

    const heap_node = try allocator.create(struct { int: u64 });
    allocator.destroy(heap_node);

    var map = std.StringHashMap([]const u8).init(allocator);
    try map.put("hello", "world");
    map.deinit();

    try testing.expectEqual(@as(usize, 0), ta.bytesAllocated());
    try testing.expectEqual(@as(usize, 0), ta.live_allocations);
    try testing.expect(ta.peak_bytes > 0);
    try testing.expect(ta.total_allocations >= 3);
}

test "shrinking does not underflow the live byte count" {
    var ta: TrackingAllocator = undefined;
    const allocator = ta.init(testing.allocator);
    defer ta.deinit();

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendNTimes(allocator, 'x', 4096);
    const peak_after_growth = ta.bytesAllocated();
    try testing.expect(peak_after_growth >= 4096);

    list.shrinkAndFree(allocator, 16);
    try testing.expect(ta.bytesAllocated() < peak_after_growth);
    try testing.expect(ta.bytesAllocated() >= 16);
}

test "startup baseline separates startup cost from runtime growth" {
    var ta: TrackingAllocator = undefined;
    const allocator = ta.init(testing.allocator);
    defer ta.deinit();

    const startup = try allocator.alloc(u8, 128);
    defer allocator.free(startup);
    ta.markStartupComplete();
    try testing.expectEqual(@as(usize, 0), ta.runtimeBytes());

    const runtime = try allocator.alloc(u8, 64);
    defer allocator.free(runtime);
    try testing.expectEqual(@as(usize, 64), ta.runtimeBytes());
}
