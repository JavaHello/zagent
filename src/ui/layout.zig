//! The conversation's left margin.
//!
//! Everything the conversation shows starts two columns in: the line that
//! announces a tool call, the preview of what it returned, the answer with its
//! header, and the notices between turns. That is the layout the status lines
//! always had — `⚙` a call, `✓` its result — but the answer and the blocks a
//! command prints were written at column zero, so one turn could start at two
//! different left edges. The margin is here, once, and a site that lays a block
//! out asks for it instead of spelling out its own two spaces.
//!
//! The margin is presentation, not content: a run whose output is a pipe or a
//! file gets the bytes as they are, which is why the helpers here are applied by
//! the callers that know who is reading, never by the writers that only format.

const std = @import("std");

/// Columns of left margin before every line the conversation shows. A call line
/// is `indent ++ "⚙ name"`, a result is `indent ++ "✓ …"`; this is that margin.
pub const indent = "  ";

/// `indent` in columns, for callers that lay text out by width rather than by
/// writing a prefix — the markdown renderer is the one that does.
pub const columns: usize = indent.len;

/// What lines after the first of a block sit at when the first one follows a
/// leading glyph and a space: the margin plus those two columns, so a
/// multi-line result lines up under its own text rather than under its marker.
pub const after_glyph = "    ";

/// Write `bytes` with `first` before its first line and `rest` before each line
/// after it.
///
/// A blank line is written blank: a margin on an empty line is trailing
/// whitespace that changes nothing on screen and everything in a copy-paste.
pub fn writeBlock(
    w: *std.Io.Writer,
    bytes: []const u8,
    first: []const u8,
    rest: []const u8,
) std.Io.Writer.Error!void {
    var prefix = first;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        const line = bytes[start..end];
        if (line.len > 0) try w.writeAll(prefix);
        try w.writeAll(line);
        if (end == bytes.len) return;
        try w.writeByte('\n');
        start = end + 1;
        prefix = rest;
    }
}

/// Write `bytes` at the margin: `indent` before every line that has content.
pub fn write(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    return writeBlock(w, bytes, indent, indent);
}

test "every line of a block takes the margin, blank lines do not" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, "one\n\ntwo\n");
    try std.testing.expectEqualStrings("  one\n\n  two\n", aw.written());
}

test "the first line of a block can be marked differently from the rest" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeBlock(&aw.writer, "first\nsecond\n", indent ++ "✓ ", after_glyph);
    try std.testing.expectEqualStrings("  ✓ first\n    second\n", aw.written());
}

test "a block with no trailing newline keeps its last line" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, "a\nb");
    try std.testing.expectEqualStrings("  a\n  b", aw.written());
}

test "empty input writes nothing" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, "");
    try std.testing.expectEqualStrings("", aw.written());
}
