//! Display width and terminal size.
//!
//! Width is measured in terminal cells, never bytes: this program is used with
//! CJK text, where one codepoint is two cells. Line wrapping that counts bytes
//! produces lines that overflow the terminal by a factor of two.

const std = @import("std");
const builtin = @import("builtin");
const wcwidth = @import("wcwidth").wcwidth;
const text = @import("text.zig");

/// Used when the terminal size cannot be read, and on Windows.
pub const default_columns: usize = 80;
/// Wrapping narrower than this leaves no room for content once a prefix has
/// been written, so a bogus terminal size is clamped up to it.
pub const min_columns: usize = 24;
/// Tab stops, for callers that expand tabs into spaces.
pub const tab_width: usize = 4;

/// A codepoint decoded from a byte slice, along with how many bytes it took.
/// An invalid sequence yields the offending byte with `valid == false`, so
/// callers can keep making progress through malformed input.
pub const Codepoint = struct {
    value: u21,
    len: usize,
    valid: bool,
};

/// Decode the codepoint starting at `index`. `index` must be in bounds.
pub fn decodeAt(bytes: []const u8, index: usize) Codepoint {
    const byte = bytes[index];
    if (byte < 0x80) return .{ .value = byte, .len = 1, .valid = true };

    const len = std.unicode.utf8ByteSequenceLength(byte) catch
        return .{ .value = byte, .len = 1, .valid = false };
    if (index + len > bytes.len) return .{ .value = byte, .len = 1, .valid = false };

    const value = std.unicode.utf8Decode(bytes[index..][0..len]) catch
        return .{ .value = byte, .len = 1, .valid = false };
    return .{ .value = value, .len = len, .valid = true };
}

/// Cells occupied by one decoded codepoint. Control characters and invalid
/// bytes are one cell rather than zero, so nothing can be used to hide width.
pub fn codepointWidth(cp: Codepoint) usize {
    if (!cp.valid) return 1;
    const w = wcwidth(cp.value);
    return if (w < 0) 1 else @intCast(w);
}

/// Cells occupied by `bytes` when printed.
///
/// SGR and OSC sequences count as nothing, so this measures bytes that has
/// already been styled as well as plain bytes. Callers that lay out columns
/// depend on that: a padded cell is measured after its colour codes are in it.
///
/// Malformed bytes are counted one cell each and iteration continues, rather
/// than collapsing the whole measurement to zero the way a single `Utf8View`
/// decode error would. A tab counts as one cell: callers that care about tab
/// stops expand them themselves, because the answer depends on the column the
/// tab starts at, which this function does not know.
pub fn width(bytes: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            i = text.skipAnsiEscape(bytes, i);
            continue;
        }
        const cp = decodeAt(bytes, i);
        i += cp.len;
        total += codepointWidth(cp);
    }
    return total;
}

/// Longest prefix of `text` that fits in `avail` columns, as a byte length and
/// always on a codepoint boundary.
///
/// Returns at least one codepoint's worth of bytes even when nothing fits, so a
/// caller looping over the remainder cannot fail to make progress. Trailing
/// zero-width codepoints are pulled into the chunk so that a combining mark or
/// a ZWJ sequence never starts the following line.
pub fn takeFit(bytes: []const u8, avail: usize) usize {
    if (bytes.len == 0) return 0;

    var i: usize = 0;
    var used: usize = 0;
    while (i < bytes.len) {
        const cp = decodeAt(bytes, i);
        const w = codepointWidth(cp);
        if (used + w > avail) break;
        used += w;
        i += cp.len;
    }
    if (i == 0) i = decodeAt(bytes, 0).len;

    while (i < bytes.len) {
        const cp = decodeAt(bytes, i);
        if (codepointWidth(cp) != 0) break;
        i += cp.len;
    }
    return i;
}

/// Columns a renderer may fill. One cell is left empty so that writing a full
/// line never leaves the terminal in the pending-wrap state, where the
/// following newline moves down two rows on several emulators.
pub fn usableWidth(cols: usize) usize {
    return if (cols <= min_columns) min_columns else cols - 1;
}

/// Terminal width in columns, or `default_columns` if it cannot be determined.
///
/// Deliberately does not fall back to a cursor-position report: that trick has
/// to read the reply from the same descriptor, which is not readable when the
/// output is a pipe (`zagent "q" | less`) and would consume a line of the
/// user's input when it is a redirected file.
pub fn columns(file: std.Io.File) usize {
    return switch (builtin.os.tag) {
        // Zig 0.16's std has no GetConsoleScreenBufferInfo, so there is no
        // console size to query here. Wrapping at 80 costs only the hanging
        // indent, and terminal soft-wrap keeps the text readable.
        .windows => default_columns,
        else => blk: {
            var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            const rc = std.posix.system.ioctl(
                file.handle,
                std.posix.T.IOCGWINSZ,
                @intFromPtr(&ws),
            );
            if (std.posix.errno(rc) != .SUCCESS) break :blk default_columns;
            if (ws.col == 0) break :blk default_columns;
            break :blk @min(@as(usize, ws.col), 1000);
        },
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "width counts cells, not bytes" {
    try expectEqual(0, width(""));
    try expectEqual(5, width("hello"));
    // Two cells per CJK codepoint, three bytes each.
    try expectEqual(8, width("你好世界"));
    try expectEqual(10, width("hi 你好 ok"));
}

test "width handles combining marks and invalid bytes" {
    // "e" + U+0301 COMBINING ACUTE ACCENT: one visible cell, two codepoints.
    try expectEqual(1, width("e\xcc\x81"));
    // Stray bytes count one cell each and do not stop iteration.
    try expectEqual(3, width("a\xffb"));
    try expectEqual(7, width("a\xffb\xfec\xffd"));
    // A truncated multi-byte sequence degrades to one cell per leftover byte
    // rather than reading past the end of the buffer.
    try expectEqual(2, width("\xe4\xbd"));
}

test "width ignores escape sequences" {
    // A padded column is measured after its colour codes are already in it.
    try expectEqual(5, width("\x1b[1mhello\x1b[0m"));
    try expectEqual(0, width("\x1b[0m"));
    try expectEqual(4, width("\x1b]8;;https://e.com\x1b\\\x1b[4m你好\x1b[0m"));
}

test "width counts a tab as one cell" {
    try expectEqual(1, width("\t"));
    try expectEqual(3, width("a\tb"));
}

test "decodeAt reports length and validity" {
    const ascii = decodeAt("abc", 0);
    try expectEqual(1, ascii.len);
    try expect(ascii.valid);

    const cjk = decodeAt("你", 0);
    try expectEqual(3, cjk.len);
    try expect(cjk.valid);
    try expectEqual(@as(u21, 0x4f60), cjk.value);

    const bad = decodeAt("a\xffb", 1);
    try expectEqual(1, bad.len);
    try expect(!bad.valid);
}

test "usableWidth leaves a cell and has a floor" {
    try expectEqual(79, usableWidth(80));
    try expectEqual(24, usableWidth(25));
    // At and below the floor the result stops shrinking rather than going to zero.
    try expectEqual(min_columns, usableWidth(24));
    try expectEqual(min_columns, usableWidth(20));
    try expectEqual(min_columns, usableWidth(0));
}
