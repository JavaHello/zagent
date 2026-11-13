//! Text helpers that are about bytes rather than about a terminal.
//!
//! Sanitising what came from outside this program lives in `terminal/`, split by
//! what it does: `terminal/ansi.zig` recognises the escape sequences a terminal
//! acts on, `terminal/sanitize.zig` walks text and drops or escapes what must not
//! be printed, and `terminal/normalize.zig` keeps what a screen ended up showing
//! of a line redrawn in place.

/// Compile-time byte repetition, used for terminal fixtures and rule glyphs.
pub fn repeat(comptime bytes: []const u8, comptime count: usize) *const [bytes.len * count]u8 {
    @setEvalBranchQuota(10 * count + 1000);
    const repeated = comptime blk: {
        var out: [bytes.len * count]u8 = undefined;
        for (0..count) |i| @memcpy(out[i * bytes.len ..][0..bytes.len], bytes);
        break :blk out;
    };
    return &repeated;
}

test "repeat builds the bytes at compile time" {
    try @import("std").testing.expectEqualStrings("ababab", repeat("ab", 3));
}
