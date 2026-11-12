//! Running a host program while it is still running.
//!
//! A tool that runs another program — `bash`, the searches — reads what it says
//! as it arrives rather than waiting for it to finish: a command that prints
//! without end must not be able to fill this process's memory, and one that
//! hangs must not be able to hold the session. So the output goes to a sink as
//! it comes off the pipes, the deadline is set once for the whole run, and when
//! it passes the program's whole process group is killed — background children
//! included, which is what a plain `kill` of the program would leave behind.
const std = @import("std");

/// Which of a program's two output streams a chunk came from.
pub const Stream = enum(u1) { stdout, stderr };

/// How one run ended.
pub const Run = struct {
    term: std.process.Child.Term,
    /// The deadline passed and the group was killed; `term` is then what the
    /// wait reported, which is not an exit the program chose.
    timed_out: bool = false,

    /// The exit code, when the program exited rather than being killed.
    pub fn exitCode(self: Run) ?u8 {
        return switch (self.term) {
            .exited => |code| code,
            else => null,
        };
    }
};

pub const Options = struct {
    argv: []const []const u8,
    /// The environment the program runs with; null inherits this process's.
    env: ?*const std.process.Environ.Map = null,
    /// How long the program may run before its group is killed.
    timeout_seconds: u32,
};

/// Bytes asked of the pipes in one read: large enough that an ordinary command
/// costs a handful of reads, small enough that one chunk is cheap to hold.
pub const read_chunk: usize = 64 * 1024;

/// Run `options.argv`, passing each piece of its output to
/// `sink.feed(io, stream, bytes)` as it arrives, and kill its process group when
/// the deadline passes.
///
/// An error from `feed` stops the run and is returned unchanged. It is the
/// sink's judgement — too much output, a failed write — rather than a failure of
/// the program, and only the sink knows what to say about it.
pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options, sink: anytype) !Run {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .environ_map = options.env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // A process group of its own: the deadline has to reach what the
        // program started, or a command that only backgrounds its work would
        // outlive the call that made it.
        .pgid = 0,
    });
    defer _ = killGroup(&child, io);

    var multi_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(allocator, io, multi_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    // One deadline for the whole run, not one per read: a program that keeps
    // talking must not be able to push it back a chunk at a time.
    const deadline = (std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromSeconds(@intCast(options.timeout_seconds)),
        .clock = .awake,
    } }).toDeadline(io);

    while (true) {
        multi.fill(read_chunk, deadline) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => return .{ .term = .{ .unknown = 0 }, .timed_out = true },
            else => |other| return other,
        };
        try drain(io, &multi, sink);
        // A command that never stops printing keeps a pipe ready every time it
        // is polled, so the deadline is not what ends the wait: it has to be
        // looked at here, between one chunk and the next.
        if (expired(deadline, io)) return .{ .term = .{ .unknown = 0 }, .timed_out = true };
    }

    return .{ .term = killGroup(&child, io) orelse .{ .unknown = 1 } };
}

/// Whether the deadline has passed, asked of the clock rather than waited out.
fn expired(deadline: std.Io.Timeout, io: std.Io) bool {
    const remaining = deadline.toDurationFromNow(io) orelse return false;
    return remaining.raw.nanoseconds <= 0;
}

/// Hand every byte the reader is holding to the sink, then let the reader
/// forget about it.
fn drain(io: std.Io, multi: *std.Io.File.MultiReader, sink: anytype) !void {
    const streams = [_]struct { index: usize, stream: Stream }{
        .{ .index = 0, .stream = .stdout },
        .{ .index = 1, .stream = .stderr },
    };
    for (streams) |entry| {
        const reader = multi.reader(entry.index);
        const data = reader.buffered();
        if (data.len == 0) continue;
        try sink.feed(io, entry.stream, data);
        reader.tossBuffered();
    }
}

/// Kill and reap the program and whatever is left of its group.
fn killGroup(child: *std.process.Child, io: std.Io) ?std.process.Child.Term {
    const pid = child.id orelse return null;
    std.posix.kill(-pid, .KILL) catch {};
    return child.wait(io) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Collects what a run says, for the tests below.
const Catcher = struct {
    allocator: std.mem.Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    /// Stop the run once a stream holds more than this.
    limit: usize = std.math.maxInt(usize),

    fn feed(self: *Catcher, io: std.Io, stream: Stream, data: []const u8) !void {
        _ = io;
        const list = switch (stream) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        if (list.items.len + data.len > self.limit) return error.StreamTooLong;
        try list.appendSlice(self.allocator, data);
    }

    fn deinit(self: *Catcher) void {
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
    }
};

test "a program's output arrives with its status and its stderr apart" {
    const a = std.testing.allocator;
    var catcher: Catcher = .{ .allocator = a };
    defer catcher.deinit();

    const run_result = try run(std.testing.io, a, .{
        .argv = &.{ "sh", "-c", "printf out; printf err >&2; exit 3" },
        .timeout_seconds = 10,
    }, &catcher);

    try std.testing.expect(!run_result.timed_out);
    try std.testing.expectEqual(@as(?u8, 3), run_result.exitCode());
    try std.testing.expectEqualStrings("out", catcher.stdout.items);
    try std.testing.expectEqualStrings("err", catcher.stderr.items);
}

test "the deadline kills the run and answers before the program would have" {
    const a = std.testing.allocator;
    var catcher: Catcher = .{ .allocator = a };
    defer catcher.deinit();

    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    // The shell waits on a background child that ignores nothing: killing only
    // the shell would leave that child holding the pipes.
    const run_result = try run(std.testing.io, a, .{
        .argv = &.{ "sh", "-c", "sleep 30 & wait" },
        .timeout_seconds = 1,
    }, &catcher);

    try std.testing.expect(run_result.timed_out);
    try std.testing.expectEqual(@as(?u8, null), run_result.exitCode());
    const elapsed = started.untilNow(std.testing.io).raw.toSeconds();
    try std.testing.expect(elapsed < 10);
}

test "the deadline ends a run whose output never stops arriving" {
    const a = std.testing.allocator;
    var catcher: Catcher = .{ .allocator = a };
    defer catcher.deinit();

    // Every read finds something waiting, so nothing about this run ever waits
    // out a deadline: only the clock can end it.
    const run_result = try run(std.testing.io, a, .{
        .argv = &.{ "sh", "-c", "yes" },
        .timeout_seconds = 1,
    }, &catcher);
    try std.testing.expect(run_result.timed_out);
    try std.testing.expect(catcher.stdout.items.len > 0);
}

test "a sink that has read enough stops the run" {
    const a = std.testing.allocator;
    var catcher: Catcher = .{ .allocator = a, .limit = 1024 };
    defer catcher.deinit();

    // `yes` prints without end: nothing but the sink's own limit ends this.
    try std.testing.expectError(error.StreamTooLong, run(std.testing.io, a, .{
        .argv = &.{"yes"},
        .timeout_seconds = 30,
    }, &catcher));
    try std.testing.expect(catcher.stdout.items.len <= 1024);
}

test "a program that cannot be started reports why" {
    const a = std.testing.allocator;
    var catcher: Catcher = .{ .allocator = a };
    defer catcher.deinit();

    try std.testing.expectError(error.FileNotFound, run(std.testing.io, a, .{
        .argv = &.{"zagent-definitely-not-here"},
        .timeout_seconds = 10,
    }, &catcher));
}
