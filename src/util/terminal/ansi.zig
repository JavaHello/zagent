//! Recognising the escape sequences a terminal acts on.
//!
//! On a terminal these are not a cosmetic problem: a CSI sequence can move the
//! cursor or clear the screen, OSC 52 can write the user's clipboard, and OSC 8
//! can forge a hyperlink whose visible text is not its target. A sequence also
//! has to be measured right for a duller reason: whatever of it is not recognised
//! as part of a sequence is printed as text, so a designation (`ESC ( 0`) taken
//! for a whole sequence leaves `0mqB` where a tree drew `└─`. Both passes over
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
    /// Past an ESC and the intermediate bytes that name a character set or a
    /// designation — `ESC ( 0` for the line-drawing set, `ESC # 8`, `ESC % G`,
    /// `ESC $ ( C` — which ends on a final byte in 0x30..0x7e. Without this the
    /// bytes after a designation are printed as text: a build summary that
    /// draws its tree with `ESC ( 0` reads `0mqB run test`.
    intermediate,
    /// Inside a CSI, which ends on a byte in 0x40..0x7e.
    csi,
    /// Inside an OSC, which ends on BEL or on ESC \.
    osc,
    /// Inside an OSC, just past an ESC that may be the start of its terminator.
    osc_escape,
    /// Inside a DCS, SOS, PM or APC, which ends on ESC \ alone: unlike an OSC,
    /// BEL is part of its payload. What one of these carries — a sixel picture,
    /// a graphics command, a terminal's own reply — is not text, so its bytes
    /// are dropped rather than printed.
    string,
    /// Inside one of those, just past an ESC that may be the start of its
    /// terminator.
    string_escape,
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
            // The C1 members that carry a string instead of ending on a byte.
            'P', 'X', '^', '_' => .string,
            // A byte in this range introduces a designation of its own.
            0x20...0x2f => .intermediate,
            else => .text,
        },
        .intermediate => switch (byte) {
            0x1b => .escape,
            0x20...0x2f => .intermediate,
            else => .text,
        },
        .csi => if (byte >= 0x40 and byte <= 0x7e) .text else .csi,
        .osc => switch (byte) {
            0x07 => .text,
            0x1b => .osc_escape,
            else => .osc,
        },
        .osc_escape => if (byte == '\\') .text else .osc,
        // BEL is payload here, so only ST ends it.
        .string => if (byte == 0x1b) .string_escape else .string,
        .string_escape => if (byte == '\\') .text else .string,
    };
}

/// A character set designation: the sequence that says which set a slot is to
/// draw the bytes that follow with.
pub const Designation = struct {
    /// The slot named: '(' is G0 and ')' is G1, the two SI and SO choose
    /// between; '*' and '+' are G2 and G3, which nothing shifts to.
    slot: u8,
    /// The set named: '0' is the line-drawing set, 'B' is ASCII.
    set: u8,
};

/// The designation `sequence` spells out, if that is what it is: `ESC ( 0`,
/// `ESC ) B`. A sequence that is not one answers null — a CSI, a string
/// control, or a designation with more than one intermediate byte (`ESC $ ( C`),
/// which names a set this program does not read.
pub fn designation(sequence: []const u8) ?Designation {
    if (sequence.len != 3 or sequence[0] != 0x1b) return null;
    const slot = sequence[1];
    if (slot < '(' or slot > '+') return null;
    return .{ .slot = slot, .set = sequence[2] };
}

/// What a terminal draws for `byte` while the line-drawing set is in force, or
/// null when that set draws nothing with it: the corners and lines of the tree
/// a build summary is, the symbols of a box drawn with `ESC ( 0`. Read back as
/// letters they say nothing — `mq` where the screen showed `└─` — so they are
/// translated rather than passed through.
pub fn graphicsGlyph(byte: u8) ?[]const u8 {
    return switch (byte) {
        0x5f => " ", // blank
        0x60 => "◆", // diamond
        0x61 => "▒", // checkerboard
        0x62 => "␉", // horizontal tab
        0x63 => "␌", // form feed
        0x64 => "␍", // carriage return
        0x65 => "␊", // line feed
        0x66 => "°", // degree
        0x67 => "±", // plus/minus
        0x68 => "␤", // newline
        0x69 => "␋", // vertical tab
        0x6a => "┘", // lower right corner
        0x6b => "┐", // upper right corner
        0x6c => "┌", // upper left corner
        0x6d => "└", // lower left corner
        0x6e => "┼", // crossing lines
        0x6f => "⎺", // scan line 1
        0x70 => "⎻", // scan line 3
        0x71 => "─", // horizontal line
        0x72 => "⎼", // scan line 7
        0x73 => "⎽", // scan line 9
        0x74 => "├", // left tee
        0x75 => "┤", // right tee
        0x76 => "┴", // bottom tee
        0x77 => "┬", // top tee
        0x78 => "│", // vertical line
        0x79 => "≤", // less than or equal
        0x7a => "≥", // greater than or equal
        0x7b => "π", // pi
        0x7c => "≠", // not equal
        0x7d => "£", // pound sterling
        0x7e => "·", // centered dot
        else => null,
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

test "skipAnsiEscape consumes DCS, SOS, PM and APC to their terminator" {
    // DCS: a sixel picture, or the termcap strings xterm is asked for.
    const dcs = "\x1bPq#0;2;0;0;0\x1b\\tail";
    try std.testing.expectEqualStrings("tail", dcs[skipAnsiEscape(dcs, 0)..]);

    // APC: the graphics protocol, whose payload is a command, not text.
    const apc = "\x1b_Gf=100;AAAA\x1b\\tail";
    try std.testing.expectEqualStrings("tail", apc[skipAnsiEscape(apc, 0)..]);

    // SOS and PM carry a string too.
    for ([_][]const u8{ "\x1bXpayload\x1b\\tail", "\x1b^payload\x1b\\tail" }) |s| {
        try std.testing.expectEqualStrings("tail", s[skipAnsiEscape(s, 0)..]);
    }

    // A BEL is payload inside a DCS, not the terminator an OSC ends on: the
    // sequence runs to ST and the bytes between are never printed.
    const bell = "\x1bPq\x07payload\x1b\\tail";
    try std.testing.expectEqualStrings("tail", bell[skipAnsiEscape(bell, 0)..]);
}

test "skipAnsiEscape consumes a designation with its final byte" {
    // `ESC ( 0` selects the line-drawing set, which is how a build summary
    // draws its tree; `ESC ( B` selects ASCII again. Both are three bytes, and
    // the letters between them are the drawing, not words.
    const drawn = "\x1b(0mq\x1b(B run test";
    const select = skipAnsiEscape(drawn, 0);
    try std.testing.expectEqual(3, select);
    try std.testing.expectEqualStrings("mq", drawn[select .. select + 2]);
    try std.testing.expectEqualStrings(" run test", drawn[skipAnsiEscape(drawn, select + 2)..]);

    // One intermediate byte, and more than one.
    try std.testing.expectEqualStrings("x", "\x1b#8x"[skipAnsiEscape("\x1b#8x", 0)..]);
    try std.testing.expectEqualStrings("x", "\x1b%Gx"[skipAnsiEscape("\x1b%Gx", 0)..]);
    try std.testing.expectEqualStrings("x", "\x1b$(Cx"[skipAnsiEscape("\x1b$(Cx", 0)..]);

    // A designation cut off by the end of the buffer takes it all.
    try std.testing.expectEqual(2, skipAnsiEscape("\x1b(", 0));
    try std.testing.expectEqual(3, skipAnsiEscape("\x1b$(", 0));
}

test "skipAnsiEscape always makes progress" {
    // Truncated sequence: consumes to the end rather than past it.
    try std.testing.expectEqual(2, skipAnsiEscape("\x1b[", 0));
    try std.testing.expectEqual(1, skipAnsiEscape("\x1b", 0));
    // A bare ESC followed by an ordinary byte takes that byte too.
    try std.testing.expectEqual(2, skipAnsiEscape("\x1bA", 0));
    // An unterminated CSI stops at the end of the buffer.
    try std.testing.expectEqual(4, skipAnsiEscape("\x1b[12", 0));
}

test "designation reads only the sequence that names a set" {
    try std.testing.expectEqual(@as(?Designation, .{ .slot = ')', .set = '0' }), designation("\x1b)0"));
    try std.testing.expectEqual(@as(?Designation, .{ .slot = '(', .set = 'B' }), designation("\x1b(B"));
    // A sequence that names no slot, or one this file does not read, is not a
    // designation.
    try std.testing.expectEqual(@as(?Designation, null), designation("\x1b[1m"));
    try std.testing.expectEqual(@as(?Designation, null), designation("\x1b$(C"));
    try std.testing.expectEqual(@as(?Designation, null), designation("\x1b("));
    try std.testing.expectEqual(@as(?Designation, null), designation(""));
}

test "the line-drawing set has the glyphs a terminal shows" {
    // The corners and lines a tree is drawn with.
    try std.testing.expectEqualStrings("└", graphicsGlyph('m').?);
    try std.testing.expectEqualStrings("─", graphicsGlyph('q').?);
    try std.testing.expectEqualStrings("├", graphicsGlyph('t').?);
    try std.testing.expectEqualStrings("│", graphicsGlyph('x').?);
    try std.testing.expectEqualStrings("┼", graphicsGlyph('n').?);
    // Bytes the set draws nothing with are left to the text itself.
    try std.testing.expectEqual(@as(?[]const u8, null), graphicsGlyph('R'));
    try std.testing.expectEqual(@as(?[]const u8, null), graphicsGlyph(' '));
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
