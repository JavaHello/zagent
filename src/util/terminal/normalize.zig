//! Normalising text that was written for a screen, before it is read back.
//!
//! A command that draws a progress bar rewrites one line hundreds of times with
//! a carriage return, and a body of output often has runs of blank lines that
//! say nothing. On a terminal those cost nothing — the line is overwritten in
//! place — but kept as text they are lines of stale percentages and empty rows,
//! both of which are paid for in tokens when the model reads the output back.
//!
//! So the text keeps what the screen ended up showing: a carriage return that
//! is not a line ending drops the line it went back over, and a run of blank
//! lines becomes one. Text arrives in pieces while a command runs, so the line
//! in progress is held back until it is known whether a carriage return will
//! overwrite it; `max_line_bytes` bounds what one line may hold, past which the
//! line is written out as it arrives and a carriage return no longer erases it.
//!
//! This runs on text `sanitize.zig` has already cleaned: escapes are gone, so a
//! carriage return here is the one a program meant as a redraw.

const std = @import("std");

/// Streaming normalisation of already-sanitised text: feed what arrived, write
/// what the screen showed, and `finish` at the end of the stream.
pub const Normalizer = struct {
    /// Text of the line in progress, held back because a carriage return may
    /// overwrite it.
    line: std.ArrayList(u8) = .empty,
    /// The line in progress has already been written out because it grew past
    /// `max_line_bytes`; nothing can take it back now.
    spilled: bool = false,
    /// A carriage return was just read: whether it ends the line depends on the
    /// byte after it, which may still be in the next chunk.
    pending_cr: bool = false,
    /// Blank lines written since the last line that carried something.
    blank_lines: usize = 0,

    /// Most blank lines kept in a row. More than one is only ever whitespace.
    pub const max_blank_lines: usize = 1;
    /// Bytes of one line held back before it is written out as it arrives.
    pub const max_line_bytes: usize = 8 * 1024;

    pub fn deinit(self: *Normalizer, allocator: std.mem.Allocator) void {
        self.line.deinit(allocator);
        self.* = .{};
    }

    pub fn feed(self: *Normalizer, allocator: std.mem.Allocator, w: *std.Io.Writer, raw: []const u8) !void {
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            const byte = raw[i];

            if (self.pending_cr) {
                if (byte == '\r') continue;
                self.pending_cr = false;
                if (byte == '\n') {
                    try self.endLine(w);
                    continue;
                }
                // A carriage return that is not a line ending: the terminal
                // went back to the start of the line, so only what came after
                // it is still on the screen.
                self.redraw();
            }

            switch (byte) {
                '\n' => try self.endLine(w),
                '\r' => self.pending_cr = true,
                else => try self.push(allocator, w, byte),
            }
        }
    }

    /// Whatever is left is the last line, written without a terminator it never
    /// had. A carriage return the stream ended on overwrote nothing.
    pub fn finish(self: *Normalizer, w: *std.Io.Writer) !void {
        self.pending_cr = false;
        try w.writeAll(self.line.items);
        self.line.clearRetainingCapacity();
        self.spilled = false;
        self.blank_lines = 0;
    }

    fn push(self: *Normalizer, allocator: std.mem.Allocator, w: *std.Io.Writer, byte: u8) !void {
        // A line past the cap is not worth holding for a redraw that a progress
        // bar never draws: it is written out, and what follows it follows on.
        if (self.spilled) return w.writeByte(byte);
        try self.line.append(allocator, byte);
        if (self.line.items.len < max_line_bytes) return;
        try w.writeAll(self.line.items);
        self.line.clearRetainingCapacity();
        self.spilled = true;
    }

    fn redraw(self: *Normalizer) void {
        self.line.clearRetainingCapacity();
        self.spilled = false;
    }

    fn endLine(self: *Normalizer, w: *std.Io.Writer) !void {
        if (self.line.items.len == 0 and !self.spilled) {
            if (self.blank_lines >= max_blank_lines) return;
            self.blank_lines += 1;
        } else {
            self.blank_lines = 0;
        }
        try w.writeAll(self.line.items);
        try w.writeByte('\n');
        self.line.clearRetainingCapacity();
        self.spilled = false;
    }
};

/// `Normalizer` for a text that arrived whole.
pub fn write(w: *std.Io.Writer, allocator: std.mem.Allocator, raw: []const u8) !void {
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(allocator);
    try normalizer.feed(allocator, w, raw);
    try normalizer.finish(w);
}

const testing = std.testing;

/// Normalise `raw` in one pass split at every offset `chunks` names, so a test
/// reads the same answer however a command's output was cut up.
fn expectNormalized(allocator: std.mem.Allocator, raw: []const u8, expected: []const u8) !void {
    var whole: std.Io.Writer.Allocating = .init(allocator);
    defer whole.deinit();
    try write(&whole.writer, allocator, raw);
    try testing.expectEqualStrings(expected, whole.written());

    var size: usize = 1;
    while (size <= raw.len + 1) : (size += 1) {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var normalizer: Normalizer = .{};
        defer normalizer.deinit(allocator);
        var i: usize = 0;
        while (i < raw.len) : (i += size) {
            try normalizer.feed(allocator, &aw.writer, raw[i..@min(i + size, raw.len)]);
        }
        try normalizer.finish(&aw.writer);
        try testing.expectEqualStrings(expected, aw.written());
    }
}

test "a progress bar keeps the frame the screen ended on" {
    try expectNormalized(testing.allocator, "10%\r20%\r30%\rdone\nnext\n", "done\nnext\n");
}

test "text before a redraw is dropped and text after it is kept" {
    try expectNormalized(testing.allocator, "loading...\rdone\n", "done\n");
    // A line redrawn more than once keeps only the last frame.
    try expectNormalized(testing.allocator, "a\rb\rc\r\rd\n", "d\n");
}

test "a carriage return that ends the line keeps the text it ends" {
    try expectNormalized(testing.allocator, "one\r\ntwo\r\n", "one\ntwo\n");
    try expectNormalized(testing.allocator, "one\r\ntwo", "one\ntwo");
}

test "a redraw with nothing after it leaves the frame it overwrote" {
    // The stream ended on the carriage return: the terminal would have shown
    // whatever came next, and nothing did, so the line stands.
    try expectNormalized(testing.allocator, "50%\r", "50%");
}

test "a run of blank lines becomes one" {
    try expectNormalized(testing.allocator, "one\n\n\n\ntwo\n", "one\n\ntwo\n");
    try expectNormalized(testing.allocator, "\n\n\none\n", "\none\n");
    // A single blank line is layout the program meant, and stays.
    try expectNormalized(testing.allocator, "one\n\ntwo\n", "one\n\ntwo\n");
}

test "a line too long to hold is written as it arrives" {
    const allocator = testing.allocator;
    const long = try allocator.alloc(u8, Normalizer.max_line_bytes + 16);
    defer allocator.free(long);
    @memset(long, 'x');

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(allocator);
    // Fed a byte at a time, the line passes the cap halfway through and is
    // written out; the rest follows it rather than replacing it.
    for (long) |byte| try normalizer.feed(allocator, &aw.writer, &.{byte});
    try normalizer.feed(allocator, &aw.writer, "\rtail\n");
    try normalizer.finish(&aw.writer);

    try testing.expect(std.mem.startsWith(u8, aw.written(), long));
    try testing.expect(std.mem.endsWith(u8, aw.written(), "tail\n"));
}

test "bytes that are not text are left to the sanitizer" {
    // Normalisation only decides which lines survive; it never rewrites a byte.
    try expectNormalized(testing.allocator, "a\x1b[31mb", "a\x1b[31mb");
}
