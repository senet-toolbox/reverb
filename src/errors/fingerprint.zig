const std = @import("std");
const types = @import("types.zig");

/// Compute a stable SHA-256 fingerprint for error grouping.
///
/// Format:  error_type :: crash_function :: crash_file :: crash_line :: message
///
/// Groups errors that crash at the same location with the same type,
/// even if the message varies slightly (e.g. different pointer values).
/// The message is included as a tiebreaker for cases where crash_site
/// is null (e.g. pure JS errors with no WASM frame info).
pub fn compute(report: types.ErrorReport) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    hasher.update(report.wasmError.type);
    hasher.update("::");

    if (report.wasmError.crash_site) |cs| {
        hasher.update(cs.function orelse "");
        hasher.update("::");
        hasher.update(cs.file orelse "");
        hasher.update("::");
        if (cs.line) |line| {
            var buf: [16]u8 = undefined;
            const line_str = std.fmt.bufPrint(&buf, "{d}", .{line}) catch "";
            hasher.update(line_str);
        }
    } else {
        hasher.update("::");
        hasher.update("::");
    }

    hasher.update("::");
    hasher.update(report.wasmError.message);

    return hexDigest(hasher.finalResult());
}

fn hexDigest(digest: [32]u8) [64]u8 {
    const chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        hex[i * 2] = chars[byte >> 4];
        hex[i * 2 + 1] = chars[byte & 0x0f];
    }
    return hex;
}

// ============================================================================
// Tests
// ============================================================================

test "fingerprint is stable for same input" {
    const report = types.ErrorReport{
        .wasmError = .{
            .type = "RuntimeError",
            .message = "unreachable",
            .is_wasm_trap = true,
            .crash_site = .{
                .function = "main.sample",
                .wasm_function_index = 841,
                .wasm_offset = "0xbd070",
                .frame_type = .wasm,
            },
            .user_stack = &.{},
        },
        .events = &.{},
        .timestamp = 1234567890,
    };

    const fp1 = compute(report);
    const fp2 = compute(report);
    try std.testing.expectEqualSlices(u8, &fp1, &fp2);
}

test "fingerprint differs when crash function changes" {
    const base = types.ErrorReport{
        .wasmError = .{
            .type = "RuntimeError",
            .message = "unreachable",
            .is_wasm_trap = true,
            .crash_site = .{
                .function = "main.sample",
                .frame_type = .wasm,
            },
            .user_stack = &.{},
        },
        .events = &.{},
        .timestamp = 1234567890,
    };

    var different = base;
    different.wasmError.crash_site = .{
        .function = "main.other",
        .frame_type = .wasm,
    };

    const fp1 = compute(base);
    const fp2 = compute(different);
    try std.testing.expect(!std.mem.eql(u8, &fp1, &fp2));
}

test "fingerprint without crash site still works" {
    const report = types.ErrorReport{
        .wasmError = .{
            .type = "TypeError",
            .message = "x is not a function",
            .is_wasm_trap = false,
            .crash_site = null,
            .user_stack = &.{},
        },
        .events = &.{},
        .timestamp = 1234567890,
    };

    const fp = compute(report);
    try std.testing.expectEqual(@as(usize, 64), fp.len);
}
