//! The rest of a call's line: its arguments, named rather than serialised.
//!
//! A call reaches a tool as JSON, and a line that shows that JSON as it arrived
//! is showing a serialisation to someone who wanted to read an intention:
//! `⚙ read {"path":"src/main.zig","offset":40,"limit":20}` is the same call as
//! `⚙ read src/main.zig · offset 40 · limit 20`, and only the second one is read
//! without decoding braces and quotes by eye. A block of content in the
//! arguments — `write` carries a whole file — makes the difference sharper
//! still: the first form is the file, escaped, on the terminal.
//!
//! So a tool names the arguments worth showing in its own spec (`Tool.summary`),
//! through `writeFields` below. A tool whose arguments this program does not
//! know — an MCP server's — gets `writeObject`, which names all of them and cuts
//! each one short. Neither writes a control byte: this is model output, and it
//! is sanitised as it is written.
const std = @import("std");
const sanitize = @import("../util/terminal/sanitize.zig");
const term = @import("../ui/term.zig");
const util = @import("util.zig");

/// What one argument value may take of the line before it is cut. A shell
/// command is worth reading to its end; an MCP argument holding a file is not.
const value_bytes: usize = 200;

/// Between one argument and the next.
const separator = " · ";

/// Write the arguments `fields` names, in that order, as one line:
/// `src/main.zig · offset 40 · limit 20`.
///
/// The first one is written bare, because it is what the call is about; the ones
/// after it carry their names, so that no two values are read as one. An
/// argument the call did not send, an empty string and a flag that is off are
/// left out: the line says what the call asked for, and a default is not
/// something it asked for.
///
/// Answers whether anything was written. A tool whose arguments it cannot read
/// says so, and its call keeps the raw text: that is the one case where the JSON
/// is all there is to show.
pub fn writeFields(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    arguments: []const u8,
    fields: []const []const u8,
) !bool {
    const parsed = parseObject(allocator, arguments) orelse return false;
    defer parsed.deinit();
    var line: Line = .{ .w = w, .allocator = allocator };
    for (fields) |field| try line.field(field, parsed.value.object.get(field) orelse continue);
    return line.written;
}

/// The same for a call whose arguments no spec here describes: every field it
/// carries, in the order it sent them.
pub fn writeObject(w: *std.Io.Writer, allocator: std.mem.Allocator, arguments: []const u8) !bool {
    const parsed = parseObject(allocator, arguments) orelse return false;
    defer parsed.deinit();
    var line: Line = .{ .w = w, .allocator = allocator };
    var fields = parsed.value.object.iterator();
    while (fields.next()) |entry| try line.field(entry.key_ptr.*, entry.value_ptr.*);
    return line.written;
}

/// Write one argument value on the call's line: sanitised onto one line, and cut
/// where it stops being worth reading.
pub fn writeText(w: *std.Io.Writer, raw: []const u8) !void {
    const cut = util.truncateUtf8(raw, value_bytes);
    try sanitize.writeOnOneLine(w, cut);
    if (cut.len < raw.len) try w.writeAll("…");
}

/// Write `text` cut to `avail` columns, ending in `…` when something was lost,
/// so that a call stays one line whatever it was asked to do.
///
/// `text` carries no escape sequences — it is a summary, which is sanitised as it
/// is built — so it can be measured and cut by column.
pub fn writeFitted(w: *std.Io.Writer, text: []const u8, avail: usize) !void {
    if (term.width(text) <= avail) return w.writeAll(text);
    const fit = term.takeFit(text, avail -| 1);
    try w.writeAll(text[0..fit]);
    return w.writeAll("…");
}

/// The arguments as the object they should be, or null when they are not one.
fn parseObject(allocator: std.mem.Allocator, arguments: []const u8) ?std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch return null;
    if (parsed.value != .object) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

/// One line being built: where it goes, and whether anything yet has.
const Line = struct {
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    written: bool = false,

    fn field(self: *Line, name: []const u8, value: std.json.Value) !void {
        switch (value) {
            .null => return,
            .string => |text| {
                if (text.len == 0) return;
            },
            // A flag that is off is the default, and says nothing.
            .bool => |on| {
                if (!on) return;
            },
            else => {},
        }
        // A flag carries its name as the whole of what it says: `hidden`, not
        // `hidden true`.
        const flag = value == .bool;
        if (self.written) try self.w.writeAll(separator);
        if (flag) {
            try sanitize.writeOnOneLine(self.w, name);
        } else {
            if (self.written) {
                try sanitize.writeOnOneLine(self.w, name);
                try self.w.writeByte(' ');
            }
            try self.writeValue(value);
        }
        self.written = true;
    }

    fn writeValue(self: *Line, value: std.json.Value) !void {
        switch (value) {
            .string => |text| try writeText(self.w, text),
            .integer => |number| try self.w.print("{d}", .{number}),
            .float => |number| try self.w.print("{d}", .{number}),
            .number_string => |text| try writeText(self.w, text),
            // A nested value has no line of its own to be read on; it is shown
            // as the JSON it is, cut short like any other long argument.
            else => {
                var encoded: std.Io.Writer.Allocating = .init(self.allocator);
                defer encoded.deinit();
                try std.json.Stringify.value(value, .{}, &encoded.writer);
                try writeText(self.w, encoded.written());
            },
        }
    }
};

test "the fields a tool names are written as one line, the first one bare" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expect(try writeFields(&out.writer, a, "{\"path\":\"src/main.zig\",\"offset\":40,\"limit\":20}", &.{ "path", "offset", "limit" }));
    try std.testing.expectEqualStrings("src/main.zig · offset 40 · limit 20", out.written());
}

test "absent, empty and false arguments are left out of the line" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expect(try writeFields(&out.writer, a, "{\"pattern\":\"fn run\",\"path\":\"\",\"ignore_case\":false,\"hidden\":true}", &.{ "pattern", "path", "ignore_case", "hidden" }));
    // A flag that is on says its name and nothing else.
    try std.testing.expectEqualStrings("fn run · hidden", out.written());
}

test "a command is flattened onto the line and kept whole" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expect(try writeFields(&out.writer, a, "{\"command\":\"cd src\\nmake -j8\"}", &.{"command"}));
    try std.testing.expectEqualStrings("cd src make -j8", out.written());
}

test "arguments that are not an object are not a line" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expect(!try writeFields(&out.writer, a, "not json", &.{"path"}));
    try std.testing.expect(!try writeFields(&out.writer, a, "{}", &.{"path"}));
    try std.testing.expect(!try writeFields(&out.writer, a, "[1,2]", &.{"path"}));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "a tool this program does not know still names every argument it was sent" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.testing.expect(try writeObject(&out.writer, a, "{\"path\":\"/tmp\",\"depth\":2,\"nested\":{\"a\":1}}"));
    try std.testing.expectEqualStrings("/tmp · depth 2 · nested {\"a\":1}", out.written());
}

test "a long argument is cut, a wide one too" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const long: [value_bytes + 10]u8 = @splat('x');
    try writeText(&out.writer, &long);
    try std.testing.expectEqual(value_bytes + "…".len, out.written().len);

    out.clearRetainingCapacity();
    try writeFitted(&out.writer, "make -j8 test", 8);
    try std.testing.expectEqualStrings("make -j…", out.written());
}

test "a line that fits is written as it is, and never splits a character" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeFitted(&out.writer, "make test", 40);
    try std.testing.expectEqualStrings("make test", out.written());

    out.clearRetainingCapacity();
    // Two columns per character: the cut lands between the two of them.
    try writeFitted(&out.writer, "搜索工具调用", 6);
    try std.testing.expectEqualStrings("搜索…", out.written());
}
