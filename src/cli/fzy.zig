//! Classic fzy scoring over Unicode code points; only ASCII is case folded.
//!
//! The weights, the gap/leading/trailing rule and the word-boundary bonuses are
//! those of fzy's `config.def.h` and `bonus.h`. Three deliberate differences:
//! matching is a subsequence over code points rather than a byte-wise
//! `tolower`, an invalid UTF-8 candidate never matches, and an empty query
//! scores every candidate alike instead of fzy's "no score" so the caller can
//! fall back to its own order.
const std = @import("std");
const Allocator = std.mem.Allocator;
const neg = -std.math.inf(f64);

pub const Scratch = struct {
    query: std.ArrayList(u21) = .empty,
    path: std.ArrayList(u21) = .empty,
    bonus: std.ArrayList(f64) = .empty,
    d: std.ArrayList(f64) = .empty,
    m: std.ArrayList(f64) = .empty,
    /// Set once per keystroke instead of failing every candidate in turn.
    invalid_query: bool = false,

    pub fn deinit(self: *Scratch, allocator: Allocator) void {
        self.query.deinit(allocator);
        self.path.deinit(allocator);
        self.bonus.deinit(allocator);
        self.d.deinit(allocator);
        self.m.deinit(allocator);
    }

    fn decode(list: *std.ArrayList(u21), allocator: Allocator, text: []const u8) !void {
        list.clearRetainingCapacity();
        // Callers validate first; an invalid slice simply decodes to nothing.
        const view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| try list.append(allocator, cp);
    }

    pub fn initQuery(self: *Scratch, allocator: Allocator, query: []const u8) !void {
        // An invalid query must not quietly become an empty one, which would
        // match every path: remember it and refuse every candidate instead.
        self.invalid_query = !std.unicode.utf8ValidateSlice(query);
        try decode(&self.query, allocator, if (self.invalid_query) "" else query);
    }

    pub fn score(self: *Scratch, allocator: Allocator, text: []const u8) !?f64 {
        if (self.invalid_query or !std.unicode.utf8ValidateSlice(text)) return null;
        try decode(&self.path, allocator, text);
        const n = self.path.items.len;
        const q = self.query.items;
        if (q.len == 0) return 0;
        if (q.len > n) return null;
        try self.bonus.resize(allocator, n);
        try self.d.resize(allocator, n);
        try self.m.resize(allocator, n);
        var previous: u21 = '/';
        for (self.path.items, 0..) |cp, j| {
            self.bonus.items[j] = bonus(previous, cp);
            previous = cp;
        }
        // The first row reads the previous row's slots before writing them, so
        // a freshly grown buffer must never hold undefined bytes.
        @memset(self.d.items, neg);
        @memset(self.m.items, neg);
        for (q, 0..) |needle, i| {
            var diagonal_m: f64 = neg;
            var diagonal_d: f64 = neg;
            var best: f64 = neg;
            const gap: f64 = if (i + 1 == q.len) -0.005 else -0.01;
            for (self.path.items, 0..) |cp, j| {
                const old_m = self.m.items[j];
                const old_d = self.d.items[j];
                var matched: f64 = neg;
                if (fold(needle) == fold(cp)) {
                    matched = if (i == 0) @as(f64, @floatFromInt(j)) * -0.005 + self.bonus.items[j] else @max(diagonal_m + self.bonus.items[j], diagonal_d + 1);
                }
                best = @max(matched, best + gap);
                self.d.items[j] = matched;
                self.m.items[j] = best;
                diagonal_m = old_m;
                diagonal_d = old_d;
            }
        }
        const result = self.m.items[n - 1];
        if (result == neg) return null;
        return if (q.len == n) std.math.inf(f64) else result;
    }
};

fn fold(cp: u21) u21 {
    return if (cp >= 'A' and cp <= 'Z') cp + ('a' - 'A') else cp;
}

fn isWord(cp: u21) bool {
    return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9');
}

/// fzy only rewards the start of a word: a match on a separator itself earns
/// nothing, which keeps `@fzy.zig` from ranking by the dot it happens to hit.
fn bonus(previous: u21, cp: u21) f64 {
    if (!isWord(cp)) return 0;
    if (previous == '/') return 0.9;
    if (previous == '-' or previous == '_' or previous == ' ') return 0.8;
    if (previous == '.') return 0.6;
    if (previous >= 'a' and previous <= 'z' and cp >= 'A' and cp <= 'Z') return 0.7;
    return 0;
}

test "fzy subsequences, bonuses, gaps and Unicode" {
    var scratch: Scratch = .{};
    defer scratch.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try scratch.initQuery(a, "ab");
    try std.testing.expectApproxEqAbs(@as(f64, 1.895), (try scratch.score(a, "abx")).?, 0.000001);
    try std.testing.expect((try scratch.score(a, "a_b")).? > (try scratch.score(a, "axxb")).?);
    try std.testing.expect((try scratch.score(a, "AB")).? == std.math.inf(f64));
    try std.testing.expect(try scratch.score(a, "ba") == null);
    try scratch.initQuery(a, "b");
    try std.testing.expectApproxEqAbs(@as(f64, 0.89), (try scratch.score(a, "a/b")).?, 0.000001);
    // Matching the separator itself is worth no bonus: only the character after
    // it starts a word, which is what fzy's bonus table says too.
    try scratch.initQuery(a, "/");
    try std.testing.expectApproxEqAbs(@as(f64, -0.01), (try scratch.score(a, "a/b")).?, 0.000001);
    try scratch.initQuery(a, ".");
    try std.testing.expectApproxEqAbs(@as(f64, -0.01), (try scratch.score(a, "a.b")).?, 0.000001);
    try scratch.initQuery(a, "é中");
    try std.testing.expect(try scratch.score(a, "é/中") != null);
    try std.testing.expect(try scratch.score(a, "É中") == null);
    try std.testing.expect(try scratch.score(a, "中é") == null);
}

test "an invalid query matches nothing and an empty one matches everything" {
    var scratch: Scratch = .{};
    defer scratch.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try scratch.initQuery(a, "\xff");
    try std.testing.expect(try scratch.score(a, "src/main.zig") == null);
    try scratch.initQuery(a, "");
    try std.testing.expectEqual(@as(f64, 0), (try scratch.score(a, "src/main.zig")).?);
}

test "scratch allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: Allocator) !void {
            var scratch: Scratch = .{};
            defer scratch.deinit(a);
            try scratch.initQuery(a, "sz");
            _ = try scratch.score(a, "src/zig.zig");
            _ = try scratch.score(a, "some/longer/path/zig.zig");
        }
    }.run, .{});
}
