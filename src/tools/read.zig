const std = @import("std");
const openai = @import("../model/openai.zig");
const args_mod = @import("args.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");

const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;
const optionalUnsigned = args_mod.optionalUnsigned;

/// One page of a file: where it starts, and how many lines it may hold.
pub const ReadPage = struct {
    /// 1-based number of the first line to read.
    offset: usize = 1,
    /// Number of lines to read; null reads all remaining lines.
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

/// The read tool: one numbered page of one file.
pub const spec: tool.Tool = .{
    .name = "read",
    .description = "Read a file page, numbered by line. Follow the next offset for more; use limit to request fewer lines.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"offset":{"type":"integer","minimum":1,"description":"1-based number of the first line to read; defaults to 1"},"limit":{"type":"integer","minimum":1,"description":"Number of lines to read; defaults to all remaining lines; large results are cached by CCR"}},"required":["path"]}
    ,
    .label = "read…",
    .run = run,
};

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    const path = args_mod.requiredString(ctx.allocator, arguments, "path") catch
        return ctx.refuse("Error: missing 'path' argument");
    defer ctx.allocator.free(path);
    const page = parseReadPage(ctx.allocator, arguments) catch return ctx.refuse(
        "Error: read takes a path plus an optional 'offset' (1-based first line) and 'limit' (line count), both integers of at least 1",
    );
    const result = try readFilePage(ctx.io, ctx.allocator, path, page);
    // A failed read shows nothing that could already be in the conversation.
    if (result.is_error) return result;
    // Read is the one tool whose output a later call can repeat, so the second
    // copy is folded away here, where the page that was asked for and the
    // history it repeats are both at hand.
    defer ctx.allocator.free(result.output);
    return .{
        .output = try deduplicateReadResult(ctx.allocator, history(ctx), arguments, result.output),
        .is_error = false,
    };
}

/// The conversation so far. A call made outside an agent loop has no history
/// to consult, and so nothing to point a repeated page at.
fn history(ctx: tool.Context) []const openai.Message {
    const agent = ctx.agent orelse return &.{};
    return agent.history.items;
}

/// The marker standing in for a read whose output is already in the history.
/// The reference it carries is only a pointer, which is why the original
/// result it names is never treated as a cache hit.
const duplicate_marker = "[Duplicate read omitted: same path, page and content SHA-256={s}. See earlier tool result {s} in this context.]";

/// Keep one full copy of identical read output in the live context. Do not
/// treat a marker as a cache hit: once the original result is gone, the model
/// must receive the contents again rather than a reference to a missing
/// message. The returned string is owned by the caller, just like a normal
/// tool result, and `content` stays the caller's.
pub fn deduplicateReadResult(
    allocator: std.mem.Allocator,
    messages: []const openai.Message,
    arguments: []const u8,
    content: []const u8,
) ![]u8 {
    if (try readKey(allocator, arguments, content)) |digest| {
        for (messages, 0..) |message, index| {
            if (!std.mem.eql(u8, message.role, "tool")) continue;
            const id = message.tool_call_id orelse continue;
            const previous_content = (message.tool_result orelse continue).output;
            // A duplicate marker cannot stand in for a full result.
            if (!std.mem.eql(u8, previous_content, content)) continue;
            var previous_index = index;
            while (previous_index > 0) {
                previous_index -= 1;
                const calls = messages[previous_index].tool_calls orelse continue;
                for (calls) |previous_call| {
                    if (!std.mem.eql(u8, previous_call.id, id)) continue;
                    // Only a read can repeat a read.
                    if (!std.mem.eql(u8, previous_call.name, spec.name)) break;
                    const previous_key = try readKey(allocator, previous_call.arguments, previous_content) orelse break;
                    if (std.mem.eql(u8, &digest, &previous_key)) {
                        var content_digest: [32]u8 = undefined;
                        std.crypto.hash.sha2.Sha256.hash(content, &content_digest, .{});
                        const marker = try std.fmt.allocPrint(allocator, duplicate_marker, .{ std.fmt.bytesToHex(content_digest, .lower), id });
                        if (marker.len < content.len) return marker;
                        allocator.free(marker);
                        return allocator.dupe(u8, content);
                    }
                    break;
                }
            }
        }
    }
    return allocator.dupe(u8, content);
}

/// Hash the effective read arguments plus output, not the JSON spelling.
/// Path spelling is intentionally exact: resolving aliases could conflate
/// paths whose targets change between reads.
fn readKey(allocator: std.mem.Allocator, arguments: []const u8, content: []const u8) !?[32]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path = parsed.value.object.get("path") orelse return null;
    if (path != .string) return null;
    const page = parseReadPage(allocator, arguments) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(path.string);
    // A length prefix prevents a path from being confused with page bytes.
    var fields: [24]u8 = undefined;
    std.mem.writeInt(u64, fields[0..8], @intCast(path.string.len), .little);
    std.mem.writeInt(u64, fields[8..16], @intCast(page.offset), .little);
    // 0 is a limit no caller can ask for, so it marks the page that has none.
    std.mem.writeInt(u64, fields[16..24], @intCast(page.limit orelse 0), .little);
    hash.update(&fields);
    hash.update(content);
    return hash.finalResult();
}

/// Read a page of a file, each line carrying the number it has in the file.
///
/// The page starts at `offset` and holds up to `limit` lines, or all remaining
/// lines when no limit is supplied. It always ends on a line boundary, so the offset it reports
/// as the next one is a line the model has not seen a part of.
pub fn readFilePage(io: std.Io, allocator: std.mem.Allocator, path: []const u8, page: ReadPage) !ToolResult {
    if (page.offset == 0 or (page.limit != null and page.limit.? == 0))
        return toolError(allocator, "Error: offset is a 1-based line number and limit a count of lines; both must be at least 1", .{});
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        return .{
            .output = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
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
    while (page.limit == null or shown < page.limit.?) {
        const ending = readLine(reader, allocator, &current, std.math.maxInt(usize)) catch |err|
            return toolError(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) });
        if (ending == .eof) break;
        try appendNumberedLine(&body, allocator, line, current.items);
        shown += 1;
        line += 1;
    }
    // A page that stopped because it had shown `limit` lines only continues if
    // another line is there; the file may have ended exactly on the limit.
    if (resumes_at == null and page.limit != null and shown == page.limit.?) {
        if ((reader.peekByte() catch null) != null) resumes_at = line;
    }

    // The page is handed over as the file holds it. Reading is how the model
    // gets the exact text of what it means to quote, copy or patch, so nothing
    // is rewritten on the way out: a sanitiser here would drop escape
    // sequences and escape bytes that are not UTF-8, handing the model text
    // that is not in the file. The screen is guarded where it is written.
    if (resumes_at) |next| {
        return .{
            .output = try std.fmt.allocPrint(allocator, "{s}\n[Output truncated; continue with offset={d} (1-based line number).]", .{ std.mem.trimEnd(u8, body.items, "\n"), next }),
            .is_error = false,
        };
    }
    return .{ .output = try allocator.dupe(u8, body.items), .is_error = false };
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
        page.output,
    );
    try std.testing.expect(std.mem.indexOf(u8, page.output, "continue with offset=4") != null);

    const tail = try readFilePage(io, a, path, .{ .offset = 4 });
    defer tail.deinit(a);
    try std.testing.expectEqualStrings("4:last\n", tail.output);

    // A page past the last line has no lines to show: the page is empty, and
    // says nothing a file does not.
    const beyond = try readFilePage(io, a, path, .{ .offset = 5 });
    defer beyond.deinit(a);
    try std.testing.expectEqualStrings("", beyond.output);

    // Even a first line larger than the presentation budget is returned whole.
    const full = try readFilePage(io, a, path, .{});
    defer full.deinit(a);
    try std.testing.expect(!full.is_error);
    try std.testing.expect(std.mem.startsWith(u8, full.output, "1:xxx"));
    try std.testing.expect(std.mem.indexOf(u8, full.output, "4:last") != null);
    // The cache, not the file reader, owns the presentation budget: a read of
    // a large file is handed over whole and cached afterwards.
    try std.testing.expect(full.output.len > @import("ccr.zig").max_output_bytes);
}

test "read returns every line when no explicit limit is supplied" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    // More lines than one page holds, so the first page has to stop and say
    // where the next one starts.
    var index: usize = 0;
    const page_bytes = @import("ccr.zig").page_room_bytes;
    while (buffer.items.len <= page_bytes * 2) : (index += 1) try buffer.print(a, "line {d}\n", .{index});
    try tmp.dir.writeFile(io, .{ .sub_path = "lines.txt", .data = buffer.items });
    const path = try tmp.dir.realPathFileAlloc(io, "lines.txt", a);
    defer a.free(path);

    const first = try readFilePage(io, a, path, .{});
    defer first.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, first.output, "1:line 0\n"));
    try std.testing.expectEqual(index, std.mem.count(u8, first.output, "\n"));
}

test "read preserves a line longer than a page without splitting a character" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    while (buffer.items.len <= @import("ccr.zig").page_room_bytes) try buffer.appendSlice(a, "你");
    try tmp.dir.writeFile(io, .{ .sub_path = "utf8", .data = buffer.items });
    const path = try tmp.dir.realPathFileAlloc(io, "utf8", a);
    defer a.free(path);

    const result = try readFilePage(io, a, path, .{});
    defer result.deinit(a);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.output));
    try std.testing.expectEqual(buffer.items.len + 3, result.output.len);
    try std.testing.expectEqualStrings(buffer.items, result.output[2 .. result.output.len - 1]);
}

test "read hands back the file's bytes as they are" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A cursor-move sequence and a byte that is not UTF-8 are the file's own
    // contents: a model reading it to copy it exactly must get them back
    // unchanged, not dropped or escaped.
    const raw = "\x1b[2Jred\xff\nsecond\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "raw.txt", .data = raw });
    const path = try tmp.dir.realPathFileAlloc(io, "raw.txt", a);
    defer a.free(path);

    const result = try readFilePage(io, a, path, .{});
    defer result.deinit(a);
    try std.testing.expectEqualStrings("1:\x1b[2Jred\xff\n2:second\n", result.output);
}

test "read missing file" {
    const result = try readFilePage(std.testing.io, std.testing.allocator, "/nonexistent/path/file.txt", .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

test "read deduplication compares effective arguments and contents only in live history" {
    const a = std.testing.allocator;
    const long_content = "file contents: abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    var calls = [_]openai.ToolCallData{.{ .id = "original", .name = "read", .arguments = "{\"path\":\"a.zig\"}" }};
    const messages = [_]openai.Message{
        .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null },
        .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "original", .tool_result = .{ .output = long_content, .is_error = false } },
    };
    const duplicate = try deduplicateReadResult(a, &messages, "{ \"offset\": 1, \"path\": \"a.zig\" }", long_content);
    defer a.free(duplicate);
    try std.testing.expect(std.mem.startsWith(u8, duplicate, "[Duplicate read omitted:"));
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "original") != null);

    const Case = struct { args: []const u8 = "{\"path\":\"a.zig\"}", content: []const u8 = long_content };
    for ([_]Case{
        .{ .args = "{\"path\":\"b.zig\"}" },
        .{ .args = "{\"path\":\"a.zig\",\"offset\":2}" },
        .{ .args = "{\"path\":\"a.zig\",\"limit\":1}" },
        .{ .args = "{\"path\":\"a.zig\",\"offset\":1,\"limit\":5}" },
        .{ .content = "changed contents" },
        .{ .args = "{\"path\":\"a.zig\",\"offset\":0}" },
    }) |case| {
        const result = try deduplicateReadResult(a, &messages, case.args, case.content);
        defer a.free(result);
        try std.testing.expectEqualStrings(case.content, result);
    }

    // The original result is gone. A remaining marker is not a cache hit.
    const compacted = [_]openai.Message{
        messages[0],
        .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "original", .tool_result = .{ .output = duplicate, .is_error = false } },
    };
    // Only a read repeats a read: the same arguments under another tool's
    // name say nothing about this page having been in the context.
    var other = [_]openai.ToolCallData{.{ .id = "original", .name = "bash", .arguments = calls[0].arguments }};
    const renamed = [_]openai.Message{ .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = &other, .tool_call_id = null }, messages[1] };
    const other_tool = try deduplicateReadResult(a, &renamed, calls[0].arguments, long_content);
    defer a.free(other_tool);
    try std.testing.expectEqualStrings(long_content, other_tool);

    const reread = try deduplicateReadResult(a, &compacted, calls[0].arguments, long_content);
    defer a.free(reread);
    try std.testing.expectEqualStrings(long_content, reread);
    const empty = try deduplicateReadResult(a, &.{}, calls[0].arguments, long_content);
    defer a.free(empty);
    try std.testing.expectEqualStrings(long_content, empty);

    // Even identical reads must not grow the context (including equal sizes).
    const boundary = try std.fmt.allocPrint(a, duplicate_marker, .{ "0000000000000000000000000000000000000000000000000000000000000000", "original" });
    defer a.free(boundary);
    for ([_][]const u8{ "", "short", boundary }) |content| {
        const short_messages = [_]openai.Message{
            messages[0],
            .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "original", .tool_result = .{ .output = content, .is_error = false } },
        };
        const result = try deduplicateReadResult(a, &short_messages, calls[0].arguments, content);
        defer a.free(result);
        try std.testing.expectEqualStrings(content, result);
    }
}
