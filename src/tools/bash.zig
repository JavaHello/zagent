const std = @import("std");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const ccr = @import("ccr.zig");
const sanitize = @import("../util/terminal/sanitize.zig");
const normalize = @import("../util/terminal/normalize.zig");
const host_exec = @import("../host/exec.zig");

const ToolResult = result_mod.ToolResult;
const ownedResult = result_mod.ownedResult;

/// How many lines of a long output the preview keeps. Enough for the end of a
/// build to be read at a glance, few enough that the result stays a summary:
/// the rest is a `ccr_retrieve` call away.
const preview_lines = 40;

/// Bytes a preview may take before whole lines are dropped from its beginning.
const preview_bytes = 4 * 1024;

/// Cache command output strictly larger than 8 KiB.
pub const cache_threshold_bytes = 8 * 1024;

/// Where the last `lines` lines of `text` start, walking back no further than
/// `budget` bytes and never cutting a line in half: whole lines are dropped
/// from the beginning instead. A single line longer than the budget is the one
/// exception, and it is cut on a UTF-8 boundary.
fn tailStart(raw: []const u8, lines: usize, budget: usize) usize {
    var start: usize = 0;
    var remaining = lines;
    var index = raw.len;
    while (index > 0 and remaining > 0) {
        index -= 1;
        if (raw[index] == '\n' and index + 1 < raw.len) {
            remaining -= 1;
            start = index + 1;
        }
    }
    if (remaining > 0) start = 0;
    while (start < raw.len and raw.len - start > budget) {
        const next = std.mem.indexOfScalarPos(u8, raw, start, '\n') orelse break;
        if (next + 1 == raw.len) break;
        start = next + 1;
    }
    if (raw.len - start <= budget) return start;
    var cut = raw.len - budget;
    while (cut < raw.len and (raw[cut] & 0xc0) == 0x80) cut += 1;
    return cut;
}

/// How long a shell call may run when it names no limit of its own: long
/// enough for a build or a test run, short enough that a command which hangs is
/// not the session.
pub const default_timeout_seconds: u32 = 180;

/// The most a call may ask for. A shell that runs for an hour is a choice the
/// model makes on purpose, not a default anyone waits out by accident.
pub const max_timeout_seconds: u32 = 3600;

/// Most bytes of one command's output kept in the cache. A command that prints
/// without end — `yes`, a runaway loop — is bounded by the deadline and by this:
/// past it the output is still read and counted, but no more of it is written,
/// so the cache cannot fill the disk before the deadline passes.
pub const cache_max_bytes: usize = 64 * 1024 * 1024;

/// The last `preview_bytes` of the body, kept as it is written so that the
/// preview of a long output costs a fixed amount of memory rather than a copy
/// of the whole of it.
const Tail = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn push(self: *Tail, allocator: std.mem.Allocator, data: []const u8) !void {
        if (data.len >= preview_bytes) {
            self.bytes.clearRetainingCapacity();
            try self.bytes.appendSlice(allocator, data[data.len - preview_bytes ..]);
            return;
        }
        try self.bytes.appendSlice(allocator, data);
        const excess = self.bytes.items.len -| preview_bytes;
        if (excess == 0) return;
        const kept = self.bytes.items.len - excess;
        std.mem.copyForwards(u8, self.bytes.items[0..kept], self.bytes.items[excess..]);
        self.bytes.shrinkRetainingCapacity(kept);
    }

    fn slice(self: Tail) []const u8 {
        return self.bytes.items;
    }

    fn deinit(self: *Tail, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }
};

/// What a command's two streams are collected into while it runs.
///
/// The body is the text one result would show if it had no size limit: the
/// sanitised and normalised stdout, then stderr under a label of its own, so a
/// line read back later is never two streams run together — and a progress bar
/// redrawn in place is not one line per redraw. It is built as the output
/// arrives rather than after the command ends — up to `cache_threshold_bytes` it
/// is held as text, and past that the whole of it is streamed into the cache
/// file, so a command that prints without end costs this process a fixed amount
/// of memory instead of all of it.
const Collector = struct {
    allocator: std.mem.Allocator,
    cache_dir: ?[]const u8,
    /// The body, while it still fits in one result.
    head: std.ArrayList(u8) = .empty,
    /// The end of the body, for the preview that stands in for a long one.
    tail: Tail = .{},
    /// The cache entry, once the body has outgrown one result.
    stream: ?ccr.Stream = null,
    /// An entry that could not be written. The command still ran; only the copy
    /// of its output was lost, so this is reported rather than raised.
    cache_error: ?anyerror = null,
    /// Output past `max_bytes`, which is read and counted but not cached.
    capped: bool = false,
    /// How much of the output may be written. A test asks for less than a
    /// command would print; a real run takes the whole allowance.
    max_bytes: usize = cache_max_bytes,
    /// Whether the body has outgrown one result, whatever became of its cache.
    overflowed: bool = false,
    /// Bytes and lines of the whole body, cached or not.
    bytes: usize = 0,
    newlines: usize = 0,
    last_byte: u8 = 0,
    labelled: bool = false,
    /// Sanitising state of each stream: text arrives in pieces, and a sequence
    /// or a character cut in half by a chunk boundary is finished by the next.
    sanitizers: [2]sanitize.Chunked = .{ .{}, .{} },
    /// Normalising state of each stream: the line in progress is held back
    /// until the carriage return that may overwrite it, or its end, arrives.
    normalizers: [2]normalize.Normalizer = .{ .{}, .{} },
    scratch: std.ArrayList(u8) = .empty,
    normalized: std.ArrayList(u8) = .empty,

    pub fn feed(self: *Collector, io: std.Io, stream: host_exec.Stream, raw: []const u8) !void {
        if (stream == .stderr and !self.labelled) {
            self.labelled = true;
            // The body's own shape: stdout, a newline if it did not end with
            // one, then the label stderr is read under. What stdout's normaliser
            // is still holding is stdout's last line, so it goes out first.
            try self.flushNormalizer(io, .stdout);
            if (self.bytes > 0 and self.last_byte != '\n') try self.append(io, "\n");
            try self.append(io, "stderr:\n");
        }
        self.scratch.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.scratch);
        defer self.scratch = aw.toArrayList();
        try self.sanitizers[@backingInt(stream)].feed(&aw.writer, raw);
        try self.emitNormalized(io, stream, aw.written());
    }

    /// Normalise one sanitised piece of a stream and append what a terminal
    /// would have ended up showing of it.
    fn emitNormalized(self: *Collector, io: std.Io, stream: host_exec.Stream, raw: []const u8) !void {
        if (raw.len == 0) return;
        self.normalized.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.normalized);
        defer self.normalized = aw.toArrayList();
        try self.normalizers[@backingInt(stream)].feed(self.allocator, &aw.writer, raw);
        try self.append(io, aw.written());
    }

    /// Write out the line a stream's normaliser is still holding: its end is
    /// known because nothing more is coming for that stream.
    fn flushNormalizer(self: *Collector, io: std.Io, stream: host_exec.Stream) !void {
        self.normalized.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.normalized);
        defer self.normalized = aw.toArrayList();
        try self.normalizers[@backingInt(stream)].finish(&aw.writer);
        try self.append(io, aw.written());
    }

    /// Take one piece of the body: count it, keep its end for the preview, and
    /// put it where the body is being kept.
    fn append(self: *Collector, io: std.Io, data: []const u8) !void {
        if (data.len == 0) return;
        for (data) |byte| {
            if (byte == '\n') self.newlines += 1;
        }
        self.bytes += data.len;
        self.last_byte = data[data.len - 1];
        try self.tail.push(self.allocator, data);

        if (self.stream) |*stream| {
            self.cache(io, stream, data) catch |err| {
                self.cache_error = err;
                stream.abandon(io, self.allocator);
                self.stream = null;
            };
            return;
        }

        if (!self.overflowed and self.head.items.len + data.len <= cache_threshold_bytes) {
            try self.head.appendSlice(self.allocator, data);
            return;
        }
        self.overflowed = true;
        // Every byte before this point is in the head, and the body is about to
        // grow past what one result holds: from here it belongs in the cache.
        var head = self.head;
        self.head = .empty;
        defer head.deinit(self.allocator);

        const dir = self.cache_dir orelse return;
        var stream = ccr.createStream(io, self.allocator, dir) catch |err| {
            self.cache_error = err;
            return;
        };
        for ([_][]const u8{ head.items, data }) |piece| {
            self.cache(io, &stream, piece) catch |err| {
                self.cache_error = err;
                stream.abandon(io, self.allocator);
                return;
            };
        }
        self.stream = stream;
    }

    /// Put one piece into the cache entry, stopping at the cap: past it the
    /// output is still counted, but writing it would only fill the disk before
    /// the deadline ends the command.
    fn cache(self: *Collector, io: std.Io, stream: *ccr.Stream, data: []const u8) !void {
        if (self.capped) return;
        const room = self.max_bytes -| stream.bytes;
        try stream.write(io, data[0..@min(data.len, room)]);
        if (data.len > room) self.capped = true;
    }

    /// Finish the body: whatever a sanitizer or a normaliser still holds is
    /// written out, and the cache entry is closed. Answers what the whole output
    /// held, for the notice a long one names it in.
    pub fn finish(self: *Collector, io: std.Io) !?ccr.Saved {
        for ([_]host_exec.Stream{ .stdout, .stderr }) |stream| {
            self.scratch.clearRetainingCapacity();
            var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.scratch);
            defer self.scratch = aw.toArrayList();
            try self.sanitizers[@backingInt(stream)].finish(&aw.writer);
            try self.emitNormalized(io, stream, aw.written());
            try self.flushNormalizer(io, stream);
        }
        if (self.stream) |*stream| return stream.finish(io);
        return null;
    }

    /// Give up on the body: the run was cut short, so there is no result to
    /// name a cache entry in.
    pub fn abandon(self: *Collector, io: std.Io) void {
        if (self.stream) |*stream| stream.abandon(io, self.allocator);
        self.stream = null;
    }

    pub fn deinit(self: *Collector, io: std.Io) void {
        if (self.stream) |*stream| stream.deinit(io, self.allocator);
        self.head.deinit(self.allocator);
        self.tail.deinit(self.allocator);
        for (&self.normalizers) |*normalizer| normalizer.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.normalized.deinit(self.allocator);
    }
};

pub fn executeShell(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !ToolResult {
    return executeShellTimed(io, allocator, command, null, null, default_timeout_seconds);
}

pub fn executeShellWithEnv(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: []const u8,
    env: ?*const std.process.Environ.Map,
    cache_dir: ?[]const u8,
) !ToolResult {
    return executeShellTimed(io, allocator, command, env, cache_dir, default_timeout_seconds);
}

/// Run one shell command with a deadline, keeping its output to what one result
/// can show and streaming the rest into the cache.
pub fn executeShellTimed(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: []const u8,
    env: ?*const std.process.Environ.Map,
    cache_dir: ?[]const u8,
    timeout_seconds: u32,
) !ToolResult {
    var collector: Collector = .{ .allocator = allocator, .cache_dir = cache_dir };
    defer collector.deinit(io);

    const shell = host_exec.run(io, allocator, .{
        .argv = &.{ "bash", "--noprofile", "--norc", "-c", command },
        .env = env,
        .timeout_seconds = timeout_seconds,
    }, &collector) catch |err| return .{
        .content = try std.fmt.allocPrint(allocator, "Error: the shell could not be run ({s}).", .{@errorName(err)}),
        .is_error = true,
    };

    if (shell.timed_out) {
        // Nothing of what the command said is worth keeping: the call failed
        // for taking too long, and a half-written entry would outlive the
        // answer that would have named it.
        collector.abandon(io);
        return .{
            .content = try std.fmt.allocPrint(allocator, "Tool timed out after {d}s.", .{timeout_seconds}),
            .is_error = true,
            .timed_out = true,
        };
    }

    const saved = try collector.finish(io);
    const exit_code = shell.exitCode();
    const failed = exit_code == null or exit_code.? != 0;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    // Content is sent to the model and persisted in session history. Keep
    // status first so a preview of long command output cannot hide it.
    if (exit_code) |code| {
        try aw.writer.print("Exit code: {d}\n", .{code});
    } else {
        try aw.writer.print("Exit code: unavailable (termination: {any})\n", .{shell.term});
    }

    if (!collector.overflowed) {
        if (collector.bytes == 0) {
            try aw.writer.writeAll("(no output)");
        } else {
            try aw.writer.writeAll(collector.head.items);
        }
        return ownedResult(try aw.toOwnedSlice(), .{
            .is_error = failed,
            .exit_code = exit_code,
        });
    }

    // Too long for one result. The tail is what the model needs first — the end
    // of a build, the last error of a test run — and the whole of it is kept
    // where `ccr_retrieve` reads it back, rather than lost.
    const tail = collector.tail.slice();
    const preview = tail[tailStart(tail, preview_lines, preview_bytes)..];
    try aw.writer.writeAll(preview);
    if (preview.len == 0 or preview[preview.len - 1] != '\n') try aw.writer.writeByte('\n');

    if (saved) |entry| {
        try aw.writer.print(
            "[ccr {s}: {d} lines, {d} bytes, the last lines shown here. Call ccr_retrieve with id \"{s}\" to page through it with offset and limit, or query=\"text\" to find lines.]",
            .{ entry.id, entry.lines, entry.bytes, entry.id },
        );
        if (collector.capped) try aw.writer.print(
            "[This command printed more than {d} MiB; the rest is not cached and was not kept.]",
            .{cache_max_bytes / (1024 * 1024)},
        );
        var result = ownedResult(try aw.toOwnedSlice(), .{
            .is_error = failed,
            .exit_code = exit_code,
        });
        // The preview names the entry, and the entry is what the model reads
        // back: `ccr` leaves a result that already names one alone.
        result.ccr_id = entry.id;
        return result;
    }

    if (collector.cache_error) |err| {
        // The command ran; only the copy of its output was lost. Saying so
        // keeps the failure where it belongs instead of failing the call.
        try aw.writer.print(
            "[Output cut here: {d} lines, {d} bytes of output, and this run could not cache the rest ({s}). Redirect long output to a file and read it in pages.]",
            .{ countedLines(collector.bytes, collector.newlines, collector.last_byte), collector.bytes, @errorName(err) },
        );
        return ownedResult(try aw.toOwnedSlice(), .{
            .is_error = failed,
            .exit_code = exit_code,
        });
    }

    // No cache was offered: the rest of this output is not reachable, so the
    // call reports what it could not show rather than reading as complete.
    try aw.writer.print(
        "[Output cut: {d} lines, {d} bytes, only the last lines shown. Redirect long output to a file and read it in pages.]",
        .{ countedLines(collector.bytes, collector.newlines, collector.last_byte), collector.bytes },
    );
    return ownedResult(try aw.toOwnedSlice(), .{
        .is_error = true,
        .exit_code = exit_code,
    });
}

/// The bash tool: one command, one deadline, and the cache a long output is
/// kept in.
pub const spec: tool.Tool = .{
    .name = "bash",
    .description = "Execute a Bash command once. Output larger than 8 KiB is cached: the call returns its last lines, the cache id, its line count and its size, and ccr_retrieve reads the rest by id.",
    .parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"},"timeout_seconds":{"type":"integer","minimum":1,"maximum":3600,"description":"Command time limit in seconds, default 180. Increase for long builds or tests."}},"required":["command"]}
    ,
    .label = "bash…",
    .run = run,
};

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    const command = args_mod.requiredString(ctx.allocator, arguments, "command") catch
        return ctx.refuse("Error: missing 'command' argument");
    defer ctx.allocator.free(command);
    const timeout_seconds = parseTimeout(ctx.allocator, arguments) catch
        return ctx.refuse("Invalid timeout_seconds: use an integer from 1 to 3600.");
    return executeShellTimed(ctx.io, ctx.allocator, command, ctx.env, ctx.cache_dir, timeout_seconds);
}

/// The deadline a call asked for, in seconds. Arguments that do not parse, or a
/// number outside 1..3600, are refused rather than defaulted: a command that
/// runs longer than the caller meant is worse than a failed call.
fn parseTimeout(allocator: std.mem.Allocator, arguments: []const u8) !u32 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const value = parsed.value.object.get("timeout_seconds") orelse return default_timeout_seconds;
    if (value != .integer or value.integer < 1 or value.integer > max_timeout_seconds) return error.InvalidTimeout;
    return @intCast(value.integer);
}

/// The line count of a body counted as it was written: a trailing terminator
/// ends the last line rather than starting an empty one.
fn countedLines(bytes: usize, newlines: usize, last_byte: u8) usize {
    return newlines + @intFromBool(bytes > 0 and last_byte != '\n');
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
        try std.testing.expectEqual(size > cache_threshold_bytes, result.ccr_id != null);
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
        try std.testing.expect(result.content.len <= ccr.max_output_bytes);
    }
    // Without a cache the rest is out of reach, so the cut is reported as a
    // failure that names what was dropped.
    const long = try executeShell(std.testing.io, std.testing.allocator, "printf '%50000s' ''");
    defer long.deinit(std.testing.allocator);
    try std.testing.expect(long.content.len <= ccr.max_output_bytes);
    try std.testing.expect(long.is_error and long.ccr_id == null);
    try std.testing.expect(std.mem.indexOf(u8, long.content, "Output cut") != null);
}

test "output is collected as the screen showed it, not as it was written" {
    const a = std.testing.allocator;
    const cases = [_]struct { command: []const u8, expected: []const u8 }{
        // A progress bar redrawn in place: one line per redraw would be lines
        // of stale percentages read back as if they had all been printed.
        .{ .command = "printf 'one\\rtwo\\rdone\\n'", .expected = "Exit code: 0\ndone\n" },
        // A carriage return that ends the line is a line ending like any other.
        .{ .command = "printf 'one\\r\\ntwo\\r\\n'", .expected = "Exit code: 0\none\ntwo\n" },
        // Blank lines are layout; more than one of them in a row is not.
        .{ .command = "printf 'a\\n\\n\\n\\nb\\n'", .expected = "Exit code: 0\na\n\nb\n" },
    };
    for (cases) |case| {
        const result = try executeShell(std.testing.io, a, case.command);
        defer result.deinit(a);
        try std.testing.expectEqualStrings(case.expected, result.content);
    }
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
    try std.testing.expect(result.ccr_id != null);
    try std.testing.expect(result.content.len <= ccr.max_output_bytes);
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

test "a command that prints without end is cut by its deadline and leaves no entry" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const dir = try @import("ccr.zig").dirPath(a, base);
    defer a.free(dir);

    // `yes` never stops on its own: only the deadline does, and the cache entry
    // it was streaming into must not outlive the call that would name it.
    const result = try executeShellTimed(io, a, "yes", null, dir, 1);
    defer result.deinit(a);
    try std.testing.expect(result.is_error and result.timed_out);
    try std.testing.expectEqualStrings("Tool timed out after 1s.", result.content);
    // The directory the entry was reserved in stays; nothing in it does.
    var entries = try tmp.dir.openDir(io, "ccr", .{ .iterate = true });
    defer entries.close(io);
    var iterator = entries.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

test "output past the cache cap is counted but not written" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const dir = try @import("ccr.zig").dirPath(a, base);
    defer a.free(dir);

    var collector: Collector = .{ .allocator = a, .cache_dir = dir, .max_bytes = 64 };
    defer collector.deinit(io);
    const big = try a.alloc(u8, 9000);
    defer a.free(big);
    @memset(big, 'x');
    try collector.feed(io, .stdout, big);
    try collector.feed(io, .stdout, big[0..1000]);
    const saved = (try collector.finish(io)).?;

    try std.testing.expect(collector.capped);
    try std.testing.expectEqual(@as(usize, 10000), collector.bytes);
    try std.testing.expectEqual(@as(usize, 64), saved.bytes);
}
