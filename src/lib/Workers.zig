//! A fixed pool of threads running jobs from a bounded queue.
//!
//! For work too slow to do on the event loop: a handler calls
//! `ctx.deferReply()`, submits a job carrying the `*Reply`, and returns; a
//! worker runs the job and calls `reply.send`. Keep one pool per kind of
//! work, so slow work cannot starve other work -- CPU-bound builds on a
//! pool the size of what the machine can spare, network waits on a larger
//! one.
//!
//! Plain threads and a mutex-guarded queue (`std.Io.Queue`), not lock-free:
//! the jobs this is for take milliseconds to minutes, against tens of
//! nanoseconds for an uncontended lock.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Workers(comptime Job: type, comptime run: fn (Job) void) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            /// Threads running jobs.
            threads: usize = 1,
            /// Jobs that may wait for a thread. Beyond this `submit`
            /// refuses, so the handler can answer 503 rather than queue
            /// without bound.
            queue: usize = 16,
        };

        allocator: Allocator,
        io: std.Io,
        queue: std.Io.Queue(Job),
        buffer: []Job,
        threads: []std.Thread,

        /// Starts the threads. `self` must stay put until `deinit`: the
        /// threads hold a pointer to it.
        pub fn init(self: *Self, allocator: Allocator, io: std.Io, options: Options) !void {
            if (options.threads == 0 or options.queue == 0) return error.InvalidConfig;

            const buffer = try allocator.alloc(Job, options.queue);
            errdefer allocator.free(buffer);
            const threads = try allocator.alloc(std.Thread, options.threads);
            errdefer allocator.free(threads);

            self.* = .{
                .allocator = allocator,
                .io = io,
                .queue = .init(buffer),
                .buffer = buffer,
                .threads = threads,
            };

            var spawned: usize = 0;
            errdefer {
                self.queue.close(io);
                for (threads[0..spawned]) |thread| thread.join();
            }
            while (spawned < threads.len) : (spawned += 1) {
                threads[spawned] = try std.Thread.spawn(.{}, work, .{self});
            }
        }

        /// Queues `job` without blocking. `error.Busy` if the queue is
        /// full, `error.Closed` once `deinit` has begun; either way the
        /// job was not taken, and anything it owns is still the caller's.
        /// Threadsafe.
        pub fn submit(self: *Self, job: Job) error{ Busy, Closed }!void {
            const taken = self.queue.putUncancelable(self.io, &.{job}, 0) catch
                return error.Closed;
            if (taken == 0) return error.Busy;
        }

        /// Stops taking jobs, lets the threads finish everything already
        /// queued, and joins them.
        ///
        /// With a server, call this after `stop` has returned from
        /// `listen` and before the server's `deinit`: the jobs it finishes
        /// still `send` their replies, and the server's `deinit` is what
        /// frees replies that no longer have a connection.
        pub fn deinit(self: *Self) void {
            self.queue.close(self.io);
            for (self.threads) |thread| thread.join();
            self.allocator.free(self.threads);
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        fn work(self: *Self) void {
            while (true) {
                // `error.Closed` only once the queue is closed *and* empty.
                const job = self.queue.getOneUncancelable(self.io) catch return;
                run(job);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Counter = struct {
    var ran: std.atomic.Value(usize) = .init(0);
    var gate: std.atomic.Value(bool) = .init(true);

    fn job(n: usize) void {
        while (!gate.load(.acquire)) std.atomic.spinLoopHint();
        _ = ran.fetchAdd(n, .acq_rel);
    }
};

test "every submitted job runs exactly once" {
    Counter.ran.store(0, .release);
    Counter.gate.store(true, .release);

    var threaded: std.Io.Threaded = .init_single_threaded;
    var pool: Workers(usize, Counter.job) = undefined;
    try pool.init(testing.allocator, threaded.io(), .{ .threads = 4, .queue = 64 });

    var expected: usize = 0;
    var i: usize = 1;
    while (i <= 1000) : (i += 1) {
        while (true) {
            pool.submit(i) catch |err| switch (err) {
                error.Busy => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                error.Closed => return err,
            };
            break;
        }
        expected += i;
    }

    pool.deinit();
    try testing.expectEqual(expected, Counter.ran.load(.acquire));
}

test "a full queue refuses at once instead of blocking" {
    Counter.ran.store(0, .release);
    Counter.gate.store(false, .release);

    var threaded: std.Io.Threaded = .init_single_threaded;
    var pool: Workers(usize, Counter.job) = undefined;
    try pool.init(testing.allocator, threaded.io(), .{ .threads = 1, .queue = 2 });

    // One job may be taken by the (gated) thread before the queue fills,
    // so at most three are accepted; the fourth must be refused.
    var accepted: usize = 0;
    var refused = false;
    for (0..4) |_| {
        pool.submit(1) catch |err| {
            try testing.expectEqual(error.Busy, err);
            refused = true;
            break;
        };
        accepted += 1;
    }
    try testing.expect(refused);
    try testing.expect(accepted >= 2 and accepted <= 3);

    // `deinit` drains what was accepted.
    Counter.gate.store(true, .release);
    pool.deinit();
    try testing.expectEqual(accepted, Counter.ran.load(.acquire));
}

test "submit after deinit has begun is refused as closed" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var pool: Workers(usize, Counter.job) = undefined;
    Counter.gate.store(true, .release);
    try pool.init(testing.allocator, threaded.io(), .{});
    pool.queue.close(pool.io);
    try testing.expectError(error.Closed, pool.submit(1));
    pool.deinit();
}
