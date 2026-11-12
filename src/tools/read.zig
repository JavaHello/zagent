const std = @import("std");
const args_mod = @import("args.zig");
const result_mod = @import("result.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;
const finalizeToolContent = result_mod.finalizeToolContent;
const max_output_bytes = result_mod.max_output_bytes;
const page_room_bytes = result_mod.page_room_bytes;
const optionalUnsigned = args_mod.optionalUnsigned;
const truncateUtf8 = util.truncateUtf8;

/// One page of a file: where it starts, and how many lines it may hold.
pub const ReadPage = struct {
    /// 1-based number of the first line to read.
    offset: usize = 1,
    /// Number of lines to read; null reads as many as the output page holds.
    limit: ?usize = null,
};

pub fn parseReadPage(allocator: std.mem.Allocator, arguments: []const u8) !ReadPage {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const fields = parsed.value.object;
    return .{
        .offset = (try optionalUnsigned(fields.get("offset"), 1)) orelse 1,
        .limit = try optionalUnsigned(fields.get("limit"), 1),
    };
}

pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ToolResult {
    return readFilePage(io, allocator, path, .{});
}

/// How one attempt to read a line ended.
pub const LineEnd = enum {
    /// A whole line is in the buffer, without its terminator.
    line,
    /// The file ended before the buffer held anything.
    eof,
    /// The line is longer than the cap it was read against, and was abandoned.
    too_long,
};

/// Read the next line into `out`, holding at most `cap` bytes of it. A CRLF
/// terminator is normalised away, so a page is one line per row either way.
pub fn readLine(reader: *std.Io.Reader, allocator: std.mem.Allocator, out: *std.ArrayList(u8), cap: usize) !LineEnd {
    out.clearRetainingCapacity();
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (out.items.len == 0) .eof else .line,
            else => return err,
        };
        if (byte == '\n') {
            if (out.items.len > 0 and out.items[out.items.len - 1] == '\r') out.items.len -= 1;
            return .line;
        }
        if (out.items.len == cap) return .too_long;
        try out.append(allocator, byte);
    }
}

/// Consume one line without holding any of it. False means the file ended
/// before a line was there.
pub fn skipLine(reader: *std.Io.Reader) !bool {
    var consumed = false;
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return consumed,
            else => return err,
        };
        consumed = true;
        if (byte == '\n') return true;
    }
}

/// Bytes a numbered line spends before its text: the digits and a `:`. The
/// digits are not padded, so the cost is measured per line.
pub fn linePrefixWidth(number: usize) usize {
    var digits: usize = 1;
    var rest = number;
    while (rest >= 10) : (rest /= 10) digits += 1;
    return digits + 1;
}

/// Number a line as `42:`, so a model reading the page can copy a reference
/// that reads as one, rather than a bare figure in a column it has to count.
pub fn appendNumberedLine(body: *std.ArrayList(u8), allocator: std.mem.Allocator, number: usize, line_text: []const u8) !void {
    var digits_buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{number}) catch unreachable;
    try body.appendSlice(allocator, digits);
    try body.append(allocator, ':');
    try body.appendSlice(allocator, line_text);
    try body.append(allocator, '\n');
}

/// Read a page of a file, each line carrying the number it has in the file.
///
/// The page starts at `offset` and holds up to `limit` lines, or as many as fit
/// the output cap. It always ends on a line boundary, so the offset it reports
/// as the next one is a line the model has not seen a part of.
pub fn readFilePage(io: std.Io, allocator: std.mem.Allocator, path: []const u8, page: ReadPage) !ToolResult {
    if (page.offset == 0 or (page.limit != null and page.limit.? == 0))
        return toolError(allocator, "Error: offset is a 1-based line number and limit a count of lines; both must be at least 1", .{});
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    // Lines before the page are skipped rather than read, so an offset deep
    // into a large file costs one pass and no memory.
    var line: usize = 1;
    while (line < page.offset) {
        const skipped = skipLine(reader) catch |err|
            return toolError(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) });
        if (!skipped) break;
        line += 1;
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var shown: usize = 0;
    // The line the next page starts at, when this one stopped short.
    var resumes_at: ?usize = null;
    // The one line that is longer than a page can hold, when that is why.
    var cut_line: ?usize = null;
    while (page.limit == null or shown < page.limit.?) {
        const ending = readLine(reader, allocator, &current, page_room_bytes) catch |err|
            return toolError(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) });
        if (ending == .eof) break;
        // A page ends on a line boundary, and the line prefix counts against it.
        if (body.items.len + linePrefixWidth(line) + current.items.len + 1 > page_room_bytes) {
            if (shown == 0) {
                // A single line fills the page and more: pass on its beginning
                // so the model has somewhere to start, and say where it stops.
                const room = page_room_bytes - linePrefixWidth(line) - 1;
                try appendNumberedLine(&body, allocator, line, truncateUtf8(current.items, room));
                cut_line = line;
            } else resumes_at = line;
            break;
        }
        try appendNumberedLine(&body, allocator, line, current.items);
        shown += 1;
        line += 1;
    }
    // A page that stopped because it had shown `limit` lines only continues if
    // another line is there; the file may have ended exactly on the limit.
    if (resumes_at == null and cut_line == null and page.limit != null and shown == page.limit.?) {
        if ((reader.peekByte() catch null) != null) resumes_at = line;
    }

    const normalized = try finalizeToolContent(allocator, body.items);
    const body_text = std.mem.trimEnd(u8, normalized, "\n");
    if (resumes_at) |next| {
        defer allocator.free(normalized);
        return .{
            .content = try std.fmt.allocPrint(allocator, "{s}\n[Output truncated; continue with offset={d} (1-based line number).]", .{ body_text, next }),
            .is_error = false,
            .truncated = true,
        };
    }
    if (cut_line) |number| {
        defer allocator.free(normalized);
        return .{
            .content = try std.fmt.allocPrint(allocator, "{s}\n[Line {d} alone is longer than a page holds and was cut; read the rest of it with bash.]", .{ body_text, number }),
            .is_error = false,
            .truncated = true,
        };
    }
    return .{ .content = normalized, .is_error = false, .truncated = false };
}

test "read takes a 1-based offset and a line limit" {
    const a = std.testing.allocator;
    const defaults = try parseReadPage(a, "{}");
    try std.testing.expectEqual(@as(usize, 1), defaults.offset);
    try std.testing.expect(defaults.limit == null);
    for ([_][]const u8{
        "[]",                "{\"offset\":0}",   "{\"offset\":-1}",
        "{\"limit\":0}",     "{\"offset\":1.5}", "{\"limit\":\"2\"}",
        "{\"offset\":null}", "{\"limit\":null}",
    }) |json| try std.testing.expectError(error.InvalidArguments, parseReadPage(a, json));
    const page = try parseReadPage(a, "{\"offset\":100,\"limit\":50}");
    try std.testing.expectEqual(@as(usize, 100), page.offset);
    try std.testing.expectEqual(@as(?usize, 50), page.limit);
}

test "read prefixes every line with the number it has in the file" {
    try std.testing.expectEqual(@as(usize, 2), linePrefixWidth(1));
    try std.testing.expectEqual(@as(usize, 7), linePrefixWidth(999999));
    try std.testing.expectEqual(@as(usize, 8), linePrefixWidth(1000000));
}

test "read streams a page from deep in a large file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    // More than 1 MiB before the target, without allocating skipped lines.
    try data.appendNTimes(a, 'x', 1024 * 1024 + 1);
    try data.appendSlice(a, "\none\r\ntwo\nlast");
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = data.items });
    const path = try tmp.dir.realPathFileAlloc(io, "large.txt", a);
    defer a.free(path);

    // A page is numbered by the line's place in the file, not by its place in
    // the page, and a CRLF terminator does not survive into the output.
    const page = try readFilePage(io, a, path, .{ .offset = 2, .limit = 2 });
    defer page.deinit(a);
    try std.testing.expect(!page.is_error);
    try std.testing.expectEqualStrings(
        "2:one\n3:two\n[Output truncated; continue with offset=4 (1-based line number).]",
        page.content,
    );
    try std.testing.expect(page.truncated);

    const tail = try readFilePage(io, a, path, .{ .offset = 4 });
    defer tail.deinit(a);
    try std.testing.expectEqualStrings("4:last\n", tail.content);
    try std.testing.expect(!tail.truncated);

    // A page past the last line has nothing to show, and says so.
    const beyond = try readFilePage(io, a, path, .{ .offset = 5 });
    defer beyond.deinit(a);
    try std.testing.expectEqualStrings("(no output)", beyond.content);

    // The first line alone is larger than a page, so it is cut and named.
    const full = try readFile(io, a, path);
    defer full.deinit(a);
    try std.testing.expect(!full.is_error);
    try std.testing.expect(full.truncated);
    try std.testing.expect(std.mem.startsWith(u8, full.content, "1:xxx"));
    try std.testing.expect(std.mem.indexOf(u8, full.content, "Line 1 alone is longer") != null);
    // The page plus its notice stays inside the limit a result is held to.
    try std.testing.expect(full.content.len <= max_output_bytes);
}

test "read continues at a line boundary the model has not seen" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    // More lines than one page holds, so the first page has to stop and say
    // where the next one starts.
    var index: usize = 0;
    while (buffer.items.len <= page_room_bytes * 2) : (index += 1) try buffer.print(a, "line {d}\n", .{index});
    try tmp.dir.writeFile(io, .{ .sub_path = "lines.txt", .data = buffer.items });
    const path = try tmp.dir.realPathFileAlloc(io, "lines.txt", a);
    defer a.free(path);

    const first = try readFilePage(io, a, path, .{});
    defer first.deinit(a);
    try std.testing.expect(first.truncated);
    try std.testing.expect(std.mem.startsWith(u8, first.content, "1:line 0\n"));
    // Every row is a whole line; the next page starts at the first one skipped.
    const rows = std.mem.count(u8, first.content, "\n");
    const hint = try std.fmt.allocPrint(a, "offset={d} ", .{rows + 1});
    defer a.free(hint);
    try std.testing.expect(std.mem.indexOf(u8, first.content, hint) != null);
    try std.testing.expect(std.mem.endsWith(u8, first.content, "(1-based line number).]"));

    const next = try readFilePage(io, a, path, .{ .offset = rows + 1, .limit = 1 });
    defer next.deinit(a);
    const expected = try std.fmt.allocPrint(a, "{d}:line {d}\n[Output truncated; continue with offset={d} (1-based line number).]", .{ rows + 1, rows, rows + 2 });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, next.content);
}

test "read cuts a line longer than a page without splitting a character" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    while (buffer.items.len <= page_room_bytes) try buffer.appendSlice(a, "你");
    try tmp.dir.writeFile(io, .{ .sub_path = "utf8", .data = buffer.items });
    const path = try tmp.dir.realPathFileAlloc(io, "utf8", a);
    defer a.free(path);

    const result = try readFilePage(io, a, path, .{});
    defer result.deinit(a);
    try std.testing.expect(result.truncated);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.content));
    try std.testing.expect(std.mem.indexOf(u8, result.content, "你") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Line 1 alone is longer") != null);
    // The line was given all the room its prefix left, cut back to a character.
    const room = std.mem.indexOf(u8, result.content, "\n").? - "1:".len;
    // Include the newline in the page budget before rounding to UTF-8.
    try std.testing.expect(room <= page_room_bytes - "1:".len - 1);
    try std.testing.expect(room > page_room_bytes - "1:".len - 1 - 3);
    try std.testing.expectEqual(@as(usize, 0), room % 3);
}

test "read missing file" {
    const result = try readFile(std.testing.io, std.testing.allocator, "/nonexistent/path/file.txt");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}
