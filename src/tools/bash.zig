const std = @import("std");
const result_mod = @import("result.zig");

const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;
const normalizeToolText = result_mod.normalizeToolText;
const finalizeNormalizedResultOwnedLimited = result_mod.finalizeNormalizedResultOwnedLimited;
const max_output_bytes = result_mod.default_output_bytes;
const util = @import("util.zig");

// Budget streams independently: stdout must never hide stderr.
fn appendStream(writer: *std.Io.Writer, normalized: []const u8, budget: usize) !bool {
    if (normalized.len <= budget) {
        try writer.writeAll(normalized);
        return false;
    }
    const marker = "\n... [middle omitted; redirect long output to a file and read pages] ...\n";
    const room = budget - marker.len;
    const head = util.truncateUtf8(normalized, room / 2);
    var tail_start = normalized.len - (room - room / 2);
    while (tail_start < normalized.len and (normalized[tail_start] & 0xc0) == 0x80) : (tail_start += 1) {}
    try writer.writeAll(head);
    try writer.writeAll(marker);
    try writer.writeAll(normalized[tail_start..]);
    return true;
}

pub fn executeShell(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !ToolResult {
    return executeShellWithEnv(io, allocator, command, null);
}

pub fn executeShellWithEnv(io: std.Io, allocator: std.mem.Allocator, command: []const u8, env: ?*const std.process.Environ.Map) !ToolResult {
    // Capture once, with room for both ends of each stream. Never rerun the
    // command or create files automatically. Larger streams are refused by std.
    const read_window = 1024 * 1024;
    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "bash", "--noprofile", "--norc", "-c", command },
        .environ_map = env,
        .stdout_limit = .limited(read_window),
        .stderr_limit = .limited(read_window),
    }) catch |err| switch (err) {
        // std refuses the whole result once a limit is passed, so there is
        // nothing of it to keep; the model is told how to read it in parts
        // rather than being left with a bare error name.
        error.StreamTooLong => return toolError(
            allocator,
            "Error: the command wrote more than a megabyte of output. Redirect it to a file, or pipe it through head or tail, to read it in parts.",
            .{},
        ),
        else => |other| return other,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: ?u8 = switch (result.term) {
        .exited => |code| code,
        else => null,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Content is sent to the model and persisted in session history. Keep
    // status first so truncating long command output cannot hide it.
    if (exit_code) |code| {
        try aw.writer.print("Exit code: {d}\n", .{code});
    } else {
        try aw.writer.print("Exit code: unavailable (termination: {any})\n", .{result.term});
    }

    const stream_room = max_output_bytes - 256; // status and stream label
    const both = result.stderr.len > 0 and result.stdout.len > 0;
    const stream_budget = if (both) stream_room / 2 else stream_room;
    var truncated = false;
    if (result.stdout.len > 0) {
        const normalized = try normalizeToolText(allocator, result.stdout);
        defer allocator.free(normalized);
        truncated = try appendStream(&aw.writer, normalized, stream_budget);
    }
    if (result.stderr.len > 0) {
        if (aw.written().len > 0) try aw.writer.writeAll("\n");
        try aw.writer.writeAll("stderr: ");
        const normalized = try normalizeToolText(allocator, result.stderr);
        defer allocator.free(normalized);
        truncated = (try appendStream(&aw.writer, normalized, stream_budget)) or truncated;
    }
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try aw.writer.writeAll("(no output)");
    }

    // Sanitize each stream independently: an unfinished escape in stdout must
    // never consume the stderr label or stderr bytes. The joined text is safe.
    return finalizeNormalizedResultOwnedLimited(allocator, try aw.toOwnedSlice(), .{
        .is_error = exit_code == null or exit_code.? != 0 or truncated,
        .exit_code = exit_code,
        .truncated = truncated,
    }, max_output_bytes);
}

test "shell status survives empty output, stderr, signals and truncation" {
    const cases = [_]struct { command: []const u8, prefix: []const u8, is_error: bool }{
        .{ .command = "exit 0", .prefix = "Exit code: 0\n(no output)", .is_error = false },
        .{ .command = "exit 42", .prefix = "Exit code: 42\n(no output)", .is_error = true },
        .{ .command = "printf out; printf err >&2; exit 7", .prefix = "Exit code: 7\nout\nstderr: err", .is_error = true },
        .{ .command = "printf warning >&2", .prefix = "Exit code: 0\n", .is_error = false },
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
    // Output past the limit is cut there rather than kept whole, and the cut
    // keeps the status line first.
    const long = try executeShell(std.testing.io, std.testing.allocator, "printf '%50000s' ''");
    defer long.deinit(std.testing.allocator);
    try std.testing.expect(long.content.len <= max_output_bytes);
    try std.testing.expect(long.truncated);
    try std.testing.expect(std.mem.indexOf(u8, long.content, "middle omitted") != null);
}

test "shell head tail keeps both streams and utf8 with status" {
    const a = std.testing.allocator;
    const r = try executeShell(std.testing.io, a, "printf START; for ((i=0;i<6000;i++)); do printf '你好'; done; printf OUT_END; printf ERR_START >&2; for ((i=0;i<6000;i++)); do printf '世界' >&2; done; printf ERR_END >&2; exit 7");
    defer r.deinit(a);
    try std.testing.expect(r.truncated and r.is_error);
    try std.testing.expectEqual(@as(?u8, 7), r.exit_code);
    try std.testing.expect(r.content.len <= max_output_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.content));
    try std.testing.expect(std.mem.startsWith(u8, r.content, "Exit code: 7\nSTART"));
    for ([_][]const u8{ "OUT_END", "stderr: ERR_START", "ERR_END", "middle omitted" }) |part| {
        try std.testing.expect(std.mem.indexOf(u8, r.content, part) != null);
    }
    try std.testing.expect(std.mem.endsWith(u8, r.content, "ERR_END"));
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
