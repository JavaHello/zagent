const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqualSlices = std.testing.expectEqualSlices;

const wcwidth = @import("../unicode_width/wcwidth.zig").wcwidth;

pub fn width(s: []const u8) usize {
    var result: usize = 0;

    var escape_seq = false;
    const view = std.unicode.Utf8View.init(s) catch return 0;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        if (escape_seq) {
            if (codepoint == 'm') {
                escape_seq = false;
            }
        } else {
            if (codepoint == '\x1b') {
                escape_seq = true;
            } else {
                const wcw = wcwidth(codepoint);
                if (wcw < 0) return 0;
                result += @intCast(wcw);
            }
        }
    }

    return result;
}

/// The byte offset just past the part of `buf` that fits in `cells`, counted
/// the way `width` counts cells: an SGR sequence between ESC and its `m` takes
/// none.
///
/// A line being edited is cut at a cell. Mapping every character of the line to
/// its byte offset for that cut was an allocation the length of the line on
/// every keystroke; this is one pass and none.
pub fn fitEnd(buf: []const u8, cells: usize) !usize {
    var used: usize = 0;
    var escaped = false;
    var fit: usize = 0;
    var offset: usize = 0;
    const view = try std.unicode.Utf8View.init(buf);
    var iter = view.iterator();
    while (iter.nextCodepointSlice()) |cp| {
        // The character does not fit: the line is cut before it, so no cell of
        // a wide character is ever left dangling past the edge.
        if (used > cells) return fit;
        fit = offset;
        if (escaped) {
            if (cp.len == 1 and cp[0] == 'm') escaped = false;
        } else if (cp.len == 1 and cp[0] == '\x1b') {
            escaped = true;
        } else {
            const scalar = if (cp.len == 1) @as(u21, cp[0]) else std.unicode.utf8Decode(cp) catch return fit;
            const width_of = wcwidth(scalar);
            // A control character makes `width` call the whole line zero
            // cells wide, which is a line there is no cutting.
            if (width_of < 0) return 0;
            used += @intCast(width_of);
        }
        offset += cp.len;
    }
    return if (used <= cells) buf.len else fit;
}

/// The byte offset from which the rest of `buf` fits in `cells`, `total` being
/// how wide all of it is.
pub fn fitStart(buf: []const u8, cells: usize, total: usize) !usize {
    const limit = total -| cells;
    var used: usize = 0;
    var escaped = false;
    var offset: usize = 0;
    const view = try std.unicode.Utf8View.init(buf);
    var iter = view.iterator();
    while (iter.nextCodepointSlice()) |cp| {
        if (used >= limit) return offset;
        if (escaped) {
            if (cp.len == 1 and cp[0] == 'm') escaped = false;
        } else if (cp.len == 1 and cp[0] == '\x1b') {
            escaped = true;
        } else {
            const scalar = if (cp.len == 1) @as(u21, cp[0]) else std.unicode.utf8Decode(cp) catch return 0;
            const width_of = wcwidth(scalar);
            if (width_of < 0) return 0;
            used += @intCast(width_of);
        }
        offset += cp.len;
    }
    return buf.len;
}

test "a cell of the line is a byte offset, and an escape sequence takes none" {
    // ASCII: one cell, one byte.
    try std.testing.expectEqual(@as(usize, 0), try fitEnd("abc", 0));
    try std.testing.expectEqual(@as(usize, 1), try fitEnd("abc", 1));
    try std.testing.expectEqual(@as(usize, 2), try fitEnd("abc", 2));
    try std.testing.expectEqual(@as(usize, 3), try fitEnd("abc", 3));
    // A two-cell character that does not fit is left out whole.
    try std.testing.expectEqual(@as(usize, 3), try fitEnd("你好", 3));
    try std.testing.expectEqual(@as(usize, 0), try fitEnd("你好", 1));
    // Colours take no cells, at either end of the line.
    try std.testing.expectEqual(@as(usize, 5), try fitEnd("\x1b[1mab", 1));
    try std.testing.expectEqual(@as(usize, 6), try fitEnd("ab\x1b[0m", 2));
    try std.testing.expectEqual(@as(usize, 0), try fitEnd("a\tb", 1));

    // The other end: where the part that fits stops starting.
    try std.testing.expectEqual(@as(usize, 3), try fitStart("你好", 3, 4));
    try std.testing.expectEqual(@as(usize, 1), try fitStart("abc", 2, 3));
    try std.testing.expectEqual(@as(usize, 0), try fitStart("abc", 3, 3));
    try std.testing.expectEqual(@as(usize, 0), try fitStart("\x1b[1mab", 2, 2));
    // A line that has to be cut is cut inside its text, after the colours.
    try std.testing.expectEqual(@as(usize, 5), try fitStart("\x1b[1mab", 1, 2));
}

test "editor measures colored multilingual prompts" {
    try std.testing.expectEqual(@as(usize, 6), width("\x1b[1;32m❯\x1b[0m 中文"));
    try std.testing.expectEqual(@as(usize, 1), width("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), width("😀"));
    try std.testing.expectEqual(@as(usize, 0), width(""));
}

test "editor rejects invalid UTF8 and control widths" {
    try std.testing.expectEqual(@as(usize, 0), width("\xff"));
    try std.testing.expectEqual(@as(usize, 0), width("abc\t"));
}
