//! The wordmark drawn above the first prompt.
//!
//! All colours come from the terminal's ANSI palette, never an RGB or indexed
//! custom palette. Redirected output, TERM=dumb and NO_COLOR stay uncoloured.

const std = @import("std");
const text = @import("text.zig");
const style = @import("style.zig");

pub const ColorMode = enum { none, ansi };

/// Two spaces of breathing room, matching the lines following the wordmark.
pub const indent = "  ";
pub const tagline = "✦ an AI agent in your terminal";
const compact = "✦ zagent";

const art = [6][]const u8{
    "███████╗ █████╗  ██████╗ ███████╗███╗   ██╗████████╗",
    "╚══███╔╝██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝",
    "  ███╔╝ ███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║",
    " ███╔╝  ██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║",
    "███████╗██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║",
    "╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝",
};

pub const width: usize = width: {
    @setEvalBranchQuota(10_000);
    var widest: usize = 0;
    for (art) |row| widest = @max(widest, cells(row));
    break :width widest;
};
pub const height: usize = art.len;

pub const Options = struct {
    mode: ColorMode,
    /// Use the compact wordmark when the full letterforms would wrap.
    columns: usize = 80,
};

/// Draw the wordmark and tagline with a blank line before them.
pub fn write(w: *std.Io.Writer, options: Options) !void {
    try w.writeByte('\n');
    if (options.columns < width + indent.len) {
        try writeWord(w, options.mode, compact);
        return;
    }
    for (art) |row| try writeWord(w, options.mode, row);
    try writeWord(w, options.mode, tagline);
}

fn writeWord(w: *std.Io.Writer, mode: ColorMode, word: []const u8) !void {
    try w.writeAll(indent);
    if (mode == .ansi) try w.writeAll(style.CYAN);
    try w.writeAll(word);
    if (mode == .ansi) try w.writeAll(style.RESET);
    try w.writeByte('\n');
}

/// Use only the terminal's theme-defined palette, regardless of COLORTERM.
pub fn detect(env: *const std.process.Environ.Map, supported: bool) ColorMode {
    if (!supported) return .none;
    if (env.get("NO_COLOR")) |value| {
        if (value.len > 0) return .none;
    }
    if (env.get("TERM")) |value| {
        if (std.mem.eql(u8, value, "dumb")) return .none;
    }
    return .ansi;
}

fn cells(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn render(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try write(&aw.writer, options);
    return aw.toOwnedSlice();
}

test "plain wordmark preserves the letterforms and tagline" {
    const out = try render(std.testing.allocator, .{ .mode = .none });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) == null);
    var lines = std.mem.splitScalar(u8, out, '\n');
    try std.testing.expectEqualStrings("", lines.next().?);
    for (art) |row| {
        const line = lines.next().?;
        try std.testing.expect(std.mem.startsWith(u8, line, indent));
        try std.testing.expectEqualStrings(row, line[indent.len..]);
    }
    try std.testing.expectEqualStrings(indent ++ tagline, lines.next().?);
}

test "ANSI wordmark uses only the terminal palette and preserves glyphs" {
    const out = try render(std.testing.allocator, .{ .mode = .ansi });
    defer std.testing.allocator.free(out);
    const plain = try render(std.testing.allocator, .{ .mode = .none });
    defer std.testing.allocator.free(plain);
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try text.writeSanitized(&aw.writer, out);
    try std.testing.expectEqualStrings(plain, aw.written());
    var lines = std.mem.splitScalar(u8, out, '\n');
    _ = lines.next();
    for (0..height + 1) |_| {
        const line = lines.next().?;
        try std.testing.expect(std.mem.startsWith(u8, line, indent ++ style.CYAN));
        try std.testing.expect(std.mem.endsWith(u8, line, style.RESET));
        // Exactly one theme colour and one reset per line; no custom colours.
        const content = line[(indent.len + style.CYAN.len)..(line.len - style.RESET.len)];
        try std.testing.expect(std.mem.indexOfScalar(u8, content, 0x1b) == null);
    }
}

test "narrow terminals use the compact wordmark" {
    inline for (.{ ColorMode.none, ColorMode.ansi }) |mode| {
        const out = try render(std.testing.allocator, .{ .mode = mode, .columns = width + indent.len - 1 });
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, compact) != null);
        try std.testing.expect(std.mem.indexOf(u8, out, tagline) == null);
        try std.testing.expect(std.mem.indexOf(u8, out, art[0]) == null);
    }
}

test "colour detection respects terminal support and NO_COLOR, not truecolor" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(ColorMode.none, detect(&env, false));
    try std.testing.expectEqual(ColorMode.ansi, detect(&env, true));
    inline for (.{ "truecolor", "24bit" }) |value| {
        try env.put("COLORTERM", value);
        try std.testing.expectEqual(ColorMode.ansi, detect(&env, true));
    }
    try env.put("NO_COLOR", "1");
    try std.testing.expectEqual(ColorMode.none, detect(&env, true));
    try env.put("NO_COLOR", "");
    try std.testing.expectEqual(ColorMode.ansi, detect(&env, true));
    try env.put("TERM", "dumb");
    try std.testing.expectEqual(ColorMode.none, detect(&env, true));
}
