//! Sanitising text that came from outside this program.
//!
//! Both tool output and model replies can carry raw control bytes. On a
//! terminal those are not a cosmetic problem: a CSI sequence can move the
//! cursor or clear the screen, OSC 52 can write the user's clipboard, and
//! OSC 8 can forge a hyperlink whose visible text is not its target. Everything
//! printed therefore goes through these helpers, including text inside a code
//! fence — a fence is not a licence to pass escapes through.

const std = @import("std");

/// Render a stray byte as a `\xNN` escape into `buf`, which must be 4 bytes.
pub fn escapeByte(buf: *[4]u8, byte: u8) []const u8 {
    const hex = "0123456789ABCDEF";
    buf.* = .{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] };
    return buf;
}

/// Index just past the escape sequence starting at `raw[start]`, which must be
/// ESC. A malformed or truncated sequence consumes what is there and returns an
/// index in bounds, so callers always make progress.
pub fn skipAnsiEscape(raw: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= raw.len) return i;

    switch (raw[i]) {
        '[' => {
            i += 1;
            while (i < raw.len) : (i += 1) {
                const ch = raw[i];
                if (ch >= 0x40 and ch <= 0x7e) return i + 1;
            }
            return i;
        },
        ']' => {
            i += 1;
            while (i < raw.len) : (i += 1) {
                if (raw[i] == 0x07) return i + 1;
                if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') return i + 2;
            }
            return i;
        },
        else => return @min(i + 1, raw.len),
    }
}

/// Whether `byte` is a C0 control character or DEL, i.e. something that would
/// move the cursor or otherwise act on the terminal if written literally.
pub fn isControl(byte: u8) bool {
    return byte < 0x20 or byte == 0x7f;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "skipAnsiEscape consumes CSI sequences" {
    const sgr = "\x1b[1;36mrest";
    try expectEqual(7, skipAnsiEscape(sgr, 0));
    try expectEqualStrings("rest", sgr[skipAnsiEscape(sgr, 0)..]);

    // The first byte in the 0x40..0x7e range terminates the sequence.
    try expectEqual(3, skipAnsiEscape("\x1b[K.", 0));
}

test "skipAnsiEscape consumes OSC sequences terminated either way" {
    // OSC 52 (clipboard) terminated by BEL.
    const bel = "\x1b]52;c;aGk=\x07tail";
    try expectEqualStrings("tail", bel[skipAnsiEscape(bel, 0)..]);

    // Terminated by ST instead.
    const st = "\x1b]8;;https://example.com\x1b\\tail";
    try expectEqualStrings("tail", st[skipAnsiEscape(st, 0)..]);
}

test "skipAnsiEscape always makes progress" {
    // Truncated sequence: consumes to the end rather than past it.
    try expectEqual(2, skipAnsiEscape("\x1b[", 0));
    try expectEqual(1, skipAnsiEscape("\x1b", 0));
    // A bare ESC followed by an ordinary byte takes that byte too.
    try expectEqual(2, skipAnsiEscape("\x1bX", 0));
    // An unterminated CSI stops at the end of the buffer.
    try expectEqual(4, skipAnsiEscape("\x1b[12", 0));
}

test "escapeByte renders a printable escape" {
    var buf: [4]u8 = undefined;
    try expectEqualStrings("\\xFF", escapeByte(&buf, 0xff));
    try expectEqualStrings("\\x00", escapeByte(&buf, 0x00));
    try expectEqualStrings("\\x0A", escapeByte(&buf, 0x0a));
}

test "isControl covers C0 and DEL but not space" {
    try expect(isControl(0x00));
    try expect(isControl(0x1f));
    try expect(isControl(0x7f));
    // Newline and tab are C0 too; callers that treat them as whitespace check
    // for them before asking.
    try expect(isControl('\n'));
    try expect(isControl('\t'));
    try expect(!isControl(' '));
    try expect(!isControl('a'));
}
