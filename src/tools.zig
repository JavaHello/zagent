const std = @import("std");
const text = @import("text.zig");
const diff = @import("diff.zig");

pub const ToolStatus = struct {
    is_error: bool,
    exit_code: ?u8 = null,
    timed_out: bool = false,
    truncated: bool = false,
};

/// Status is separate from the body in snapshots, but visible to the model
/// even when output is empty, deduplicated, or clipped.
pub fn formatToolOutput(allocator: std.mem.Allocator, status: ToolStatus, content: []const u8) ![]u8 {
    const encoded = try std.json.Stringify.valueAlloc(allocator, status, .{});
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "[tool_status {s}]\n{s}", .{ encoded, content });
}

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool,
    exit_code: ?u8 = null,
    timed_out: bool = false,
    truncated: bool = false,

    pub fn status(self: ToolResult) ToolStatus {
        return .{
            .is_error = self.is_error,
            .exit_code = self.exit_code,
            .timed_out = self.timed_out,
            .truncated = self.truncated,
        };
    }

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

/// A label for the animation shown while `name` runs, or null for a tool that
/// must not have one.
///
/// The names are written out rather than taken from the call: a tool name is
/// model output, and a name carrying escape sequences would be written straight
/// into the terminal (see `text.zig`). `ask_user` is deliberately absent — it
/// asks a question on the terminal and reads the answer from it, so it needs
/// the line to itself.
pub fn progressLabel(name: []const u8) ?[]const u8 {
    const labels = [_]struct { name: []const u8, label: []const u8 }{
        .{ .name = "bash", .label = "bash…" },
        .{ .name = "read", .label = "read…" },
        .{ .name = "write", .label = "write…" },
        .{ .name = "ls", .label = "ls…" },
        .{ .name = "rg", .label = "rg…" },
        .{ .name = "fd", .label = "fd…" },
        .{ .name = "apply_patch", .label = "apply_patch…" },
        .{ .name = "grep", .label = "grep…" },
        .{ .name = "find", .label = "find…" },
        .{ .name = "http", .label = "http…" },
        .{ .name = "remember", .label = "remember…" },
        .{ .name = "memory_search", .label = "searching memory…" },
    };
    for (labels) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.label;
    }
    return null;
}

test "shell status survives empty output, stderr, signals and truncation" {
    const cases = [_]struct { command: []const u8, prefix: []const u8, is_error: bool }{
        .{ .command = "exit 0", .prefix = "Exit code: 0\n(no output)", .is_error = false },
        .{ .command = "exit 42", .prefix = "Exit code: 42\n(no output)", .is_error = true },
        .{ .command = "printf out; printf err >&2; exit 7", .prefix = "Exit code: 7\nout\nstderr: err", .is_error = true },
        .{ .command = "printf warning >&2", .prefix = "Exit code: 0\n", .is_error = false },
        .{ .command = "kill -TERM $$", .prefix = "Exit code: unavailable (termination: ", .is_error = true },
        .{ .command = "printf '%10000s' ''; exit 9", .prefix = "Exit code: 9\n", .is_error = true },
    };
    for (cases) |case| {
        const result = try executeShell(std.testing.io, std.testing.allocator, case.command);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.is_error, result.is_error);
        try std.testing.expect(std.mem.startsWith(u8, result.content, case.prefix));
        try std.testing.expect(result.content.len < 10000);
    }
}

pub fn executeShell(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !ToolResult {
    return executeShellWithEnv(io, allocator, command, null);
}

pub fn executeShellWithEnv(io: std.Io, allocator: std.mem.Allocator, command: []const u8, env: ?*const std.process.Environ.Map) !ToolResult {
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "bash", "--noprofile", "--norc", "-c", command },
        .environ_map = env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // Content is sent to the model and persisted in session history. Keep
    // status first so truncating long command output cannot hide it.
    if (exit_code) |code| {
        try aw.writer.print("Exit code: {d}\n", .{code});
    } else {
        try aw.writer.print("Exit code: unavailable (termination: {any})\n", .{result.term});
    }

    if (result.stdout.len > 0) {
        const normalized = try normalizeToolText(allocator, result.stdout);
        defer allocator.free(normalized);
        try aw.writer.writeAll(normalized);
    }
    if (result.stderr.len > 0) {
        if (aw.written().len > 0) try aw.writer.writeAll("\n");
        try aw.writer.writeAll("stderr: ");
        const normalized = try normalizeToolText(allocator, result.stderr);
        defer allocator.free(normalized);
        try aw.writer.writeAll(normalized);
    }
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try aw.writer.writeAll("(no output)");
    }

    defer aw.deinit();
    return finalizeResultLimited(allocator, aw.written(), .{
        .is_error = exit_code == null or exit_code.? != 0,
        .exit_code = exit_code,
    }, 8192);
}

test "read ranges validate positive inclusive line numbers" {
    const a = std.testing.allocator;
    const defaults = try parseReadRange(a, "{}");
    try std.testing.expectEqual(@as(usize, 1), defaults.start_line);
    try std.testing.expect(defaults.end_line == null);
    for ([_][]const u8{
        "[]",                   "{\"start_line\":0}",                "{\"start_line\":-1}",
        "{\"end_line\":0}",     "{\"start_line\":3,\"end_line\":2}", "{\"start_line\":1.5}",
        "{\"end_line\":\"2\"}", "{\"start_line\":null}",
    }) |json| try std.testing.expectError(error.InvalidArguments, parseReadRange(a, json));
    const range = try parseReadRange(a, "{\"start_line\":2,\"end_line\":3}");
    try std.testing.expectEqual(@as(usize, 2), range.start_line);
    try std.testing.expectEqual(@as(?usize, 3), range.end_line);
}

test "read streams ranges beyond the old file and output limits" {
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
    const cases = [_]struct { range: ReadRange, expected: []const u8 }{
        .{ .range = .{ .start_line = 2, .end_line = 3 }, .expected = "one\r\ntwo\n" },
        .{ .range = .{ .start_line = 4 }, .expected = "last" },
        .{ .range = .{ .start_line = 5 }, .expected = "(no output)" },
    };
    for (cases) |case| {
        const result = try readFileRange(io, a, path, case.range);
        defer result.deinit(a);
        try std.testing.expect(!result.is_error);
        try std.testing.expectEqualStrings(case.expected, result.content);
    }
    const full = try readFile(io, a, path);
    defer full.deinit(a);
    try std.testing.expect(!full.is_error);
    try std.testing.expect(std.mem.indexOf(u8, full.content, "start_line=1") != null);
}

test "read continuation preserves long utf8 lines without skipping bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    for (0..3000) |_| try buffer.appendSlice(a, "你");
    const data = buffer.items;
    try tmp.dir.writeFile(io, .{ .sub_path = "utf8", .data = data });
    const path = try tmp.dir.realPathFileAlloc(io, "utf8", a);
    defer a.free(path);
    const first = try readFileRange(io, a, path, .{});
    defer first.deinit(a);
    try std.testing.expect(first.truncated);
    try std.testing.expect(std.mem.startsWith(u8, first.content, data[0..8190]));
    try std.testing.expect(std.mem.indexOf(u8, first.content, "start_column=8191") != null);
    const second = try readFileRange(io, a, path, .{ .start_column = 8191 });
    defer second.deinit(a);
    try std.testing.expect(!second.truncated);
    try std.testing.expectEqualStrings(data[8190..], second.content);
}

test "search pages sort names, preserve status, and expose continuation" {
    const a = std.testing.allocator;
    const sorted = try searchPage(a, "z\na\nm\n", 1, true, .{ .is_error = false, .exit_code = 0 });
    defer sorted.deinit(a);
    try std.testing.expectEqualStrings("m\nz\n", sorted.content);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    for (0..600) |_| try buffer.appendSlice(a, "one matching line\n");
    const data = buffer.items;
    const first = try searchPage(a, data, 0, false, .{ .is_error = true, .exit_code = 2 });
    defer first.deinit(a);
    try std.testing.expect(first.is_error);
    try std.testing.expectEqual(@as(?u8, 2), first.exit_code);
    try std.testing.expect(first.truncated);
    const cursor = 7800 / "one matching line\n".len;
    const marker = try std.fmt.allocPrint(a, "offset={d}", .{cursor});
    defer a.free(marker);
    try std.testing.expect(std.mem.indexOf(u8, first.content, marker) != null);
    const second = try searchPage(a, data, cursor, false, .{ .is_error = false });
    defer second.deinit(a);
    try std.testing.expect(!second.truncated);
    try std.testing.expectEqualStrings(data[cursor * "one matching line\n".len ..], second.content);
}

test "search limits parse and reach both backends" {
    const a = std.testing.allocator;
    const args = try parseGrepArgs(a, "{\"pattern\":\"needle\",\"context_lines\":2,\"max_matches\":1}");
    defer args.deinit(a);
    try std.testing.expectEqual(@as(?usize, 2), args.context_lines);
    try std.testing.expectEqual(@as(?usize, 1), args.max_matches);
    for ([_]bool{ false, true }) |rg| {
        const argv = try grepArgv(a, args, .{ .rg = rg });
        defer freeGrepArgv(a, argv);
        const start: usize = if (rg) 4 else 6;
        try std.testing.expectEqualStrings("--context=2", argv[start]);
        try std.testing.expectEqualStrings("--max-count=1", argv[start + 1]);
    }
    for ([_][]const u8{
        "{\"pattern\":\"x\",\"context_lines\":-1}",
        "{\"pattern\":\"x\",\"context_lines\":true}",
        "{\"pattern\":\"x\",\"max_matches\":0}",
        "{\"pattern\":\"x\",\"max_matches\":1.5}",
        "{\"pattern\":\"x\",\"max_matches\":\"2\"}",
    }) |json| try std.testing.expectError(error.InvalidArguments, parseGrepArgs(a, json));
}

test "grep includes context and stops matching per file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "before\nneedle\nafter\ngap\nneedle later\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "note.txt", a);
    defer a.free(path);
    const result = try grep(io, a, .{}, .{
        .pattern = "needle",
        .path = path,
        .glob = null,
        .ignore_case = false,
        .context_lines = 1,
        .max_matches = 1,
    });
    defer result.deinit(a);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "needle later") == null);
}

pub const ReadRange = struct {
    start_line: usize = 1,
    end_line: ?usize = null,
    /// 1-based byte position within start_line.
    start_column: usize = 1,
};

pub fn optionalUnsigned(value: ?std.json.Value, minimum: usize) !?usize {
    const field = value orelse return null;
    if (field != .integer) return error.InvalidArguments;
    const number = std.math.cast(usize, field.integer) orelse return error.InvalidArguments;
    if (number < minimum) return error.InvalidArguments;
    return number;
}

pub fn parseReadRange(allocator: std.mem.Allocator, arguments: []const u8) !ReadRange {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const range = ReadRange{
        .start_line = (try optionalUnsigned(parsed.value.object.get("start_line"), 1)) orelse 1,
        .end_line = try optionalUnsigned(parsed.value.object.get("end_line"), 1),
        .start_column = (try optionalUnsigned(parsed.value.object.get("start_column"), 1)) orelse 1,
    };
    if (range.end_line) |end| {
        if (end < range.start_line) return error.InvalidArguments;
    }
    return range;
}

pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ToolResult {
    return readFileRange(io, allocator, path, .{});
}

pub fn readFileRange(io: std.Io, allocator: std.mem.Allocator, path: []const u8, range: ReadRange) !ToolResult {
    if (range.start_line == 0 or range.start_column == 0 or (range.end_line != null and range.end_line.? < range.start_line))
        return toolError(allocator, "Error: line numbers must be positive and end_line must be >= start_line", .{});
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var line: usize = 1;
    var column: usize = 1;
    var truncated = false;
    while (range.end_line == null or line <= range.end_line.?) {
        const byte = file_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return toolError(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) }),
        };
        if (line > range.start_line or (line == range.start_line and column >= range.start_column)) {
            if (content.items.len == 8192) {
                truncated = true;
                break;
            }
            try content.append(allocator, byte);
        }
        if (byte == '\n') {
            line = std.math.add(usize, line, 1) catch break;
            column = 1;
        } else column += 1;
    }
    // Never split a valid UTF-8 character at the byte cap. Its bytes belong
    // to the next page, whose cursor refers to the original file, not output.
    if (truncated and content.items.len > 0) {
        var lead = content.items.len - 1;
        while (lead > 0 and content.items[lead] & 0xc0 == 0x80) : (lead -= 1) {}
        const width = std.unicode.utf8ByteSequenceLength(content.items[lead]) catch 1;
        if (width > content.items.len - lead) {
            column -= content.items.len - lead;
            content.shrinkRetainingCapacity(lead);
        }
    }
    const normalized = try finalizeToolContent(allocator, content.items);
    if (truncated) {
        defer allocator.free(normalized);
        return .{
            .content = try std.fmt.allocPrint(allocator, "{s}\n[Output truncated; continue with start_line={d}, start_column={d} (1-based byte column).]", .{ normalized, line, column }),
            .is_error = false,
            .truncated = true,
        };
    }
    return .{ .content = normalized, .is_error = false, .truncated = content.items.len > 8192 };
}

pub fn writeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !ToolResult {
    const cwd = std.Io.Dir.cwd();
    const target = cwd.realPathFileAlloc(io, path, allocator) catch try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(target);
    if (std.Io.Dir.path.dirname(target)) |parent| try cwd.createDirPath(io, parent);
    const stat = cwd.statFile(io, target, .{}) catch null;
    const permissions: std.Io.File.Permissions = if (stat) |s| s.permissions else .default_file;
    var atomic = cwd.createFileAtomic(io, target, .{ .replace = true, .permissions = permissions }) catch |err|
        return toolError(allocator, "Error creating '{s}': {s}", .{ path, @errorName(err) });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, content);
    if (stat != null) try atomic.file.setPermissions(io, permissions);
    try atomic.replace(io);

    return .{
        .content = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to '{s}'", .{ content.len, path }),
        .is_error = false,
    };
}

/// Replace one exact, unique text block without requiring hunk line counts.
pub fn editFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, old_text: []const u8, new_text: []const u8) !ToolResult {
    if (old_text.len == 0) return toolError(allocator, "Error: old_text must be non-empty; use write with content for a new file.", .{});
    const cwd = std.Io.Dir.cwd();
    const target = cwd.realPathFileAlloc(io, path, allocator) catch |err| return toolError(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) });
    defer allocator.free(target);
    const original = cwd.readFileAlloc(io, target, allocator, .limited(1024 * 1024)) catch |err| return toolError(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) });
    defer allocator.free(original);
    const position = std.mem.indexOf(u8, original, old_text) orelse return toolError(allocator, "Error: old_text was not found in '{s}'; read the current file and copy its exact text.", .{path});
    if (std.mem.indexOfPos(u8, original, position + 1, old_text) != null) return toolError(allocator, "Error: old_text occurs more than once in '{s}'; include more surrounding context.", .{path});
    const updated = try std.mem.concat(allocator, u8, &.{ original[0..position], new_text, original[position + old_text.len ..] });
    defer allocator.free(updated);
    const stat = try cwd.statFile(io, target, .{});
    var atomic = try cwd.createFileAtomic(io, target, .{ .replace = true, .permissions = stat.permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, updated);
    try atomic.file.setPermissions(io, stat.permissions);
    try atomic.replace(io);
    return .{ .content = try std.fmt.allocPrint(allocator, "Replaced one exact text block in '{s}' ({d} -> {d} bytes)", .{ path, original.len, updated.len }), .is_error = false };
}

/// The apply_patch tool: change files by applying a unified diff to them.
///
/// The result is a summary rather than the patch back again: the model wrote
/// the patch, so what it does not already have is what became of it — which
/// files were written, and, when one could not be, why it did not fit.
pub fn applyPatch(io: std.Io, allocator: std.mem.Allocator, patch_text: []const u8) !ToolResult {
    const outcome = try diff.apply(allocator, io, normalizePatchEnvelope(patch_text));
    defer outcome.deinit(allocator);

    switch (outcome) {
        // The explanation is written by whoever gave up, so it is passed on
        // as it is: it names the file, the line and the text it wanted, which
        // is what the next patch has to be built from.
        .failed => |message| {
            const content = try std.fmt.allocPrint(allocator, "Error: {s}", .{message});
            defer allocator.free(content);
            // Sanitised like any other result: the message quotes lines of the
            // patch, which the model wrote.
            return finalizeResultLimited(allocator, content, .{ .is_error = true }, 8192);
        },
        .applied => |stats| {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try aw.writer.print("Applied {d} file{s}", .{ stats.len, if (stats.len == 1) @as([]const u8, "") else "s" });
            for (stats, 0..) |stat, i| {
                try aw.writer.writeAll(if (i == 0) ": " else ", ");
                try aw.writer.print("{s} (", .{stat.path});
                switch (stat.action) {
                    .modified => try aw.writer.print("+{d} -{d}", .{ stat.added, stat.removed }),
                    .created => try aw.writer.print("new, +{d}", .{stat.added}),
                    .deleted => try aw.writer.print("deleted, -{d}", .{stat.removed}),
                }
                try aw.writer.writeByte(')');
            }
            return finalizeResultLimited(allocator, aw.written(), .{ .is_error = false }, 8192);
        },
    }
}

/// Models sometimes put their unified diff inside apply_patch sentinels.
/// Strip only those exact outer lines; keep hunk counts/context strict.
fn normalizePatchEnvelope(patch: []const u8) []const u8 {
    var value = std.mem.trim(u8, patch, "\r\n");
    if (std.mem.startsWith(u8, value, "*** Begin Patch\n")) value = value["*** Begin Patch\n".len..];
    if (std.mem.startsWith(u8, value, "*** Begin Patch\r\n")) value = value["*** Begin Patch\r\n".len..];
    if (std.mem.endsWith(u8, value, "\n*** End Patch")) value = value[0 .. value.len - "\n*** End Patch".len];
    return value;
}

test "patch envelopes do not change hunk content" {
    const patch = "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-before\n+after";
    try std.testing.expectEqualStrings(patch, normalizePatchEnvelope("*** Begin Patch\n" ++ patch ++ "\n*** End Patch\n"));
    try std.testing.expectEqualStrings(patch, normalizePatchEnvelope(patch));
    try std.testing.expectEqualStrings("+*** End Patch", normalizePatchEnvelope("+*** End Patch"));
}

test "ls pages are sorted and expose a resumable entry offset" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "z", "a", "m" }) |name|
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const first = try listDirPage(io, a, path, .{ .limit = 2 });
    defer first.deinit(a);
    try std.testing.expect(first.truncated);
    try std.testing.expect(std.mem.startsWith(u8, first.content, "a\tf\nm\tf\n"));
    try std.testing.expect(std.mem.indexOf(u8, first.content, "offset=2") != null);
    const second = try listDirPage(io, a, path, .{ .offset = 2, .limit = 2 });
    defer second.deinit(a);
    try std.testing.expect(!second.truncated);
    try std.testing.expectEqualStrings("z\tf\n", second.content);
}

pub fn listDir(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ToolResult {
    return listDirPage(io, allocator, path, .{});
}

pub const Page = struct {
    offset: usize = 0,
    limit: usize = 100,
};

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn listDirPage(io: std.Io, allocator: std.mem.Allocator, path: []const u8, page: Page) !ToolResult {
    if (page.limit == 0 or page.limit > 1000) return error.InvalidArguments;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer dir.close(io);

    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const kind_char: u8 = switch (entry.kind) {
            .directory => 'd',
            .file => 'f',
            .sym_link => 'l',
            else => '?',
        };
        const line = try std.fmt.allocPrint(allocator, "{s}\t{c}\n", .{ entry.name, kind_char });
        errdefer allocator.free(line);
        try entries.append(allocator, line);
    }
    std.mem.sort([]const u8, entries.items, {}, lessString);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var index = @min(page.offset, entries.items.len);
    while (index < entries.items.len and index - page.offset < page.limit) : (index += 1) {
        const entry = entries.items[index];
        if (aw.written().len + entry.len > 7800) break;
        try aw.writer.writeAll(entry);
    }
    const truncated = index < entries.items.len;
    if (truncated) try aw.writer.print("[More entries; continue with offset={d}, limit={d}.]\n", .{ index, page.limit });
    if (aw.written().len == 0) try aw.writer.writeAll("(no entries)");
    return .{ .content = try aw.toOwnedSlice(), .is_error = false, .truncated = truncated };
}

/// Which search programs are installed. Decided once, in `Agent.init`, so a
/// search never has to ask the filesystem mid-answer — the same reasoning that
/// keeps `render_markdown` out of the answer path.
pub const SearchBackends = struct {
    /// Search file contents with ripgrep rather than grep.
    rg: bool = false,
    /// Look for files with fd rather than find.
    fd: bool = false,
};

/// Look for `rg` and `fd` on the PATH `env` carries.
///
/// Zig has no `which` to call: there is no `std.process.findExecutable`, and no
/// `std.posix.getenv` to hand one a path. The directories are walked here
/// instead, over the same PATH a spawned program will be resolved with.
pub fn detectSearchBackends(io: std.Io, env: *const std.process.Environ.Map) SearchBackends {
    const path = env.get("PATH") orelse return .{};
    return .{
        .rg = isOnPath(io, path, "rg"),
        .fd = isOnPath(io, path, "fd"),
    };
}

/// Whether an executable file named `name` sits in one of the `path` directories.
fn isOnPath(io: std.Io, path: []const u8, name: []const u8) bool {
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (dirs.next()) |dir| {
        // An empty entry means the working directory. It is skipped rather than
        // searched: picking up a search program from whatever directory the
        // agent happens to be sitting in is not something a `which` needs to do.
        if (dir.len == 0) continue;
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (isExecutableFile(io, candidate)) return true;
    }
    return false;
}

fn isExecutableFile(io: std.Io, path: []const u8) bool {
    // `statFile` follows symlinks, which is what makes a Homebrew install
    // (/opt/homebrew/bin/rg -> ../Cellar/ripgrep/.../rg) count as present.
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        if (stat.permissions.toMode() & 0o111 == 0) return false;
    }
    return true;
}

/// A grep tool call as the model described it. Owns its strings.
pub const GrepArgs = struct {
    /// A regular expression, in the extended flavour both backends are asked
    /// for (see `grepArgv`).
    pattern: []const u8,
    /// The file or directory to search.
    path: []const u8,
    /// Only search files whose names match this glob.
    glob: ?[]const u8,
    ignore_case: bool,
    context_lines: ?usize = null,
    max_matches: ?usize = null,
    hidden: bool = false,
    no_ignore: bool = false,
    offset: usize = 0,

    pub fn deinit(self: GrepArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        allocator.free(self.path);
        if (self.glob) |glob| allocator.free(glob);
    }
};

/// Parse a grep tool call's arguments.
pub fn parseGrepArgs(allocator: std.mem.Allocator, arguments_json: []const u8) !GrepArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const arguments = parsed.value.object;

    // A search with no pattern is not a wide search, it is a missing argument:
    // every line of every file is what an empty pattern would match, and that
    // answer is worth neither the wait nor the tool result.
    const pattern_value = arguments.get("pattern") orelse return error.MissingPattern;
    if (pattern_value != .string or pattern_value.string.len == 0) return error.MissingPattern;
    const pattern = try allocator.dupe(u8, pattern_value.string);
    errdefer allocator.free(pattern);

    const path = try searchPath(allocator, arguments.get("path"));
    errdefer allocator.free(path);
    const glob = try optionalString(allocator, arguments.get("glob"));
    errdefer if (glob) |value| allocator.free(value);

    return .{
        .pattern = pattern,
        .path = path,
        .glob = glob,
        .ignore_case = try optionalBool(arguments.get("ignore_case")),
        .context_lines = try optionalUnsigned(arguments.get("context_lines"), 0),
        .max_matches = try optionalUnsigned(arguments.get("max_matches"), 1),
        .hidden = try optionalBool(arguments.get("hidden")),
        .no_ignore = try optionalBool(arguments.get("no_ignore")),
        .offset = (try optionalUnsigned(arguments.get("offset"), 0)) orelse 0,
    };
}

/// A find tool call as the model described it. Owns its strings.
pub const FindArgs = struct {
    /// A glob the name has to match, e.g. `*.zig`. Not a regular expression.
    pattern: []const u8,
    path: []const u8,
    hidden: bool = false,
    no_ignore: bool = false,
    offset: usize = 0,

    pub fn deinit(self: FindArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        allocator.free(self.path);
    }
};

/// Parse a find tool call's arguments.
pub fn parseFindArgs(allocator: std.mem.Allocator, arguments_json: []const u8) !FindArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const arguments = parsed.value.object;

    const pattern_value = arguments.get("pattern") orelse return error.MissingPattern;
    if (pattern_value != .string or pattern_value.string.len == 0) return error.MissingPattern;
    const pattern = try allocator.dupe(u8, pattern_value.string);
    errdefer allocator.free(pattern);

    const path = try searchPath(allocator, arguments.get("path"));
    errdefer allocator.free(path);

    return .{
        .pattern = pattern,
        .path = path,
        .hidden = try optionalBool(arguments.get("hidden")),
        .no_ignore = try optionalBool(arguments.get("no_ignore")),
        .offset = (try optionalUnsigned(arguments.get("offset"), 0)) orelse 0,
    };
}

fn searchPath(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const path = (try optionalString(allocator, value)) orelse return allocator.dupe(u8, ".");
    if (std.mem.startsWith(u8, path, "-")) {
        defer allocator.free(path);
        return std.fmt.allocPrint(allocator, "./{s}", .{path});
    }
    return path;
}

/// A boolean argument that may be absent, in which case it is false. Anything
/// that is not a JSON boolean is refused rather than guessed at.
fn optionalBool(value: ?std.json.Value) !bool {
    const field = value orelse return false;
    return switch (field) {
        .bool => |flag| flag,
        else => error.InvalidArguments,
    };
}

/// Build the argv for one grep call.
///
/// Borrows args and literals, but owns numeric flags. Free with freeGrepArgv.
pub fn freeGrepArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    freeGrepFlags(allocator, argv);
    allocator.free(argv);
}

fn freeGrepFlags(allocator: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;
    const start: usize = if (std.mem.eql(u8, argv[0], "rg")) 4 else 6;
    if (argv.len <= start) return;
    // Only the numeric flags immediately following the fixed backend flags
    // are owned. Glob and pattern strings may contain flag-looking text.
    for (argv[start..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "--context=") and !std.mem.startsWith(u8, arg, "--max-count=")) break;
        allocator.free(arg);
    }
}

pub fn grepArgv(allocator: std.mem.Allocator, args: GrepArgs, backends: SearchBackends) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeGrepFlags(allocator, argv.items);
        argv.deinit(allocator);
    }

    if (backends.rg) {
        // The flags are passed even though ripgrep prints this shape by itself
        // when it is not writing to a terminal: a RIPGREP_CONFIG_PATH file can
        // change the defaults, and the model should read the same output on
        // every machine. `--color=never` is for that same file: the result is
        // stripped of escapes before the model sees it, but that is no reason
        // to pay for them.
        try argv.appendSlice(allocator, &.{ "rg", "--line-number", "--no-heading", "--color=never" });
        try appendGrepLimits(allocator, &argv, args);
        try argv.appendSlice(allocator, &.{ "--no-config", "--sort=path" });
        if (args.hidden) try argv.append(allocator, "--hidden");
        if (args.no_ignore) try argv.append(allocator, "--no-ignore");
        if (args.glob) |glob| try argv.appendSlice(allocator, &.{ "--glob", glob });
        if (args.ignore_case) try argv.append(allocator, "--ignore-case");
        // `--` keeps a pattern that starts with a dash from being read as a flag.
        try argv.appendSlice(allocator, &.{ "--", args.pattern, args.path });
    } else {
        // `-E` is what makes the fallback mean the same thing as ripgrep: a plain
        // grep reads a basic regular expression, where `+`, `?`, `|` and `()`
        // are literals until they are escaped.
        // Everything else is short options plus `--include` and `--exclude-dir`,
        // which the grep macOS ships also accepts.
        // `-I` drops binary files, as ripgrep does by default, and `.git` is
        // skipped by hand because this grep does not read .gitignore and would
        // otherwise work through every object the repository has ever stored.
        try argv.appendSlice(allocator, &.{ "grep", "-r", "-n", "-I", "-E", "--exclude-dir=.git" });
        try appendGrepLimits(allocator, &argv, args);
        if (args.glob) |glob| try argv.appendSlice(allocator, &.{ "--include", glob });
        if (args.ignore_case) try argv.append(allocator, "-i");
        // `-e` rather than a bare pattern, for the same reason as `--` above.
        try argv.appendSlice(allocator, &.{ "-e", args.pattern, "--", args.path });
    }

    return argv.toOwnedSlice(allocator);
}

fn appendGrepLimits(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: GrepArgs) !void {
    if (args.context_lines) |number| {
        const flag = try std.fmt.allocPrint(allocator, "--context={d}", .{number});
        errdefer allocator.free(flag);
        try argv.append(allocator, flag);
    }
    if (args.max_matches) |number| {
        const flag = try std.fmt.allocPrint(allocator, "--max-count={d}", .{number});
        errdefer allocator.free(flag);
        try argv.append(allocator, flag);
    }
}

/// Build argv for one find call. Borrows args and literals; free only the slice.
pub fn findArgv(allocator: std.mem.Allocator, args: FindArgs, backends: SearchBackends) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);

    if (backends.fd) {
        // fd's defaults are the ones this tool wants: hidden files and anything
        // .gitignore leaves out are skipped, so the answer is the tree a
        // developer would have searched by hand.
        try argv.appendSlice(allocator, &.{ "fd", "--color=never", "--glob" });
        if (args.hidden) try argv.append(allocator, "--hidden");
        if (args.no_ignore) try argv.append(allocator, "--no-ignore");
        try argv.appendSlice(allocator, &.{ "--", args.pattern, args.path });
    } else {
        // find reads no ignore file of its own, so `.git` is pruned by hand —
        // without it, a search for a name would walk every object in the
        // repository. The `-print` on the second branch cannot be left out:
        // the `-o` alone would make find print nothing at all.
        try argv.appendSlice(allocator, &.{ "find", args.path, "-name", ".git", "-prune", "-o", "-name", args.pattern, "-print" });
    }

    return argv.toOwnedSlice(allocator);
}

/// Longest search output read back before the search is given up on. Much
/// larger than the 8 KB a result is finally cut to, so that an ordinary search
/// over a large repository comes back truncated rather than refused.
const search_max_output: usize = 256 * 1024;

/// Run a search program and shape its output into a tool result.
///
/// `exit_one_is_no_match` is the one way the two search tools differ. grep and
/// rg report a search that matched nothing with exit code 1, which is an answer
/// and not a failure; fd and find report it with a zero exit and no output, and
/// keep every nonzero code for an error — fd also uses 1 for a path it could
/// not search. A program killed by a signal is never an answer, whichever tool
/// asked for it.
fn runSearch(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    exit_one_is_no_match: bool,
    offset: usize,
) !ToolResult {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(search_max_output),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        // std refuses the whole result once the limit is passed, so there is
        // nothing of it worth showing; the model is told what to do instead.
        error.StreamTooLong => return toolError(
            allocator,
            "Error: the search matched more output than the tool reads. Narrow it with a 'glob' or a more specific 'pattern'.",
            .{},
        ),
        // A program that could not be started at all is reported rather than
        // failing the turn over, so the model can fall back to the shell.
        else => return toolError(allocator, "Error: could not run '{s}': {s}", .{ argv[0], @errorName(err) }),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // A program that died from a signal is not an answer, whatever the code it
    // would have carried means: `null` marks it as a failure below.
    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };
    const no_matches = exit_one_is_no_match and exit_code != null and exit_code.? == 1;
    const is_error = exit_code == null or (exit_code.? != 0 and !no_matches);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    if (result.stdout.len > 0) {
        const normalized = try normalizeToolText(allocator, result.stdout);
        defer allocator.free(normalized);
        try aw.writer.writeAll(normalized);
    }
    if (result.stderr.len > 0) {
        if (aw.written().len > 0) try aw.writer.writeAll("\n");
        try aw.writer.writeAll("stderr: ");
        const normalized = try normalizeToolText(allocator, result.stderr);
        defer allocator.free(normalized);
        try aw.writer.writeAll(normalized);
    }
    if (aw.written().len == 0) {
        // A search that matched nothing is the one thing this tool answers with
        // no output at all. Any other silent exit is a failure, and says that.
        try aw.writer.writeAll(if (is_error) "(no output)" else "(no matches)");
    }

    return searchPage(allocator, aw.written(), offset, !exit_one_is_no_match, .{
        .is_error = is_error,
        .exit_code = exit_code,
    });
}

fn searchPage(allocator: std.mem.Allocator, output: []const u8, offset: usize, sort: bool, status: ToolStatus) !ToolResult {
    if (offset == 0 and std.mem.eql(u8, output, "(no matches)"))
        return finalizeResultLimited(allocator, output, status, 8192);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, output, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    if (sort) std.mem.sort([]const u8, lines.items, {}, lessString);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var index = @min(offset, lines.items.len);
    var oversized = false;
    while (index < lines.items.len) : (index += 1) {
        const line = lines.items[index];
        if (aw.written().len + line.len + 1 > 7800) {
            if (aw.written().len == 0) {
                try aw.writer.writeAll("[One result exceeds the page size; use read with start_column or narrow the search.]\n");
                oversized = true;
                index += 1;
            }
            break;
        }
        try aw.writer.print("{s}\n", .{line});
    }
    const truncated = index < lines.items.len;
    if (truncated) try aw.writer.print("[More results; continue with offset={d}.]\n", .{index});
    return finalizeResultLimited(allocator, aw.written(), .{ .is_error = status.is_error, .exit_code = status.exit_code, .truncated = truncated or oversized }, 8192);
}

/// The grep tool: search file contents with a regular expression.
pub fn grep(io: std.Io, allocator: std.mem.Allocator, backends: SearchBackends, args: GrepArgs) !ToolResult {
    const argv = try grepArgv(allocator, args, backends);
    defer freeGrepArgv(allocator, argv);
    if (std.mem.indexOfAny(u8, args.path, "*?[") != null) {
        // Match the shell's pathname expansion, not rg's recursive --glob
        // filter: README* must only select entries in the current directory.
        // Pass all user input as positional arguments, never as shell source.
        // Empty IFS prevents splitting paths containing spaces; expansion does
        // not evaluate substitutions/operators contained in the path. An
        // unmatched glob stays literal, preserving the backend's error.
        var expanded: std.ArrayList([]const u8) = .empty;
        defer expanded.deinit(allocator);
        try expanded.appendSlice(allocator, &.{
            "sh", "-c", "path=$1; shift; IFS=; exec \"$@\" $path", "zagent-search", args.path,
        });
        try expanded.appendSlice(allocator, argv[0 .. argv.len - 1]);
        return runSearch(io, allocator, expanded.items, true, args.offset);
    }
    return runSearch(io, allocator, argv, true, args.offset);
}

/// The find tool: find files and directories by name.
pub fn find(io: std.Io, allocator: std.mem.Allocator, backends: SearchBackends, args: FindArgs) !ToolResult {
    const argv = try findArgv(allocator, args, backends);
    defer allocator.free(argv);
    return runSearch(io, allocator, argv, false, args.offset);
}

/// Longest response text the model is shown. Larger than the cap the other
/// tools use, because an API response cut off mid-JSON is useless.
pub const http_max_content: usize = 32 * 1024;

/// How many redirects a request without a body is followed through.
const http_max_redirects: u16 = 5;

/// An HTTP request as the model described it. Owns its strings.
pub const HttpRequest = struct {
    method: []const u8,
    url: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
    /// Write the response body to this path instead of returning it.
    save_to: ?[]const u8,

    pub fn deinit(self: HttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        if (self.body) |body| allocator.free(body);
        if (self.save_to) |path| allocator.free(path);
    }
};

/// Parse an http tool call's arguments.
pub fn parseHttpRequest(allocator: std.mem.Allocator, arguments_json: []const u8) !HttpRequest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const arguments = parsed.value.object;

    const url_value = arguments.get("url") orelse return error.MissingUrl;
    if (url_value != .string or url_value.string.len == 0) return error.MissingUrl;

    // The method keeps the casing the model used; it is matched when the
    // request is sent, so an unsupported one is reported back as an answer
    // rather than failing the parse.
    const method = if (arguments.get("method")) |value| blk: {
        if (value != .string or value.string.len == 0) break :blk "GET";
        break :blk value.string;
    } else "GET";
    if (parseHttpMethod(method) == null) return error.UnsupportedMethod;

    const url = try allocator.dupe(u8, url_value.string);
    errdefer allocator.free(url);
    const owned_method = try allocator.dupe(u8, method);
    errdefer allocator.free(owned_method);

    const headers = try parseHttpHeaders(allocator, arguments.get("headers"));
    errdefer {
        for (headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(headers);
    }

    const body = try optionalString(allocator, arguments.get("body"));
    errdefer if (body) |value| allocator.free(value);
    const save_to = try optionalString(allocator, arguments.get("save_to"));
    errdefer if (save_to) |value| allocator.free(value);

    return .{
        .method = owned_method,
        .url = url,
        .headers = headers,
        .body = body,
        .save_to = save_to,
    };
}

/// The methods the tool offers. CONNECT and TRACE are left out: neither is
/// useful to an agent, and CONNECT would take the connection over entirely.
fn parseHttpMethod(name: []const u8) ?std.http.Method {
    const offered = [_]std.http.Method{ .GET, .HEAD, .POST, .PUT, .PATCH, .DELETE, .OPTIONS };
    for (offered) |method| {
        if (std.ascii.eqlIgnoreCase(name, @tagName(method))) return method;
    }
    return null;
}

/// Parse the `headers` object, rejecting anything that could not be written as
/// a header line. std splits a header at its first colon when it sends it, so a
/// name carrying one — or either half carrying a newline — would let a value
/// forge headers of its own.
fn parseHttpHeaders(allocator: std.mem.Allocator, value: ?std.json.Value) ![]std.http.Header {
    const object = value orelse return &.{};
    if (object != .object) return error.InvalidHeaders;

    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        headers.deinit(allocator);
    }

    var iterator = object.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidHeaders;
        const name = entry.key_ptr.*;
        const header_value = entry.value_ptr.string;
        if (name.len == 0 or std.mem.indexOfAny(u8, name, ":\r\n") != null) return error.InvalidHeaders;
        if (std.mem.indexOfAny(u8, header_value, "\r\n") != null) return error.InvalidHeaders;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_value = try allocator.dupe(u8, header_value);
        errdefer allocator.free(owned_value);

        try headers.append(allocator, .{ .name = owned_name, .value = owned_value });
    }

    return headers.toOwnedSlice(allocator);
}

/// A string argument that may be absent. An empty string counts as absent, so a
/// model that sends `"body": ""` gets a request with no body rather than one
/// with a zero-length body.
fn optionalString(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const field = value orelse return null;
    if (field != .string) return error.InvalidArguments;
    if (field.string.len == 0) return null;
    return try allocator.dupe(u8, field.string);
}

/// Perform an HTTP request and return the status line, the response headers,
/// and the body. With `save_to` the body is streamed to that file and only a
/// summary comes back.
///
/// Delivery failures and HTTP 4xx/5xx statuses are error results. Failed
/// downloads leave the destination unchanged.
pub fn httpRequest(io: std.Io, allocator: std.mem.Allocator, request: HttpRequest) !ToolResult {
    const method = parseHttpMethod(request.method) orelse return toolError(
        allocator,
        "Error: unsupported HTTP method '{s}'. Use GET, HEAD, POST, PUT, PATCH, DELETE, or OPTIONS.",
        .{request.method},
    );

    const uri = std.Uri.parse(request.url) catch |err| return toolError(
        allocator,
        "Error: '{s}' is not a valid URL: {s}",
        .{ request.url, @errorName(err) },
    );

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Every method that takes a body always goes through the body path, even
    // with nothing to send, and every method that does not always goes through
    // the bodiless one: std asserts the two agree with the method.
    const sends_body = method.requestHasBody();
    const body = request.body orelse "";
    if (!sends_body and body.len != 0) return toolError(
        allocator,
        "Error: an HTTP {s} request cannot carry a body.",
        .{@tagName(method)},
    );

    var req = client.request(method, uri, .{
        // A body is already on the wire by the time a redirect arrives and std
        // cannot replay it, so a method that sends one gets the redirect
        // response back for the model to follow instead of following it here.
        // This must match the send path below, which routes by method too.
        .redirect_behavior = if (sends_body)
            .unhandled
        else
            std.http.Client.Request.RedirectBehavior.init(http_max_redirects),
        // The model's headers go through the privileged slot so that a
        // credential is not carried to another domain by a redirect.
        .privileged_headers = request.headers,
    }) catch |err| return toolError(
        allocator,
        "Error: could not send a request to '{s}': {s}",
        .{ request.url, @errorName(err) },
    );
    defer req.deinit();

    if (sends_body) {
        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| return toolError(
            allocator,
            "Error: could not send the request body to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
        body_writer.writer.writeAll(body) catch |err| return toolError(
            allocator,
            "Error: could not send the request body to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
        body_writer.end() catch |err| return toolError(
            allocator,
            "Error: could not send the request body to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
        req.connection.?.flush() catch |err| return toolError(
            allocator,
            "Error: could not send the request body to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
    } else {
        req.sendBodiless() catch |err| return toolError(
            allocator,
            "Error: could not send a request to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
    }

    const redirect_buffer = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(redirect_buffer);

    var response = req.receiveHead(redirect_buffer) catch |err| return toolError(
        allocator,
        "Error: no response from '{s}': {s}",
        .{ request.url, @errorName(err) },
    );

    // The status line and headers are written out here, before the body is
    // touched: reading the body invalidates the buffer they point into.
    var head_aw: std.Io.Writer.Allocating = .init(allocator);
    defer head_aw.deinit();
    const head = response.head;
    const http_error = @backingInt(head.status) >= 400;
    try writeResponseHead(&head_aw.writer, head.version, head.status, head.reason, head.iterateHeaders());

    const has_body = responseHasBody(&response);
    if (!has_body) {
        // Nothing will drain the body, and deinit's own drain would block on a
        // response whose framing never ends. Closing the connection instead
        // costs nothing: this client is not reused.
        if (req.connection) |connection| connection.closing = true;
    }

    if (request.save_to) |path| {
        if (http_error) return .{
            .content = try std.fmt.allocPrint(allocator, "{s}\nHTTP error: destination '{s}' was not changed.", .{ head_aw.written(), path }),
            .is_error = true,
        };
        const written = saveResponseBody(io, allocator, &response, path) catch |err| return toolError(
            allocator,
            "Error: could not save the response from '{s}' to '{s}': {s}",
            .{ request.url, path, @errorName(err) },
        );

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print("Saved {d} bytes to '{s}'\n", .{ written, path });
        try aw.writer.writeAll(head_aw.written());
        return finalizeResultLimited(allocator, aw.written(), .{ .is_error = false }, http_max_content);
    }

    const body_text = if (has_body)
        try readResponseBody(allocator, &response)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(body_text);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll(head_aw.written());
    try aw.writer.writeByte('\n');
    if (body_text.len > 0) {
        try aw.writer.writeAll(body_text);
    } else {
        try aw.writer.writeAll("(empty body)");
    }

    return finalizeResultLimited(allocator, aw.written(), .{ .is_error = http_error, .truncated = body_text.len == http_max_content }, http_max_content);
}

/// Write the status line and every response header. Takes the head's parts
/// rather than the response so that the shape of what the model sees can be
/// tested without a socket.
fn writeResponseHead(
    w: *std.Io.Writer,
    version: std.http.Version,
    status: std.http.Status,
    server_reason: []const u8,
    iterator: std.http.HeaderIterator,
) !void {
    // Prefer the reason the server sent over the one std has for the code:
    // servers are free to phrase it themselves.
    const reason = if (server_reason.len > 0) server_reason else status.phrase() orelse "";
    if (reason.len > 0) {
        try w.print("{s} {d} {s}\n", .{ @tagName(version), @backingInt(status), reason });
    } else {
        try w.print("{s} {d}\n", .{ @tagName(version), @backingInt(status) });
    }

    var headers = iterator;
    while (headers.next()) |header| {
        try w.print("{s}: {s}\n", .{ header.name, header.value });
    }
}

/// Whether the response carries a body. A reader taken on one of the exceptions
/// would stream from the raw connection instead of the message framing and
/// block until the server closes it, because std only knows to expect no body
/// for a HEAD — not for these statuses.
fn responseHasBody(response: *const std.http.Client.Response) bool {
    if (!response.request.method.responseHasBody()) return false;
    const status = response.head.status;
    if (status == .no_content or status == .reset_content or status == .not_modified) return false;
    return status.class() != .informational;
}

/// Read the response body into memory, stopping at `http_max_content` rather
/// than failing, so an oversized body still shows its beginning.
fn readResponseBody(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    while (aw.written().len < http_max_content) {
        // A short read is not the end of the body: the stream reports zero when
        // nothing has arrived yet, so only EndOfStream or the cap ends this
        // loop. Stopping at the cap leaves the rest unread, which deinit closes
        // the connection over rather than draining.
        _ = reader.stream(&aw.writer, .limited(http_max_content - aw.written().len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }
    if (aw.written().len < http_max_content) try checkResponseBodyComplete(response);
    return aw.toOwnedSlice();
}

// A decompressor can finish before the transfer reader consumes the final
// chunk framing. Advance that reader to EOF without accepting extra payload.
// Zig's content-length reader can also forward a premature socket EOF while
// framed bytes remain, so verify the state after observing EOF.
fn checkResponseBodyComplete(response: *std.http.Client.Response) !void {
    const transfer = &response.request.reader;
    switch (transfer.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => {
            if (transfer.interface.takeByte()) |_| {
                return error.UnexpectedTrailingData;
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
            switch (transfer.state) {
                .body_remaining_content_length, .body_remaining_chunk_len => return error.UnexpectedEndOfStream,
                else => {},
            }
        },
        else => {},
    }
}

/// Stream the response body into `path`, creating parent directories as needed,
/// and return the number of bytes written.
fn saveResponseBody(io: std.Io, allocator: std.mem.Allocator, response: *std.http.Client.Response, path: []const u8) !u64 {
    if (std.Io.Dir.path.dirname(path)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);

    // A bodyless response still gets its file, empty, so that a download's
    // result does not depend on the server having sent one.
    if (!responseHasBody(response)) {
        try atomic.replace(io);
        return 0;
    }

    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_writer = atomic.file.writer(io, &file_buffer);
    const written = reader.streamRemaining(&file_writer.interface) catch |err| {
        // A write failure is reported as WriteFailed, with the real error kept
        // on the writer.
        if (file_writer.err) |write_err| return write_err;
        return err;
    };
    try checkResponseBodyComplete(response);
    try file_writer.end();
    try atomic.replace(io);
    return written;
}

/// The buffer a decompressing reader needs. Empty for an uncompressed body,
/// which is the usual case.
fn allocDecompressBuffer(allocator: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => error.UnsupportedCompressionMethod,
    };
}

fn toolError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

test "bash supports arrays and double brackets" {
    const result = try executeShell(std.testing.io, std.testing.allocator, "items=(hello world); [[ ${#items[@]} == 2 ]] && printf '%s' \"${items[1]}\"");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("Exit code: 0\nworld", result.content);
}

test "shell echo" {
    const result = try executeShell(std.testing.io, std.testing.allocator, "echo hello");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "hello") != null);
}

test "shell exit code" {
    const result = try executeShell(std.testing.io, std.testing.allocator, "exit 1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

test "read missing file" {
    const result = try readFile(std.testing.io, std.testing.allocator, "/nonexistent/path/file.txt");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

/// The absolute path of a test's fixture directory.
fn fixturePath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(std.testing.io, buf)];
}

/// Assert the argv a search tool would run, element by element. Comparing the
/// two slices directly would compare pointers rather than the text.
fn expectArgv(expected: []const []const u8, argv: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a search program is only found where one can be run" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An executable `rg`, a plain file `fd`, and a directory named `grep`:
    // only the first is something the tool could run.
    var rg = try tmp.dir.createFile(io, "rg", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
    rg.close(io);
    var fd_file = try tmp.dir.createFile(io, "fd", .{ .permissions = std.Io.File.Permissions.fromMode(0o644) });
    fd_file.close(io);
    try tmp.dir.createDir(io, "grep", std.Io.File.Permissions.default_dir);

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    try std.testing.expect(isOnPath(io, dir, "rg"));
    // A file that is not executable, and a directory that shares the name, are
    // both things a shell would refuse to run.
    try std.testing.expect(!isOnPath(io, dir, "fd"));
    try std.testing.expect(!isOnPath(io, dir, "grep"));
    try std.testing.expect(!isOnPath(io, dir, "definitely-not-here"));
    // An empty entry means the working directory, which is not searched.
    try std.testing.expect(!isOnPath(io, ":", "rg"));
}

test "grep argv picks ripgrep when it is installed" {
    const allocator = std.testing.allocator;
    const args = GrepArgs{ .pattern = "fn main", .path = "src", .glob = "*.zig", .ignore_case = true };

    const argv = try grepArgv(allocator, args, .{ .rg = true });
    defer allocator.free(argv);

    try expectArgv(
        &.{ "rg", "--line-number", "--no-heading", "--color=never", "--no-config", "--sort=path", "--glob", "*.zig", "--ignore-case", "--", "fn main", "src" },
        argv,
    );
}

test "grep argv falls back to grep" {
    const allocator = std.testing.allocator;
    const args = GrepArgs{ .pattern = "fn main", .path = "src", .glob = "*.zig", .ignore_case = true };

    const argv = try grepArgv(allocator, args, .{});
    defer allocator.free(argv);

    // `-E` is what makes the fallback read the same regular expressions as
    // ripgrep; without it `|`, `+` and `()` would be literals.
    try expectArgv(
        &.{ "grep", "-r", "-n", "-I", "-E", "--exclude-dir=.git", "--include", "*.zig", "-i", "-e", "fn main", "--", "src" },
        argv,
    );

    const plain = try grepArgv(allocator, .{ .pattern = "needle", .path = ".", .glob = null, .ignore_case = false }, .{});
    defer allocator.free(plain);
    try expectArgv(&.{ "grep", "-r", "-n", "-I", "-E", "--exclude-dir=.git", "-e", "needle", "--", "." }, plain);
}

test "find argv picks fd when it is installed" {
    const allocator = std.testing.allocator;
    const args = FindArgs{ .pattern = "*.zig", .path = "src" };

    const argv = try findArgv(allocator, args, .{ .fd = true });
    defer allocator.free(argv);

    try expectArgv(&.{ "fd", "--color=never", "--glob", "--", "*.zig", "src" }, argv);
}

test "find argv falls back to find" {
    const allocator = std.testing.allocator;
    const args = FindArgs{ .pattern = "*.zig", .path = "src" };

    const argv = try findArgv(allocator, args, .{});
    defer allocator.free(argv);

    // The `-print` is load-bearing: `-prune -o -name …` with nothing after it
    // would make find print nothing at all.
    try expectArgv(&.{ "find", "src", "-name", ".git", "-prune", "-o", "-name", "*.zig", "-print" }, argv);
}

test "parse grep args defaults to the current directory" {
    const allocator = std.testing.allocator;
    const args = try parseGrepArgs(allocator, "{\"pattern\":\"needle\"}");
    defer args.deinit(allocator);

    try std.testing.expectEqualStrings("needle", args.pattern);
    try std.testing.expectEqualStrings(".", args.path);
    try std.testing.expect(args.glob == null);
    try std.testing.expect(!args.ignore_case);
}

test "parse a search rejects the arguments it cannot use" {
    const allocator = std.testing.allocator;

    // An empty pattern matches every line of every file, which is a missing
    // argument rather than a wide search.
    try std.testing.expectError(error.MissingPattern, parseGrepArgs(allocator, "{}"));
    try std.testing.expectError(error.MissingPattern, parseGrepArgs(allocator, "{\"pattern\":\"\"}"));
    try std.testing.expectError(error.MissingPattern, parseGrepArgs(allocator, "{\"pattern\":7}"));
    try std.testing.expectError(error.MissingPattern, parseFindArgs(allocator, "{}"));
    try std.testing.expectError(error.InvalidArguments, parseGrepArgs(allocator, "[]"));
    try std.testing.expectError(error.InvalidArguments, parseFindArgs(allocator, "[]"));
    // A flag sent as a string is not a flag: the arguments are typed, and
    // guessing here would let the model write the command line after all.
    try std.testing.expectError(error.InvalidArguments, parseGrepArgs(allocator, "{\"pattern\":\"x\",\"ignore_case\":\"yes\"}"));
}

test "grep finds a line and the file it is in" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "first line\nthe needle is here\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // The fallback backend is asked for by name: whether the machine running
    // the tests has ripgrep installed must not change what they assert.
    const result = try grep(io, allocator, .{}, .{ .pattern = "needle", .path = dir, .glob = null, .ignore_case = false });
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "note.txt:2:the needle is here") != null);
}

test "grep expands path globs without interpreting user input as shell source" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "docs space", .default_dir);
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "docs space/README.md", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs space/README zh.md", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs space/README $(printf INJECTED).md", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/README.md", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.md", .data = "needle\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // Always exercise grep; also exercise rg when available on the test host.
    const probe = std.process.run(allocator, io, .{ .argv = &.{ "rg", "--version" } }) catch null;
    defer if (probe) |result| {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    };
    const have_rg = if (probe) |result| switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    } else false;
    for ([_]bool{ false, true }) |use_rg| {
        if (use_rg and !have_rg) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/docs */README*", .{dir});
        defer allocator.free(path);
        const result = try grep(io, allocator, .{ .rg = use_rg }, .{
            .pattern = "needle",
            .path = path,
            .glob = null,
            .ignore_case = false,
        });
        defer result.deinit(allocator);
        try std.testing.expect(!result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "README.md:1:needle") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "README zh.md:1:needle") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "README $(printf INJECTED).md:1:needle") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "nested/") == null);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "other.md") == null);

        const missing_path = try std.fmt.allocPrint(allocator, "{s}/missing*", .{dir});
        defer allocator.free(missing_path);
        const missing = try grep(io, allocator, .{ .rg = use_rg }, .{
            .pattern = "needle",
            .path = missing_path,
            .glob = null,
            .ignore_case = false,
        });
        defer missing.deinit(allocator);
        try std.testing.expect(missing.is_error);
    }
}

test "a search that matched nothing is an answer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "first line\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // grep exits 1 when it matched nothing. Reading that as a failure would
    // send the model off to retry a search that has already answered.
    const searched = try grep(io, allocator, .{}, .{ .pattern = "nowhere", .path = dir, .glob = null, .ignore_case = false });
    defer searched.deinit(allocator);
    try std.testing.expect(!searched.is_error);
    try std.testing.expectEqualStrings("(no matches)", searched.content);

    // find reports the same nothing with a zero exit and no output at all.
    const looked = try find(io, allocator, .{}, .{ .pattern = "*.nope", .path = dir });
    defer looked.deinit(allocator);
    try std.testing.expect(!looked.is_error);
    try std.testing.expectEqualStrings("(no matches)", looked.content);
}

test "find returns the paths whose name matches" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "wanted.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "not this one\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const result = try find(io, allocator, .{}, .{ .pattern = "*.zig", .path = dir });
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "wanted.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "other.txt") == null);
}

test "a search that failed is an error, not an empty answer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // A pattern the program cannot compile comes back on stderr with the code
    // that means failure — 2 for both greps, unlike the 1 for "no match".
    const result = try grep(io, allocator, .{}, .{ .pattern = "[", .path = ".", .glob = null, .ignore_case = false });
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "stderr:") != null);

    // A path that does not exist is a failure for find too, even though fd
    // reports it with the exit code the content searches use for "no match".
    const missing = try find(io, allocator, .{}, .{ .pattern = "*.zig", .path = "/nonexistent-path-for-zagent-tests" });
    defer missing.deinit(allocator);
    try std.testing.expect(missing.is_error);
}

test "apply patch changes the file and says what it changed" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try std.fmt.allocPrint(allocator,
        \\--- {s}/note.txt
        \\+++ {s}/note.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\+TWO
    , .{ dir, dir });
    defer allocator.free(patch);

    const result = try applyPatch(io, allocator, patch);
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Applied 1 file: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "note.txt (+1 -1)") != null);
}

test "a patch that does not fit is an error the model can act on" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // The context is from some other version of the file. The message has to
    // carry the file, the line and the text, or the next attempt is a guess.
    const patch = try std.fmt.allocPrint(allocator,
        \\--- {s}/note.txt
        \\+++ {s}/note.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-nowhere
        \\+anywhere
    , .{ dir, dir });
    defer allocator.free(patch);

    const result = try applyPatch(io, allocator, patch);
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "Error: "));
    try std.testing.expect(std.mem.indexOf(u8, result.content, "note.txt") != null);

    // And nothing was written: the file is exactly as it was.
    const content = try tmp.dir.readFileAlloc(io, "note.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("one\ntwo\n", content);
}

test "a search that outruns the limit is refused with advice" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // `yes` writes without end, which is the shape of output this tool cannot
    // read at all: std refuses the whole result once the cap is passed rather
    // than handing back the beginning of it.
    const result = try runSearch(io, allocator, &.{"yes"}, true, 0);
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Narrow it") != null);
}

test "tool status preserves failures and records actual truncation not printed suffixes" {
    const a = std.testing.allocator;
    const result = try finalizeResultLimited(a, "abcdefghijklmnopqrstuvwxyz0123456789", .{ .is_error = true, .exit_code = 7, .timed_out = true }, 32);
    defer a.free(result.content);
    try std.testing.expect(result.status().is_error);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    try std.testing.expect(result.timed_out and result.truncated);
    const printed = try finalizeResultLimited(a, "... (truncated)", .{ .is_error = false }, 32);
    defer a.free(printed.content);
    try std.testing.expect(!printed.truncated);
    const encoded = try formatToolOutput(a, result.status(), result.content);
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"exit_code\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"timed_out\":true") != null);
}

fn finalizeToolContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return finalizeToolContentLimited(allocator, raw, 8192);
}

/// Turn text that came from outside this program into what the model is shown:
/// Preserve truncation at the point it happens, rather than guessing from a
/// suffix which the external tool could itself have printed.
pub fn finalizeResultLimited(allocator: std.mem.Allocator, raw: []const u8, status: ToolStatus, max_len: usize) !ToolResult {
    const normalized = try normalizeToolText(allocator, raw);
    defer allocator.free(normalized);
    return .{
        .content = try finalizeToolContentLimited(allocator, normalized, max_len),
        .is_error = status.is_error,
        .exit_code = status.exit_code,
        .timed_out = status.timed_out,
        .truncated = status.truncated or normalized.len > max_len,
    };
}

/// Turn text that came from outside this program into what the model is shown:
/// sanitized, then capped on a UTF-8 boundary. Shared with the MCP client,
/// whose results are as untrusted as a tool's output and are read the same way.
pub fn finalizeToolContentLimited(allocator: std.mem.Allocator, raw: []const u8, max_len: usize) ![]u8 {
    const normalized = try normalizeToolText(allocator, raw);
    defer allocator.free(normalized);

    const suffix = "\n... (truncated)";
    if (normalized.len <= max_len) return allocator.dupe(u8, normalized);

    var cut = max_len - suffix.len;
    while (cut > 0 and !std.unicode.utf8ValidateSlice(normalized[0..cut])) : (cut -= 1) {}
    if (cut == 0) cut = max_len - suffix.len;

    return std.fmt.allocPrint(allocator, "{s}{s}", .{ normalized[0..cut], suffix });
}

/// Strip what a terminal would act on out of tool output, and escape the rest
/// of what is not text. The rule itself lives in `text.zig`, which is where the
/// renderer and the diff drawing get it from too.
fn normalizeToolText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try text.writeSanitized(&aw.writer, raw);

    if (aw.written().len == 0) {
        try aw.writer.writeAll("(no output)");
    }

    return aw.toOwnedSlice();
}

test "normalize tool text strips ansi sequences" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeToolText(allocator, "\x1b[32mgreen\x1b[0m");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("green", normalized);
}

test "normalize tool text escapes invalid utf8" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeToolText(allocator, &[_]u8{ 'o', 'k', 0xff });
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("ok\\xFF", normalized);
}

test "parse http request defaults to GET without a body" {
    const allocator = std.testing.allocator;
    const request = try parseHttpRequest(allocator, "{\"url\":\"https://example.com\"}");
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("https://example.com", request.url);
    try std.testing.expectEqual(@as(usize, 0), request.headers.len);
    try std.testing.expect(request.body == null);
    try std.testing.expect(request.save_to == null);
}

test "parse http request reads method headers and body" {
    const allocator = std.testing.allocator;
    const request = try parseHttpRequest(allocator,
        \\{"url":"https://api.example.com/items","method":"post",
        \\ "headers":{"Content-Type":"application/json","X-Trace":"  spaced  "},
        \\ "body":"{\"name\":\"widget\"}","save_to":"out/items.json"}
    );
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("post", request.method);
    try std.testing.expectEqual(@as(usize, 2), request.headers.len);
    try std.testing.expectEqualStrings("Content-Type", request.headers[0].name);
    try std.testing.expectEqualStrings("application/json", request.headers[0].value);
    try std.testing.expectEqualStrings("X-Trace", request.headers[1].name);
    try std.testing.expectEqualStrings("  spaced  ", request.headers[1].value);
    try std.testing.expectEqualStrings("{\"name\":\"widget\"}", request.body.?);
    try std.testing.expectEqualStrings("out/items.json", request.save_to.?);
}

test "parse http request rejects arguments it cannot use" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingUrl, parseHttpRequest(allocator, "{\"method\":\"GET\"}"));
    try std.testing.expectError(error.MissingUrl, parseHttpRequest(allocator, "{\"url\":\"\"}"));
    try std.testing.expectError(error.UnsupportedMethod, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"method\":\"BREW\"}",
    ));
    try std.testing.expectError(error.InvalidArguments, parseHttpRequest(allocator, "[]"));
    try std.testing.expectError(error.InvalidArguments, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"body\":5}",
    ));
    // A header that cannot be written as a header line is rejected rather than
    // sent: std asserts on the first two, and the third would forge a second
    // header of its own.
    try std.testing.expectError(error.InvalidHeaders, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"headers\":{\"X-Count\":1}}",
    ));
    try std.testing.expectError(error.InvalidHeaders, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"headers\":{\"X-Trace\":\"a\\r\\nInjected: 1\"}}",
    ));
    try std.testing.expectError(error.InvalidHeaders, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"headers\":{\"X-Trace: Injected\":\"a\"}}",
    ));
}

test "an empty body argument counts as no body" {
    const allocator = std.testing.allocator;
    const request = try parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"method\":\"POST\",\"body\":\"\"}",
    );
    defer request.deinit(allocator);
    try std.testing.expect(request.body == null);
}

test "http methods are matched case-insensitively" {
    try std.testing.expectEqual(std.http.Method.GET, parseHttpMethod("get").?);
    try std.testing.expectEqual(std.http.Method.PATCH, parseHttpMethod("Patch").?);
    try std.testing.expectEqual(std.http.Method.OPTIONS, parseHttpMethod("OPTIONS").?);
    try std.testing.expect(parseHttpMethod("") == null);
    try std.testing.expect(parseHttpMethod("get / HTTP/1.1") == null);
    // Taking the connection over is not something the tool offers.
    try std.testing.expect(parseHttpMethod("CONNECT") == null);
}

test "the response head is written as a status line then its headers" {
    const allocator = std.testing.allocator;
    const raw_headers = "HTTP/1.1 200 OK\r\n" ++
        "content-type: application/json\r\n" ++
        "content-length: 11\r\n\r\n";

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeResponseHead(
        &aw.writer,
        .@"HTTP/1.1",
        .ok,
        "OK",
        std.http.HeaderIterator.init(raw_headers),
    );

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\ncontent-type: application/json\ncontent-length: 11\n",
        aw.written(),
    );
}

test "a status the server left unphrased still gets its code" {
    const allocator = std.testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeResponseHead(
        &aw.writer,
        .@"HTTP/1.1",
        .not_found,
        "",
        std.http.HeaderIterator.init("HTTP/1.1 404 Not Found\r\n\r\n"),
    );

    // The phrase comes from std when the server sent none, so the line still
    // reads as a status rather than a bare number.
    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found\n", aw.written());
}

test "http request reports a method it cannot send" {
    const allocator = std.testing.allocator;
    // Reaching httpRequest at all is the point: the test build only compiles
    // the bodies it can see referenced, and this one is otherwise never
    // analyzed until an executable is built.
    const result = try httpRequest(std.testing.io, allocator, .{
        .method = "BREW",
        .url = "http://127.0.0.1:1/",
        .headers = &.{},
        .body = null,
        .save_to = null,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "BREW") != null);
}

test "http request reports a url it cannot use" {
    const allocator = std.testing.allocator;
    const result = try httpRequest(std.testing.io, allocator, .{
        .method = "GET",
        .url = "not a url",
        .headers = &.{},
        .body = null,
        .save_to = null,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "valid URL") != null);
}

test "http content is truncated at its own larger limit" {
    const allocator = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    for (0..http_max_content + 512) |_| try raw.append(allocator, 'x');

    const finalized = try finalizeToolContentLimited(allocator, raw.items, http_max_content);
    defer allocator.free(finalized);

    try std.testing.expect(std.mem.endsWith(u8, finalized, "\n... (truncated)"));
    try std.testing.expect(finalized.len <= http_max_content);
}

test "finalize tool content truncates on utf8 boundary" {
    const allocator = std.testing.allocator;
    var repeated: std.ArrayList(u8) = .empty;
    defer repeated.deinit(allocator);
    for (0..1500) |_| {
        try repeated.appendSlice(allocator, "你好");
    }

    const finalized = try finalizeToolContent(allocator, repeated.items);
    defer allocator.free(finalized);
    try std.testing.expect(std.mem.endsWith(u8, finalized, "\n... (truncated)"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(finalized));
}

test "every tool that waits has a progress label, ask_user does not" {
    try std.testing.expect(progressLabel("shell") == null);
    try std.testing.expect(progressLabel("http_request") == null);
    const labelled = [_][]const u8{ "bash", "read", "write", "ls", "rg", "fd", "apply_patch", "grep", "find", "http" };
    for (labelled) |name| {
        const label = progressLabel(name) orelse return error.TestUnexpectedResult;
        // The label names the tool, so a user watching the line knows what is
        // taking the time.
        try std.testing.expect(std.mem.startsWith(u8, label, name));
    }

    // ask_user puts a question on the terminal and reads the answer from it:
    // an animation over that line would fight the prompt.
    try std.testing.expectEqual(@as(?[]const u8, null), progressLabel("ask_user"));
    // A name the model made up runs nothing and waits for nothing; it is not
    // written to the terminal either.
    try std.testing.expectEqual(@as(?[]const u8, null), progressLabel("rm -rf /"));
    try std.testing.expectEqual(@as(?[]const u8, null), progressLabel("shell\x1b[31m"));
}

test "exact edits reject ambiguous text and preserve permissions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "script", .{ .permissions = .fromMode(0o755) });
    try file.setPermissions(io, .fromMode(0o755));
    try file.writeStreamingAll(io, "alpha alpha\n");
    file.close(io);
    const path = try tmp.dir.realPathFileAlloc(io, "script", allocator);
    defer allocator.free(path);
    const rejected = try editFile(io, allocator, path, "alpha", "changed");
    defer rejected.deinit(allocator);
    try std.testing.expect(rejected.is_error);
    const unchanged = try tmp.dir.readFileAlloc(io, "script", allocator, .limited(1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("alpha alpha\n", unchanged);
    const edited = try editFile(io, allocator, path, "alpha alpha", "beta");
    defer edited.deinit(allocator);
    try std.testing.expect(!edited.is_error);
    const content = try tmp.dir.readFileAlloc(io, "script", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("beta\n", content);
    const stat = try tmp.dir.statFile(io, "script", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o7777);
}
