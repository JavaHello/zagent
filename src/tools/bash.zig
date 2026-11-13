const std = @import("std");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const sanitize = @import("../util/terminal/sanitize.zig");
const normalize = @import("../util/terminal/normalize.zig");
const host_exec = @import("../host/exec.zig");

const ToolResult = result_mod.ToolResult;
const ToolStatus = result_mod.ToolStatus;
const ownedResult = result_mod.ownedResult;
const no_output = result_mod.no_output;

/// How long a shell call may run when it names no limit of its own: long
/// enough for a build or a test run, short enough that a command which hangs is
/// not the session.
pub const default_timeout_seconds: u32 = 180;

/// The most a call may ask for. A shell that runs for an hour is a choice the
/// model makes on purpose, not a default anyone waits out by accident.
pub const max_timeout_seconds: u32 = 3600;

/// What a command's two streams are collected into while it runs.
///
/// The body is the text the command printed: the sanitised and normalised
/// stdout, then stderr under a label of its own, so a line read back later is
/// never two streams run together — and a progress bar redrawn in place is not
/// one line per redraw. It is the whole of what the command said, held in this
/// process until the command ends: a long output is trimmed by the cache every
/// tool's result goes through, not here, so what this collector keeps is what
/// the machine can hold, and a command that never stops printing is ended by
/// the deadline rather than by a limit on what it may say.
const Collector = struct {
    allocator: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    labelled: bool = false,
    /// Sanitising state of each stream: text arrives in pieces, and a sequence
    /// or a character cut in half by a chunk boundary is finished by the next.
    sanitizers: [2]sanitize.Chunked = .{ .{}, .{} },
    /// Normalising state of each stream: the line in progress is held back
    /// until the carriage return that may overwrite it, or its end, arrives.
    normalizers: [2]normalize.Normalizer = .{ .{}, .{} },
    scratch: std.ArrayList(u8) = .empty,
    normalized: std.ArrayList(u8) = .empty,

    pub fn feed(self: *Collector, _: std.Io, stream: host_exec.Stream, raw: []const u8) !void {
        if (stream == .stderr and !self.labelled) {
            self.labelled = true;
            // The body's own shape: stdout, a newline if it did not end with
            // one, then the label stderr is read under. What stdout's normaliser
            // is still holding is stdout's last line, so it goes out first.
            try self.flushNormalizer(.stdout);
            const last = self.lastByte();
            if (self.body.items.len > 0 and last != '\n') try self.append("\n");
            try self.append("stderr:\n");
        }
        self.scratch.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.scratch);
        defer self.scratch = aw.toArrayList();
        try self.sanitizers[@backingInt(stream)].feed(&aw.writer, raw);
        try self.emitNormalized(stream, aw.written());
    }

    /// Normalise one sanitised piece of a stream and append what a terminal
    /// would have ended up showing of it.
    fn emitNormalized(self: *Collector, stream: host_exec.Stream, raw: []const u8) !void {
        if (raw.len == 0) return;
        self.normalized.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.normalized);
        defer self.normalized = aw.toArrayList();
        try self.normalizers[@backingInt(stream)].feed(self.allocator, &aw.writer, raw);
        try self.append(aw.written());
    }

    /// Write out the line a stream's normaliser is still holding: its end is
    /// known because nothing more is coming for that stream.
    fn flushNormalizer(self: *Collector, stream: host_exec.Stream) !void {
        self.normalized.clearRetainingCapacity();
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.normalized);
        defer self.normalized = aw.toArrayList();
        try self.normalizers[@backingInt(stream)].finish(&aw.writer);
        try self.append(aw.written());
    }

    fn append(self: *Collector, data: []const u8) !void {
        if (data.len == 0) return;
        try self.body.appendSlice(self.allocator, data);
    }

    fn lastByte(self: Collector) u8 {
        return if (self.body.items.len == 0) 0 else self.body.items[self.body.items.len - 1];
    }

    /// Finish the body: whatever a sanitizer or a normaliser still holds is
    /// written out.
    pub fn finish(self: *Collector) !void {
        for ([_]host_exec.Stream{ .stdout, .stderr }) |stream| {
            self.scratch.clearRetainingCapacity();
            var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &self.scratch);
            defer self.scratch = aw.toArrayList();
            try self.sanitizers[@backingInt(stream)].finish(&aw.writer);
            try self.emitNormalized(stream, aw.written());
            try self.flushNormalizer(stream);
        }
    }

    /// The body as a result may own it. A command that printed nothing answers
    /// the one spelling every tool uses for it.
    fn take(self: *Collector) ![]u8 {
        if (self.body.items.len == 0) return self.allocator.dupe(u8, no_output);
        return self.body.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *Collector) void {
        self.body.deinit(self.allocator);
        for (&self.normalizers) |*normalizer| normalizer.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.normalized.deinit(self.allocator);
    }
};

pub fn executeShell(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !ToolResult {
    return executeShellTimed(io, allocator, command, null, default_timeout_seconds);
}

pub fn executeShellWithEnv(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: []const u8,
    env: ?*const std.process.Environ.Map,
) !ToolResult {
    return executeShellTimed(io, allocator, command, env, default_timeout_seconds);
}

/// Run one shell command with a deadline and hand back everything it printed.
/// What a result too long to show becomes is the cache's business: this tool
/// knows how to run a command, not where an oversized answer goes.
pub fn executeShellTimed(
    io: std.Io,
    allocator: std.mem.Allocator,
    command: []const u8,
    env: ?*const std.process.Environ.Map,
    timeout_seconds: u32,
) !ToolResult {
    var collector: Collector = .{ .allocator = allocator };
    defer collector.deinit();

    const shell = host_exec.run(io, allocator, .{
        .argv = &.{ "bash", "--noprofile", "--norc", "-c", command },
        .env = env,
        .timeout_seconds = timeout_seconds,
    }, &collector) catch |err| return .{
        .output = try std.fmt.allocPrint(allocator, "Error: the shell could not be run ({s}).", .{@errorName(err)}),
        .is_error = true,
    };

    if (shell.timed_out) {
        // Nothing of what the command said is worth keeping: the call failed
        // for taking too long, and a half-written answer would read as one the
        // command chose to stop at.
        return .{
            .output = try std.fmt.allocPrint(allocator, "Tool timed out after {d}s.", .{timeout_seconds}),
            .is_error = true,
            .timed_out = true,
        };
    }

    try collector.finish();
    const exit_code = shell.exitCode();
    const failed = exit_code == null or exit_code.? != 0;
    // How the command ended belongs to the result's status, not to its text:
    // the model reads it in JSON beside the output and the terminal on
    // the line under the call, so nothing the command printed is displaced and
    // nothing is said twice.
    const ending: ToolStatus = .{
        .is_error = failed,
        .exit_code = exit_code,
        .termination = shell.termination(),
    };
    return ownedResult(try collector.take(), ending);
}

/// The bash tool: one command and one deadline. Its output is the command's
/// own, whole; a long one is cached by the hook every tool's result passes
/// through.
pub const spec: tool.Tool = .{
    .name = "bash",
    .description = "Execute a Bash command once. The whole output is returned; one larger than 8 KiB is cached, and the call answers with a preview of it, the cache id, its line count and its size, and ccr_retrieve reads the rest by id.",
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
    return executeShellTimed(ctx.io, ctx.allocator, command, ctx.env, timeout_seconds);
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

test "a long output is handed over whole, and the tool adds nothing to it" {
    const a = std.testing.allocator;
    for ([_]usize{ 8192, 8193, 1024 * 1024 + 1 }) |size| {
        const command = try std.fmt.allocPrint(a, "printf '%{d}s' ''", .{size});
        defer a.free(command);
        const result = try executeShell(std.testing.io, a, command);
        defer result.deinit(a);
        try std.testing.expect(!result.is_error);
        // Trimming belongs to the cache: this tool hands on what the command
        // printed, and says nothing about what became of it.
        try std.testing.expectEqual(size, result.output.len);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "ccr") == null);
    }
}

test "shell status survives empty output, stderr and signals" {
    // The content is what the command printed and nothing else; how it ended
    // travels in the status beside it.
    const cases = [_]struct {
        command: []const u8,
        output: ?[]const u8,
        exit_code: ?u8,
        termination: ?[]const u8,
        is_error: bool,
    }{
        .{ .command = "exit 0", .output = no_output, .exit_code = 0, .termination = null, .is_error = false },
        .{ .command = "exit 42", .output = no_output, .exit_code = 42, .termination = null, .is_error = true },
        .{ .command = "printf out; printf err >&2; exit 7", .output = "out\nstderr:\nerr", .exit_code = 7, .termination = null, .is_error = true },
        .{ .command = "printf warning >&2", .output = "stderr:\nwarning", .exit_code = 0, .termination = null, .is_error = false },
        .{ .command = "kill -TERM $$", .output = no_output, .exit_code = null, .termination = "SIGTERM", .is_error = true },
        .{ .command = "printf '%50000s' ''; exit 9", .output = null, .exit_code = 9, .termination = null, .is_error = true },
    };
    for (cases) |case| {
        const result = try executeShell(std.testing.io, std.testing.allocator, case.command);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.is_error, result.is_error);
        try std.testing.expectEqual(case.exit_code, result.exit_code);
        try std.testing.expectEqualDeep(case.termination, result.termination);
        if (case.output) |expected| try std.testing.expectEqualStrings(expected, result.output);
        // Nothing the shell reports about itself is left in the text: the
        // model reads the ending from the status, not from a line it would
        // have to parse out of the output.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Exit code:") == null);
    }
    // The output a command printed is not cut, whatever its size.
    const long = try executeShell(std.testing.io, std.testing.allocator, "printf '%50000s' ''");
    defer long.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 50000), long.output.len);
    try std.testing.expect(!long.is_error and long.ccr_id == null);
}

test "output is collected as the screen showed it, not as it was written" {
    const a = std.testing.allocator;
    const cases = [_]struct { command: []const u8, expected: []const u8 }{
        // A progress bar redrawn in place: one line per redraw would be lines
        // of stale percentages read back as if they had all been printed.
        .{ .command = "printf 'one\\rtwo\\rdone\\n'", .expected = "done\n" },
        // A carriage return that ends the line is a line ending like any other.
        .{ .command = "printf 'one\\r\\ntwo\\r\\n'", .expected = "one\ntwo\n" },
        // Blank lines are layout; more than one of them in a row is not.
        .{ .command = "printf 'a\\n\\n\\n\\nb\\n'", .expected = "a\n\nb\n" },
    };
    for (cases) |case| {
        const result = try executeShell(std.testing.io, a, case.command);
        defer result.deinit(a);
        try std.testing.expectEqualStrings(case.expected, result.output);
    }
}

test "both streams reach the result in full, stdout before stderr" {
    const a = std.testing.allocator;
    const result = try executeShell(
        std.testing.io,
        a,
        "printf START; for ((i=0;i<6000;i++)); do printf '你好'; done; printf OUT_END; printf ERR_START >&2; for ((i=0;i<6000;i++)); do printf '世界' >&2; done; printf ERR_END >&2; exit 7",
    );
    defer result.deinit(a);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    try std.testing.expect(result.ccr_id == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.output));
    // Nothing is missing from either end: no status line of the shell's own
    // comes before the output, and neither stream is cut short.
    try std.testing.expect(std.mem.startsWith(u8, result.output, "START"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OUT_END\nstderr:\nERR_START") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.output, "ERR_END"));
}

test "a command that prints without end is ended by its deadline" {
    const a = std.testing.allocator;
    // Printing slowly keeps the test about the deadline rather than about how
    // much this machine can hold: what the collector keeps is not bounded.
    const result = try executeShellTimed(std.testing.io, a, "while :; do sleep 0.05; printf 'y\\n'; done", null, 1);
    defer result.deinit(a);
    try std.testing.expect(result.is_error and result.timed_out);
    try std.testing.expectEqualStrings("Tool timed out after 1s.", result.output);
}
