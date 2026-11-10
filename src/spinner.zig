//! A one-line animation for a wait with nothing to show.
//!
//! The request that answers a question can take seconds, and a tool can take
//! minutes. With nothing moving, the terminal looks frozen, and the user cannot
//! tell work in progress from a hang. This owns a status line and optionally
//! an input prompt for the length of that wait and gives them back erased.
//!
//! The animation runs on its own task because the waiting thread is inside a
//! blocking request. `io.concurrent` is the primitive, not `io.async`: with the
//! threaded Io, `async` may run the function inline once the thread pool is
//! busy, and a loop that only ends when it is cancelled would then never
//! return. `concurrent` reports that it cannot run instead, which costs the
//! animation and nothing else.
//!
//! While a Spinner runs, nothing else may write to `file`: the next frame
//! erases the whole line, including whatever another writer put there. And
//! every Spinner must be stopped — the Io runtime joins its tasks before the
//! process exits, so one left running would hold the exit.

const std = @import("std");
const sgr = @import("style.zig");
const term = @import("term.zig");
const Screen = @import("screen.zig").Screen;

/// The frames of the animation, one cell each.
const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Back to the start of the line, then all of it cleared. Erasing the whole
/// line rather than as much as was written means a frame that is wider than it
/// measures — a braille cell on a CJK terminal, say — still cannot leave
/// residue behind.
const erase = "\r\x1b[2K";

/// Columns the two spaces and the frame take before the label.
const indent_width = 4;

pub const Options = struct {
    /// In interactive mode publish frames for the foreground instead of writing.
    screen: ?*Screen = null,
    /// Share the query's clock across model requests and tool calls.
    started: ?std.Io.Timestamp = null,
    /// Keep an empty input prompt below the status while work is running.
    prompt: ?[]const u8 = null,
    /// Live token counters, read by the animation every frame and shown next
    /// to the elapsed time. Pointers into the client's atomics, which outlive
    /// the animation task.
    in_tokens: ?*std.atomic.Value(u64) = null,
    out_tokens: ?*std.atomic.Value(u64) = null,
    /// Whether the caller's terminal can carry an animated line. The caller
    /// decides, because only it knows whether something else — a pager, a
    /// redirected stdout — is using the terminal too.
    enabled: bool,
    /// How long to wait before drawing the first frame, so that a request
    /// answered at once never flashes a line.
    first_frame_delay_ms: i64 = 200,
    /// Gap between frames: fast enough to read as motion, slow enough to be
    /// free.
    frame_interval_ms: i64 = 80,
    /// How long the animation may run before it stops itself. The Io runtime
    /// joins its tasks at exit, so a Spinner that was never stopped would keep
    /// the process from exiting at all; stopping after half an hour is a far
    /// better failure than hanging, and longer than any request this program
    /// should serve.
    max_duration_ms: i64 = 30 * std.time.ms_per_min,
};

pub const Spinner = struct {
    io: std.Io,
    /// Null when nothing was started: not enabled, or no task to be had.
    future: ?std.Io.Future(void),

    /// A spinner that draws nothing, for a caller that decided against one.
    pub fn disabled(io: std.Io) Spinner {
        return .{ .io = io, .future = null };
    }

    /// Animate `label` on `file` until `stop`. The label is borrowed and must
    /// outlive the animation — a string literal, normally.
    pub fn start(io: std.Io, file: std.Io.File, label: []const u8, options: Options) Spinner {
        if (!options.enabled) return disabled(io);

        // The task is handed everything by value: `io.concurrent` copies its
        // arguments into storage the task owns, so nothing here has to outlive
        // this call but the label.
        const started = std.Io.Timestamp.now(io, .awake);
        const future = io.concurrent(animate, .{ io, file, label, options, started }) catch
            return disabled(io);
        return .{ .io = io, .future = future };
    }

    /// Whether a task was started: false when the caller asked for no
    /// animation, and false when none could be spared, which is the same thing
    /// to a caller deciding what else to print.
    pub fn animating(self: Spinner) bool {
        return self.future != null;
    }

    /// Erase the line and wait for the animation to be gone. Idempotent, so a
    /// caller that stops early — to print something before it returns — can
    /// keep its `defer` in place. Nothing the caller prints after this lands
    /// on the animation's line: when this returns, the task has finished and
    /// the line is clear.
    pub fn stop(self: *Spinner) void {
        if (self.future) |*future| {
            _ = future.cancel(self.io);
            self.future = null;
        }
    }
};

fn animate(
    io: std.Io,
    file: std.Io.File,
    label: []const u8,
    options: Options,
    started: std.Io.Timestamp,
) void {
    var drawn = false;
    // Runs on cancelation too: this is what gives the line back.
    defer if (options.screen) |screen|
        screen.setProgress("")
    else if (drawn) file.writeStreamingAll(io, if (options.prompt != null)
        "\x1b[1A" ++ erase ++ "\r\n" ++ erase ++ "\x1b[1A\r"
    else
        erase) catch {};

    io.sleep(.fromMilliseconds(options.first_frame_delay_ms), .awake) catch return;

    var index: usize = 0;
    while (true) : (index += 1) {
        const elapsed_ms = (options.started orelse started).untilNow(io, .awake).toMilliseconds();
        if (started.untilNow(io, .awake).toMilliseconds() >= options.max_duration_ms) return;

        // Measured every frame, not once: a terminal can be resized while the
        // user waits, and a frame too wide for it wraps, half of it surviving
        // the erase that follows.
        const budget = term.usableWidth(term.columns(file));

        var buf: [256]u8 = undefined;
        const line = formatLine(
            &buf,
            frames[index % frames.len],
            label,
            @divTrunc(elapsed_ms, std.time.ms_per_s),
            budget,
            if (options.in_tokens) |p| p.load(.monotonic) else null,
            if (options.out_tokens) |p| p.load(.monotonic) else null,
        ) catch return;
        // Either of these can observe the cancelation; both end the loop.
        if (options.screen) |screen| {
            // Screen owns positioning and erasure. A leading carriage return
            // would make its single-line clipping stop before the label.
            screen.setProgress(line[erase.len..]);
            io.sleep(.fromMilliseconds(options.frame_interval_ms), .awake) catch return;
            continue;
        }
        var display_buf: [512]u8 = undefined;
        const display = if (options.prompt) |prompt|
            std.fmt.bufPrint(&display_buf, "{s}{s}\r\n" ++ erase ++ "{s}", .{ if (index > 0) "\x1b[1A" else "", line, prompt }) catch return
        else
            line;
        file.writeStreamingAll(io, display) catch return;
        drawn = true;
        io.sleep(.fromMilliseconds(options.frame_interval_ms), .awake) catch return;
    }
}

/// The bytes of one frame: the line cleared, the frame, the label, how long
/// the query has been running, and the live token totals when counters are
/// provided.
///
/// The label is shortened to fit `budget`, so the line never wraps. A wrapped
/// line would be half erased by the next frame, leaving the rest of it on
/// screen for good.
fn formatLine(
    buf: []u8,
    frame: []const u8,
    label: []const u8,
    seconds: i64,
    budget: usize,
    in_tokens: ?u64,
    out_tokens: ?u64,
) ![]const u8 {
    var tail_buf: [96]u8 = undefined;
    const tail = if (in_tokens != null or out_tokens != null)
        try std.fmt.bufPrint(&tail_buf, " {d}s · in {d} · out {d}", .{
            seconds,
            in_tokens orelse 0,
            out_tokens orelse 0,
        })
    else
        try std.fmt.bufPrint(&tail_buf, " {d}s", .{seconds});

    const taken = indent_width + term.width(tail);
    const room = if (budget > taken) budget - taken else 1;
    const shown = label[0..term.takeFit(label, room)];

    return std.fmt.bufPrint(buf, erase ++ sgr.DIM ++ "  {s} {s}{s}" ++ sgr.RESET, .{ frame, shown, tail });
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "a frame clears its line and names what is being waited for" {
    var buf: [256]u8 = undefined;
    try expectEqualStrings(
        "\r\x1b[2K\x1b[2m  ⠋ thinking… 0s\x1b[0m",
        try formatLine(&buf, "⠋", "thinking…", 0, 80, null, null),
    );
    try expectEqualStrings(
        "\r\x1b[2K\x1b[2m  ⠙ checking completion… 1s\x1b[0m",
        try formatLine(&buf, "⠙", "checking completion…", 1, 80, null, null),
    );
}

test "a frame is shortened to fit rather than allowed to wrap" {
    var buf: [256]u8 = undefined;
    const line = try formatLine(&buf, "⠋", "checking completion…", 3600, 24, null, null);

    // Everything after the erasure is what lands on the line. (`\r` counts as
    // a cell here: term.width measures bytes, so that nothing can hide width.)
    try expect(term.width(line[erase.len..]) <= 24);
    try expect(std.mem.indexOf(u8, line, "checking completion…") == null);
    // The elapsed time is what a long wait is read for, so it survives the cut.
    try expect(std.mem.indexOf(u8, line, " 3600s") != null);
}

test "a caller that decided against animating writes nothing" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "probe", .{});
    defer file.close(io);

    var spin = Spinner.start(io, file, "thinking…", .{ .enabled = false });
    try expect(!spin.animating());
    spin.stop();

    const written = try tmp.dir.readFileAlloc(io, "probe", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(written);
    try expectEqualStrings("", written);
}

test "the animation draws frames and gives the line back" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "probe", .{});
    defer file.close(io);

    var spin = Spinner.start(io, file, "thinking…", .{
        .enabled = true,
        .first_frame_delay_ms = 0,
        .frame_interval_ms = 1,
    });
    try expect(spin.animating());

    try io.sleep(.fromMilliseconds(60), .awake);
    spin.stop();
    // A caller that stops early to print something still has its `defer`, so
    // stopping twice has to be free.
    spin.stop();

    const written = try tmp.dir.readFileAlloc(io, "probe", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(written);

    try expect(std.mem.startsWith(u8, written, "\r\x1b[2K\x1b[2m  ⠋ thinking…"));
    // The next frame lands on the one before it...
    try expect(std.mem.indexOf(u8, written, "⠙") != null);
    // ...and the last thing written is the erasure that gives the line back.
    try expect(std.mem.endsWith(u8, written, "\r\x1b[2K"));
}

test "screen progress publishes text without inline cursor controls" {
    const io = std.testing.io;
    var screen = Screen.init(std.testing.allocator, io, false);
    defer screen.deinit();
    var spin = Spinner.start(io, std.Io.File.stderr(), "thinking…", .{
        .enabled = true,
        .screen = &screen,
        .first_frame_delay_ms = 0,
        .frame_interval_ms = 1,
    });
    defer spin.stop();
    // Drain while waiting so the test observes the same publication path as
    // the foreground, without racing the animation's next write.
    var attempts: usize = 0;
    while (screen.progress_len == 0 and attempts < 100) : (attempts += 1) {
        try io.sleep(.fromMilliseconds(5), .awake);
        _ = try screen.drain();
    }
    const progress = screen.progress[0..screen.progress_len];
    try expect(std.mem.indexOf(u8, progress, "thinking…") != null);
    try expect(std.mem.indexOfScalar(u8, progress, '\r') == null);
    try expect(std.mem.indexOf(u8, progress, "\x1b[2K") == null);
}

test "work status stays above the input prompt and clears both rows on stop" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "probe", .{});
    defer file.close(io);

    var spin = Spinner.start(io, file, "thinking…", .{
        .enabled = true,
        .prompt = "❯ ",
        .first_frame_delay_ms = 0,
        .frame_interval_ms = 1,
    });
    defer spin.stop();
    try io.sleep(.fromMilliseconds(60), .awake);
    spin.stop();

    const written = try tmp.dir.readFileAlloc(io, "probe", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(written);
    try expect(std.mem.indexOf(u8, written, "thinking… 0s") != null);
    try expect(std.mem.indexOf(u8, written, "\r\n" ++ erase ++ "❯ ") != null);
    try expect(std.mem.indexOf(u8, written, "❯ \x1b[1A" ++ erase) != null);
    try expect(std.mem.endsWith(u8, written, "\x1b[1A" ++ erase ++ "\r\n" ++ erase ++ "\x1b[1A\r"));
}
