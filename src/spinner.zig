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
const erase = "\r" ++ sgr.CLEAR_LINE;

/// Columns the two spaces and the frame take before the label.
const indent_width = 4;

/// A label its owner can still change while the animation runs.
///
/// A wait whose length is known before it starts — a request, a tool — names
/// itself once and a borrowed slice is enough. A sub-agent's wait is the other
/// kind: its caller draws the line before the child knows what the work will
/// turn out to be called, and the child renames the line as it goes. The owner
/// writes and the animation task reads, so the text is copied under a mutex
/// instead of shared through a pointer.
pub const LiveLabel = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    text: [max_len]u8 = undefined,
    len: usize = 0,

    /// Long enough for a task title and what the child is doing with it, short
    /// enough that the line stays the terminal's business: `formatLine`
    /// shortens it further to fit the window.
    pub const max_len = 200;

    pub fn init(io: std.Io) LiveLabel {
        return .{ .io = io };
    }

    pub fn set(self: *LiveLabel, label: []const u8) void {
        // Cut on a codepoint boundary: half a character is not shorter text,
        // it is a broken cell on the terminal.
        var len = @min(label.len, max_len);
        while (len > 0 and len < label.len and (label[len] & 0xC0) == 0x80) len -= 1;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        @memcpy(self.text[0..len], label[0..len]);
        self.len = len;
    }

    /// A copy taken under the lock, so the animation formats from its own
    /// buffer rather than from text the owner may be replacing.
    fn read(self: *LiveLabel, buf: []u8) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const len = @min(self.len, buf.len);
        @memcpy(buf[0..len], self.text[0..len]);
        return buf[0..len];
    }
};

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
    /// The SGR style the frame and its label are drawn in. Dim by default:
    /// the line is an aside to the answer. A caller can give the wait a
    /// colour of its own, so a job that is not the main model's — a
    /// sub-agent's, say — is told apart from it at a glance.
    style: []const u8 = sgr.DIM,
    /// A label its owner may replace while the wait runs; when it is set, the
    /// label handed to `start` is only what the line says until then.
    live: ?*LiveLabel = null,
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
        sgr.UP_ONE ++ erase ++ "\r\n" ++ erase ++ sgr.UP_ONE ++ "\r"
    else
        erase) catch {};

    io.sleep(.fromMilliseconds(options.first_frame_delay_ms), .awake) catch return;

    var index: usize = 0;
    // Outside the loop so a frame never resets the text its owner published.
    var live_buf: [LiveLabel.max_len]u8 = undefined;
    while (true) : (index += 1) {
        const elapsed_ms = (options.started orelse started).untilNow(io, .awake).toMilliseconds();
        if (started.untilNow(io, .awake).toMilliseconds() >= options.max_duration_ms) return;

        // Measured every frame, not once: a terminal can be resized while the
        // user waits, and a frame too wide for it wraps, half of it surviving
        // the erase that follows.
        const budget = term.usableWidth(term.columns(file));
        // Read every frame, not once: the owner may be renaming the line while
        // it runs, which is the whole point of a live label.
        const current = if (options.live) |live| live.read(&live_buf) else label;

        var buf: [256]u8 = undefined;
        const line = formatLine(
            &buf,
            options.style,
            frames[index % frames.len],
            current,
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
            std.fmt.bufPrint(&display_buf, "{s}{s}\r\n" ++ erase ++ "{s}", .{ if (index > 0) sgr.UP_ONE else "", line, prompt }) catch return
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
    style: []const u8,
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

    return std.fmt.bufPrint(buf, erase ++ "{s}  {s} {s}{s}" ++ sgr.RESET, .{ style, frame, shown, tail });
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "a frame clears its line and names what is being waited for" {
    var buf: [256]u8 = undefined;
    try expectEqualStrings(
        "\r\x1b[2K\x1b[2m  ⠋ thinking… 0s\x1b[0m",
        try formatLine(&buf, sgr.DIM, "⠋", "thinking…", 0, 80, null, null),
    );
    try expectEqualStrings(
        "\r\x1b[2K\x1b[2m  ⠙ checking completion… 1s\x1b[0m",
        try formatLine(&buf, sgr.DIM, "⠙", "checking completion…", 1, 80, null, null),
    );
}

test "a frame takes the style its caller chose" {
    var buf: [256]u8 = undefined;
    try expectEqualStrings(
        "\r\x1b[2K\x1b[36m  ⠋ subagent · count the tests… 3s\x1b[0m",
        try formatLine(&buf, sgr.CYAN, "⠋", "subagent · count the tests…", 3, 80, null, null),
    );
}

test "a frame is shortened to fit rather than allowed to wrap" {
    var buf: [256]u8 = undefined;
    const line = try formatLine(&buf, sgr.DIM, "⠋", "checking completion…", 3600, 24, null, null);

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

test "a live label keeps the text its owner last published" {
    var live = LiveLabel.init(std.testing.io);
    live.set("subagent · count the tests…");
    var buf: [LiveLabel.max_len]u8 = undefined;
    try expectEqualStrings("subagent · count the tests…", live.read(&buf));

    live.set("subagent · 数测试");
    try expectEqualStrings("subagent · 数测试", live.read(&buf));
}

test "a live label is cut on a codepoint boundary and set from any task" {
    var live = LiveLabel.init(std.testing.io);
    // Three bytes per character and longer than the limit, so the cut has to
    // fall between two of them rather than inside one.
    const phrase = "数测试的结构与渲染入口都需要看清楚，这样报告才有用。";
    const wide = phrase ++ phrase ++ phrase ++ phrase;
    try expect(wide.len > LiveLabel.max_len);
    live.set(wide);
    var buf: [LiveLabel.max_len]u8 = undefined;
    const kept = live.read(&buf);
    try expect(kept.len <= LiveLabel.max_len);
    try expect(kept.len % 3 == 0);
    try expect(std.unicode.utf8ValidateSlice(kept));
    try expect(std.mem.startsWith(u8, wide, kept));
}

test "the animation renames its line when the label changes under it" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "probe", .{});
    defer file.close(io);

    var live = LiveLabel.init(io);
    live.set("subagent · starting");
    var spin = Spinner.start(io, file, "subagent · starting", .{
        .enabled = true,
        .live = &live,
        .first_frame_delay_ms = 0,
        .frame_interval_ms = 1,
    });
    try io.sleep(.fromMilliseconds(30), .awake);
    // The whole point: the owner renames the wait while it is still drawn.
    live.set("subagent · 数测试");
    try io.sleep(.fromMilliseconds(30), .awake);
    spin.stop();

    const written = try tmp.dir.readFileAlloc(io, "probe", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(written);
    try expect(std.mem.indexOf(u8, written, "subagent · starting") != null);
    try expect(std.mem.indexOf(u8, written, "subagent · 数测试") != null);
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
