const std = @import("std");

/// Shorten `source` to at most `max` bytes without splitting a UTF-8 character.
pub fn truncateUtf8(source: []const u8, max: usize) []const u8 {
    if (source.len <= max) return source;
    var end = max;
    while (end > 0 and source[end] & 0xc0 == 0x80) : (end -= 1) {}
    return source[0..end];
}

pub fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The absolute path of a test's fixture directory.
pub fn fixturePath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(std.testing.io, buf)];
}

/// Assert the argv a search tool would run, element by element. Comparing the
/// two slices directly would compare pointers rather than the text.
pub fn expectArgv(expected: []const []const u8, argv: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try std.testing.expectEqualStrings(want, got);
}
