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
