//! Terminal output sequences and SGR styles. Import this module instead of
//! embedding escape literals at call sites. Parameterized sequences are
//! std.fmt templates (1-based terminal coordinates).
//! Colours use the terminal theme's standard ANSI palette only; do not add
//! custom RGB colours or fixed extended-palette indices.
//!
//! These are plain `const` slices rather than functions or `[N:0]u8` values on
//! purpose: `PROMPT` in `main.zig` and `CHOICE_PROMPT` in `agent.zig` build
//! their strings with comptime `++`, and the folding behaves differently for
//! other types.

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const ITALIC = "\x1b[3m";
pub const UNDERLINE = "\x1b[4m";
pub const STRIKE = "\x1b[9m";

pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";
pub const MAGENTA = "\x1b[35m";
pub const CYAN = "\x1b[36m";
pub const WHITE = "\x1b[37m";

pub const BOLD_CYAN = "\x1b[1;36m";
pub const INVERSE = "\x1b[7m";
pub const NO_INVERSE = "\x1b[27m";

pub const HIDE_CURSOR = "\x1b[?25l";
pub const SHOW_CURSOR = "\x1b[?25h";
pub const SAVE_CURSOR = "\x1b7";
pub const RESTORE_CURSOR = "\x1b8";
pub const HOME = "\x1b[H";
pub const HOME_POSITION = "\x1b[1;1H";
pub const CURSOR_POSITION = "\x1b[{d};{d}H";
pub const ROW_START = "\x1b[{d};1H";
pub const CURSOR_UP = "\x1b[{d}A";
pub const CURSOR_DOWN = "\x1b[{d}B";
pub const CURSOR_RIGHT = "\x1b[{d}C";
pub const CURSOR_LEFT = "\x1b[{d}D";
pub const UP_ONE = "\x1b[1A";
pub const DOWN_ONE = "\x1b[1B";
pub const RIGHT_MARGIN = "\x1b[999C";
pub const QUERY_CURSOR = "\x1b[6n";
pub const CSI = "\x1b[";

pub const CLEAR_LINE = "\x1b[2K";
pub const CLEAR_LINE_END = "\x1b[0K";
pub const ERASE_LINE_END = "\x1b[K";
pub const CLEAR_SCREEN_END = "\x1b[0J";
pub const CLEAR_SCREEN = "\x1b[2J";
pub const SCROLL_REGION = "\x1b[1;{d}r";
pub const RESET_SCROLL_REGION = "\x1b[r";

// Synchronized updates are not nestable; the caller owns frame boundaries.
pub const SYNC_BEGIN = "\x1b[?2026h";
pub const SYNC_END = "\x1b[?2026l";
pub const ALT_ON = "\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h";
pub const ALT_OFF = "\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?1049l";
pub const PASTE_ON = "\x1b[?2004h";
pub const PASTE_OFF = "\x1b[?2004l";
pub const PASTE_END = "\x1b[201~";

pub const SAVE_TITLE = "\x1b[22;2t";
pub const RESTORE_TITLE = "\x1b[23;2t";
pub const TITLE_PREFIX = "\x1b]2;";
pub const CLIPBOARD_PREFIX = "\x1b]52;c;";
pub const OSC_END = "\x07";

pub const Color = enum { none, red, green, yellow, blue, magenta, cyan, white };

/// SGR attributes as data, so nested renderer styles can be compared and merged.
pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    color: Color = .none,

    pub fn isPlain(self: Style) bool {
        return @import("std").meta.eql(self, Style{});
    }

    pub fn overlay(base: Style, top: Style) Style {
        return .{
            .bold = base.bold or top.bold,
            .dim = base.dim or top.dim,
            .italic = base.italic or top.italic,
            .underline = base.underline or top.underline,
            .strike = base.strike or top.strike,
            .color = if (top.color != .none) top.color else base.color,
        };
    }

    /// Whether enabling self preserves all attributes of old without a reset.
    pub fn covers(self: Style, old: Style) bool {
        return (!old.bold or self.bold) and
            (!old.dim or self.dim) and
            (!old.italic or self.italic) and
            (!old.underline or self.underline) and
            (!old.strike or self.strike) and
            (old.color == .none or self.color == old.color);
    }

    /// Write the opening sequence into buf and return it; empty when plain.
    pub fn open(self: Style, buf: *[24]u8) []const u8 {
        if (self.isPlain()) return "";

        var n: usize = 0;
        for (CSI) |byte| {
            buf[n] = byte;
            n += 1;
        }

        const parts = [_]struct { on: bool, code: []const u8 }{
            .{ .on = self.bold, .code = "1" },
            .{ .on = self.dim, .code = "2" },
            .{ .on = self.italic, .code = "3" },
            .{ .on = self.underline, .code = "4" },
            .{ .on = self.strike, .code = "9" },
            .{ .on = self.color != .none, .code = colorCode(self.color) },
        };

        var first = true;
        for (parts) |part| {
            if (!part.on) continue;
            if (!first) {
                buf[n] = ';';
                n += 1;
            }
            first = false;
            for (part.code) |ch| {
                buf[n] = ch;
                n += 1;
            }
        }

        buf[n] = 'm';
        n += 1;
        return buf[0..n];
    }

    fn colorCode(color: Color) []const u8 {
        return switch (color) {
            .none => "",
            .red => "31",
            .green => "32",
            .yellow => "33",
            .blue => "34",
            .magenta => "35",
            .cyan => "36",
            .white => "37",
        };
    }
};

test "terminal templates preserve wire format" {
    const std = @import("std");
    var buf: [128]u8 = undefined;
    const frame = try std.fmt.bufPrint(&buf, SYNC_BEGIN ++ HIDE_CURSOR ++ ROW_START ++ CLEAR_LINE ++ CURSOR_POSITION ++ SHOW_CURSOR ++ SYNC_END, .{ 23, 24, 4 });
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?25l\x1b[23;1H\x1b[2K\x1b[24;4H\x1b[?25h\x1b[?2026l", frame);
    const moves = try std.fmt.bufPrint(&buf, CURSOR_UP ++ CURSOR_DOWN ++ CURSOR_LEFT ++ CURSOR_RIGHT ++ SCROLL_REGION, .{ 2, 3, 4, 5, 22 });
    try std.testing.expectEqualStrings("\x1b[2A\x1b[3B\x1b[4D\x1b[5C\x1b[1;22r", moves);
}

test "SGR styles match palette constants" {
    const std = @import("std");
    var buf: [24]u8 = undefined;
    const cases = [_]struct { style: Style, sequence: []const u8 }{
        .{ .style = .{}, .sequence = "" },
        .{ .style = .{ .bold = true }, .sequence = BOLD },
        .{ .style = .{ .dim = true }, .sequence = DIM },
        .{ .style = .{ .italic = true }, .sequence = ITALIC },
        .{ .style = .{ .underline = true }, .sequence = UNDERLINE },
        .{ .style = .{ .strike = true }, .sequence = STRIKE },
        .{ .style = .{ .color = .red }, .sequence = RED },
        .{ .style = .{ .color = .green }, .sequence = GREEN },
        .{ .style = .{ .color = .yellow }, .sequence = YELLOW },
        .{ .style = .{ .color = .blue }, .sequence = BLUE },
        .{ .style = .{ .color = .magenta }, .sequence = MAGENTA },
        .{ .style = .{ .color = .cyan }, .sequence = CYAN },
        .{ .style = .{ .color = .white }, .sequence = WHITE },
        .{ .style = .{ .bold = true, .color = .cyan }, .sequence = BOLD_CYAN },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.sequence, case.style.open(&buf));
    try std.testing.expectEqualStrings(
        "\x1b[1;2;3;4;9;37m",
        (Style{ .bold = true, .dim = true, .italic = true, .underline = true, .strike = true, .color = .white }).open(&buf),
    );
}
