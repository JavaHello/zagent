//! Cached command output — "ccr" for the cache a `bash` call's output is kept
//! in when it is too long for one tool result to carry.
//!
//! The whole text is written to a file inside this run's scratch directory and
//! the model is handed the last lines of it plus an id. `ccr_retrieve` pages
//! that file the way `read` pages a source file, or finds lines in it by query.
//!
//! An entry is named after its content, so a large task that caches the same
//! output twice — a command rerun, a page read again, a file read again — keeps
//! one file and answers both calls with the same id.
//!
//! The cache is as temporary as the run: it lives under the scratch directory,
//! which `/new` empties and the process removes on exit. An id from an earlier
//! session therefore names nothing, and the tool says so rather than guessing.
const std = @import("std");
const args_mod = @import("args.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const read = @import("read.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;
const finalizeToolContent = result_mod.finalizeToolContent;
const page_room_bytes = result_mod.page_room_bytes;
const optionalUnsigned = args_mod.optionalUnsigned;
const truncateUtf8 = util.truncateUtf8;

/// The sub-directory of a run's scratch directory that holds cached output. It
/// is inside the scratch directory on purpose: nothing here is meant to outlive
/// the run that wrote it.
pub const dir_name = "ccr";

/// How long an id is, in hex characters: the first six bytes of the entry's
/// SHA-256, so the same output always takes the same name. Long enough that two
/// entries of one session do not meet, short enough to be quoted in a result.
pub const id_len = 12;
/// Random bytes behind the name an entry is created with, before its content is
/// known: `id_len` hex characters.
const id_bytes = id_len / 2;

/// A line longer than this is not matched against a query and not shown: the
/// tool is for reading command output, and a single line that big is one the
/// model has to narrow anyway.
const max_line_bytes: usize = 1024 * 1024;

/// Where a cached entry for this run lives, given the run's scratch directory.
pub fn dirPath(allocator: std.mem.Allocator, scratch_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ scratch_path, dir_name });
}

fn filePath(allocator: std.mem.Allocator, dir: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ dir, id });
}

/// What a cached entry holds, and what the result that named it reports.
pub const Saved = struct {
    /// The id the entry is read back with.
    id: [id_len]u8,
    /// Lines in the whole output: what `offset` counts when no query is given.
    lines: usize,
    /// Bytes of the whole output, as the model reads its size.
    bytes: usize,
};

/// The number of lines in `text`: a trailing terminator ends the last line
/// rather than starting an empty one. Empty text is no lines at all.
pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var lines: usize = 1;
    for (text) |byte| {
        if (byte == '\n') lines += 1;
    }
    if (text[text.len - 1] == '\n') lines -= 1;
    return lines;
}

/// An entry written while the output that fills it is still arriving.
///
/// A command's output is streamed into the cache as it comes off the pipe, so
/// the copy on disk costs this process nothing to hold. The line and byte
/// counts are kept as it is written, which is what a result naming the entry
/// reports. The content is hashed on the way in, so an entry can be renamed
/// after what it holds once it is closed.
pub const Stream = struct {
    file: std.Io.File,
    /// Owned; freed by `deinit`.
    path: []u8,
    id: [id_len]u8,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    bytes: usize = 0,
    newlines: usize = 0,
    last_byte: u8 = 0,
    closed: bool = false,

    /// Append what the program just said.
    pub fn write(self: *Stream, io: std.Io, data: []const u8) !void {
        if (data.len == 0) return;
        try self.file.writeStreamingAll(io, data);
        for (data) |byte| {
            if (byte == '\n') self.newlines += 1;
        }
        self.hash.update(data);
        self.bytes += data.len;
        self.last_byte = data[data.len - 1];
    }

    /// Close the entry and answer what it holds. A line count is the one
    /// `countLines` would give for the same text: a trailing terminator ends
    /// the last line rather than starting an empty one. The id is the one its
    /// content gives it, which is the name it is kept under.
    pub fn finish(self: *Stream, io: std.Io) Saved {
        self.close(io);
        const lines = self.newlines + @intFromBool(self.bytes > 0 and self.last_byte != '\n');
        return .{ .id = self.contentName(io), .lines = lines, .bytes = self.bytes };
    }

    /// Rename the closed entry after its content — the first `id_len` hex
    /// characters of its SHA-256 — and answer the id it is read back with. An
    /// entry that finds another of the same content already under that name is
    /// the duplicate of it and is dropped, which is what keeps one file per
    /// distinct output however many calls produce it. Renaming is best effort:
    /// an entry that cannot take the content name keeps the unique one it was
    /// created with, rather than its content being lost.
    fn contentName(self: *Stream, io: std.Io) [id_len]u8 {
        const dir = std.fs.path.dirname(self.path) orelse return self.id;
        const id: [id_len]u8 = std.fmt.bytesToHex(self.hash.finalResult(), .lower)[0..id_len].*;
        var name: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const target = std.fmt.bufPrint(&name, "{s}/{s}.log", .{ dir, id }) catch return self.id;
        const cwd = std.Io.Dir.cwd();
        cwd.renamePreserve(self.path, cwd, target, io) catch |err| switch (err) {
            // The name is taken. With the same content behind it this entry is
            // the copy, and the one already there answers for both.
            error.PathAlreadyExists => {
                if (sameContent(io, self.path, target)) {
                    std.Io.Dir.deleteFileAbsolute(io, self.path) catch {};
                    return id;
                }
                return self.id;
            },
            else => return self.id,
        };
        return id;
    }

    /// Give up on the entry: the output it holds is not worth reading back —
    /// the run passed its deadline, so there is no result to name it in.
    pub fn abandon(self: *Stream, io: std.Io, allocator: std.mem.Allocator) void {
        self.close(io);
        if (self.path.len > 0) std.Io.Dir.deleteFileAbsolute(io, self.path) catch {};
        self.deinit(io, allocator);
    }

    /// Release the entry's file and name. Safe after `finish`, and called
    /// unconditionally by way of `defer`.
    pub fn deinit(self: *Stream, io: std.Io, allocator: std.mem.Allocator) void {
        self.close(io);
        if (self.path.len > 0) {
            allocator.free(self.path);
            self.path = &.{};
        }
    }

    fn close(self: *Stream, io: std.Io) void {
        if (self.closed) return;
        self.file.close(io);
        self.closed = true;
    }
};

/// Whether two entries hold the same bytes: their sizes first, then their
/// content in chunks, stopping at the first difference. A shared prefix of a
/// digest is not proof enough to answer one entry's name with another's content.
fn sameContent(io: std.Io, first_path: []const u8, second_path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const first_stat = cwd.statFile(io, first_path, .{}) catch return false;
    const second_stat = cwd.statFile(io, second_path, .{}) catch return false;
    if (first_stat.size != second_stat.size) return false;
    const first = std.Io.Dir.openFileAbsolute(io, first_path, .{}) catch return false;
    defer first.close(io);
    const second = std.Io.Dir.openFileAbsolute(io, second_path, .{}) catch return false;
    defer second.close(io);
    var first_buf: [8 * 1024]u8 = undefined;
    var second_buf: [8 * 1024]u8 = undefined;
    var first_reader = first.reader(io, &first_buf);
    var second_reader = second.reader(io, &second_buf);
    var first_chunk: [4 * 1024]u8 = undefined;
    var second_chunk: [4 * 1024]u8 = undefined;
    while (true) {
        const first_len = first_reader.interface.readSliceShort(&first_chunk) catch return false;
        const second_len = second_reader.interface.readSliceShort(&second_chunk) catch return false;
        if (first_len != second_len) return false;
        if (first_len == 0) return true;
        if (!std.mem.eql(u8, first_chunk[0..first_len], second_chunk[0..second_len])) return false;
    }
}

/// Start an entry under `dir`. Its name is reserved before anything is written
/// so that two entries being written at once cannot take the same one; `finish`
/// renames what it holds after its content. The directory is created on first
/// use, so a run that never prints that much never leaves one behind.
pub fn createStream(io: std.Io, allocator: std.mem.Allocator, dir: []const u8) !Stream {
    std.Io.Dir.createDirAbsolute(io, dir, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    for (0..16) |_| {
        var random: [id_bytes]u8 = undefined;
        std.Io.random(io, &random);
        const id: [id_len]u8 = std.fmt.bytesToHex(random, .lower);
        const path = try filePath(allocator, dir, &id);
        errdefer allocator.free(path);
        const file = std.Io.Dir.createFileAbsolute(io, path, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        return .{ .file = file, .path = path, .id = id };
    }
    return error.CacheIdCollision;
}

/// Keep `text` under `dir` and report the id it can be read back with. Saving
/// the same text again — or finding another entry already holding it — answers
/// with the same id and keeps one copy.
pub fn save(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, text: []const u8) !Saved {
    var stream = try createStream(io, allocator, dir);
    defer stream.deinit(io, allocator);
    errdefer std.Io.Dir.deleteFileAbsolute(io, stream.path) catch {};
    try stream.write(io, text);
    return stream.finish(io);
}

/// Optional execution-after hook for any tool (including MCP). Unlike bash's
/// streaming cache this handles already-materialized results. Install as
/// Context.hooks.after or Tool.hooks.after; producers preserve complete output.
/// Consumes outcome's content on success and failure.
pub fn afterExecute(ctx: tool.Context, _: []const u8, _: []const u8, outcome: anyerror!ToolResult) !ToolResult {
    var result = try outcome;
    if (result.content.len <= result_mod.max_output_bytes) return result;
    const dir = ctx.cache_dir orelse return result;
    const saved = save(ctx.io, ctx.allocator, dir, result.content) catch return result;
    const original = result.content;
    defer ctx.allocator.free(original);
    const preview = headPreview(original, result_mod.preview_room_bytes);
    result.content = try std.fmt.allocPrint(ctx.allocator, "{s}\n[ccr {s}: {d} lines, {d} bytes. The beginning of it is shown here; call ccr_retrieve with id \"{s}\" to read the rest.]", .{ preview, saved.id, saved.lines, saved.bytes, saved.id });
    result.truncated = true;
    return result;
}

/// The beginning of `text` a preview can hold: whole lines where there are
/// any, and a cut on a UTF-8 boundary when one line fills the whole budget.
fn headPreview(text: []const u8, budget: usize) []const u8 {
    if (text.len <= budget) return text;
    const window = text[0..budget];
    if (std.mem.lastIndexOfScalar(u8, window, '\n')) |end| {
        if (end + 1 > budget / 2) return window[0 .. end + 1];
    }
    return truncateUtf8(text, budget);
}

/// What one `ccr_retrieve` call asks for. `offset` counts lines, or matching
/// lines when `query` is given; a null `limit` reads as many as a page holds.
pub const RetrieveArgs = struct {
    id: []u8,
    offset: usize = 1,
    limit: ?usize = null,
    query: ?[]const u8 = null,

    pub fn deinit(self: RetrieveArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.query) |query| allocator.free(query);
    }
};

/// The message a call gets when it cannot be read as a `ccr_retrieve` call.
pub const invalid_arguments =
    "Error: ccr_retrieve takes the hex 'id' a cached result named, plus an optional 1-based 'offset', an optional 'limit' of lines, and an optional 'query' string to find lines case-insensitively. Run the call again to cache its output.";

/// A call's id as the file name it stands for: trimmed, with the `.log` a model
/// may copy off a path removed, in lower case, and refused unless it is hex.
fn normalizeId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.endsWith(u8, text, ".log")) text = text[0 .. text.len - ".log".len];
    if (text.len == 0 or text.len > 64) return error.InvalidId;
    const id = try allocator.dupe(u8, text);
    errdefer allocator.free(id);
    for (id) |*char| {
        if (!std.ascii.isHex(char.*)) return error.InvalidId;
        char.* = std.ascii.toLower(char.*);
    }
    // Both forms of the empty case above: nothing hex at all.
    if (id.len == 0) return error.InvalidId;
    return id;
}

pub fn parseArgs(allocator: std.mem.Allocator, arguments: []const u8) !RetrieveArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const fields = parsed.value.object;
    const raw_id = fields.get("id") orelse return error.InvalidArguments;
    if (raw_id != .string) return error.InvalidArguments;
    const id = try normalizeId(allocator, raw_id.string);
    errdefer allocator.free(id);
    const query = try args_mod.optionalString(allocator, fields.get("query"));
    errdefer if (query) |text| allocator.free(text);
    return .{
        .id = id,
        .offset = (try optionalUnsigned(fields.get("offset"), 1)) orelse 1,
        .limit = try optionalUnsigned(fields.get("limit"), 1),
        .query = query,
    };
}

/// The ccr_retrieve tool: read back what a long result was cached as.
pub const spec: tool.Tool = .{
    .name = "ccr_retrieve",
    .description = "Read back cached output: the whole of a command's or a tool's result when that result was too long for one. It names an id and how many lines and bytes it holds; call this with that id to page through it, or with a query to find the lines that contain text (ignoring case). Without a query, offset is a 1-based line number and limit a count of lines, and the page names the offset the next one starts at; with a query, offset counts matching lines.",
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string","description":"The hex id a cached result named"},"offset":{"type":"integer","minimum":1,"description":"1-based first line, or first matching line when query is given; defaults to 1"},"limit":{"type":"integer","minimum":1,"description":"Number of lines to return; defaults to as many as the page holds"},"query":{"type":"string","description":"Only the lines containing this text, matched without regard to case"}},"required":["id"],"additionalProperties":false}
    ,
    .label = "ccr_retrieve…",
    .run = run,
};

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    const dir = ctx.cache_dir orelse return ctx.refuse(
        "Error: no cached output is available here: ccr_retrieve reads this run's scratch directory, and this call was given none. Run the command again with its output going to a file, and read that file in pages.",
    );
    return retrieve(ctx.io, ctx.allocator, dir, arguments);
}

/// Read back what a `bash` result cached: one page of it, or the lines that
/// match a query.
pub fn retrieve(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, arguments: []const u8) !ToolResult {
    const args = parseArgs(allocator, arguments) catch
        return toolError(allocator, "{s}", .{invalid_arguments});
    defer args.deinit(allocator);

    const path = try filePath(allocator, dir, args.id);
    defer allocator.free(path);
    // A missing entry is named as such: the cache is dropped by `/new` and by
    // the end of the run, so an id from earlier is expected to be gone.
    {
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return toolError(
                allocator,
                "Error: no cached output with id '{s}'. Cached output lives only in this run's scratch directory: `/new` empties it and the end of the run removes it, so an id from earlier names nothing. Run the call again to cache its output.",
                .{args.id},
            ),
            else => |other| return toolError(allocator, "Error opening ccr {s}: {s}", .{ args.id, @errorName(other) }),
        };
        file.close(io);
    }

    if (args.query) |query| return queryPage(io, allocator, path, args.id, query, args.offset, args.limit);
    return read.readFilePage(io, allocator, path, .{ .offset = args.offset, .limit = args.limit });
}

/// The first place `needle` appears in `haystack`, ignoring ASCII case. A model
/// looking for an error in a log does not care which case a build chose.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, haystack[start..][0..needle.len]) |want, got| {
            if (std.ascii.toLower(want) != std.ascii.toLower(got)) {
                matched = false;
                break;
            }
        }
        if (matched) return start;
    }
    return null;
}

fn queryPage(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    id: []const u8,
    query: []const u8,
    offset: usize,
    limit: ?usize,
) !ToolResult {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err|
        return toolError(allocator, "Error opening ccr {s}: {s}", .{ id, @errorName(err) });
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    // Line numbers are the ones the whole output has, so a match can be read
    // again with an offset while the query is off; `matches` is the count the
    // query's own offset is measured in.
    var line: usize = 1;
    var matches: usize = 0;
    var shown: usize = 0;
    // The match the next call starts at, when this page stopped short of the
    // end: the query is not re-read from the beginning.
    var resumes_at: ?usize = null;
    var clipped_line = false;
    scan: while (true) {
        const ending = read.readLine(reader, allocator, &current, max_line_bytes) catch |err|
            return toolError(allocator, "Error reading ccr {s}: {s}", .{ id, @errorName(err) });
        if (ending == .eof) break;
        if (ending == .line and indexOfIgnoreCase(current.items, query) != null) {
            matches += 1;
            if (matches < offset) {
                line += 1;
                continue;
            }
            if (limit != null and shown == limit.?) {
                resumes_at = matches;
                break :scan;
            }
            const width = read.linePrefixWidth(line);
            const room = page_room_bytes - body.items.len;
            if (width + current.items.len + 1 > room) {
                // The page is full on this line. A first match that does not
                // fit is shown by its beginning, so the call is not empty.
                if (shown == 0 and room > width + 1) {
                    try read.appendNumberedLine(&body, allocator, line, truncateUtf8(current.items, room - width - 1));
                    shown += 1;
                    clipped_line = true;
                }
                resumes_at = matches + @intFromBool(clipped_line);
                break :scan;
            }
            try read.appendNumberedLine(&body, allocator, line, current.items);
            shown += 1;
        }
        line += 1;
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    if (body.items.len > 0) try aw.writer.writeAll(body.items);

    if (clipped_line) try aw.writer.writeAll("[Matching line exceeds page size; only its beginning is shown.]\n");
    if (resumes_at) |next| {
        try aw.writer.print(
            "[More matches; continue with offset={d} (a 1-based count of matching lines when 'query' is given).]",
            .{next},
        );
    } else if (matches == 0) {
        try aw.writer.print("[No line of ccr {s} matches \"{s}\" (case-insensitive).]", .{ id, query });
    } else if (shown == 0) {
        if (body.items.len > 0) try aw.writer.writeByte('\n');
        try aw.writer.print("[ccr {s} has {d} matching line(s); offset={d} is past the last one.]", .{ id, matches, offset });
    } else {
        try aw.writer.print("[End of ccr {s}: {d} matching line(s) for \"{s}\".]", .{ id, matches, query });
    }

    return .{
        .content = try finalizeToolContent(allocator, aw.written()),
        .is_error = false,
        .truncated = resumes_at != null,
    };
}

test "afterExecute caches a result past 8 KiB and keeps a 4 KiB beginning" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const ctx: tool.Context = .{ .io = io, .allocator = a, .cache_dir = dir };

    // A result of exactly the threshold is small enough to be shown whole.
    const under = try a.alloc(u8, result_mod.max_output_bytes);
    defer a.free(under);
    @memset(under, 'x');
    const kept = try afterExecute(ctx, "mcp_dynamic", "{}", .{ .content = try a.dupe(u8, under), .is_error = false });
    defer kept.deinit(a);
    try std.testing.expect(!kept.truncated);
    try std.testing.expectEqualStrings(under, kept.content);

    // One byte more is cached, and what comes back is a preview under the
    // threshold that names the entry.
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (0..1200) |_| try text.writer.writeAll("payload line\n");
    try std.testing.expect(text.written().len > result_mod.max_output_bytes);
    const result = try afterExecute(ctx, "mcp_dynamic", "{}", .{ .content = try a.dupe(u8, text.written()), .is_error = false });
    defer result.deinit(a);
    try std.testing.expect(result.truncated and !result.is_error);
    try std.testing.expect(result.content.len < result_mod.max_output_bytes);
    const marker = std.mem.indexOf(u8, result.content, "\n[ccr ") orelse return error.MissingCacheId;
    try std.testing.expect(marker <= result_mod.preview_room_bytes);
    try std.testing.expect(marker > result_mod.preview_room_bytes - 16);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "payload line\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.content[marker..], "ccr_retrieve") != null);

    // The same output again is the same entry, not a second copy of it.
    const again = try afterExecute(ctx, "mcp_dynamic", "{}", .{ .content = try a.dupe(u8, text.written()), .is_error = false });
    defer again.deinit(a);
    try std.testing.expectEqualStrings(result.content, again.content);
    var entries = try std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true });
    defer entries.close(io);
    var iterator = entries.iterate();
    var files: usize = 0;
    while (try iterator.next(io)) |_| files += 1;
    try std.testing.expectEqual(@as(usize, 1), files);
}

test "afterExecute caches materialized output, preserves status and retrieves the tail" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const ctx: tool.Context = .{ .io = io, .allocator = a, .cache_dir = dir };
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (0..6000) |_| try text.writer.writeAll("payload\n");
    try text.writer.writeAll("uncut tail\n");
    const result = try afterExecute(ctx, "mcp_dynamic", "{}", .{ .content = try a.dupe(u8, text.written()), .is_error = true, .exit_code = 7, .timed_out = true });
    defer result.deinit(a);
    try std.testing.expect(result.is_error and result.timed_out and result.truncated);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    try std.testing.expect(result.content.len < result_mod.max_output_bytes);
    const start = (std.mem.indexOf(u8, result.content, "[ccr ") orelse return error.MissingCacheId) + "[ccr ".len;
    const id = result.content[start..][0..id_len];
    const path = try filePath(a, dir, id);
    defer a.free(path);
    const cached = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(100 * 1024));
    defer a.free(cached);
    try std.testing.expectEqualStrings(text.written(), cached);
    const args = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"offset\":6001}}", .{id});
    defer a.free(args);
    const retrieved = try spec.execute(ctx, args);
    defer retrieved.deinit(a);
    try std.testing.expect(!retrieved.is_error);
    try std.testing.expectEqualStrings("6001:uncut tail\n", retrieved.content);
}

test "afterExecute leaves short results and uncached fallbacks untouched and propagates errors" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "not-a-directory", .data = "occupied" });
    const invalid_dir = try tmp.dir.realPathFileAlloc(io, "not-a-directory", a);
    defer a.free(invalid_dir);
    // A regular file is a deterministic save failure even when running as root.
    for ([_]?[]const u8{ null, invalid_dir }) |dir| {
        for ([_]usize{ 5, result_mod.max_output_bytes, result_mod.max_output_bytes + 1 }) |len| {
            const content = try a.alloc(u8, len);
            @memset(content, 'x');
            const original: ToolResult = .{ .content = content, .is_error = true, .exit_code = 9, .timed_out = true, .truncated = true };
            const result = try afterExecute(.{ .io = io, .allocator = a, .cache_dir = dir }, "test", "{}", original);
            defer result.deinit(a);
            try std.testing.expect(result.content.ptr == original.content.ptr);
            try std.testing.expectEqualStrings(original.content, result.content);
            try std.testing.expectEqualDeep(original.status(), result.status());
        }
    }
    try std.testing.expectError(error.RunFailed, afterExecute(.{ .io = io, .allocator = a }, "test", "{}", error.RunFailed));
}

test "cached output is read back in pages and by query" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);

    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (1..201) |index| try text.writer.print("line {d}\n", .{index});
    try text.writer.writeAll("the last line has no terminator");

    const saved = try save(io, a, base, text.written());
    try std.testing.expectEqual(@as(usize, 201), saved.lines);
    try std.testing.expectEqual(text.written().len, saved.bytes);
    try std.testing.expectEqual(@as(usize, id_len), saved.id.len);
    for (saved.id) |char| try std.testing.expect(std.ascii.isHex(char) and !std.ascii.isUpper(char));

    // A page is numbered by the line's place in the output, and names the
    // offset the next one starts at.
    const arguments = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"offset\":199,\"limit\":2}}", .{saved.id});
    defer a.free(arguments);
    const page = try retrieve(io, a, base, arguments);
    defer page.deinit(a);
    try std.testing.expect(!page.is_error);
    try std.testing.expect(page.truncated);
    try std.testing.expectEqualStrings(
        "199:line 199\n200:line 200\n[Output truncated; continue with offset=201 (1-based line number).]",
        page.content,
    );

    const last = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"offset\":201}}", .{saved.id});
    defer a.free(last);
    const tail = try retrieve(io, a, base, last);
    defer tail.deinit(a);
    try std.testing.expectEqualStrings("201:the last line has no terminator\n", tail.content);
    try std.testing.expect(!tail.truncated);
}

test "a query finds lines ignoring case and pages through the matches" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);

    const saved = try save(io, a, base, "start\nERROR one\nok\nError two\nend\n");
    const found = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"query\":\"error\",\"limit\":1}}", .{saved.id});
    defer a.free(found);
    const first = try retrieve(io, a, base, found);
    defer first.deinit(a);
    try std.testing.expect(!first.is_error and first.truncated);
    try std.testing.expectEqualStrings(
        "2:ERROR one\n[More matches; continue with offset=2 (a 1-based count of matching lines when 'query' is given).]",
        first.content,
    );

    const rest = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"query\":\"error\",\"offset\":2}}", .{saved.id});
    defer a.free(rest);
    const second = try retrieve(io, a, base, rest);
    defer second.deinit(a);
    const expected = try std.fmt.allocPrint(a, "4:Error two\n[End of ccr {s}: 2 matching line(s) for \"error\".]", .{saved.id});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, second.content);
    try std.testing.expect(!second.truncated);
}

test "a missing entry, a wrong id and an unknown query each say what is wrong" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);

    for ([_][]const u8{
        "{}",
        "[]",
        "{\"id\":42}",
        "{\"id\":\"\"}",
        "{\"id\":\"../escape\"}",
        "{\"id\":\"beef\",\"offset\":0}",
        "not json",
    }) |arguments| {
        const result = try retrieve(io, a, base, arguments);
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "ccr_retrieve takes") != null);
    }

    // Nothing was cached under this id in this run: the error says why.
    const missing = try retrieve(io, a, base, "{\"id\":\"deadbeef0123\"}");
    defer missing.deinit(a);
    try std.testing.expect(missing.is_error);
    try std.testing.expect(std.mem.indexOf(u8, missing.content, "no cached output with id 'deadbeef0123'") != null);

    // An id copied off a path, with its extension and in upper case, is read.
    const saved = try save(io, a, base, "all good\n");
    var upper: [id_len]u8 = undefined;
    for (saved.id, 0..) |char, index| upper[index] = std.ascii.toUpper(char);
    const copied = try std.fmt.allocPrint(a, "{{\"id\":\"{s}.log\"}}", .{upper});
    defer a.free(copied);
    const page = try retrieve(io, a, base, copied);
    defer page.deinit(a);
    try std.testing.expectEqualStrings("1:all good\n", page.content);

    const nothing = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"query\":\"absent\"}}", .{saved.id});
    defer a.free(nothing);
    const none = try retrieve(io, a, base, nothing);
    defer none.deinit(a);
    try std.testing.expect(!none.is_error);
    try std.testing.expect(std.mem.indexOf(u8, none.content, "[No line of ccr") != null);
}

test "an oversized matching line advances instead of repeating forever" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const text = try a.alloc(u8, 20000);
    defer a.free(text);
    @memset(text, 'x');
    const saved = try save(io, a, dir, text);
    const args = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"query\":\"x\"}}", .{saved.id});
    defer a.free(args);
    const page = try retrieve(io, a, dir, args);
    defer page.deinit(a);
    try std.testing.expect(page.truncated);
    try std.testing.expect(std.mem.indexOf(u8, page.content, "only its beginning") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.content, "offset=2") != null);
}

test "identical output is kept once and named after its content" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);

    // The same text cached many times over — the way a large task reruns a
    // command or reads a page again — is one entry, under one id.
    var first: [id_len]u8 = undefined;
    for (0..8) |index| {
        const saved = try save(io, a, dir, "same output\n");
        try std.testing.expectEqual(@as(usize, 1), saved.lines);
        if (index == 0) first = saved.id else try std.testing.expectEqualStrings(&first, &saved.id);
    }
    var entries = try std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true });
    defer entries.close(io);
    var iterator = entries.iterate();
    var files: usize = 0;
    while (try iterator.next(io)) |entry| {
        try std.testing.expectEqualStrings(&first, entry.name[0..id_len]);
        files += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), files);
    const name = try std.fmt.allocPrint(a, "{s}.log", .{first});
    defer a.free(name);
    const cached = try entries.readFileAlloc(io, name, a, .limited(1024));
    defer a.free(cached);
    try std.testing.expectEqualStrings("same output\n", cached);

    // Different output takes a name of its own rather than joining it.
    const other = try save(io, a, dir, "other output\n");
    try std.testing.expect(!std.mem.eql(u8, &first, &other.id));
}

test "line counting ends with the last line, not after it" {
    try std.testing.expectEqual(@as(usize, 0), countLines(""));
    try std.testing.expectEqual(@as(usize, 1), countLines("one"));
    try std.testing.expectEqual(@as(usize, 1), countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 2), countLines("one\ntwo\n"));
    try std.testing.expectEqual(@as(usize, 3), countLines("\n\n\n"));
}

test "an entry written as the output arrives counts what a whole text would" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);

    const pieces = [_][]const u8{ "first\n", "second", "\nthird\n", "", "fourth" };
    var stream = try createStream(io, a, dir);
    defer stream.deinit(io, a);
    for (pieces) |piece| try stream.write(io, piece);
    const written = stream.finish(io);

    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(a);
    for (pieces) |piece| try whole.appendSlice(a, piece);
    try std.testing.expectEqual(countLines(whole.items), written.lines);
    try std.testing.expectEqual(whole.items.len, written.bytes);

    const path = try filePath(a, dir, &written.id);
    defer a.free(path);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const kept = try file_reader.interface.allocRemaining(a, .limited(4096));
    defer a.free(kept);
    try std.testing.expectEqualStrings(whole.items, kept);
}

test "an abandoned entry leaves nothing behind" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);

    var stream = try createStream(io, a, dir);
    const path = try filePath(a, dir, &stream.id);
    defer a.free(path);
    try stream.write(io, "half an answer");
    stream.abandon(io, a);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(io, path, .{}));
}
