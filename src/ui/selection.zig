//! SGR mouse parsing and terminal-cell to transcript selection mapping.
const std = @import("std");
const term = @import("term.zig");
const vt = @import("../util/terminal/ansi.zig");

pub const Mouse = struct { button: usize, x: usize, y: usize, release: bool };
pub fn parse(report: []const u8) ?Mouse {
    if (report.len < 6) return null;
    const last = report[report.len - 1];
    if (last != 'M' and last != 'm') return null;
    var parts = std.mem.splitScalar(u8, report[0 .. report.len - 1], ';');
    const button = std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch return null;
    const x = std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null or x == 0 or y == 0) return null;
    return .{ .button = button, .x = x, .y = y, .release = last == 'm' };
}

/// Offset at a cell; `after` includes the glyph under the pointer.
pub fn offset(bytes: []const u8, cell: usize, after: bool) usize {
    var i: usize = 0;
    var col: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            i = vt.skipAnsiEscape(bytes, i);
            continue;
        }
        if (bytes[i] == '\n' or bytes[i] == '\r') return i;
        const cp = term.decodeAt(bytes, i);
        const width = term.codepointWidth(cp);
        if (width > 0 and col + width > cell) {
            if (!after) return i;
            i += cp.len;
            while (i < bytes.len and bytes[i] != 0x1b) {
                const next = term.decodeAt(bytes, i);
                if (term.codepointWidth(next) != 0) break;
                i += next.len;
            }
            return i;
        }
        col += width;
        i += cp.len;
    }
    return i;
}

pub fn plain(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            i = vt.skipAnsiEscape(bytes, i);
            continue;
        }
        const cp = term.decodeAt(bytes, i);
        if (cp.valid and (cp.value >= 32 or cp.value == '\n' or cp.value == '\t'))
            try out.appendSlice(a, bytes[i..][0..cp.len]);
        i += cp.len;
    }
    return out.toOwnedSlice(a);
}

test "mouse reports validate coordinates and distinguish drag and release" {
    try std.testing.expectEqual(@as(usize, 32), parse("32;10;20M").?.button);
    try std.testing.expect(parse("0;10;20m").?.release);
    for ([_][]const u8{ "0;0;1M", "0;1;2;3M", "0;1;2X", "bad" }) |s|
        try std.testing.expect(parse(s) == null);
}

test "selection uses cells, preserves Unicode, and removes styling" {
    const s = "\x1b[31m你é好\x1b[0m\n";
    const start = offset(s, 1, false);
    const end = offset(s, 2, true);
    const p = try plain(std.testing.allocator, s[start..end]);
    defer std.testing.allocator.free(p);
    try std.testing.expectEqualStrings("你é", p);
    try std.testing.expectEqual(@as(usize, 3), try std.unicode.utf8CountCodepoints(p));
}
