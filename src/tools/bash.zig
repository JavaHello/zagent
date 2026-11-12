const std = @import("std");
const result_mod = @import("result.zig");
const ccr = @import("ccr.zig");

const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;
const normalizeToolText = result_mod.normalizeToolText;
const finalizeNormalizedResultOwnedLimited = result_mod.finalizeNormalizedResultOwnedLimited;
const max_output_bytes = result_mod.default_output_bytes;

/// How many lines of a long output the preview keeps. Enough for the end of a
/// build to be read at a glance, few enough that the result stays a summary:
/// the rest is a `ccr_retrieve` call away.
const preview_lines = 40;

/// Bytes a preview may take before whole lines are dropped from its beginning.
const preview_bytes = 4 * 1024;

/// Cache command output strictly larger than 8 KiB.
pub const cache_threshold_bytes = 8 * 1024;

/// The whole text one call would show if a result had no size limit: the
/// normalized stdout, then stderr under a label of its own, so a line read back
/// later is never two streams run together. One body is built for both the
/// cache file and the preview, so `offset` counts the lines the model was told
/// about.
fn buildBody(allocator: std.mem.Allocator, stdout_text: ?[]const u8, stderr_text: ?[]const u8) ![]u8 {
    const out = stdout_text orelse "";
    const err = stderr_text orelse "";
    if (out.len == 0 and err.len == 0) return allocator.dupe(u8, "(no output)");
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll(out);
    if (err.len > 0) {
        if (out.len > 0 and out[out.len - 1] != '\n') try aw.writer.writeByte('\n');
        try aw.writer.writeAll("stderr:\n");
        try aw.writer.writeAll(err);
    }
    return aw.toOwnedSlice();
}

/// Where the last `lines` lines of `text` start, walking back no further than
/// `budget` bytes and never cutting a line in half: whole lines are dropped
/// from the beginning instead. A single line longer than the budget is the one
/// exception, and it is cut on a UTF-8 boundary.
fn tailStart(text: []const u8, lines: usize, budget: usize) usize {
    var start: usize = 0;
    var remaining = lines;
    var index = text.len;
    while (index > 0 and remaining > 0) {
        index -= 1;
        if (text[index] == '\n' and index + 1 < text.len) {
            remaining -= 1;
            start = index + 1;
        }
    }
    if (remaining > 0) start = 0;
    while (start < text.len and text.len - start > budget) {
        const next = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse break;
        if (next + 1 == text.len) break;
        start = next + 1;
    }
    if (text.len - start <= budget) return start;
    var cut = text.len - budget;
    while (cut < text.len and (text[cut] & 0xc0) == 0x80) cut += 1;
    return cut;
}

pub fn executeShell(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !ToolResult {
    return executeShellWithEnv(io, allocator, command, null, null);
}

pub fn executeShellWithEnv(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: []const u8,
    env: ?*const std.process.Environ.Map,
    cache_dir: ?[]const u8,
) !ToolResult {
    // Capture once without dropping output at an arbitrary stream limit.
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "bash", "--noprofile", "--norc", "-c", command },
        .environ_map = env,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };

    const stdout_text: ?[]u8 = if (result.stdout.len > 0) try normalizeToolText(allocator, result.stdout) else null;
    defer if (stdout_text) |text| allocator.free(text);
    const stderr_text: ?[]u8 = if (result.stderr.len > 0) try normalizeToolText(allocator, result.stderr) else null;
    defer if (stderr_text) |text| allocator.free(text);

    const body = try buildBody(allocator, stdout_text, stderr_text);
    defer allocator.free(body);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    // Content is sent to the model and persisted in session history. Keep
    // status first so a preview of long command output cannot hide it.
    if (exit_code) |code| {
        try aw.writer.print("Exit code: {d}\n", .{code});
    } else {
        try aw.writer.print("Exit code: unavailable (termination: {any})\n", .{result.term});
    }
    const failed = exit_code == null or exit_code.? != 0;

    if (body.len <= cache_threshold_bytes) {
        try aw.writer.writeAll(body);
        return finalizeNormalizedResultOwnedLimited(allocator, try aw.toOwnedSlice(), .{
            .is_error = failed,
            .exit_code = exit_code,
            .truncated = false,
        }, max_output_bytes);
    }

    // Too long for one result. The tail is what the model needs first — the end
    // of a build, the last error of a test run — and the whole text is kept so
    // the rest is one `ccr_retrieve` call away rather than a lost answer.
    const preview = body[tailStart(body, preview_lines, preview_bytes)..];
    try aw.writer.writeAll(preview);
    if (preview.len == 0 or preview[preview.len - 1] != '\n') try aw.writer.writeByte('\n');

    if (cache_dir) |dir| {
        const saved = ccr.save(io, allocator, dir, body) catch |err| {
            // The command ran; only the copy of its output was lost. Saying so
            // keeps the failure where it belongs instead of failing the call.
            try aw.writer.print(
                "[Output cut here: {d} lines, {d} bytes of output, and this run could not cache the rest ({s}). Redirect long output to a file and read it in pages.]",
                .{ ccr.countLines(body), body.len, @errorName(err) },
            );
            return finalizeNormalizedResultOwnedLimited(allocator, try aw.toOwnedSlice(), .{
                .is_error = failed,
                .exit_code = exit_code,
                .truncated = true,
            }, max_output_bytes);
        };
        try aw.writer.print(
            "[ccr {s}: {d} lines, {d} bytes, the last lines shown here. Call ccr_retrieve with id \"{s}\" to page through it with offset and limit, or query=\"text\" to find lines.]",
            .{ saved.id, saved.lines, saved.bytes, saved.id },
        );
        return finalizeNormalizedResultOwnedLimited(allocator, try aw.toOwnedSlice(), .{
            .is_error = failed,
            .exit_code = exit_code,
            .truncated = true,
        }, max_output_bytes);
    }

    // No cache was offered: the rest of this output is not reachable, so the
    // call reports what it could not show rather than reading as complete.
    try aw.writer.print(
        "[Output cut: {d} lines, {d} bytes, only the last lines shown. Redirect long output to a file and read it in pages.]",
        .{ ccr.countLines(body), body.len },
    );
    return finalizeNormalizedResultOwnedLimited(allocator, try aw.toOwnedSlice(), .{
        .is_error = true,
        .exit_code = exit_code,
        .truncated = true,
    }, max_output_bytes);
}

test "preview keeps all short tails and bounds a single long terminated line" {
    try std.testing.expectEqual(@as(usize, 0), tailStart("one\ntwo\nthree\n", 40, 4096));
    try std.testing.expectEqual(@as(usize, 4), tailStart("one\ntwo\nthree\n", 2, 4096));
    try std.testing.expectEqual(@as(usize, 4), tailStart("one\ntwo\nthree\n", 40, 10));
    try std.testing.expectEqual(@as(usize, 6), tailStart("123456789\n", 40, 4));
}

test "cache threshold is strictly greater than eight KiB and large outputs survive" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    for ([_]usize{ 8192, 8193, 1024 * 1024 + 1 }) |size| {
        const command = try std.fmt.allocPrint(a, "printf '%{d}s' ''", .{size});
        defer a.free(command);
        const result = try executeShellWithEnv(io, a, command, null, dir);
        defer result.deinit(a);
        try std.testing.expect(!result.is_error);
        try std.testing.expectEqual(size > cache_threshold_bytes, result.truncated);
        const marker = std.mem.indexOf(u8, result.content, "[ccr ");
        try std.testing.expectEqual(size > cache_threshold_bytes, marker != null);
        if (marker) |start| {
            const id = result.content[start + 5 ..][0..ccr.id_len];
            const name = try std.fmt.allocPrint(a, "{s}.log", .{id});
            defer a.free(name);
            const file = try tmp.dir.openFile(io, name, .{});
            defer file.close(io);
            const stat = try file.stat(io);
            try std.testing.expectEqual(size, stat.size);
        }
    }
}

test "shell status survives empty output, stderr, signals and truncation" {
    const cases = [_]struct { command: []const u8, prefix: []const u8, is_error: bool }{
        .{ .command = "exit 0", .prefix = "Exit code: 0\n(no output)", .is_error = false },
        .{ .command = "exit 42", .prefix = "Exit code: 42\n(no output)", .is_error = true },
        .{ .command = "printf out; printf err >&2; exit 7", .prefix = "Exit code: 7\nout\nstderr:\nerr", .is_error = true },
        .{ .command = "printf warning >&2", .prefix = "Exit code: 0\nstderr:\nwarning", .is_error = false },
        .{ .command = "kill -TERM $$", .prefix = "Exit code: unavailable (termination: ", .is_error = true },
        .{ .command = "printf '%50000s' ''; exit 9", .prefix = "Exit code: 9\n", .is_error = true },
    };
    for (cases) |case| {
        const result = try executeShell(std.testing.io, std.testing.allocator, case.command);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.is_error, result.is_error);
        try std.testing.expect(std.mem.startsWith(u8, result.content, case.prefix));
        try std.testing.expect(result.content.len <= max_output_bytes);
    }
    // Without a cache the rest is out of reach, so the cut is reported as a
    // failure that names what was dropped.
    const long = try executeShell(std.testing.io, std.testing.allocator, "printf '%50000s' ''");
    defer long.deinit(std.testing.allocator);
    try std.testing.expect(long.content.len <= max_output_bytes);
    try std.testing.expect(long.is_error and long.truncated);
    try std.testing.expect(std.mem.indexOf(u8, long.content, "Output cut") != null);
}

test "long output is cached and the result names the id it is read back with" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const dir = try @import("ccr.zig").dirPath(a, base);
    defer a.free(dir);

    // Both ends of the output are far past the preview, and stderr has an end
    // of its own that the tail still reaches.
    const result = try executeShellWithEnv(
        io,
        a,
        "printf START; for ((i=0;i<6000;i++)); do printf '你好'; done; printf OUT_END; printf ERR_START >&2; for ((i=0;i<6000;i++)); do printf '世界' >&2; done; printf ERR_END >&2; exit 7",
        null,
        dir,
    );
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    try std.testing.expect(result.truncated);
    try std.testing.expect(result.content.len <= max_output_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.content));
    try std.testing.expect(std.mem.startsWith(u8, result.content, "Exit code: 7\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.content, "ERR_END") != null);

    // The line the model reads names the id, the size and the retrieval tool;
    // the id is the file the whole output was kept in.
    const marker = std.mem.indexOf(u8, result.content, "[ccr ").?;
    const notice = result.content[marker..];
    try std.testing.expect(std.mem.indexOf(u8, notice, "ccr_retrieve") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, " lines, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, " bytes") != null);
    const id_start = marker + "[ccr ".len;
    const id_end = id_start + @import("ccr.zig").id_len;
    const id = result.content[id_start..id_end];

    const arguments = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"offset\":1,\"limit\":2}}", .{id});
    defer a.free(arguments);
    const head = try @import("ccr.zig").retrieve(io, a, dir, arguments);
    defer head.deinit(a);
    try std.testing.expectEqualStrings("1:START你好", head.content[0.."1:START你好".len]);
}
