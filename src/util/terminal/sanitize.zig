//! Sanitising text that came from outside this program.
//!
//! Both tool output and model replies can carry raw control bytes. On a
//! terminal those are not a cosmetic problem: a CSI sequence can move the
//! cursor or clear the screen, OSC 52 can write the user's clipboard, and
//! OSC 8 can forge a hyperlink whose visible text is not its target. Everything
//! printed therefore goes through these helpers, including text inside a code
//! fence — a fence is not a licence to pass escapes through.
//!
//! What a sequence *is* belongs to `ansi.zig`; this file walks the text and
//! decides what reaches the writer. What is left once the escapes are gone — a
//! carriage return redrawing a line, runs of blank lines — is `normalize.zig`.

const std = @import("std");
const ansi = @import("ansi.zig");

/// Write `raw` with everything a terminal would act on removed or escaped:
/// escape sequences are dropped, other control bytes become spaces, and bytes
/// that are not valid UTF-8 are rendered as `\xNN`.
///
/// Newline, carriage return and tab are the exceptions, and pass through:
/// callers' own line and column handling is built on them, and tool output that
/// draws a progress bar with a carriage return is text the user asked to see.
/// A caller for which a carriage return *is* a line ending rather than content
/// — the diff drawing is one — takes it off the line first. Everything else is
/// taken out rather than escaped, so a caller can draw styled output from text
/// it does not trust without a stray ESC ending the styling early.
pub fn writeSanitized(w: *std.Io.Writer, raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        const byte = raw[i];

        if (byte == 0x1b) {
            i = ansi.skipAnsiEscape(raw, i);
            continue;
        }

        if (byte < 0x80) {
            try w.writeByte(if (ansi.isPrintable(byte)) byte else ' ');
            i += 1;
            continue;
        }

        const seq_len = utf8Length(raw, i) orelse {
            var escape_buf: [4]u8 = undefined;
            try w.writeAll(ansi.escapeByte(&escape_buf, byte));
            i += 1;
            continue;
        };
        try w.writeAll(raw[i .. i + seq_len]);
        i += seq_len;
    }
}

/// `writeSanitized` for text that must not break the caller's line: a line
/// ending or a tab becomes a space, so what is written stays on one line
/// however much of it there is.
///
/// A call's arguments and a title are the model's own text; a line drawn from
/// one of them and cut in two by a newline inside it would be read as two
/// unrelated lines, one of which says nothing.
pub fn writeOnOneLine(w: *std.Io.Writer, raw: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const byte = raw[i];
        if (byte != '\n' and byte != '\r' and byte != '\t') continue;
        try writeSanitized(w, raw[start..i]);
        try w.writeByte(' ');
        // A CRLF is one line ending, not two.
        if (byte == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
        start = i + 1;
    }
    try writeSanitized(w, raw[start..]);
}

/// The length of the UTF-8 character at `raw[start]`, or null when the bytes
/// there are not one: either the lead byte starts no character, or the bytes
/// that would complete it do not.
fn utf8Length(raw: []const u8, start: usize) ?usize {
    const seq_len = std.unicode.utf8ByteSequenceLength(raw[start]) catch return null;
    if (start + seq_len > raw.len) return null;
    if (!std.unicode.utf8ValidateSlice(raw[start .. start + seq_len])) return null;
    return seq_len;
}

/// `writeSanitized` for text that arrives in pieces.
///
/// A whole text is sanitised in one pass: an escape sequence or a character cut
/// off by the end of the buffer is dropped or escaped there. A caller reading a
/// program's output as it arrives would get that cut at every chunk boundary —
/// the end of a CSI sequence would be printed as text, a multi-byte character
/// split in two would be escaped byte by byte — so the bytes that may still be
/// completed are held back until the rest of them arrives.
pub const Chunked = struct {
    state: ansi.State = .text,
    /// The beginning of a character whose remaining bytes have not arrived.
    carry: [4]u8 = undefined,
    carry_len: usize = 0,

    pub fn feed(self: *Chunked, w: *std.Io.Writer, raw: []const u8) !void {
        var i: usize = try self.completeCarry(w, raw);

        while (i < raw.len) {
            const byte = raw[i];

            // Inside a sequence only its end matters; a sequence this program
            // does not know is dropped whole, the way `ansi.skipAnsiEscape`
            // drops it.
            if (self.state != .text) {
                self.state = ansi.advance(self.state, byte);
                i += 1;
                continue;
            }

            if (byte == 0x1b) {
                self.state = .escape;
                i += 1;
                continue;
            }

            if (byte < 0x80) {
                try w.writeByte(if (ansi.isPrintable(byte)) byte else ' ');
                i += 1;
                continue;
            }

            const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                var escape_buf: [4]u8 = undefined;
                try w.writeAll(ansi.escapeByte(&escape_buf, byte));
                i += 1;
                continue;
            };
            // The rest of the character may be in the next chunk, and it is
            // not a broken character until the stream ends.
            if (i + seq_len > raw.len) {
                @memcpy(self.carry[0 .. raw.len - i], raw[i..]);
                self.carry_len = raw.len - i;
                return;
            }
            if (!std.unicode.utf8ValidateSlice(raw[i .. i + seq_len])) {
                var escape_buf: [4]u8 = undefined;
                try w.writeAll(ansi.escapeByte(&escape_buf, byte));
                i += 1;
                continue;
            }
            try w.writeAll(raw[i .. i + seq_len]);
            i += seq_len;
        }
    }

    /// Finish the character held back from the previous chunk, if this chunk
    /// holds the rest of it. Answers how much of `raw` that took.
    fn completeCarry(self: *Chunked, w: *std.Io.Writer, raw: []const u8) !usize {
        if (self.carry_len == 0) return 0;
        const held = self.carry_len;
        // A character is at most four bytes, so what is held plus what this
        // chunk starts with is always enough to tell.
        const seq_len = std.unicode.utf8ByteSequenceLength(self.carry[0]) catch held;
        const filled = @min(seq_len, held + raw.len);
        var scratch: [4]u8 = undefined;
        @memcpy(scratch[0..held], self.carry[0..held]);
        @memcpy(scratch[held..filled], raw[0 .. filled - held]);
        self.carry_len = 0;

        if (filled < seq_len) {
            // Still not the whole character: hold all of it again.
            @memcpy(self.carry[0..filled], scratch[0..filled]);
            self.carry_len = filled;
            return filled - held;
        }
        if (std.unicode.utf8ValidateSlice(scratch[0..filled])) {
            try w.writeAll(scratch[0..filled]);
            return filled - held;
        }
        // It was never a character: each byte is escaped on its own, which is
        // what a whole-text pass does with bytes that are not UTF-8.
        for (scratch[0..held]) |byte| {
            var escape_buf: [4]u8 = undefined;
            try w.writeAll(ansi.escapeByte(&escape_buf, byte));
        }
        return 0;
    }

    /// Whatever was held back never became a character or an entire sequence.
    /// A half character is escaped the way a whole-text pass escapes it, and an
    /// unfinished escape is dropped, which is also what that pass does at the
    /// end of its buffer.
    pub fn finish(self: *Chunked, w: *std.Io.Writer) !void {
        for (self.carry[0..self.carry_len]) |byte| {
            var escape_buf: [4]u8 = undefined;
            try w.writeAll(ansi.escapeByte(&escape_buf, byte));
        }
        self.carry_len = 0;
        self.state = .text;
    }
};

const expectEqualStrings = std.testing.expectEqualStrings;

test "chunked sanitising matches a whole-text pass at every split" {
    const fixture = "plain \x1b[32mgreen\x1b[0m 你好 ok\xff \x1b]52;c;aGk=\x07end\r\n\x7f!";
    const a = std.testing.allocator;

    var whole: std.Io.Writer.Allocating = .init(a);
    defer whole.deinit();
    try writeSanitized(&whole.writer, fixture);
    const expected = whole.written();

    // Every chunk size, so every place a sequence or a character can be cut.
    var size: usize = 1;
    while (size <= fixture.len) : (size += 1) {
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        var chunked: Chunked = .{};
        var i: usize = 0;
        while (i < fixture.len) : (i += size) try chunked.feed(&aw.writer, fixture[i..@min(i + size, fixture.len)]);
        try chunked.finish(&aw.writer);
        try expectEqualStrings(expected, aw.written());
    }
}

test "a character cut in half is finished by the next chunk" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var chunked: Chunked = .{};
    try chunked.feed(&aw.writer, "a\xe4\xbd");
    try chunked.feed(&aw.writer, "\xa0b");
    try chunked.finish(&aw.writer);
    try expectEqualStrings("a\u{4f60}b", aw.written());
}

test "an unfinished character at the end of the stream is escaped" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var chunked: Chunked = .{};
    try chunked.feed(&aw.writer, "ab\xe4");
    try chunked.finish(&aw.writer);
    try expectEqualStrings("ab\\xE4", aw.written());
}

test "writeSanitized strips escapes and keeps the text around them" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSanitized(&aw.writer, "\x1b[32mgreen\x1b[0m");
    try expectEqualStrings("green", aw.written());
}

test "writeSanitized escapes what is not text and keeps what is" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSanitized(&aw.writer, "ok \xff \x07 \xe4\xbd\xa0\xe5\xa5\xbd\ttail");
    // The invalid byte and the bell are escaped and replaced; the CJK text and
    // the tab are not touched, because a tab cannot act on the terminal.
    try expectEqualStrings("ok \\xFF   \xe4\xbd\xa0\xe5\xa5\xbd\ttail", aw.written());
}

test "writeSanitized drops an escape that would restyle the caller's output" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // The point of dropping rather than escaping: a caller that has already
    // written its own colour must not have it cancelled from inside the text.
    try writeSanitized(&aw.writer, "before\x1b[0mafter");
    try expectEqualStrings("beforeafter", aw.written());
}

test "writeSanitized turns DEL into a space like any other control byte" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSanitized(&aw.writer, "a\x7fb");
    try expectEqualStrings("a b", aw.written());
}

test "writeOnOneLine flattens line endings and tabs into one line" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeOnOneLine(&aw.writer, "one\ntwo\r\nthree\tfour \x1b[31mred\x1b[0m");
    try expectEqualStrings("one two three four red", aw.written());
}
