const std = @import("std");

/// Appends into a buffer the caller owns.
///
/// Previously this called `std.c.realloc`, which was wrong three ways: it
/// pulled in a dependency on libc that the executable does not declare (so
/// the build failed on Linux, and only worked on macOS because libSystem is
/// linked there regardless); it passed `contents` while that field was still
/// `undefined`, making the very first append a realloc of a garbage pointer;
/// and nothing ever freed the result.
///
/// The buffer belongs to the caller, so its lifetime is visible at the call
/// site. That matters here: `Server.prepare` stores a slice of it in
/// `Context.cors_headers`, which outlives the builder, so the backing memory
/// cannot be a local of the function that fills it.
pub const String = struct {
    start: usize = 0,
    len: usize = 0,
    contents: []u8,
    /// Set when an append did not fit. The content is then truncated, so
    /// callers that must not silently emit a half-built string check this.
    overflowed: bool = false,

    pub fn new(buffer: []u8) String {
        return .{ .contents = buffer };
    }

    pub fn init(buffer: []u8, initial: []const u8) String {
        var string = String.new(buffer);
        string.append_str(initial);
        return string;
    }

    /// Appends `input`, or records an overflow and appends nothing.
    ///
    /// Infallible by design: there are ~13 call sites in `Cors`, each of
    /// which would otherwise need a `try` for a condition that is a
    /// programming error (an undersized buffer) rather than a runtime one.
    /// `overflowed` is how the caller finds out.
    pub fn append_str(self: *String, input: []const u8) void {
        if (input.len > self.contents.len - self.len) {
            self.overflowed = true;
            return;
        }

        @memcpy(self.contents[self.len .. self.len + input.len], input);
        self.len += input.len;
    }

    /// The bytes written so far.
    pub fn slice(self: *const String) []const u8 {
        return self.contents[self.start..self.len];
    }
};

const testing = std.testing;

test "appends into the caller's buffer" {
    var buf: [64]u8 = undefined;
    var s = String.new(&buf);

    s.append_str("Hello");
    s.append_str(", ");
    s.append_str("world");

    try testing.expectEqualStrings("Hello, world", s.slice());
    try testing.expect(!s.overflowed);
}

test "init seeds the buffer" {
    var buf: [16]u8 = undefined;
    var s = String.init(&buf, "seed");
    try testing.expectEqualStrings("seed", s.slice());
}

// An append that does not fit must not write past the end of the buffer,
// and must say so rather than silently producing a truncated string.
test "an oversized append overflows instead of writing out of bounds" {
    var buf: [8]u8 = undefined;
    var s = String.new(&buf);

    s.append_str("12345");
    try testing.expect(!s.overflowed);

    s.append_str("678901");
    try testing.expect(s.overflowed);
    // The content that did fit is intact and the buffer was not exceeded.
    try testing.expectEqualStrings("12345", s.slice());
}

test "filling the buffer exactly is not an overflow" {
    var buf: [5]u8 = undefined;
    var s = String.new(&buf);

    s.append_str("12345");
    try testing.expect(!s.overflowed);
    try testing.expectEqualStrings("12345", s.slice());
}

test "an empty append always fits" {
    var buf: [1]u8 = undefined;
    var s = String.new(&buf);

    s.append_str("x");
    s.append_str("");
    try testing.expect(!s.overflowed);
    try testing.expectEqualStrings("x", s.slice());
}
