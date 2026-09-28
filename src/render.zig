//! Renders markdown into a terminal.
//!
//! The renderer never allocates: its only error is `WriteFailed`. It also never
//! measures a styled string — it measures plain spans and computes prefix
//! widths arithmetically from the parts they are built from, so "how wide is
//! `\x1b[1mfoo\x1b[0m`" is not a question it has to answer.
//!
//! Blocks are recognised from a line's prefix rather than by building a
//! container stack. Every construct supported here is a line-prefix decision,
//! and the wrapping rule is per line, so a stack would buy only lazy
//! continuation lines joining a paragraph back onto a list item — which is
//! deliberately not done, because only indented elements are reflowed. Mixed
//! two- and four-space indentation from a model therefore renders unevenly, but
//! never incorrectly.
//!
//! Only lines that carry a prefix are reflowed. A plain paragraph is emitted
//! whole and left to the terminal's own soft-wrap.

const std = @import("std");
const sgr = @import("style.zig");
const term = @import("term.zig");
const text = @import("text.zig");

/// Beyond this, an unmatched marker is treated as literal text. Without a cap,
/// scanning for a closer is quadratic: `"*" ** 100_000` would compare ~10^10
/// bytes on a 100 KB reply.
const max_span_scan: usize = 2048;
/// Nesting caps. A prefix wider than the terminal would leave no room for
/// content and make the splitter spin, so depth is bounded everywhere.
const max_quote_depth: u8 = 4;
const max_list_depth: usize = 8;
const max_inline_depth: u8 = 4;
/// Columns of base indent applied to a fenced block, so the bar does not sit
/// flush against the left margin.
const code_indent: usize = 2;

/// Columns of base indent applied to a table, matching a fenced block's.
const table_indent: usize = 2;
/// Blank columns between two table cells.
const table_gap: usize = 2;
/// Rows buffered before a table is given up on. A "table" longer than this is
/// far more likely to be prose that happens to contain pipes.
const max_table_rows: usize = 128;
/// Columns past this are not laid out; such a line is treated as prose instead,
/// which loses nothing.
const max_table_columns: usize = 10;
/// A cell is laid out through this buffer. Only a cell longer than this is
/// truncated, and a cell that long would not fit a terminal column anyway.
const cell_buffer_size: usize = 1024;

pub const Color = enum { none, red, green, yellow, blue, magenta, cyan, white };

/// A set of SGR attributes. Kept as data rather than a rendered escape string
/// so that two styles can be compared and merged without allocating.
pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    color: Color = .none,

    pub fn isPlain(self: Style) bool {
        return std.meta.eql(self, Style{});
    }

    /// Combine an outer style with one applied on top of it.
    pub fn overlay(base: Style, top: Style) Style {
        return .{
            .bold = base.bold or top.bold,
            .dim = base.dim or top.dim,
            .italic = base.italic or top.italic,
            .underline = base.underline or top.underline,
            .strike = base.strike or top.strike,
            .color = if (top.color != .none) top.color else base.color,
        };
    }

    /// Whether turning `self` on top of `old` keeps every attribute `old` had.
    /// When it does, no reset is needed in between and the two spans emit as
    /// one, which is what makes nested emphasis produce a single reset.
    pub fn covers(self: Style, old: Style) bool {
        return (!old.bold or self.bold) and
            (!old.dim or self.dim) and
            (!old.italic or self.italic) and
            (!old.underline or self.underline) and
            (!old.strike or self.strike) and
            (old.color == .none or self.color == old.color);
    }

    /// Write the opening sequence into `buf` and return it; empty when plain.
    pub fn open(self: Style, buf: *[24]u8) []const u8 {
        if (self.isPlain()) return "";

        var n: usize = 0;
        buf[n] = 0x1b;
        n += 1;
        buf[n] = '[';
        n += 1;

        const parts = [_]struct { on: bool, code: []const u8 }{
            .{ .on = self.bold, .code = "1" },
            .{ .on = self.dim, .code = "2" },
            .{ .on = self.italic, .code = "3" },
            .{ .on = self.underline, .code = "4" },
            .{ .on = self.strike, .code = "9" },
            .{ .on = self.color != .none, .code = colorCode(self.color) },
        };

        var first = true;
        for (parts) |part| {
            if (!part.on) continue;
            if (!first) {
                buf[n] = ';';
                n += 1;
            }
            first = false;
            for (part.code) |ch| {
                buf[n] = ch;
                n += 1;
            }
        }

        buf[n] = 'm';
        n += 1;
        return buf[0..n];
    }

    fn colorCode(color: Color) []const u8 {
        return switch (color) {
            .none => "",
            .red => "31",
            .green => "32",
            .yellow => "33",
            .blue => "34",
            .magenta => "35",
            .cyan => "36",
            .white => "37",
        };
    }
};

pub const Theme = struct {
    h1: Style = .{ .bold = true, .color = .magenta },
    h2: Style = .{ .bold = true, .color = .cyan },
    h3: Style = .{ .bold = true },
    h4: Style = .{ .bold = true, .dim = true },
    code_lang: Style = .{ .dim = true },
    code_bar: Style = .{ .dim = true },
    quote_bar: Style = .{ .dim = true },
    marker: Style = .{ .dim = true },
    link_text: Style = .{ .underline = true, .color = .cyan },
    link_url: Style = .{ .dim = true },
    rule: Style = .{ .dim = true },
    table_header: Style = .{ .bold = true },

    bullet_glyph: []const u8 = "\xe2\x80\xa2", // •
    rule_glyph: []const u8 = "\xe2\x94\x80", // ─
    quote_bar_glyph: []const u8 = "\xe2\x94\x82 ", // │
    code_bar_glyph: []const u8 = "\xe2\x96\x8f ", // ▏

    pub const default: Theme = .{};

    pub fn heading(self: Theme, level: u8) Style {
        return switch (level) {
            1 => self.h1,
            2 => self.h2,
            3 => self.h3,
            else => self.h4,
        };
    }
};

pub const Options = struct {
    /// Usable columns. The renderer never queries the terminal itself, which is
    /// what lets the tests drive wrapping directly.
    width: usize = 80,
    /// False suppresses all SGR output but keeps the structure, so tests can
    /// assert layout without escape codes in every expectation.
    styled: bool = true,
    /// Wrap long code lines. Turning this off keeps a long path or URL on one
    /// line for copy-paste, at the cost of the bar vanishing past the margin.
    wrap_code: bool = true,
};

/// What is written before the content of a line, and before each continuation
/// line of a wrapped one.
const Prefix = struct {
    quote_depth: u8 = 0,
    code_bar: bool = false,
    indent: usize = 0,
    /// Written followed by one space, e.g. "•" or "12.".
    marker: []const u8 = "",
    marker_style: Style = .{},

    fn width(self: Prefix, theme: Theme) usize {
        var total: usize = @as(usize, self.quote_depth) * term.width(theme.quote_bar_glyph);
        if (self.code_bar) total += term.width(theme.code_bar_glyph);
        total += self.indent;
        if (self.marker.len > 0) total += term.width(self.marker) + 1;
        return total;
    }
};

/// Accumulates one output line, wrapping as it goes.
const Wrap = struct {
    w: *std.Io.Writer,
    theme: Theme,
    styled: bool,
    width: usize,
    first: Prefix = .{},
    cont: Prefix = .{},
    allow_wrap: bool = false,
    /// Display columns used on the current line, prefix included.
    col: usize = 0,
    /// Whether the prefix of the current line has been written.
    started: bool = false,
    /// Which output line of this input line we are on; selects first vs cont.
    line_index: usize = 0,
    /// Spaces held back until a word follows them, so a wrapped line never ends
    /// in trailing whitespace and a continuation never starts indented.
    pending_spaces: usize = 0,
    open_style: Style = .{},

    fn setup(self: *Wrap, first: Prefix, cont: Prefix) void {
        self.first = first;
        self.cont = cont;
        // The one rule that implements "reflow only what is indented": a
        // paragraph has an empty prefix and is therefore left to the terminal.
        self.allow_wrap = first.width(self.theme) > 0;
        self.line_index = 0;
        self.started = false;
        self.col = 0;
        self.pending_spaces = 0;
    }

    fn setStyle(self: *Wrap, s: Style) !void {
        if (!self.styled) return;
        if (std.meta.eql(s, self.open_style)) return;
        // Resetting is only necessary when the new style drops something the
        // current one set.
        if (!s.covers(self.open_style)) try self.w.writeAll(sgr.RESET);
        if (!s.isPlain()) {
            var buf: [24]u8 = undefined;
            try self.w.writeAll(s.open(&buf));
        }
        self.open_style = s;
    }

    fn writePrefix(self: *Wrap, p: Prefix) !void {
        var i: u8 = 0;
        while (i < p.quote_depth) : (i += 1) {
            try self.setStyle(self.theme.quote_bar);
            try self.w.writeAll(self.theme.quote_bar_glyph);
        }
        // Indent before the bar: a fenced block nested in a list should have
        // its bar to the right of the list's indentation, not the other way
        // round. Width is a sum, so the order here does not affect it.
        var n: usize = 0;
        while (n < p.indent) : (n += 1) try self.w.writeByte(' ');
        if (p.code_bar) {
            try self.setStyle(self.theme.code_bar);
            try self.w.writeAll(self.theme.code_bar_glyph);
        }
        try self.setStyle(.{});
        if (p.marker.len > 0) {
            try self.setStyle(p.marker_style);
            try self.w.writeAll(p.marker);
            try self.w.writeByte(' ');
        }
        self.col = p.width(self.theme);
    }

    fn ensureLine(self: *Wrap) !void {
        if (self.started) return;
        try self.writePrefix(if (self.line_index == 0) self.first else self.cont);
        self.started = true;
    }

    fn breakLine(self: *Wrap) !void {
        try self.setStyle(.{});
        try self.w.writeByte('\n');
        self.line_index += 1;
        self.started = false;
        self.col = 0;
        self.pending_spaces = 0;
    }

    fn flushSpaces(self: *Wrap) !void {
        const n = self.pending_spaces;
        self.pending_spaces = 0;
        if (n == 0 or !self.started) return;
        var i: usize = 0;
        while (i < n) : (i += 1) try self.w.writeByte(' ');
        self.col += n;
    }

    /// Hold back `n` spaces until the next word is written.
    fn space(self: *Wrap, n: usize) void {
        if (!self.started) return;
        self.pending_spaces += n;
    }

    fn tabStop(self: *Wrap) !void {
        if (!self.started) return;
        const next = ((self.col / term.tab_width) + 1) * term.tab_width;
        try self.flushSpaces();
        var n = next - self.col;
        if (n == 0) n = term.tab_width;
        var i: usize = 0;
        while (i < n) : (i += 1) try self.w.writeByte(' ');
        self.col += n;
    }

    fn repeat(self: *Wrap, s: Style, glyph: []const u8, count: usize) !void {
        try self.ensureLine();
        try self.flushSpaces();
        try self.setStyle(s);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try self.w.writeAll(glyph);
            self.col += term.width(glyph);
        }
    }

    /// Emit `run`, breaking it at spaces so wrapping happens between words.
    fn flow(self: *Wrap, s: Style, run: []const u8) !void {
        var i: usize = 0;
        while (i < run.len) {
            var spaces: usize = 0;
            while (i < run.len and run[i] == ' ') : (i += 1) spaces += 1;
            if (spaces > 0) self.space(spaces);
            if (i >= run.len) break;

            const start = i;
            while (i < run.len and run[i] != ' ') : (i += 1) {}
            try self.word(s, run[start..i]);
        }
    }

    /// Emit one unbreakable run, hard-splitting it if it cannot fit on a line
    /// by itself. Tabs are expanded here so that every caller gets tab stops
    /// without having to know about them.
    fn word(self: *Wrap, s: Style, bytes: []const u8) !void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\t')) |idx| {
            try self.plainWord(s, rest[0..idx]);
            try self.tabStop();
            rest = rest[idx + 1 ..];
        }
        try self.plainWord(s, rest);
    }

    fn plainWord(self: *Wrap, s: Style, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const wpx = term.width(bytes);
        const gap: usize = if (self.started and self.pending_spaces > 0) 1 else 0;

        if (self.allow_wrap and self.started and self.col + gap + wpx > self.width) {
            try self.breakLine();
        }
        try self.ensureLine();

        if (!self.allow_wrap or wpx <= self.width -| self.col) {
            // Spaces are flushed before the style switch so that the leading
            // space of a span stays unstyled. Dim, bold and italic are
            // invisible on a space either way, but underline is not: a styled
            // leading space draws a stray rule in front of a link label.
            try self.flushSpaces();
            try self.setStyle(s);
            try self.w.writeAll(bytes);
            self.col += wpx;
            return;
        }

        // Wider than what is left of this line: emit it in chunks, each on its
        // own line behind a fresh prefix. Overflowing instead would drop the
        // bar for the rest of the visual row, which is the whole point of the
        // hanging indent.
        var rest = bytes;
        while (rest.len > 0) {
            // Each chunk after the first starts a fresh line, so it needs the
            // continuation prefix written before anything else.
            try self.ensureLine();
            const taken = term.takeFit(rest, self.width -| self.col);
            const chunk = rest[0..taken];
            const chunk_width = term.width(chunk);

            try self.flushSpaces();
            try self.setStyle(s);
            try self.w.writeAll(chunk);
            self.col += chunk_width;

            rest = rest[taken..];
            if (rest.len > 0) try self.breakLine();
        }
    }

    fn finish(self: *Wrap) !void {
        self.pending_spaces = 0;
        try self.setStyle(.{});
        try self.w.writeByte('\n');
        self.line_index += 1;
        self.started = false;
        self.col = 0;
    }

    /// Start a line whose layout the caller computes itself. Tables decide
    /// where every column begins, so they write through this rather than
    /// through `word`, which would wrap at spaces the caller already placed.
    fn beginRaw(self: *Wrap, p: Prefix) !void {
        try self.setStyle(.{});
        try self.writePrefix(p);
        self.started = true;
    }

    fn endRaw(self: *Wrap) !void {
        try self.setStyle(.{});
        try self.w.writeByte('\n');
        self.started = false;
        self.col = 0;
        self.line_index = 0;
        self.pending_spaces = 0;
    }

    fn writeSpaces(self: *Wrap, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) try self.w.writeByte(' ');
        self.col += count;
    }
};

/// A candidate emphasis or code span found by the inline scanner.
const Span = struct {
    content_start: usize,
    content_end: usize,
    /// Index just past the closing marker.
    end: usize,
    style: Style = .{},
};

const Inline = struct {
    wrap: *Wrap,
    theme: Theme,
    depth: u8 = 0,
    cur: Style = .{},

    /// The error set is spelled out because `run` and `nested` are mutually
    /// recursive, and inferred sets would form a dependency loop.
    fn run(self: *Inline, source: []const u8) std.Io.Writer.Error!void {
        var i: usize = 0;
        var start: usize = 0;

        while (i < source.len) {
            const byte = source[i];

            if (byte == 0x1b) {
                try self.wrap.flow(self.cur, source[start..i]);
                i = text.skipAnsiEscape(source, i);
                start = i;
                continue;
            }

            if (text.isControl(byte) and byte != '\t') {
                try self.wrap.flow(self.cur, source[start..i]);
                var buf: [4]u8 = undefined;
                try self.wrap.word(self.cur, text.escapeByte(&buf, byte));
                i += 1;
                start = i;
                continue;
            }

            if (byte >= 0x80) {
                const cp = term.decodeAt(source, i);
                if (cp.valid) {
                    // Advance by the whole sequence: no marker byte is ever
                    // >= 0x80, so this only keeps offsets honest.
                    i += cp.len;
                } else {
                    try self.wrap.flow(self.cur, source[start..i]);
                    var buf: [4]u8 = undefined;
                    try self.wrap.word(self.cur, text.escapeByte(&buf, byte));
                    i += 1;
                    start = i;
                }
                continue;
            }

            if (byte == '\\' and i + 1 < source.len and std.ascii.isPunctuation(source[i + 1])) {
                try self.wrap.flow(self.cur, source[start..i]);
                try self.wrap.word(self.cur, source[i + 1 .. i + 2]);
                i += 2;
                start = i;
                continue;
            }

            // Code spans come before emphasis: that ordering is what keeps a
            // `*` inside backticks from being read as a marker.
            if (byte == '`') {
                if (matchCodeSpan(source, i)) |span| {
                    try self.wrap.flow(self.cur, source[start..i]);
                    try self.wrap.flow(self.theme.code_lang, source[span.content_start..span.content_end]);
                    i = span.end;
                    start = i;
                    continue;
                }
            }

            if (byte == '*' or byte == '_' or byte == '~') {
                if (matchEmphasis(source, i, self.cur)) |span| {
                    try self.wrap.flow(self.cur, source[start..i]);
                    try self.nested(source[span.content_start..span.content_end], span.style);
                    i = span.end;
                    start = i;
                    continue;
                }
            }

            if (byte == '[' or (byte == '!' and i + 1 < source.len and source[i + 1] == '[')) {
                const bracket = if (byte == '!') i + 1 else i;
                if (matchLink(source, bracket)) |link| {
                    try self.wrap.flow(self.cur, source[start..i]);
                    try self.emitLink(source, link);
                    i = link.end;
                    start = i;
                    continue;
                }
            }

            i += 1;
        }

        try self.wrap.flow(self.cur, source[start..]);
    }

    fn nested(self: *Inline, content: []const u8, style: Style) std.Io.Writer.Error!void {
        // At the depth cap the content still renders, just without the extra
        // style, rather than recursing without bound.
        const level = @min(self.depth + 1, max_inline_depth);
        var inner = Inline{
            .wrap = self.wrap,
            .theme = self.theme,
            .depth = level,
            .cur = if (level == self.depth) self.cur else style,
        };
        try inner.run(content);
    }

    fn emitLink(self: *Inline, source: []const u8, link: Link) !void {
        const label = source[link.text_start..link.text_end];
        const url = source[link.url_start..link.url_end];
        try self.wrap.flow(self.theme.link_text, label);
        // A bare link prints once; anything else gets its target alongside.
        if (std.mem.eql(u8, label, url)) return;

        // Close the label's style before the separating space. Spaces are
        // emitted with whatever style is open when they are flushed, and an
        // underlined space draws a visible rule in front of the URL — the one
        // attribute that is not invisible on a space.
        try self.wrap.setStyle(.{});
        try self.wrap.flow(self.theme.link_url, " (");
        try self.wrap.flow(self.theme.link_url, url);
        try self.wrap.flow(self.theme.link_url, ")");
    }
};

const Link = struct {
    text_start: usize,
    text_end: usize,
    url_start: usize,
    url_end: usize,
    end: usize,
};

fn countRun(source: []const u8, start: usize, ch: u8) usize {
    var i = start;
    while (i < source.len and source[i] == ch) : (i += 1) {}
    return i - start;
}

fn isSpace(cp: ?u21) bool {
    const value = cp orelse return true;
    if (value >= 128) return false;
    return switch (@as(u8, @intCast(value))) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

fn isWordChar(cp: ?u21) bool {
    const value = cp orelse return false;
    // Anything non-ASCII counts as a word character, so an underscore next to
    // CJK text does not open emphasis.
    if (value >= 128) return true;
    return std.ascii.isAlphanumeric(@intCast(value));
}

/// Codepoint ending at `index`, or the raw preceding byte when the sequence is
/// malformed.
fn cpBefore(source: []const u8, index: usize) ?u21 {
    if (index == 0) return null;
    var start = index - 1;
    var back: usize = 0;
    while (back < 3 and start > 0 and (source[start] & 0xc0) == 0x80) : (back += 1) start -= 1;

    const cp = term.decodeAt(source, start);
    if (start + cp.len != index) return source[index - 1];
    return cp.value;
}

fn cpAfter(source: []const u8, index: usize) ?u21 {
    if (index >= source.len) return null;
    return term.decodeAt(source, index).value;
}

/// A run of backticks closed by a run of exactly the same length. Backticks
/// that never close are literal text, which is what keeps `a `b` c` sane.
fn matchCodeSpan(source: []const u8, start: usize) ?Span {
    const open_len = countRun(source, start, '`');
    const content_start = start + open_len;
    const limit = @min(source.len, content_start + max_span_scan);

    var j = content_start;
    while (j < limit) {
        if (source[j] != '`') {
            j += 1;
            continue;
        }
        const run = countRun(source, j, '`');
        if (run == open_len and j > content_start) {
            return .{ .content_start = content_start, .content_end = j, .end = j + run };
        }
        j += run;
    }
    return null;
}

/// Find the emphasis span opening at `start`, if any.
///
/// The closer is the *last* `n` characters of the first later run long enough
/// to close, which is what makes `**bold *and italic***` nest correctly instead
/// of collapsing to literal asterisks.
fn matchEmphasis(source: []const u8, start: usize, outer: Style) ?Span {
    const ch = source[start];
    const run_len = countRun(source, start, ch);

    var n: usize = undefined;
    var inner = Style{};
    switch (ch) {
        '~' => {
            if (run_len < 2) return null;
            n = 2;
            inner = .{ .strike = true };
        },
        else => {
            n = @min(run_len, 2);
            inner = if (n == 2) .{ .bold = true } else .{ .italic = true };
        },
    }

    const open_end = start + n;
    if (open_end >= source.len) return null;
    if (!emphasisOpens(source, start, ch, n)) return null;

    const limit = @min(source.len, open_end + max_span_scan);
    var j = open_end;
    while (j < limit) {
        if (source[j] != ch) {
            j += 1;
            continue;
        }
        const close_run = countRun(source, j, ch);
        if (close_run >= n and emphasisCloses(source, j, ch, n)) {
            const content_end = j + close_run - n;
            if (content_end > open_end) {
                return .{
                    .content_start = open_end,
                    .content_end = content_end,
                    .end = j + close_run,
                    .style = Style.overlay(outer, inner),
                };
            }
        }
        j += close_run;
    }

    return null;
}

fn emphasisOpens(source: []const u8, start: usize, ch: u8, n: usize) bool {
    if (isSpace(cpAfter(source, start + n))) return false;
    if (ch != '_') return true;
    // An underscore only opens a span when it is not preceded by a word
    // character, which is what leaves identifiers like snake_case_name alone.
    return !isWordChar(cpBefore(source, start));
}

fn emphasisCloses(source: []const u8, start: usize, ch: u8, n: usize) bool {
    if (isSpace(cpBefore(source, start))) return false;
    if (ch != '_') return true;
    // ...and only closes one when it is not followed by a word character, so
    // the closing underscore of _foo_bar_ is the last one, not the middle one.
    var end = start + n;
    while (end < source.len and source[end] == ch) end += 1;
    return !isWordChar(cpAfter(source, end));
}

/// Index of the bracket that closes the one at `start`, honouring nesting.
fn findClose(source: []const u8, start: usize, open: u8, close: u8) ?usize {
    const limit = @min(source.len, start + max_span_scan);
    var depth: usize = 0;
    var i = start;
    while (i < limit) : (i += 1) {
        const byte = source[i];
        if (byte == '\\') {
            i += 1;
            continue;
        }
        if (byte == open) {
            depth += 1;
        } else if (byte == close) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn matchLink(source: []const u8, start: usize) ?Link {
    if (start >= source.len or source[start] != '[') return null;
    const close = findClose(source, start, '[', ']') orelse return null;
    if (close + 1 >= source.len or source[close + 1] != '(') return null;
    const paren = findClose(source, close + 1, '(', ')') orelse return null;

    const text_start = start + 1;
    const url_start = close + 2;
    if (close <= text_start or paren < url_start) return null;
    return .{
        .text_start = text_start,
        .text_end = close,
        .url_start = url_start,
        .url_end = paren,
        .end = paren + 1,
    };
}

const Fence = struct {
    marker: u8,
    len: usize,
    lang: []const u8,
    quote_depth: u8,
};

fn matchFenceOpen(line: []const u8) ?struct { marker: u8, len: usize, lang: []const u8 } {
    if (line.len < 3) return null;
    const marker = line[0];
    if (marker != '`' and marker != '~') return null;
    const len = countRun(line, 0, marker);
    if (len < 3) return null;
    return .{ .marker = marker, .len = len, .lang = std.mem.trim(u8, line[len..], " \t") };
}

fn isFenceClose(line: []const u8, fence: Fence) bool {
    if (line.len == 0 or line[0] != fence.marker) return false;
    const len = countRun(line, 0, fence.marker);
    if (len < fence.len) return false;
    return std.mem.trim(u8, line[len..], " \t").len == 0;
}

/// `---`, `***`, `___`, and the spaced variants like `- - -`.
fn isThematicBreak(line: []const u8) bool {
    var marker: u8 = 0;
    var count: usize = 0;
    for (line) |byte| {
        if (byte == ' ') continue;
        if (byte != '-' and byte != '*' and byte != '_') return false;
        if (marker == 0) {
            marker = byte;
        } else if (byte != marker) return false;
        count += 1;
    }
    return count >= 3;
}

const ListItem = struct {
    level: usize,
    /// Digits plus the delimiter, e.g. "12."; empty for a bullet.
    number: []const u8,
    content: []const u8,
};

fn matchListItem(line: []const u8) ?ListItem {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    if (i >= line.len) return null;

    const level = @min(i / 2, max_list_depth);
    const byte = line[i];

    if (byte == '-' or byte == '*' or byte == '+') {
        const rest = line[i + 1 ..];
        if (rest.len > 0 and rest[0] != ' ') return null;
        const content = std.mem.trimStart(u8, rest, " ");
        // A bare marker is not an item. Rendering it as an empty bullet would
        // silently drop the character the model actually wrote.
        if (content.len == 0) return null;
        return .{ .level = level, .number = "", .content = content };
    }

    if (std.ascii.isDigit(byte)) {
        var j = i;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
        if (j >= line.len) return null;
        if (line[j] != '.' and line[j] != ')') return null;
        const rest = line[j + 1 ..];
        if (rest.len > 0 and rest[0] != ' ') return null;
        const content = std.mem.trimStart(u8, rest, " ");
        if (content.len == 0) return null;
        return .{ .level = level, .number = line[i .. j + 1], .content = content };
    }

    return null;
}

/// Strip one leading `>` marker, allowing the indentation markdown permits.
fn stripQuoteMarker(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') : (i += 1) {}
    if (i >= line.len or line[i] != '>') return null;
    const rest = line[i + 1 ..];
    if (rest.len > 0 and rest[0] == ' ') return rest[1..];
    return rest;
}

/// Render `doc` to `w`. Every input line produces exactly one output line,
/// plus one more for each wrap and one for a code fence's language label.
pub fn render(w: *std.Io.Writer, doc: []const u8, options: Options) std.Io.Writer.Error!void {
    var r = Renderer.init(w, options);
    try r.feed(doc);
}

pub const Renderer = struct {
    wrap: Wrap,
    theme: Theme,
    options: Options,
    fence: ?Fence = null,
    table: Table = .{},

    pub fn init(w: *std.Io.Writer, options: Options) Renderer {
        const theme: Theme = .default;
        return .{
            .wrap = .{
                .w = w,
                .theme = theme,
                .styled = options.styled,
                .width = options.width,
            },
            .theme = theme,
            .options = options,
        };
    }

    /// Feed a whole document. A streaming caller would call `feedLine` itself
    /// with complete lines; the renderer keeps no state that requires more.
    pub fn feed(self: *Renderer, doc: []const u8) !void {
        if (doc.len == 0) return;
        var body = doc;
        if (std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];

        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| try self.feedLine(line);

        // A table is only recognisable once the line after it is known to be a
        // delimiter row, so the last one is still held here.
        if (self.table.count > 0) try self.flushTable();
    }

    pub fn feedLine(self: *Renderer, raw: []const u8) !void {
        // A stray carriage return would send the cursor back to column zero.
        const line = std.mem.trimEnd(u8, raw, " \t\r");

        if (self.fence) |fence| {
            if (isFenceClose(line, fence)) {
                // The closing fence is structure, not content.
                self.fence = null;
                return;
            }
            return self.codeLine(line, fence);
        }

        var rest = line;
        var quote_depth: u8 = 0;
        while (quote_depth < max_quote_depth) {
            rest = stripQuoteMarker(rest) orelse break;
            quote_depth += 1;
        }

        // A line that cannot continue the buffered table ends it, and is then
        // processed normally below. Rows are only ever buffered from lines that
        // would otherwise be a paragraph, so a buffer that turns out not to be
        // a table renders as exactly that.
        if (self.table.count > 0) {
            const continues = !self.table.full and
                quote_depth == self.table.quote_depth and
                hasRowSeparator(rest);
            if (continues) return self.bufferRow(rest, quote_depth);
            try self.flushTable();
        }

        if (rest.len == 0) {
            // Blank lines stay blank; a lone quote marker draws nothing.
            return self.wrap.finish();
        }

        if (matchFenceOpen(rest)) |open| {
            self.fence = .{
                .marker = open.marker,
                .len = open.len,
                .lang = open.lang,
                .quote_depth = quote_depth,
            };
            return self.codeLabel(self.fence.?);
        }

        if (isThematicBreak(rest)) return self.rule(quote_depth);

        if (headingLevel(rest)) |heading| {
            return self.headingLine(heading.level, heading.content, quote_depth);
        }

        if (matchListItem(rest)) |item| {
            return self.listLine(item, quote_depth);
        }

        // Only lines that reach this point — those that would be a paragraph —
        // are candidates, which is what makes a wrong guess free to undo.
        if (hasRowSeparator(rest)) return self.bufferRow(rest, quote_depth);

        return self.paragraph(rest, quote_depth);
    }

    fn bufferRow(self: *Renderer, row: []const u8, quote_depth: u8) !void {
        if (self.table.count == max_table_rows) {
            self.table.full = true;
            try self.flushTable();
        }
        if (self.table.count == 0) self.table.quote_depth = quote_depth;
        self.table.rows[self.table.count] = row;
        self.table.count += 1;
    }

    fn flushTable(self: *Renderer) !void {
        const table = self.table;
        self.table = .{};

        // Fewer than two rows cannot hold a delimiter row, and a buffer that
        // overflowed is prose that happened to contain pipes.
        if (table.full or table.count < 2) return self.tableProse(table);

        var cells: [max_table_columns][]const u8 = undefined;
        var aligns = [_]Alignment{.left} ** max_table_columns;
        const declared = splitRow(table.rows[1], &cells) orelse return self.tableProse(table);
        for (cells[0..declared], 0..) |cell, i| {
            // Every cell of the delimiter row has to be a delimiter, or this
            // is not a table at all.
            aligns[i] = parseAlignment(cell) orelse return self.tableProse(table);
        }

        return self.emitTable(table, aligns, declared);
    }

    /// The buffered rows were never a table after all.
    fn tableProse(self: *Renderer, table: Table) !void {
        for (table.rows[0..table.count]) |row| {
            try self.paragraph(row, table.quote_depth);
        }
    }

    fn emitTable(
        self: *Renderer,
        table: Table,
        aligns: [max_table_columns]Alignment,
        declared: usize,
    ) !void {
        var cells: [max_table_columns][]const u8 = undefined;
        var cols = declared;
        var widths = [_]usize{0} ** max_table_columns;

        // Every cell is measured before anything is written: the widest one in
        // a column decides that column's width. Row 1 is the delimiter row —
        // it is drawn as a rule rather than as content, so its dashes must not
        // widen the column they stand under.
        for (table.rows[0..table.count], 0..) |row, r| {
            if (r == 1) continue;
            const count = splitRow(row, &cells) orelse return self.tableProse(table);
            cols = @max(cols, count);
            for (cells[0..count], 0..) |cell, c| {
                widths[c] = @max(widths[c], measureCell(self.theme, cell));
            }
        }
        if (cols == 0) return self.tableProse(table);

        const indent = Prefix{ .quote_depth = table.quote_depth, .indent = table_indent };
        fitColumns(widths[0..cols], self.wrap.width -| indent.width(self.theme));

        try self.tableRowLine(table.rows[0], cols, widths[0..cols], aligns[0..cols], table.quote_depth, self.theme.table_header);
        try self.tableRule(cols, widths[0..cols], table.quote_depth);
        for (table.rows[2..table.count]) |row| {
            try self.tableRowLine(row, cols, widths[0..cols], aligns[0..cols], table.quote_depth, .{});
        }
    }

    fn tableRowLine(
        self: *Renderer,
        row: []const u8,
        cols: usize,
        widths: []const usize,
        aligns: []const Alignment,
        quote_depth: u8,
        base: Style,
    ) !void {
        var cells: [max_table_columns][]const u8 = undefined;
        const count = splitRow(row, &cells) orelse return;

        var bufs: [max_table_columns][cell_buffer_size]u8 = undefined;
        var used = [_]usize{0} ** max_table_columns;
        var lines: usize = 1;

        for (0..cols) |c| {
            const cell = if (c < count) cells[c] else "";
            const rendered = renderCell(self.theme, cell, widths[c], base, self.options.styled, &bufs[c]);
            used[c] = rendered.len;
            lines = @max(lines, renderedLines(rendered));
        }

        const indent = Prefix{ .quote_depth = quote_depth, .indent = table_indent };
        for (0..lines) |line_index| {
            // A row whose later cells are empty on this line stops there: the
            // padding that would align them is whitespace at the end of a line.
            var last: usize = 0;
            for (0..cols) |c| {
                if (term.width(nthRenderedLine(bufs[c][0..used[c]], line_index)) > 0) last = c;
            }

            try self.wrap.beginRaw(indent);
            for (0..last + 1) |c| {
                const line = nthRenderedLine(bufs[c][0..used[c]], line_index);
                const slack = widths[c] -| term.width(line);

                var lead: usize = 0;
                switch (aligns[c]) {
                    .left => {},
                    .right => lead = slack,
                    .center => lead = slack / 2,
                }

                try self.wrap.writeSpaces(lead);
                if (line.len > 0) try self.wrap.w.writeAll(line);
                // Nothing trails the last cell that has content, so a line
                // never ends in whitespace.
                if (c < last) try self.wrap.writeSpaces(slack - lead + table_gap);
            }
            try self.wrap.endRaw();
        }
    }

    fn tableRule(self: *Renderer, cols: usize, widths: []const usize, quote_depth: u8) !void {
        const indent = Prefix{ .quote_depth = quote_depth, .indent = table_indent };
        try self.wrap.beginRaw(indent);
        for (0..cols) |c| {
            try self.wrap.setStyle(self.theme.rule);
            var n: usize = 0;
            while (n < widths[c]) : (n += 1) try self.wrap.w.writeAll(self.theme.rule_glyph);
            try self.wrap.setStyle(.{});
            if (c + 1 < cols) try self.wrap.writeSpaces(table_gap);
        }
        try self.wrap.endRaw();
    }

    fn paragraph(self: *Renderer, content: []const u8, quote_depth: u8) !void {
        const prefix = Prefix{ .quote_depth = quote_depth };
        self.wrap.setup(prefix, prefix);
        try self.inlineRun(content);
        return self.wrap.finish();
    }

    fn headingLine(self: *Renderer, level: u8, content: []const u8, quote_depth: u8) !void {
        const prefix = Prefix{ .quote_depth = quote_depth };
        self.wrap.setup(prefix, prefix);
        var scanner = Inline{
            .wrap = &self.wrap,
            .theme = self.theme,
            .cur = self.theme.heading(level),
        };
        try scanner.run(content);
        return self.wrap.finish();
    }

    fn rule(self: *Renderer, quote_depth: u8) !void {
        const prefix = Prefix{ .quote_depth = quote_depth };
        self.wrap.setup(prefix, prefix);
        const glyph_width = term.width(self.theme.rule_glyph);
        const room = self.wrap.width -| prefix.width(self.theme);
        try self.wrap.repeat(self.theme.rule, self.theme.rule_glyph, room / glyph_width);
        return self.wrap.finish();
    }

    fn listLine(self: *Renderer, item: ListItem, quote_depth: u8) !void {
        const base = item.level * 2;
        const marker = if (item.number.len > 0) item.number else self.theme.bullet_glyph;

        const first = Prefix{
            .quote_depth = quote_depth,
            .indent = base,
            .marker = marker,
            .marker_style = self.theme.marker,
        };
        // The continuation prefix is exactly as wide as the first one, so the
        // wrapped text lines up under the item's text and never at column zero.
        const cont = Prefix{
            .quote_depth = quote_depth,
            .indent = base + term.width(marker) + 1,
        };

        self.wrap.setup(first, cont);
        try self.inlineRun(item.content);
        return self.wrap.finish();
    }

    fn codeLabel(self: *Renderer, fence: Fence) !void {
        if (fence.lang.len == 0) return;
        const prefix = Prefix{
            .quote_depth = fence.quote_depth,
            .indent = code_indent,
        };
        self.wrap.setup(prefix, prefix);
        try self.wrap.flow(self.theme.code_lang, fence.lang);
        return self.wrap.finish();
    }

    fn codeLine(self: *Renderer, line: []const u8, fence: Fence) !void {
        const prefix = Prefix{
            .quote_depth = fence.quote_depth,
            .code_bar = true,
            .indent = code_indent,
        };
        self.wrap.setup(prefix, prefix);
        self.wrap.allow_wrap = self.options.wrap_code and prefix.width(self.theme) > 0;
        // Code is emitted verbatim — no markers are interpreted inside a fence
        // — but it is still sanitised: a fence is not a licence for escapes.
        try self.rawText(line);
        return self.wrap.finish();
    }

    fn inlineRun(self: *Renderer, content: []const u8) !void {
        var scanner = Inline{ .wrap = &self.wrap, .theme = self.theme };
        return scanner.run(content);
    }

    fn rawText(self: *Renderer, source: []const u8) !void {
        var i: usize = 0;
        var start: usize = 0;
        while (i < source.len) {
            const byte = source[i];
            if (byte == 0x1b) {
                try self.wrap.flow(.{}, source[start..i]);
                i = text.skipAnsiEscape(source, i);
                start = i;
                continue;
            }
            if (text.isControl(byte) and byte != '\t') {
                try self.wrap.flow(.{}, source[start..i]);
                var buf: [4]u8 = undefined;
                try self.wrap.word(.{}, text.escapeByte(&buf, byte));
                i += 1;
                start = i;
                continue;
            }
            if (byte >= 0x80) {
                const cp = term.decodeAt(source, i);
                if (cp.valid) {
                    i += cp.len;
                } else {
                    try self.wrap.flow(.{}, source[start..i]);
                    var buf: [4]u8 = undefined;
                    try self.wrap.word(.{}, text.escapeByte(&buf, byte));
                    i += 1;
                    start = i;
                }
                continue;
            }
            i += 1;
        }
        try self.wrap.flow(.{}, source[start..]);
    }
};

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

const Alignment = enum { left, center, right };

/// Rows held back while a table is being recognised. The slices borrow the
/// document, so nothing is copied and nothing is allocated.
const Table = struct {
    rows: [max_table_rows][]const u8 = undefined,
    count: usize = 0,
    quote_depth: u8 = 0,
    /// Set when the buffer filled. The rows are then rendered as prose rather
    /// than dropped.
    full: bool = false,
};

fn hasRowSeparator(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '|') return true;
    }
    return false;
}

/// Whether the last byte is a pipe that is not backslash-escaped.
fn endsWithSeparator(line: []const u8) bool {
    if (line.len == 0 or line[line.len - 1] != '|') return false;
    var backslashes: usize = 0;
    var i = line.len - 1;
    while (i > 0 and line[i - 1] == '\\') : (backslashes += 1) i -= 1;
    return backslashes % 2 == 0;
}

/// Split a row into cells, dropping the empty cells that leading and trailing
/// pipes produce. Returns null when the row has more columns than can be laid
/// out, so the caller can fall back to prose rather than drop content.
fn splitRow(line: []const u8, cells: *[max_table_columns][]const u8) ?usize {
    var rest = std.mem.trim(u8, line, " \t");
    if (rest.len > 0 and rest[0] == '|') rest = rest[1..];
    if (endsWithSeparator(rest)) rest = rest[0 .. rest.len - 1];

    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '\\') {
            i += 1;
            continue;
        }
        if (rest[i] != '|') continue;
        if (count == max_table_columns) return null;
        cells[count] = std.mem.trim(u8, rest[start..i], " \t");
        count += 1;
        start = i + 1;
    }
    if (count == max_table_columns) return null;
    cells[count] = std.mem.trim(u8, rest[start..], " \t");
    return count + 1;
}

/// `---`, `:---`, `:---:` and `---:` in any dash count.
fn parseAlignment(cell: []const u8) ?Alignment {
    var body = cell;
    const left = body.len > 0 and body[0] == ':';
    if (left) body = body[1..];
    const right = body.len > 0 and body[body.len - 1] == ':';
    if (right) body = body[0 .. body.len - 1];
    if (body.len == 0) return null;
    for (body) |byte| {
        if (byte != '-') return null;
    }
    if (left and right) return .center;
    if (right) return .right;
    return .left;
}

/// Display width of a cell once rendered, with its markers removed. Measured by
/// running the real inline scanner into a discarding writer, so the width a
/// column is sized from cannot drift from what is actually emitted.
fn measureCell(theme: Theme, cell: []const u8) usize {
    var sink: [1]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    var wrap = Wrap{
        .w = &discarding.writer,
        .theme = theme,
        .styled = false,
        .width = std.math.maxInt(usize),
    };
    // An empty prefix leaves wrapping off, so the cell stays on one line and
    // `col` ends up holding its full rendered width.
    wrap.setup(.{}, .{});
    var scanner = Inline{ .wrap = &wrap, .theme = theme };
    scanner.run(cell) catch {};
    return wrap.col;
}

/// Render one cell, wrapped at `width`, into `buf`. Returns the bytes written,
/// newline separated. A cell too long for the buffer is truncated rather than
/// overflowing its column.
fn renderCell(theme: Theme, cell: []const u8, width: usize, base: Style, styled: bool, buf: []u8) []u8 {
    var fixed = std.Io.Writer.fixed(buf);
    var wrap = Wrap{
        .w = &fixed,
        .theme = theme,
        .styled = styled,
        .width = @max(width, 1),
    };
    wrap.setup(.{}, .{});
    wrap.allow_wrap = true;
    var scanner = Inline{ .wrap = &wrap, .theme = theme, .cur = base };
    // WriteFailed here only means the buffer filled; whatever was written is
    // still a valid prefix of the cell.
    scanner.run(cell) catch {};
    wrap.setStyle(.{}) catch {};
    return fixed.buffered();
}

fn renderedLines(buf: []const u8) usize {
    return std.mem.count(u8, buf, "\n") + 1;
}

fn nthRenderedLine(buf: []const u8, index: usize) []const u8 {
    var start: usize = 0;
    var n: usize = 0;
    while (n < index) : (n += 1) {
        const newline = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse return "";
        start = newline + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse buf.len;
    return buf[start..end];
}

/// Narrow `widths` in place until the row fits `avail` columns, keeping the
/// columns proportional to their natural widths.
fn fitColumns(widths: []usize, avail: usize) void {
    if (widths.len == 0) return;

    const gaps = table_gap * (widths.len - 1);
    if (avail <= gaps) {
        @memset(widths, 1);
        return;
    }
    const room = avail - gaps;

    var total: usize = 0;
    for (widths) |w| total += w;
    if (total <= room) return;

    for (widths) |*w| w.* = @max(min_column_width, w.* * room / total);

    // Rounding down usually lands under `room`; the floor can push it back
    // over, so shave the widest column until it fits.
    while (true) {
        var sum: usize = 0;
        var widest: usize = 0;
        for (widths, 0..) |w, i| {
            sum += w;
            if (w > widths[widest]) widest = i;
        }
        if (sum <= room or widths[widest] <= min_column_width) return;
        widths[widest] -= 1;
    }
}

const min_column_width: usize = 3;

const Heading = struct { level: u8, content: []const u8 };

fn headingLevel(line: []const u8) ?Heading {
    var i: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {}
    if (i == 0 or i > 6) return null;
    // ATX headings need a space (or nothing) after the hashes.
    if (i < line.len and line[i] != ' ') return null;
    return .{ .level = @intCast(i), .content = std.mem.trim(u8, line[i..], " ") };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderWith(
    allocator: std.mem.Allocator,
    input: []const u8,
    width: usize,
    styled: bool,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try render(&aw.writer, input, .{ .width = width, .styled = styled });
    return aw.toOwnedSlice();
}

fn expectPlain(expected: []const u8, input: []const u8, width: usize) !void {
    const actual = try renderWith(testing.allocator, input, width, false);
    defer testing.allocator.free(actual);
    testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("\n--- input ---\n{s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ input, expected, actual });
        return err;
    };
}

fn expectStyled(expected: []const u8, input: []const u8, width: usize) !void {
    const actual = try renderWith(testing.allocator, input, width, true);
    defer testing.allocator.free(actual);
    testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("\n--- input ---\n{s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ input, expected, actual });
        return err;
    };
}

fn countLines(s: []const u8) usize {
    return std.mem.count(u8, s, "\n");
}

// --- inline -----------------------------------------------------------------

test "inline markers are removed and text survives" {
    try expectPlain("bold italic underline strike code\n", "**bold** *italic* _underline_ ~~strike~~ `code`", 80);
}

test "emphasis markers inside words and code are left alone" {
    // Underscores inside an identifier must survive.
    try expectPlain("snake_case_name_here\n", "snake_case_name_here", 80);
    // Arithmetic is not emphasis.
    try expectPlain("2 * 3 * 4\n", "2 * 3 * 4", 80);
    // A marker inside a code span is content.
    try expectPlain("a * b\n", "`a * b`", 80);
    // A backslash escape is literal.
    try expectPlain("*literal*\n", "\\*literal\\*", 80);
    // Intraword asterisks do emphasise, as CommonMark says.
    try expectPlain("abc\n", "a*b*c", 80);
}

test "an unmatched marker stays literal and leaves no style open" {
    try expectPlain("**open\n", "**open", 80);
    try expectPlain("*\n", "*", 80);
    try expectPlain("a **b\n", "a **b", 80);

    // Nothing may be left styled at the end of the output: whatever the last
    // escape emitted was, it has to be a reset.
    const styled = try renderWith(testing.allocator, "a **b *c _d ~~e", 80, true);
    defer testing.allocator.free(styled);
    if (std.mem.lastIndexOfScalar(u8, styled, 0x1b)) |last| {
        try testing.expect(std.mem.startsWith(u8, styled[last..], sgr.RESET));
    }
}

test "emphasis nests through the last characters of a closing run" {
    // The inner span closes with the last character of the trailing run, so the
    // text renders as bold with an italic island rather than as literal
    // asterisks. One reset closes both spans, because the inner style is a
    // superset of the outer one.
    try expectStyled("\x1b[1mbold \x1b[1;3mand italic\x1b[0m\n", "**bold *and italic***", 80);
}

test "links render their text and keep the url out of emphasis" {
    try expectPlain("text (https://e.com/a_b)\n", "[text](https://e.com/a_b)", 80);
    // A link whose label is the url prints once.
    try expectPlain("https://e.com\n", "[https://e.com](https://e.com)", 80);
    // A malformed link is literal.
    try expectPlain("[not a link\n", "[not a link", 80);
    // Images degrade to their alt text rather than corrupting the line.
    try expectPlain("alt (img.png)\n", "![alt](img.png)", 80);
}

test "the space before a link's url is not underlined" {
    // Spaces take the style that is open when they are flushed, and underline
    // is the one attribute that is visible on a space. The label's style is
    // therefore closed before the separator is written.
    try expectStyled(
        "\x1b[4;36mdocs\x1b[0m \x1b[2m(https://e.com)\x1b[0m\n",
        "[docs](https://e.com)",
        80,
    );
}

// --- wrapping ---------------------------------------------------------------

test "list continuation lines keep a hanging indent" {
    try expectPlain("\xe2\x80\xa2 a b c d\n  e f\n", "- a b c d e f", 10);
}

test "the marker's own width sets the continuation indent" {
    try expectPlain("1. a b c d\n   e f\n", "1. a b c d e f", 10);
    try expectPlain("10. a b c\n    d e f\n", "10. a b c d e f", 10);
}

test "an unbreakable run is split and keeps its prefix" {
    try expectPlain("\xe2\x80\xa2 aaaa\n  aaaa\n", "- aaaaaaaa", 6);
}

test "a long token never exceeds the width" {
    var input_buf: [128]u8 = undefined;
    @memset(&input_buf, 'x');
    const input = try std.fmt.allocPrint(testing.allocator, "- {s}", .{input_buf[0..100]});
    defer testing.allocator.free(input);

    const out = try renderWith(testing.allocator, input, 40, false);
    defer testing.allocator.free(out);

    var lines = std.mem.splitScalar(u8, out, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        seen += 1;
        try testing.expect(term.width(line) <= 40);
        // Every line after the first still carries the continuation indent,
        // which is what keeps a split token from falling back to column zero.
        if (seen > 1) try testing.expect(std.mem.startsWith(u8, line, "  "));
    }
    try testing.expect(seen > 1);
}

test "cjk is measured in cells rather than bytes" {
    // Each CJK codepoint is two cells, so a six-cell budget after the two-cell
    // prefix holds three of them. Measuring bytes would emit two per line.
    try expectPlain("\xe2\x80\xa2 \xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\n  \xe7\x95\x8c\xe4\xbd\xa0\xe5\xa5\xbd\n", "- \xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c\xe4\xbd\xa0\xe5\xa5\xbd", 8);
}

test "a paragraph is not reflowed" {
    // No prefix means no wrapping: the terminal's own soft-wrap handles it.
    try expectPlain("a b c d e f\n", "a b c d e f", 4);
    try expectPlain("a b c d e f\n", "a b c d e f", 80);
}

test "trailing spaces are never emitted" {
    try expectPlain("\xe2\x80\xa2 a b\n  c\n", "- a b c", 6);
}

// --- blocks -----------------------------------------------------------------

test "a fence labels itself and bars every line" {
    try expectPlain(
        "  zig\n  \xe2\x96\x8f const x = 1;\n  \xe2\x96\x8f try foo();\n",
        "```zig\nconst x = 1;\ntry foo();\n```",
        80,
    );
}

test "a fence body is not parsed as markdown" {
    try expectPlain("  \xe2\x96\x8f **not bold**\n", "```\n**not bold**\n```", 80);
    try expectPlain("  \xe2\x96\x8f # not a heading\n", "```\n# not a heading\n```", 80);
    try expectPlain("  \xe2\x96\x8f - not a list\n", "```\n- not a list\n```", 80);
}

test "an unclosed fence still renders its body" {
    try expectPlain("  \xe2\x96\x8f a\n  \xe2\x96\x8f b\n", "```\na\nb", 80);
}

test "a tilde fence works too" {
    try expectPlain("  \xe2\x96\x8f a\n", "~~~\na\n~~~", 80);
}

test "blockquotes bar every line, including wrapped continuations" {
    try expectPlain("\xe2\x94\x82 a\n\xe2\x94\x82 b\n", "> a\n> b", 80);
    try expectPlain("\xe2\x94\x82 a b\n\xe2\x94\x82 c\n", "> a b c", 6);
}

test "headings and rules are recognised" {
    try expectPlain("Title\n", "# Title", 80);
    try expectPlain("Sub\n", "###### Sub", 80);
    // A hash without a space is not a heading.
    try expectPlain("#nope\n", "#nope", 80);
    // A rule has to be the whole line: a paragraph mentioning one is not one.
    try expectPlain("not a rule --- ok\n", "not a rule --- ok", 80);

    const rule = try renderWith(testing.allocator, "---", 20, false);
    defer testing.allocator.free(rule);
    try testing.expectEqualStrings("\xe2\x94\x80" ** 20 ++ "\n", rule);

    // The spaced form is a rule as well.
    const spaced = try renderWith(testing.allocator, "- - -", 10, false);
    defer testing.allocator.free(spaced);
    try testing.expectEqualStrings("\xe2\x94\x80" ** 10 ++ "\n", spaced);
}

test "a line without a marker is a paragraph, not a list item" {
    try expectPlain("-nope\n", "-nope", 80);
    try expectPlain("1.nope\n", "1.nope", 80);
    try expectPlain("+\n", "+", 80);
}

test "nested list items indent from their source indentation" {
    try expectPlain(
        "\xe2\x80\xa2 a\n  \xe2\x80\xa2 b\n",
        "- a\n  - b",
        80,
    );
}

test "every input line produces exactly one output line" {
    const input =
        "# Title\n" ++
        "\n" ++
        "Some text.\n" ++
        "- one\n" ++
        "- two\n" ++
        "\n" ++
        "```zig\n" ++
        "const x = 1;\n" ++
        "```\n" ++
        "> quoted\n";
    const out = try renderWith(testing.allocator, input, 80, false);
    defer testing.allocator.free(out);
    // One output line per input line, except that the closing fence is
    // structure rather than content and emits nothing.
    try testing.expectEqual(@as(usize, 9), countLines(out));
}

// --- robustness -------------------------------------------------------------

test "escape sequences in the input never reach the output" {
    // Plain mode must be genuinely escape-free.
    try expectPlain("red\n", "\x1b[31mred\x1b[0m", 80);
    // And an OSC 8 hyperlink must not survive either.
    try expectPlain("click\n", "\x1b]8;;https://evil.example\x1b\\click\x1b]8;;\x1b\\", 80);

    // In styled mode the only escapes are the ones the renderer emits itself,
    // which in this input means none at all.
    const styled = try renderWith(testing.allocator, "\x1b[31mred\x1b[0m", 80, true);
    defer testing.allocator.free(styled);
    try testing.expectEqualStrings("red\n", styled);
}

test "an escape inside a fence is stripped as well" {
    try expectPlain("  \xe2\x96\x8f red\n", "```\n\x1b[31mred\x1b[0m\n```", 80);
}

test "invalid utf-8 is escaped rather than emitted raw" {
    try expectPlain("ok \\xFF end\n", "ok \xff end", 80);
    try expectPlain("  \xe2\x96\x8f a\\xFFb\n", "```\na\xffb\n```", 80);
}

test "other control bytes are escaped" {
    try expectPlain("a\\x07b\n", "a\x07b", 80);
}

test "carriage returns and trailing whitespace are dropped" {
    try expectPlain("a\nb\n", "a\r\nb\r", 80);
    try expectPlain("a\n", "a   ", 80);
}

test "empty and newline-only documents" {
    try expectPlain("", "", 80);
    try expectPlain("a\n", "a\n", 80);
    try expectPlain("a\n\nb\n", "a\n\nb", 80);
    try expectPlain("\n", "\n", 80);
}

test "tabs expand to tab stops" {
    // A tab in a code line moves to the next multiple of four.
    try expectPlain("  \xe2\x96\x8f a   b\n", "```\na\tb\n```", 80);
}

test "deeply nested quotes do not run away" {
    const input = "> > > > > > > > deep";
    const out = try renderWith(testing.allocator, input, 40, false);
    defer testing.allocator.free(out);
    try testing.expect(countLines(out) >= 1);
    // The prefix is capped, so content still has room.
    try testing.expect(term.width(out) > 0);
}

test "a pathological run of unmatched markers terminates" {
    const input = try std.fmt.allocPrint(testing.allocator, "*{s}", .{"*" ** 5000});
    defer testing.allocator.free(input);
    const out = try renderWith(testing.allocator, input, 40, false);
    defer testing.allocator.free(out);
    try testing.expect(countLines(out) >= 1);
}

// --- style ------------------------------------------------------------------

test "style.open renders and merges attributes" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("", (Style{}).open(&buf));
    try testing.expectEqualStrings("\x1b[1m", (Style{ .bold = true }).open(&buf));

    const combined = Style.overlay(.{ .bold = true }, .{ .italic = true, .color = .cyan });
    try testing.expectEqualStrings("\x1b[1;3;36m", combined.open(&buf));

    // An inner colour wins, and an inner plain leaves the outer colour alone.
    const kept = Style.overlay(.{ .color = .red }, .{ .bold = true });
    try testing.expectEqualStrings("\x1b[1;31m", kept.open(&buf));
}

test "styled output opens and closes every span" {
    const out = try renderWith(testing.allocator, "**bold**", 80, true);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[1mbold\x1b[0m\n", out);
}

test "styled mode wraps a list item with the prefix styled" {
    const out = try renderWith(testing.allocator, "- a b c d e f", 10, true);
    defer testing.allocator.free(out);
    // The bullet is dimmed, the content after it is not, and the line ends
    // reset. The space belonging to the marker is dim too, which is invisible.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m\xe2\x80\xa2 \x1b[0ma b c d\n") != null);
    if (std.mem.lastIndexOfScalar(u8, out, 0x1b)) |last| {
        try testing.expect(std.mem.startsWith(u8, out[last..], sgr.RESET));
    }
}
// --- tables -----------------------------------------------------------------

/// `─`, so the expectations below stay readable next to the CJK text.
const dash = "\xe2\x94\x80";
/// `│`, the blockquote bar.
const vbar = "\xe2\x94\x82";

test "a table renders with a header rule and aligned columns" {
    try expectPlain(
        "  名称  说明\n" ++
        "  " ++ dash ++ dash ++ dash ++ dash ++ "  " ++ dash ** 6 ++ "\n" ++
        "  foo   第一个\n" ++
        "  bar   第二个\n",
        "| 名称 | 说明 |\n| --- | --- |\n| foo | 第一个 |\n| bar | 第二个 |",
        80,
    );
}

test "the delimiter row does not widen the columns it stands under" {
    // Its dashes are drawn as a rule, not measured as content: a column of
    // one-character cells stays one character wide whatever the delimiter says.
    try expectPlain(
        "  a  b\n" ++
        "  " ++ dash ++ "  " ++ dash ++ "\n" ++
        "  1  2\n",
        "a | b\n--- | ---\n1 | 2",
        80,
    );
}

test "a row without a leading pipe is still a table row" {
    try expectPlain(
        "  a  b\n" ++
        "  " ++ dash ++ "  " ++ dash ++ "\n" ++
        "  1  2\n",
        "a | b\n- | -\n1 | 2",
        80,
    );
}

test "alignment markers move the cell within its column" {
    try expectPlain(
        "  aaa  bbb  ccc\n" ++
        "  " ++ dash ** 3 ++ "  " ++ dash ** 3 ++ "  " ++ dash ** 3 ++ "\n" ++
        "  x      y   z\n",
        "| aaa | bbb | ccc |\n| :- | -: | :-: |\n| x | y | z |",
        80,
    );
}

test "the header is bold and the rule is dim" {
    try expectStyled(
        "  \x1b[1mhi\x1b[0m  \x1b[1mx\x1b[0m\n" ++
        "  \x1b[2m" ++ dash ** 2 ++ "\x1b[0m  \x1b[2m" ++ dash ++ "\x1b[0m\n" ++
        "  a   y\n",
        "| **hi** | x |\n| --- | --- |\n| a | y |",
        80,
    );
}

test "a pipe-escaped cell does not split the row" {
    try expectPlain(
        "  a|b  x\n" ++
        "  " ++ dash ** 3 ++ "  " ++ dash ++ "\n" ++
        "  c|d  y\n",
        "| a\\|b | x |\n| --- | --- |\n| c\\|d | y |",
        80,
    );
}

test "a row with a missing cell stops there, and an extra cell is kept" {
    try expectPlain(
        "  a  b  c\n" ++
        "  " ++ dash ++ "  " ++ dash ++ "  " ++ dash ++ "\n" ++
        "  1\n" ++
        "  2  3  4\n",
        "| a | b | c |\n| - | - | - |\n| 1 |\n| 2 | 3 | 4 |",
        80,
    );
}

test "a table inside a blockquote keeps its bars" {
    try expectPlain(
        vbar ++ "   a  b\n" ++
        vbar ++ "   " ++ dash ++ "  " ++ dash ++ "\n" ++
        vbar ++ "   1  2\n",
        "> | a | b |\n> | - | - |\n> | 1 | 2 |",
        80,
    );
}

test "a table wider than the terminal wraps cells inside their columns" {
    const input = "| 名称 | 说明 |\n| --- | --- |\n| foo | 这是一个很长的说明文字 |";
    const out = try renderWith(testing.allocator, input, 24, false);
    defer testing.allocator.free(out);

    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(term.width(line) <= 24);
    }
    // The long cell needed more than one line, and the continuation keeps the
    // rest of the row aligned underneath it.
    try testing.expect(renderedLines(out) > 3);
    try testing.expect(std.mem.indexOf(u8, out, "明文字") != null);
}

test "a table ends at a blank line" {
    try expectPlain(
        "  a  b\n" ++
        "  " ++ dash ++ "  " ++ dash ++ "\n" ++
        "  1  2\n" ++
        "\n" ++
        "after\n",
        "| a | b |\n| - | - |\n| 1 | 2 |\n\nafter",
        80,
    );
}

test "a fence opened after a table body is not part of it" {
    const out = try renderWith(
        testing.allocator,
        "| a | b |\n| - | - |\n| 1 | 2 |\n```\ncode\n```",
        80,
        false,
    );
    defer testing.allocator.free(out);
    // The table rendered, and the fence after it rendered as a code block.
    try testing.expect(std.mem.indexOf(u8, out, dash) != null);
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x96\x8f code") != null);
}

test "a table survives being the last thing in the document" {
    try expectPlain(
        "  a  b\n" ++
        "  " ++ dash ++ "  " ++ dash ++ "\n" ++
        "  1  2\n",
        "| a | b |\n| - | - |\n| 1 | 2 |",
        80,
    );
}

test "a line that only looks like a table row stays prose" {
    // No delimiter row at all.
    try expectPlain("a | b\nc | d\n", "a | b\nc | d", 80);
    // A second row that is not a delimiter row.
    try expectPlain("a | b\n:-: | x\n", "a | b\n:-: | x", 80);
    // A single row cannot hold one either.
    try expectPlain("a | b\n", "a | b", 80);
    // A list item that happens to contain a pipe is still a list item: the
    // list check runs first, so the row buffer never sees it.
    try expectPlain("\xe2\x80\xa2 a | b\n", "- a | b", 80);
}

test "a table too wide to be laid out falls back to prose" {
    // Eleven columns is past the layout limit; nothing may be dropped.
    const input = "| a | b | c | d | e | f | g | h | i | j | k |\n" ++
        "| - | - | - | - | - | - | - | - | - | - | - |\n" ++
        "| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |";
    const out = try renderWith(testing.allocator, input, 400, false);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "| 11 |") != null);
}
