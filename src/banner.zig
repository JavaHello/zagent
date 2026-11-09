//! The wordmark drawn above the first prompt.
//!
//! The letterforms are one block font, six rows tall, and the colour is decided
//! per cell: a diagonal gradient runs from cyan at the top left to pink at the
//! bottom right, so the wordmark reads as a single lit object rather than six
//! flat coloured rows. Colour degrades to the 256-colour palette, or to no
//! colour at all, when the terminal cannot do better (`TERM=dumb`, a redirected
//! stdout, `NO_COLOR`).

const std = @import("std");
const text = @import("text.zig");

/// How much colour the terminal can take.
pub const ColorMode = enum { none, ansi256, truecolor };

/// Two spaces of breathing room, matching the indentation of the lines that
/// follow the wordmark.
pub const indent = "  ";

/// One tagline, phrased as what the program is rather than what it does.
pub const tagline = "✦ an AI agent in your terminal";

/// Shown instead of the letterforms when the terminal is too narrow to hold
/// them without wrapping.
const compact = "✦ zagent";

/// The wordmark, one row per line, trailing spaces already trimmed. Rows are
/// measured in cells, so a row's byte length is longer than its width.
const art = [6][]const u8{
    "███████╗ █████╗  ██████╗ ███████╗███╗   ██╗████████╗",
    "╚══███╔╝██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝",
    "  ███╔╝ ███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║",
    " ███╔╝  ██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║",
    "███████╗██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║",
    "╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝",
};

/// Width of the wordmark in terminal cells, not bytes.
pub const width: usize = width: {
    var widest: usize = 0;
    for (art) |row| widest = @max(widest, cells(row));
    break :width widest;
};

/// Height of the wordmark in rows.
pub const height: usize = art.len;

pub const Options = struct {
    mode: ColorMode,
    /// Terminal width in cells. The one-line wordmark is used below
    /// `width + indent.len`.
    columns: usize = 80,
};

/// Draw the wordmark and its tagline, each line ending in a newline. The first
/// line is blank, so the wordmark is not glued to whatever was printed before.
pub fn write(w: *std.Io.Writer, options: Options) !void {
    try w.writeByte('\n');
    if (options.columns < width + indent.len) {
        try writeWord(w, options.mode, compact);
        return;
    }
    if (options.mode == .none) {
        for (art) |row| try w.print("{s}{s}\n", .{ indent, row });
    } else {
        for (art, 0..) |row, y| {
            try w.writeAll(indent);
            try writeRow(w, options.mode, row, y);
            try w.writeAll("\x1b[0m\n");
        }
    }
    try writeWord(w, options.mode, tagline);
}

fn writeWord(w: *std.Io.Writer, mode: ColorMode, word: []const u8) !void {
    try w.writeAll(indent);
    if (mode == .none) {
        try w.print("{s}\n", .{word});
        return;
    }
    try writeSgr(w, mode, accent);
    try w.writeAll(word);
    try w.writeAll("\x1b[0m\n");
}

/// One row of letterforms, one colour per glyph. Spaces take the colour of the
/// glyph before them and so cost no escape sequence of their own.
fn writeRow(w: *std.Io.Writer, mode: ColorMode, row: []const u8, y: usize) !void {
    var last: ?Rgb = null;
    var x: usize = 0;
    var i: usize = 0;
    while (i < row.len) {
        const len = std.unicode.utf8ByteSequenceLength(row[i]) catch 1;
        const glyph = row[i..@min(i + len, row.len)];
        i += glyph.len;
        if (!std.mem.eql(u8, glyph, " ")) {
            const rgb = colorAt(x, y);
            if (last == null or !last.?.eql(rgb)) {
                try writeSgr(w, mode, rgb);
                last = rgb;
            }
        }
        try w.writeAll(glyph);
        x += 1;
    }
}

const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

/// The gradient, from aqua to fuchsia. Intermediate stops keep the middle of
/// the word from turning grey the way a two-colour blend does.
const stops = [_]Rgb{
    .{ .r = 34, .g = 211, .b = 238 },
    .{ .r = 96, .g = 165, .b = 250 },
    .{ .r = 167, .g = 139, .b = 250 },
    .{ .r = 244, .g = 114, .b = 182 },
};

/// Colour of the tagline and the one-line wordmark: the lavender the letters
/// pass through on their way to pink.
const accent: Rgb = stops[2];

/// The colour at cell (x, y) of the wordmark.
///
/// The blend is weighted towards the horizontal — 60% across, 40% down — so the
/// letters differ from their neighbours left to right while the rows still
/// darken together, which is what makes the shape read as one solid.
fn colorAt(x: usize, y: usize) Rgb {
    const last_col: usize = width - 1;
    const last_row: usize = height - 1;
    const across = (if (x < last_col) x else last_col) * 600 / last_col;
    const down = (if (y < last_row) y else last_row) * 400 / last_row;
    return sample(across + down);
}

/// Colour at position `t` of the gradient, measured in thousandths of the
/// whole run so the arithmetic stays integral.
fn sample(t: usize) Rgb {
    const spans = stops.len - 1;
    const raw = t * spans / 1000;
    const segment = if (raw < spans - 1) raw else spans - 1;
    const offset = t * spans - segment * 1000;
    return mix(stops[segment], stops[segment + 1], offset);
}

fn mix(from: Rgb, to: Rgb, t: usize) Rgb {
    return .{
        .r = channel(from.r, to.r, t),
        .g = channel(from.g, to.g, t),
        .b = channel(from.b, to.b, t),
    };
}

fn channel(from: u8, to: u8, t: usize) u8 {
    const a: i32 = from;
    const b: i32 = to;
    const weight: i32 = @intCast(t);
    return @intCast(@divTrunc(a * (1000 - weight) + b * weight + 500, 1000));
}

fn writeSgr(w: *std.Io.Writer, mode: ColorMode, rgb: Rgb) !void {
    switch (mode) {
        .truecolor => try w.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
        .ansi256 => try w.print("\x1b[38;5;{d}m", .{ansi256(rgb)}),
        .none => {},
    }
}

/// The xterm-256 index closest to `c`.
///
/// The cube alone would drag muted colours towards the nearest saturated one,
/// so the grey ramp is tried as well and whichever is nearer in RGB wins.
fn ansi256(c: Rgb) u8 {
    const cube = [6]u8{ 0, 95, 135, 175, 215, 255 };

    const r = nearestStep(cube, c.r);
    const g = nearestStep(cube, c.g);
    const b = nearestStep(cube, c.b);
    const cube_index: u8 = @intCast(16 + 36 * @as(u16, r) + 6 * @as(u16, g) + b);
    const cube_rgb = Rgb{ .r = cube[r], .g = cube[g], .b = cube[b] };

    const mean = (@as(u16, c.r) + @as(u16, c.g) + @as(u16, c.b)) / 3;
    const grey_step: u8 = if (mean > 238) 23 else @intCast(@divTrunc(@as(i32, @intCast(mean)) - 3, 10));
    const grey_index: u8 = @intCast(232 + @as(u16, grey_step));
    const grey_level: u8 = @intCast(8 + 10 * @as(u16, grey_step));
    const grey_rgb = Rgb{ .r = grey_level, .g = grey_level, .b = grey_level };

    return if (distance(grey_rgb, c) < distance(cube_rgb, c)) grey_index else cube_index;
}

fn nearestStep(cube: [6]u8, value: u8) u8 {
    var best: u8 = 0;
    var best_distance: u32 = std.math.maxInt(u32);
    for (cube, 0..) |level, i| {
        const delta = @abs(@as(i32, level) - @as(i32, value));
        const squared: u32 = @intCast(delta * delta);
        if (squared < best_distance) {
            best_distance = squared;
            best = @intCast(i);
        }
    }
    return best;
}

fn distance(a: Rgb, b: Rgb) u32 {
    const dr: i32 = @as(i32, a.r) - @as(i32, b.r);
    const dg: i32 = @as(i32, a.g) - @as(i32, b.g);
    const db: i32 = @as(i32, a.b) - @as(i32, b.b);
    return @intCast(dr * dr + dg * dg + db * db);
}

/// Pick the richest colour the terminal is known to handle. `supported` is the
/// editor's own verdict, which already rules out `TERM=dumb`.
pub fn detect(env: *const std.process.Environ.Map, supported: bool) ColorMode {
    if (!supported) return .none;
    // https://no-color.org: any non-empty value asks for no colour.
    if (env.get("NO_COLOR")) |value| {
        if (value.len > 0) return .none;
    }
    if (env.get("COLORTERM")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "truecolor") or std.ascii.eqlIgnoreCase(value, "24bit")) {
            return .truecolor;
        }
    }
    return .ansi256;
}

/// Cells in `row`: one per codepoint, which holds for the block and box-drawing
/// characters the wordmark is built from.
fn cells(row: []const u8) usize {
    var count: usize = 0;
    for (row) |byte| {
        if (byte & 0xc0 != 0x80) count += 1;
    }
    return count;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "the letterforms are six rows of one width" {
    try expectEqual(52, width);
    for (art) |row| try expect(cells(row) <= width);

    // The first two rows are the widest, and they are what fixes the width.
    try expectEqual(width, cells(art[0]));
    try expectEqual(width, cells(art[1]));
}

test "a plain wordmark is only the art and the tagline" {
    var buffer: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(&w, .{ .mode = .none });
    const drawn = w.buffered();

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    try expected.append(std.testing.allocator, '\n');
    for (art) |row| {
        try expected.appendSlice(std.testing.allocator, indent);
        try expected.appendSlice(std.testing.allocator, row);
        try expected.append(std.testing.allocator, '\n');
    }
    try expected.appendSlice(std.testing.allocator, indent ++ tagline ++ "\n");

    try expectEqualStrings(expected.items, drawn);
}

test "colouring the wordmark changes no glyph" {
    inline for (.{ ColorMode.truecolor, ColorMode.ansi256 }) |mode| {
        var buffer: [64 * 1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try write(&w, .{ .mode = mode });
        const drawn = w.buffered();

        try expect(std.mem.indexOf(u8, drawn, "\x1b[") != null);

        // Stripping the SGR sequences has to leave exactly the plain drawing.
        var plain: [8192]u8 = undefined;
        var len: usize = 0;
        var i: usize = 0;
        while (i < drawn.len) {
            if (drawn[i] == 0x1b) {
                i = text.skipAnsiEscape(drawn, i);
                continue;
            }
            plain[len] = drawn[i];
            len += 1;
            i += 1;
        }

        var buffer2: [8192]u8 = undefined;
        var w2 = std.Io.Writer.fixed(&buffer2);
        try write(&w2, .{ .mode = .none });
        try expectEqualStrings(w2.buffered(), plain[0..len]);
    }
}

test "every line is reset before its newline" {
    var buffer: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(&w, .{ .mode = .truecolor });

    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    var coloured: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\x1b[") == null) continue;
        coloured += 1;
        try expect(std.mem.endsWith(u8, line, "\x1b[0m"));
    }
    // Six rows of letters plus the tagline.
    try expectEqual(height + 1, coloured);
}

test "the gradient starts cool and ends warm" {
    const first = colorAt(0, 0);
    const last = colorAt(width - 1, height - 1);
    try expect(first.b > first.r);
    try expect(last.r > last.b);
    // Moving right and moving down both advance the gradient.
    try expect(!colorAt(0, 0).eql(colorAt(width - 1, 0)));
    try expect(!colorAt(0, 0).eql(colorAt(0, height - 1)));
}

test "the palette index matches the nearest xterm colour" {
    try expectEqual(16, ansi256(.{ .r = 0, .g = 0, .b = 0 }));
    try expectEqual(231, ansi256(.{ .r = 255, .g = 255, .b = 255 }));
    // A mid grey belongs to the grey ramp, not to the cube's corners.
    try expectEqual(244, ansi256(.{ .r = 128, .g = 128, .b = 128 }));
}

test "truecolor is only claimed when the terminal says so" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try expectEqual(ColorMode.none, detect(&env, false));
    try expectEqual(ColorMode.ansi256, detect(&env, true));

    try env.put("COLORTERM", "truecolor");
    try expectEqual(ColorMode.truecolor, detect(&env, true));

    try env.put("COLORTERM", "24bit");
    try expectEqual(ColorMode.truecolor, detect(&env, true));

    try env.put("NO_COLOR", "1");
    try expectEqual(ColorMode.none, detect(&env, true));

    // An empty NO_COLOR is what `NO_COLOR= ` leaves behind and means nothing.
    try env.put("NO_COLOR", "");
    try expectEqual(ColorMode.truecolor, detect(&env, true));
}

test "a narrow terminal gets the one-line wordmark" {
    var buffer: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(&w, .{ .mode = .none, .columns = 40 });
    try expectEqualStrings("\n" ++ indent ++ compact ++ "\n", w.buffered());
}
