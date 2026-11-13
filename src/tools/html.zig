//! HTML read as text.
//!
//! A page is markup around the words a reader wants, and the model reads the
//! words. `toText` walks the markup once and writes the page back as the
//! markdown a person would have copied out of it: headings as headings, list
//! items as list items, links with their target beside them, code as code. What
//! says nothing a reader needs — scripts, styles, the document head, the tag
//! attributes themselves — is dropped.
//!
//! `fragment` is the same reading for a piece of markup the tools parse
//! themselves: a search result's title, a snippet, a link's own text.
const std = @import("std");
const web = @import("web.zig");

/// Where the text of one page stops. A page longer than this is cut and the
/// result says so; it is far more than one message can carry, and the cache
/// keeps whatever of it the model asks to read back.
pub const max_text_bytes: usize = 256 * 1024;

pub const Options = struct {
    /// The URL the page was read from, so that a relative link can be written
    /// as the address a reader would follow.
    base_url: ?[]const u8 = null,
    /// Where the text stops.
    max_bytes: usize = max_text_bytes,
};

/// Read a whole page as markdown.
pub fn toText(allocator: std.mem.Allocator, html_text: []const u8, options: Options) ![]u8 {
    var page: Page = .{
        .allocator = allocator,
        .out = .empty,
        .limit = options.max_bytes,
        .title = .empty,
    };
    defer page.out.deinit(allocator);
    defer page.title.deinit(allocator);

    try page.walk(html_text, options.base_url);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // The document's own title names the page in one line, above what it says.
    if (page.title.items.len > 0) {
        const title = try fragment(allocator, page.title.items);
        defer allocator.free(title);
        if (title.len > 0) {
            try out.appendSlice(allocator, "# ");
            try out.appendSlice(allocator, title);
            try out.appendSlice(allocator, "\n\n");
        }
    }

    const text = std.mem.trim(u8, page.out.items, " \t\r\n");
    if (text.len > 0) {
        try out.appendSlice(allocator, text);
        try out.append(allocator, '\n');
    }

    if (page.stopped) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        const notice = try std.fmt.allocPrint(allocator, "\n[text stopped at the limit of {d} bytes]\n", .{page.limit});
        defer allocator.free(notice);
        try out.appendSlice(allocator, notice);
    }
    return out.toOwnedSlice(allocator);
}

/// The text of a piece of markup, with its tags removed, its entities decoded
/// and its whitespace collapsed to single spaces.
pub fn fragment(allocator: std.mem.Allocator, html_text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var space = false;
    var started = false;
    var i: usize = 0;
    while (i < html_text.len) {
        if (html_text[i] == '<') {
            const gt = std.mem.indexOfScalarPos(u8, html_text, i, '>') orelse break;
            i = gt + 1;
            // A tag boundary separates words the way a space does.
            if (started) space = true;
            continue;
        }
        if (decodeEntity(html_text, i)) |decoded| {
            i = decoded.next;
            if (isSpace(decoded.cp)) {
                if (started) space = true;
                continue;
            }
            if (space) try out.append(allocator, ' ');
            space = false;
            started = true;
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(decoded.cp, &buffer) catch 1;
            try out.appendSlice(allocator, buffer[0..len]);
            continue;
        }
        const c = html_text[i];
        i += 1;
        if (isAsciiSpace(c)) {
            if (started) space = true;
            continue;
        }
        if (space) try out.append(allocator, ' ');
        space = false;
        started = true;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// Decode the entities in a value that carries no markup, such as an
/// attribute.
pub fn decodeEntities(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (decodeEntity(text, i)) |decoded| {
            var buffer: [4]u8 = undefined;
            if (std.unicode.utf8Encode(decoded.cp, &buffer)) |len| {
                try out.appendSlice(allocator, buffer[0..len]);
                i = decoded.next;
                continue;
            } else |_| {}
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// The tokens of a tag: its name, whether it closes, and whether it closes
/// itself.
pub const Tag = struct {
    name: []const u8,
    closing: bool,
    self_closing: bool,
};

pub fn tag(raw: []const u8) Tag {
    const closing = raw.len > 1 and raw[1] == '/';
    const start = @min(if (closing) @as(usize, 2) else 1, raw.len);
    const self_closing = std.mem.endsWith(u8, raw, "/>");
    var end = start;
    while (end < raw.len) : (end += 1) {
        const c = raw[end];
        if (std.ascii.isWhitespace(c) or c == '/' or c == '>') break;
    }
    return .{ .name = raw[start..end], .closing = closing, .self_closing = self_closing };
}

/// The value of one attribute of a tag, matched without regard to case; quoted
/// or bare, as an attribute may be written. Null when the tag does not carry it.
pub fn attribute(raw: []const u8, name: []const u8) ?[]const u8 {
    const parsed = tag(raw);
    var i: usize = (if (parsed.closing) @as(usize, 2) else 1) + parsed.name.len;
    while (i < raw.len) {
        while (i < raw.len and (std.ascii.isWhitespace(raw[i]) or raw[i] == '/')) i += 1;
        if (i >= raw.len or raw[i] == '>') return null;

        const name_start = i;
        while (i < raw.len and raw[i] != '=' and raw[i] != '>' and !std.ascii.isWhitespace(raw[i])) i += 1;
        const attribute_name = raw[name_start..i];
        while (i < raw.len and std.ascii.isWhitespace(raw[i])) i += 1;
        if (i >= raw.len or raw[i] != '=') continue;
        i += 1;
        while (i < raw.len and std.ascii.isWhitespace(raw[i])) i += 1;
        if (i >= raw.len) return null;

        const value = if (raw[i] == '"' or raw[i] == '\'') blk: {
            const quote = raw[i];
            i += 1;
            const value_start = i;
            while (i < raw.len and raw[i] != quote) i += 1;
            const value_end = i;
            if (i < raw.len) i += 1;
            break :blk raw[value_start..value_end];
        } else blk: {
            const value_start = i;
            while (i < raw.len and !std.ascii.isWhitespace(raw[i]) and raw[i] != '>') i += 1;
            break :blk raw[value_start..i];
        };

        if (std.ascii.eqlIgnoreCase(attribute_name, name)) return value;
    }
    return null;
}

/// Whether a tag carries `token` in its class list.
pub fn hasClass(raw: []const u8, token: []const u8) bool {
    const classes = attribute(raw, "class") orelse return false;
    var list = std.mem.tokenizeAny(u8, classes, " \t\r\n");
    while (list.next()) |class| {
        if (std.mem.eql(u8, class, token)) return true;
    }
    return false;
}

/// One page being written out: the output, where it may stop, and the line
/// breaks that are owed before the next word.
const Page = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8),
    limit: usize,
    /// Line breaks owed before the next word: 0 none, 1 a new line, 2 a blank
    /// line between blocks.
    pending: u2 = 0,
    /// Whether the output is empty or ends with a line break.
    at_line_start: bool = true,
    /// Whether a space is owed before the next word.
    space: bool = false,
    /// Set when the text reached the limit: nothing more is written.
    stopped: bool = false,
    in_pre: bool = false,
    /// The anchor being read, and the address it points at.
    link: ?[]u8 = null,
    /// The document's `<title>`, if it has one.
    title: std.ArrayList(u8),

    fn deinit(self: *Page) void {
        if (self.link) |link| self.allocator.free(link);
        self.link = null;
    }

    fn walk(self: *Page, html_text: []const u8, base_url: ?[]const u8) !void {
        defer self.deinit();
        var i: usize = 0;
        while (i < html_text.len) {
            if (self.stopped) return;
            const lt = std.mem.indexOfScalarPos(u8, html_text, i, '<') orelse {
                try self.text(html_text[i..]);
                return;
            };
            if (lt > i) try self.text(html_text[i..lt]);
            if (self.stopped) return;

            if (std.mem.startsWith(u8, html_text[lt..], "<!--")) {
                const end = std.mem.indexOfPos(u8, html_text, lt + 4, "-->") orelse return;
                i = @min(end + 3, html_text.len);
                continue;
            }
            if (std.mem.startsWith(u8, html_text[lt..], "<!")) {
                const end = std.mem.indexOfScalarPos(u8, html_text, lt, '>') orelse return;
                i = @min(end + 1, html_text.len);
                continue;
            }
            const gt = std.mem.indexOfScalarPos(u8, html_text, lt, '>') orelse return;
            const tag_text = html_text[lt .. gt + 1];
            i = gt + 1;

            const parsed = tag(tag_text);
            if (parsed.name.len == 0) continue;

            // What a reader never sees: the element and everything inside it.
            if (!parsed.closing and !parsed.self_closing and isSilent(parsed.name)) {
                i = findElementEnd(html_text, i, parsed.name) orelse return;
                continue;
            }
            // The title is kept apart: it names the page above what it says.
            if (!parsed.closing and !parsed.self_closing and std.ascii.eqlIgnoreCase(parsed.name, "title")) {
                const close = findClose(html_text, i, "title") orelse return;
                try self.title.appendSlice(self.allocator, html_text[i..close.content_end]);
                i = close.next;
                continue;
            }

            try self.element(tag_text, parsed, base_url);
        }
    }

    fn element(self: *Page, tag_text: []const u8, parsed: Tag, base_url: ?[]const u8) !void {
        const name = parsed.name;

        if (std.ascii.eqlIgnoreCase(name, "pre")) {
            if (parsed.closing) return self.endPre();
            if (!parsed.self_closing) return self.startPre();
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, "code") and !self.in_pre) {
            return self.markup("`");
        }
        if (std.ascii.eqlIgnoreCase(name, "a")) {
            if (parsed.closing) return self.endLink();
            return self.startLink(attribute(tag_text, "href"), base_url);
        }
        if (std.ascii.eqlIgnoreCase(name, "br")) {
            if (self.in_pre) return self.append("\n");
            return self.breakLine(1);
        }
        if (std.ascii.eqlIgnoreCase(name, "hr")) {
            try self.breakLine(2);
            try self.markup("---");
            return self.breakLine(2);
        }
        if (std.ascii.eqlIgnoreCase(name, "li")) {
            if (parsed.closing) return self.breakLine(1);
            try self.breakLine(1);
            return self.markup("- ");
        }
        if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') {
            if (parsed.closing) return self.breakLine(2);
            try self.breakLine(2);
            const marks: [6]u8 = .{ '#', '#', '#', '#', '#', '#' };
            try self.markup(marks[0 .. name[1] - '0']);
            return self.markup(" ");
        }
        if (std.ascii.eqlIgnoreCase(name, "td") or std.ascii.eqlIgnoreCase(name, "th")) {
            if (!parsed.closing and !self.in_pre) try self.markup(" ");
            return;
        }
        if (std.ascii.eqlIgnoreCase(name, "tr")) {
            return self.breakLine(1);
        }
        if (isBlock(name)) return self.breakLine(2);
    }

    fn startPre(self: *Page) !void {
        try self.breakLine(2);
        try self.flush();
        try self.append("```\n");
        self.in_pre = true;
        self.at_line_start = true;
        self.space = false;
    }

    fn endPre(self: *Page) !void {
        if (!self.in_pre) return;
        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] != '\n') try self.append("\n");
        try self.append("```");
        self.in_pre = false;
        try self.breakLine(2);
        try self.flush();
    }

    fn startLink(self: *Page, href: ?[]const u8, base_url: ?[]const u8) !void {
        if (self.link != null) try self.endLink();
        const target = href orelse return;
        const decoded = try decodeEntities(self.allocator, target);
        defer self.allocator.free(decoded);
        const resolved = (resolveLink(self.allocator, base_url, decoded) catch null) orelse return;
        self.link = resolved;
        // Inside code the address itself is what the reader wants; in a
        // sentence it goes beside the words as a markdown link.
        try self.markup(if (self.in_pre) "<" else "[");
    }

    fn endLink(self: *Page) !void {
        const target = self.link orelse return;
        self.link = null;
        defer self.allocator.free(target);
        if (self.in_pre) return self.markup(">");
        try self.markup("](");
        try self.markup(target);
        try self.markup(")");
    }

    /// Write a text run: whitespace collapsed, entities decoded, and a run
    /// inside `<pre>` kept exactly as it was written.
    fn text(self: *Page, run: []const u8) !void {
        var i: usize = 0;
        while (i < run.len) {
            if (self.stopped) return;
            if (decodeEntity(run, i)) |decoded| {
                i = decoded.next;
                if (self.in_pre) {
                    var buffer: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(decoded.cp, &buffer) catch 1;
                    try self.append(buffer[0..len]);
                } else if (isSpace(decoded.cp)) {
                    self.markSpace();
                } else {
                    var buffer: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(decoded.cp, &buffer) catch 1;
                    try self.word(buffer[0..len]);
                }
                continue;
            }
            const c = run[i];
            i += 1;
            if (self.in_pre) {
                try self.append(run[i - 1 .. i]);
            } else if (isAsciiSpace(c)) {
                self.markSpace();
            } else {
                try self.word(run[i - 1 .. i]);
            }
        }
    }

    fn markSpace(self: *Page) void {
        if (!self.at_line_start) self.space = true;
    }

    fn breakLine(self: *Page, lines: u2) !void {
        if (self.in_pre) return;
        if (lines > self.pending) self.pending = lines;
    }

    /// Write markup of the page's own making — a heading's `#`, a list item's
    /// dash, a link's brackets — at the position the line breaks leave it.
    fn markup(self: *Page, bytes: []const u8) !void {
        if (self.stopped) return;
        try self.flush();
        if (self.space and !self.at_line_start) try self.append(" ");
        self.space = false;
        try self.append(bytes);
        self.at_line_start = bytes.len > 0 and bytes[bytes.len - 1] == '\n';
    }

    /// Write one word, with the space or line break that comes before it.
    fn word(self: *Page, bytes: []const u8) !void {
        if (self.stopped or bytes.len == 0) return;
        try self.flush();
        if (self.space and !self.at_line_start) try self.append(" ");
        self.space = false;
        try self.append(bytes);
        self.at_line_start = false;
    }

    /// Write the line breaks that are owed, if any.
    fn flush(self: *Page) !void {
        if (self.pending == 0) return;
        const lines = self.pending;
        self.pending = 0;
        self.space = false;
        if (self.out.items.len == 0) {
            self.at_line_start = true;
            return;
        }
        // A break is owed against the words, not against the spaces after them.
        while (self.out.items.len > 0 and (self.out.items[self.out.items.len - 1] == ' ' or self.out.items[self.out.items.len - 1] == '\t')) {
            self.out.items.len -= 1;
        }
        if (self.out.items[self.out.items.len - 1] != '\n') try self.append("\n");
        // A blank line stands between blocks; one already there is enough.
        if (lines == 2 and !std.mem.endsWith(u8, self.out.items, "\n\n")) try self.append("\n");
        self.at_line_start = true;
    }

    fn append(self: *Page, bytes: []const u8) !void {
        if (self.stopped or bytes.len == 0) return;
        const room = self.limit - @min(self.limit, self.out.items.len);
        if (bytes.len > room) {
            try self.out.appendSlice(self.allocator, bytes[0..room]);
            self.stopped = true;
            return;
        }
        try self.out.appendSlice(self.allocator, bytes);
    }
};

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn isSpace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0b or cp == 0x0c or cp == 0xa0;
}

const Decoded = struct {
    cp: u21,
    next: usize,
};

/// The character one entity stands for, and where the text after it starts.
fn decodeEntity(text: []const u8, at: usize) ?Decoded {
    if (at >= text.len or text[at] != '&') return null;
    const end = std.mem.indexOfScalarPos(u8, text, at, ';') orelse return null;
    if (end - at > 12) return null;
    const name = text[at + 1 .. end];
    if (name.len == 0) return null;

    if (name[0] == '#') {
        if (name.len < 2) return null;
        const digits = name[1..];
        const cp = if (digits[0] == 'x' or digits[0] == 'X')
            std.fmt.parseInt(u21, digits[1..], 16) catch return null
        else
            std.fmt.parseInt(u21, digits, 10) catch return null;
        if (cp == 0 or cp > 0x10ffff) return null;
        return .{ .cp = cp, .next = end + 1 };
    }

    const named = [_]struct { name: []const u8, cp: u21 }{
        .{ .name = "amp", .cp = '&' },
        .{ .name = "lt", .cp = '<' },
        .{ .name = "gt", .cp = '>' },
        .{ .name = "quot", .cp = '"' },
        .{ .name = "apos", .cp = '\'' },
        .{ .name = "nbsp", .cp = '\u{a0}' },
        .{ .name = "copy", .cp = '\u{a9}' },
        .{ .name = "reg", .cp = '\u{ae}' },
        .{ .name = "trade", .cp = '\u{2122}' },
        .{ .name = "hellip", .cp = '\u{2026}' },
        .{ .name = "mdash", .cp = '\u{2014}' },
        .{ .name = "ndash", .cp = '\u{2013}' },
        .{ .name = "lsquo", .cp = '\u{2018}' },
        .{ .name = "rsquo", .cp = '\u{2019}' },
        .{ .name = "ldquo", .cp = '\u{201c}' },
        .{ .name = "rdquo", .cp = '\u{201d}' },
        .{ .name = "laquo", .cp = '\u{ab}' },
        .{ .name = "raquo", .cp = '\u{bb}' },
        .{ .name = "middot", .cp = '\u{b7}' },
        .{ .name = "times", .cp = '\u{d7}' },
        .{ .name = "divide", .cp = '\u{f7}' },
        .{ .name = "bull", .cp = '\u{2022}' },
        .{ .name = "deg", .cp = '\u{b0}' },
        .{ .name = "euro", .cp = '\u{20ac}' },
        .{ .name = "pound", .cp = '\u{a3}' },
        .{ .name = "yen", .cp = '\u{a5}' },
        .{ .name = "sect", .cp = '\u{a7}' },
        .{ .name = "para", .cp = '\u{b6}' },
    };
    for (named) |entity| {
        if (std.ascii.eqlIgnoreCase(entity.name, name)) return .{ .cp = entity.cp, .next = end + 1 };
    }
    return null;
}

/// Elements whose contents are not what a reader reads.
fn isSilent(name: []const u8) bool {
    const silent = [_][]const u8{
        "script", "style", "noscript", "svg", "template", "iframe", "object", "canvas",
    };
    for (silent) |element| {
        if (std.ascii.eqlIgnoreCase(name, element)) return true;
    }
    return false;
}

/// Elements that stand on their own line.
fn isBlock(name: []const u8) bool {
    const blocks = [_][]const u8{
        "address", "article", "aside",   "blockquote", "body",   "center",   "dd",         "details",
        "dialog",  "dir",     "div",     "dl",         "dt",     "fieldset", "figcaption", "figure",
        "footer",  "form",    "header",  "html",       "legend", "main",     "menu",       "nav",
        "ol",      "p",       "section", "summary",    "table",  "tbody",    "tfoot",      "thead",
        "ul",      "video",   "audio",
    };
    for (blocks) |element| {
        if (std.ascii.eqlIgnoreCase(name, element)) return true;
    }
    return false;
}

pub const Close = struct {
    /// Where the contents of the element end.
    content_end: usize,
    /// Where the text after its closing tag starts.
    next: usize,
};

/// Find the closing tag of an element, matched without regard to case.
pub fn findClose(html_text: []const u8, from: usize, name: []const u8) ?Close {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, html_text, i, '<')) |lt| {
        if (lt + 2 + name.len <= html_text.len and
            html_text[lt + 1] == '/' and
            std.ascii.eqlIgnoreCase(html_text[lt + 2 .. lt + 2 + name.len], name))
        {
            const gt = std.mem.indexOfScalarPos(u8, html_text, lt, '>') orelse return .{
                .content_end = lt,
                .next = html_text.len,
            };
            return .{ .content_end = lt, .next = gt + 1 };
        }
        i = lt + 1;
    }
    return null;
}

/// Where the text after a silent element's closing tag starts, which is how its
/// contents are skipped without being read.
fn findElementEnd(html_text: []const u8, from: usize, name: []const u8) ?usize {
    const close = findClose(html_text, from, name) orelse return null;
    return close.next;
}

/// The address a link points at, written whole when that can be worked out from
/// the page it was found on. A link a reader could not follow — a script, an
/// anchor, a mail address — is dropped rather than written out.
fn resolveLink(allocator: std.mem.Allocator, base_url: ?[]const u8, href: []const u8) !?[]u8 {
    const base = base_url orelse {
        const trimmed = std.mem.trim(u8, href, " \t\r\n");
        return if (trimmed.len == 0) null else try allocator.dupe(u8, trimmed);
    };
    return try web.join(allocator, base, href);
}
