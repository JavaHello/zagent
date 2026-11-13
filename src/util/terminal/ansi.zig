//! Recognising the escape sequences a terminal acts on.
//!
//! On a terminal these are not a cosmetic problem: a CSI sequence can move the
//! cursor or clear the screen, OSC 52 can write the user's clipboard, and OSC 8
//! can forge a hyperlink whose visible text is not its target. Both passes over
//! untrusted text — the one that takes a whole string (`sanitize.zig`) and the
//! one that takes it in pieces — ask this file where a sequence starts and where
//! it ends, so that a sequence dropped by one is dropped by the other.

const std = @import("std");

/// Render a stray byte as a `\xNN` escape into `buf`, which must be 4 bytes.
pub fn escapeByte(buf: *[4]u8, byte: u8) []const u8 {
    const hex = "0123456789ABCDEF";
    buf.* = .{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] };
    return buf;
}

/// How much of an escape sequence has been read, as far as finding its end is
/// concerned.
pub const State = enum {
    /// Between sequences: the text itself.
    text,
    /// Just past an ESC, before the byte that says what kind of sequence it is.
    escape,
    /// Inside a CSI, which ends on a byte in 0x40..0x7e.
    csi,
    /// Inside an OSC, which ends on BEL or on ESC \.
    osc,
    /// Inside an OSC, just past an ESC that may be the start of its terminator.
    osc_escape,
};

/// Where `state` stands once `byte` has been read.
///
/// A sequence this file does not know is dropped as a whole rather than
/// printed: a bare ESC takes the byte after it, which is what keeps
/// `skipAnsiEscape` making progress on input it cannot parse.
pub fn advance(state: State, byte: u8) State {
    return switch (state) {
        .text => if (byte == 0x1b) .escape else .text,
        .escape => switch (byte) {
            '[' => .csi,
            ']' => .osc,
            else => .text,
        },
        .csi => if (byte >= 0x40 and byte <= 0x7e) .text else .csi,
        .osc => switch (byte) {
            0x07 => .text,
            0x1b => .osc_escape,
            else => .osc,
        },
        .osc_escape => if (byte == '\\') .text else .osc,
    };
}

/// Whether `byte` is a C0 control character or DEL, i.e. something that would
/// move the cursor or otherwise act on the terminal if written literally.
pub fn isControl(byte: u8) bool {
    return byte < 0x20 or byte == 0x7f;
}

/// Whether `byte` may be written out as it stands: anything a terminal shows as
/// a glyph, plus the newline, carriage return and tab that callers' own line and
/// column handling is built on. Every other control byte does something to the
/// screen instead of appearing on it.
pub fn isPrintable(byte: u8) bool {
    if (byte < 0x20) return byte == '\n' or byte == '\r' or byte == '\t';
    return byte != 0x7f;
}

/// Index just past the escape sequence starting at `raw[start]`, which must be
/// ESC. A malformed or truncated sequence consumes what is there and returns an
/// index in bounds, so callers always make progress.
pub fn skipAnsiEscape(raw: []const u8, start: usize) usize {
    var state: State = .text;
    var i = start;
    while (i < raw.len) : (i += 1) {
        state = advance(state, raw[i]);
        // Back in the text with a byte of the sequence behind us: that byte
        // ended it.
        if (state == .text and i > start) return i + 1;
    }
    return raw.len;
}

test "skipAnsiEscape consumes CSI sequences" {
    const sgr = "\x1b[1;36mrest";
    try std.testing.expectEqual(7, skipAnsiEscape(sgr, 0));
    try std.testing.expectEqualStrings("rest", sgr[skipAnsiEscape(sgr, 0)..]);

    // The first byte in the 0x40..0x7e range terminates the sequence.
    try std.testing.expectEqual(3, skipAnsiEscape("\x1b[K.", 0));
}

test "skipAnsiEscape consumes OSC sequences terminated either way" {
    // OSC 52 (clipboard) terminated by BEL.
    const bel = "\x1b]52;c;aGk=\x07tail";
    try std.testing.expectEqualStrings("tail", bel[skipAnsiEscape(bel, 0)..]);

    // Terminated by ST instead.
    const st = "\x1b]8;;https://example.com\x1b\\tail";
    try std.testing.expectEqualStrings("tail", st[skipAnsiEscape(st, 0)..]);
}

test "skipAnsiEscape always makes progress" {
    // Truncated sequence: consumes to the end rather than past it.
    try std.testing.expectEqual(2, skipAnsiEscape("\x1b[", 0));
    try std.testing.expectEqual(1, skipAnsiEscape("\x1b", 0));
    // A bare ESC followed by an ordinary byte takes that byte too.
    try std.testing.expectEqual(2, skipAnsiEscape("\x1bX", 0));
    // An unterminated CSI stops at the end of the buffer.
    try std.testing.expectEqual(4, skipAnsiEscape("\x1b[12", 0));
}

test "escapeByte renders a printable escape" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\\xFF", escapeByte(&buf, 0xff));
    try std.testing.expectEqualStrings("\\x00", escapeByte(&buf, 0x00));
    try std.testing.expectEqualStrings("\\x0A", escapeByte(&buf, 0x0a));
}

test "isControl covers C0 and DEL but not space" {
    try std.testing.expect(isControl(0x00));
    try std.testing.expect(isControl(0x1f));
    try std.testing.expect(isControl(0x7f));
    // Newline and tab are C0 too; callers that treat them as whitespace check
    // for them before asking.
    try std.testing.expect(isControl('\n'));
    try std.testing.expect(isControl('\t'));
    try std.testing.expect(!isControl(' '));
    try std.testing.expect(!isControl('a'));
}

test "isPrintable keeps text and whitespace and nothing else" {
    try std.testing.expect(isPrintable(' '));
    try std.testing.expect(isPrintable('a'));
    for ([_]u8{ '\n', '\r', '\t' }) |byte| try std.testing.expect(isPrintable(byte));
    // DEL acts on nothing but is not shown either.
    try std.testing.expect(!isPrintable(0x7f));
    try std.testing.expect(!isPrintable(0x07));
    try std.testing.expect(!isPrintable(0x1b));
}
