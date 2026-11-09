//! Full-screen conversation layout.
//!
//! The interactive session takes the terminal over: the conversation scrolls in
//! a region at the top and the input line stays at the bottom, where the eye
//! expects it. The alternate screen is used, so the shell's own scrollback is
//! handed back unchanged when zagent exits, and a suspended zagent (Ctrl-Z) can
//! give the terminal back to the shell and take it again when it resumes.
//!
//! Everything written to the log is kept in `transcript`. A terminal cannot be
//! asked what is on it, and the layout changes whenever the input grows or the
//! window is resized; the bytes that produced the screen are the only way to
//! draw it again, which is what Ctrl-Z resume and the growing input rely on.
//!
//! The bottom rows are reserved all the time, not only while the prompt is
//! being edited. Answers stream above them, so the prompt never moves and no
//! answer is hidden under it.

const std = @import("std");
const builtin = @import("builtin");
const term = @import("term.zig");

const RESET = "\x1b[0m";
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";
const SAVE_CURSOR = "\x1b7";
const RESTORE_CURSOR = "\x1b8";
const ALT_ON = "\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h";
const ALT_OFF = "\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?1049l";
const selection = @import("selection.zig");

pub const Screen = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    out: std.Io.File,
    /// False for a run whose output is not a terminal. Every method then does
    /// nothing, so callers do not have to ask before writing.
    active: bool,
    /// The bytes that drew the log, in the order they were written.
    transcript: std.ArrayList(u8) = .empty,
    rows: usize = 24,
    cols: usize = 80,
    /// Rows kept clear at the bottom for the editor and its popup. Never zero
    /// while active: the prompt is always at the bottom.
    input_rows: usize = 1,
    /// The log has to be drawn again before the next write.
    dirty: bool = true,
    scroll_rows: usize = 0,
    buffered: bool = false,
    queued: std.ArrayList(u8) = .empty,
    queue_mutex: std.Io.Mutex = .init,
    progress: [256]u8 = undefined,
    progress_len: usize = 0,
    pending_progress: [256]u8 = undefined,
    pending_progress_len: usize = 0,
    progress_changed: bool = false,
    anchor: ?usize = null,
    anchor_end: usize = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
    dragging: bool = false,
    notice: [128]u8 = undefined,
    notice_len: usize = 0,
    notice_started: ?std.Io.Timestamp = null,

    pub fn mouse(self: *Screen, report: []const u8) !void {
        if (!self.active) return;
        const m = selection.parse(report) orelse return;
        // Only unmodified left-button presses, drags and releases select.
        if (m.button != 0 and m.button != 32) return;
        if (m.y > self.logBottom() and !self.dragging) return;
        const rows = try visualRows(self.allocator, self.transcript.items, self.cols);
        defer self.allocator.free(rows);
        const end_row = rows.len - @min(self.scroll_rows, rows.len -| self.logBottom());
        const first = end_row -| self.logBottom();
        const row = @min(first + @min(m.y, self.logBottom()) - 1, end_row - 1);
        const begin = rows[row];
        const end = if (row + 1 < rows.len) rows[row + 1] else self.transcript.items.len;
        const line = self.transcript.items[begin..end];
        const point = begin + selection.offset(line, m.x - 1, false);
        const point_end = begin + selection.offset(line, m.x - 1, true);
        if (!m.release and m.button == 0) {
            self.anchor = point;
            self.anchor_end = point_end;
            self.selection_start = point;
            self.selection_end = point;
            self.dragging = true;
        } else if (self.dragging) {
            const anchor = self.anchor orelse return;
            // A click without motion is not a selection.
            if (point != anchor or self.selection_end != self.selection_start) {
                self.selection_start = @min(anchor, point);
                self.selection_end = @max(self.anchor_end, point_end);
            }
            if (m.release) {
                self.dragging = false;
                if (self.selection_end > self.selection_start) try self.copySelection();
            }
        } else return;
        self.dirty = true;
    }

    fn copySelection(self: *Screen) !void {
        const plain = try selection.plain(self.allocator, self.transcript.items[self.selection_start..self.selection_end]);
        defer self.allocator.free(plain);
        if (plain.len == 0) return;
        const encoder = std.base64.standard.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(plain.len));
        defer self.allocator.free(encoded);
        _ = encoder.encode(encoded, plain);
        // OSC 52 works locally and over SSH; the terminal controls permission.
        try self.out.writeStreamingAll(self.io, "\x1b]52;c;");
        try self.out.writeStreamingAll(self.io, encoded);
        try self.out.writeStreamingAll(self.io, "\x07");
        const count = try std.unicode.utf8CountCodepoints(plain);
        const message = try std.fmt.bufPrint(&self.notice, "已复制 {d} 个字符", .{count});
        self.notice_len = message.len;
        self.notice_started = std.Io.Timestamp.now(self.io, .awake);
    }

    /// Workers publish a transient line; only the foreground draws it.
    pub fn setProgress(self: *Screen, line: []const u8) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        const len = @min(line.len, self.pending_progress.len);
        @memcpy(self.pending_progress[0..len], line[0..len]);
        self.pending_progress_len = len;
        self.progress_changed = true;
    }

    pub fn drain(self: *Screen) !bool {
        // Keep the viewport stable while the pointer is selecting streamed text.
        if (self.dragging) return false;
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        var changed = self.progress_changed;
        if (self.notice_started) |started| {
            if (started.untilNow(self.io, .awake).toMilliseconds() >= 3000) {
                self.notice_len = 0;
                self.notice_started = null;
                self.dirty = true;
                changed = true;
            }
        }
        if (self.progress_changed) {
            self.progress_len = self.pending_progress_len;
            @memcpy(self.progress[0..self.progress_len], self.pending_progress[0..self.progress_len]);
            self.progress_changed = false;
            self.dirty = true;
        }
        if (self.queued.items.len == 0) return changed;
        const old_rows = if (self.scroll_rows > 0) blk: {
            const rows = try visualRows(self.allocator, self.transcript.items, self.cols);
            defer self.allocator.free(rows);
            break :blk rows.len;
        } else 0;
        try self.transcript.appendSlice(self.allocator, self.queued.items);
        if (old_rows > 0) {
            const rows = try visualRows(self.allocator, self.transcript.items, self.cols);
            defer self.allocator.free(rows);
            self.scroll_rows += rows.len -| old_rows;
        }
        self.queued.clearRetainingCapacity();
        self.dirty = true;
        return true;
    }

    /// Wheel events advance a few visual rows; keyboard paging keeps its
    /// viewport-sized step. Wrapped lines count as separate visual rows.
    pub fn scroll(self: *Screen, up: bool, page: bool) !void {
        self.dragging = false;
        self.selection_end = self.selection_start;
        _ = try self.drain();
        const step = if (page) @max(@as(usize, 1), self.logBottom() -| 1) else 3;
        const total = try visualRows(self.allocator, self.transcript.items, self.cols);
        defer self.allocator.free(total);
        const limit = total.len -| self.logBottom();
        self.scroll_rows = if (up) @min(limit, self.scroll_rows +| step) else self.scroll_rows -| step;
        self.dirty = true;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, active: bool) Screen {
        return .{
            .allocator = allocator,
            .io = io,
            .out = std.Io.File.stdout(),
            .active = active,
        };
    }

    pub fn deinit(self: *Screen) void {
        if (self.active) self.leave();
        self.transcript.deinit(self.allocator);
        self.queued.deinit(self.allocator);
    }

    pub fn isActive(self: *const Screen) bool {
        return self.active;
    }

    /// Take the terminal over and start with a blank screen.
    pub fn enter(self: *Screen) !void {
        if (!self.active) return;
        _ = self.refreshSize();
        self.syncSignals();
        if (builtin.os.tag != .windows) {
            handler_termios = std.posix.tcgetattr(self.out.handle) catch null;
        }
        try self.out.writeStreamingAll(self.io, ALT_ON ++ HIDE_CURSOR ++ "\x1b[1;1H\x1b[0J" ++ SHOW_CURSOR);
        self.dirty = true;
        installSignals();
    }

    /// Give the terminal back exactly as it was found.
    pub fn leave(self: *Screen) void {
        if (!self.active) return;
        uninstallSignals();
        self.out.writeStreamingAll(self.io, RESET ++ "\x1b[r" ++ SHOW_CURSOR ++ ALT_OFF) catch {};
        self.active = false;
    }

    /// Re-read the window size. Returns whether it changed.
    fn refreshSize(self: *Screen) bool {
        const rows = term.rows(self.out);
        const cols = term.columns(self.out);
        const changed = rows != self.rows or cols != self.cols;
        self.rows = rows;
        self.cols = cols;
        return changed;
    }

    /// Reserve `wanted` rows at the bottom for the editor. Called before a line
    /// is read and whenever the editor's own height changes.
    ///
    /// The log is drawn again only when the reserved height, the window size or
    /// the transcript changed. `prepareInput` is what saves the log cursor;
    /// doing it here too would save the editor's own cursor on every keystroke.
    pub fn reserveInput(self: *Screen, wanted: usize, repaint: bool) !void {
        if (!self.active) return;
        _ = try self.drain();
        const resized = self.refreshSize();
        if (repaint) self.dirty = true;
        const clamped = @max(@as(usize, 1), @min(wanted, self.rows -| 1));
        if (resized or clamped != self.input_rows or self.dirty or repaintPending()) {
            self.input_rows = clamped;
            try self.replay();
        }
        self.syncSignals();
    }

    /// Get ready to read a line: reserve the prompt row and remember where the
    /// log ended. `endInput` restores that position once the editor is done,
    /// because the editor moves the cursor into its own rows.
    pub fn prepareInput(self: *Screen) !void {
        try self.reserveInput(1, false);
        if (self.active) self.saveCursor();
    }

    /// Clear the editor's rows and put the cursor back where the log ended, so
    /// the answer that follows starts right above the prompt.
    ///
    /// The position to return to is the one `prepareInput` saved before the
    /// editor took the cursor away. Saving it again here would save the
    /// editor's cursor instead, and everything written next — the question,
    /// the spinner, the answer — would land in the prompt rows and be erased
    /// by the next draw.
    pub fn endInput(self: *Screen) !void {
        if (!self.active) return;
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try w.print("\x1b[{d};1H\x1b[0J", .{self.inputTop()});
        try w.writeAll(RESTORE_CURSOR);
        try self.out.writeStreamingAll(self.io, w.buffered());

        // A multi-line question no longer needs its rows once it is sent: the
        // next write repaints the log with the taller region.
        if (self.input_rows != 1) {
            self.input_rows = 1;
            self.dirty = true;
            self.syncSignals();
        }
    }

    /// Append to the conversation and show it.
    pub fn writeLog(self: *Screen, bytes: []const u8) !void {
        if (!self.active or bytes.len == 0) return;
        if (self.buffered) {
            self.queue_mutex.lockUncancelable(self.io);
            defer self.queue_mutex.unlock(self.io);
            try self.queued.appendSlice(self.allocator, bytes);
            return;
        }
        if (self.dirty or repaintPending()) try self.replay();
        try self.transcript.appendSlice(self.allocator, bytes);
        try self.out.writeStreamingAll(self.io, bytes);
    }

    /// A writer that appends to the conversation, for callers that format into
    /// a writer rather than handing over finished bytes.
    pub fn logWriter(self: *Screen, buffer: []u8) LogWriter {
        return .init(self, buffer);
    }

    /// Draw the whole conversation again.
    ///
    /// Writing the transcript from the top of the log region is enough: a short
    /// conversation ends where it ends and leaves the space below blank, and a
    /// long one scrolls the region as it is written, ending at the bottom. No
    /// line arithmetic is needed, which is what keeps this right when the text
    /// contains wide characters or colour codes.
    pub fn replay(self: *Screen) !void {
        if (!self.active) return;
        // Cleared before drawing: a suspend that arrives in the middle of the
        // replay leaves a half-drawn screen, and the flag is what makes the
        // next write draw it again.
        _ = pending.swap(false, .acquire);
        _ = self.refreshSize();
        const bottom = self.logBottom();
        const top = bottom + 1;

        var buf: [8192]u8 = undefined;
        var file_writer = self.out.writerStreaming(self.io, &buf);
        const w = &file_writer.interface;

        try w.writeAll(HIDE_CURSOR);
        try w.print("\x1b[1;{d}r", .{bottom});
        try w.writeAll("\x1b[1;1H\x1b[0J");
        // The editor turns off output post-processing, so a bare newline would
        // leave the column where it was. Writing CRLF keeps the replay correct
        // both while a line is being edited and between turns.
        const offsets = try visualRows(self.allocator, self.transcript.items, self.cols);
        defer self.allocator.free(offsets);
        self.scroll_rows = @min(self.scroll_rows, offsets.len -| bottom);
        const end_row = offsets.len - self.scroll_rows;
        const first_row = end_row -| bottom;
        const view_start = offsets[first_row];
        const view_end = if (end_row < offsets.len) offsets[end_row] else self.transcript.items.len;
        const end = if (end_row < offsets.len and view_end > view_start and self.transcript.items[view_end - 1] == '\n') view_end - 1 else view_end;
        const view = self.transcript.items[view_start..end];
        var index: usize = 0;
        var inverse = false;
        while (index < view.len) {
            if (view[index] == 0x1b) {
                const next = @import("text.zig").skipAnsiEscape(view, index);
                try w.writeAll(view[index..next]);
                if (inverse) try w.writeAll("\x1b[7m");
                index = next;
                continue;
            }
            const selected = view_start + index >= self.selection_start and view_start + index < self.selection_end;
            if (selected != inverse) try w.writeAll(if (selected) "\x1b[7m" else "\x1b[27m");
            inverse = selected;
            const cp = term.decodeAt(view, index);
            if (view[index] == '\n') {
                if (inverse) try w.writeAll("\x1b[27m");
                inverse = false;
                try w.writeAll("\r\n");
            } else {
                try w.writeAll(view[index..][0..cp.len]);
            }
            index += cp.len;
        }
        if (inverse) try w.writeAll("\x1b[27m");
        try w.writeAll(SAVE_CURSOR);
        try w.print("\x1b[{d};1H\x1b[0J", .{top});
        if (self.notice_len > 0 or self.progress_len > 0) {
            try w.writeAll(RESET);
            try w.writeAll(if (self.notice_len > 0) self.notice[0..self.notice_len] else self.progress[0..self.progress_len]);
            try w.writeAll("\r\n");
        }
        try w.writeAll(RESTORE_CURSOR);
        try w.writeAll(SHOW_CURSOR);
        try w.flush();

        self.dirty = false;
        self.syncSignals();
    }

    /// Suspend the process the way Ctrl-Z does in a shell.
    ///
    /// The terminal is handed back first: a program stopped while holding the
    /// alternate screen hides the shell that is about to talk to the user. On
    /// resume the screen is taken again and the conversation is marked for
    /// repainting; the caller calls `reserveInput` before reading the line, and
    /// that is where the repaint happens.
    pub fn suspendProcess(self: *Screen) !void {
        if (!self.active) {
            // The inline layout has no screen to hand back, but the editor
            // still reads Ctrl-Z as a key: stop like any foreground program.
            raiseStop();
            return;
        }
        self.leave();
        raiseStop();
        self.active = true;
        try self.out.writeStreamingAll(self.io, ALT_ON ++ HIDE_CURSOR);
        self.dirty = true;
        self.syncSignals();
        installSignals();
    }

    fn logBottom(self: *const Screen) usize {
        const reserved = self.input_rows + @as(usize, if (self.progress_len > 0 or self.notice_len > 0) 1 else 0);
        return self.rows -| @min(reserved, self.rows -| 1);
    }

    fn inputTop(self: *const Screen) usize {
        return self.rows -| @min(self.input_rows, self.rows -| 1) + 1;
    }

    fn saveCursor(self: *Screen) void {
        self.out.writeStreamingAll(self.io, SAVE_CURSOR) catch {};
    }

    fn syncSignals(self: *Screen) void {
        handler_fd = self.out.handle;
        handler_rows = self.rows;
        handler_input_rows = self.input_rows;
    }
};

/// A `std.Io.Writer` over the screen's log, so the markdown renderer can stream
/// into the conversation through its own small buffer.
fn visualRows(a: std.mem.Allocator, bytes: []const u8, cols: usize) ![]usize {
    var rows: std.ArrayList(usize) = .empty;
    errdefer rows.deinit(a);
    try rows.append(a, 0);
    var column: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            i = @import("text.zig").skipAnsiEscape(bytes, i);
            continue;
        }
        if (bytes[i] == '\n') {
            i += 1;
            column = 0;
            try rows.append(a, i);
            continue;
        }
        if (bytes[i] == '\r') {
            column = 0;
            i += 1;
            continue;
        }
        const cp = term.decodeAt(bytes, i);
        const width = term.codepointWidth(cp);
        if (width > 0 and column + width > @max(cols, 1)) {
            try rows.append(a, i);
            column = 0;
        }
        column += width;
        i += cp.len;
    }
    return rows.toOwnedSlice(a);
}

pub const LogWriter = struct {
    screen: *Screen,
    writer: std.Io.Writer,

    pub fn init(screen: *Screen, buffer: []u8) LogWriter {
        return .{
            .screen = screen,
            .writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LogWriter = @alignCast(@fieldParentPtr("writer", w));
        var count: usize = 0;
        if (w.end > 0) {
            self.screen.writeLog(w.buffer[0..w.end]) catch return error.WriteFailed;
            count += w.end;
            w.end = 0;
        }
        const slices = data[0 .. data.len - 1];
        for (slices) |bytes| {
            self.screen.writeLog(bytes) catch return error.WriteFailed;
            count += bytes.len;
        }
        const pattern = data[slices.len];
        for (0..splat) |_| {
            self.screen.writeLog(pattern) catch return error.WriteFailed;
            count += pattern.len;
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Ctrl-Z
//
// In raw mode Ctrl-Z is read as a key (see the line editor), but while the
// answer is streaming the terminal is cooked and Ctrl-Z becomes SIGTSTP. The
// handler hands the terminal back before the process stops, because the shell
// must be able to show its own prompt and job-control messages, then takes it
// again on resume and asks the next layout to repaint the conversation.
// ---------------------------------------------------------------------------

var handler_fd: i32 = -1;
var handler_rows: usize = 24;
var handler_input_rows: usize = 1;
var handler_installed: bool = false;
/// The terminal attributes in force before the editor ever put it in raw
/// mode. An exit signal can arrive while the editor has it raw, and the shell
/// must not be left that way.
var handler_termios: ?std.posix.termios = null;
/// Set by the SIGTSTP/SIGCONT path; read by the main thread, which is allowed
/// to allocate and repaint.
var pending = std.atomic.Value(bool).init(false);

fn repaintPending() bool {
    return pending.load(.acquire);
}

fn handlerEnabled() bool {
    return builtin.os.tag != .windows and handler_fd >= 0;
}

fn writeRaw(bytes: []const u8) void {
    if (handler_fd < 0) return;
    _ = std.posix.system.write(handler_fd, bytes.ptr, bytes.len);
}

fn installSignals() void {
    if (!handlerEnabled() or handler_installed) return;
    setDisposition(.TSTP, onTstp);
    // An interrupt during a request would otherwise kill the process while it
    // owns the alternate screen, leaving the shell behind a screen it cannot
    // see. The answer is to put the terminal back first, then die.
    setDisposition(.INT, onExitSignal);
    setDisposition(.TERM, onExitSignal);
    setDisposition(.HUP, onExitSignal);
    handler_installed = true;
}

fn uninstallSignals() void {
    if (!handlerEnabled() or !handler_installed) return;
    setDisposition(.TSTP, std.posix.SIG.DFL);
    setDisposition(.INT, std.posix.SIG.DFL);
    setDisposition(.TERM, std.posix.SIG.DFL);
    setDisposition(.HUP, std.posix.SIG.DFL);
    handler_installed = false;
}

fn setDisposition(sig: std.posix.SIG, handler: ?std.posix.Sigaction.handler_fn) void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        // NODEFER matters for SIGTSTP: the handler re-raises it with the
        // default action to stop, and a signal blocked until the handler
        // returns would only be queued, never stopping the process.
        .flags = std.posix.SA.RESTART | std.posix.SA.NODEFER,
    };
    std.posix.sigaction(sig, &action, null);
}

fn onExitSignal(sig: std.posix.SIG) callconv(.c) void {
    writeRaw(RESET ++ "\x1b[r" ++ SHOW_CURSOR ++ ALT_OFF);
    if (handler_termios) |attributes| {
        std.posix.tcsetattr(handler_fd, .NOW, attributes) catch {};
    }
    const number: u8 = @intCast(@backingInt(sig));
    exitRaw(number +% 128);
}

fn exitRaw(code: u8) noreturn {
    switch (builtin.os.tag) {
        .linux => std.os.linux.exit_group(code),
        else => std.c._exit(code),
    }
}

fn onTstp(_: std.posix.SIG) callconv(.c) void {
    // The signal can arrive while the editor holds the terminal raw; the
    // shell that gets the terminal next must not inherit that. The raw
    // attributes are put back when the session resumes.
    const active_mode = std.posix.tcgetattr(handler_fd) catch null;
    if (handler_termios) |original| {
        std.posix.tcsetattr(handler_fd, .NOW, original) catch {};
    }
    writeRaw(RESET ++ "\x1b[r" ++ SHOW_CURSOR ++ ALT_OFF);

    // Stop with the default action: the handler must not run again, or the
    // process would never stop. NODEFER makes the re-raise effective.
    setDisposition(.TSTP, std.posix.SIG.DFL);
    raiseStop();
    setDisposition(.TSTP, onTstp);

    writeRaw(ALT_ON);
    if (active_mode) |attributes| {
        std.posix.tcsetattr(handler_fd, .NOW, attributes) catch {};
    }
    var buf: [48]u8 = undefined;
    if (handler_input_rows > 0 and handler_rows > handler_input_rows) {
        const bottom = handler_rows - handler_input_rows;
        const sequence = std.fmt.bufPrint(&buf, "\x1b[1;{d}r", .{bottom}) catch "";
        writeRaw(sequence);
    }
    pending.store(true, .release);
}

/// Stop the process until `fg`, for a caller with no full-screen layout.
pub fn stopProcess() void {
    raiseStop();
}

/// Stop the process until `fg`, using the default disposition for the signal.
/// Resumes on the same stack.
fn raiseStop() void {
    if (builtin.os.tag == .windows) return;
    std.posix.raise(.TSTP) catch {};
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "drag selects Unicode output and release copies once with character notice" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "out", .{});
    defer file.close(std.testing.io);
    var s = Screen.init(a, std.testing.io, true);
    s.out = file;
    defer {
        s.active = false;
        s.deinit();
    }
    try s.transcript.appendSlice(a, "\x1b[31m你ab\x1b[0m\nsecond");
    try s.mouse("0;1;1M");
    try s.mouse("32;3;1M");
    try std.testing.expect(s.dragging);
    try s.replay();
    try s.mouse("0;3;1m");
    try std.testing.expect(!s.dragging);
    try std.testing.expectEqualStrings("已复制 2 个字符", s.notice[0..s.notice_len]);
    const output = try readOutput(tmp.dir, a);
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[7m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b]52;c;5L2gYQ==\x07") != null);
    try s.mouse("0;3;1m");
    const again = try readOutput(tmp.dir, a);
    defer a.free(again);
    try std.testing.expectEqual(output.len, again.len);
    // Reverse selection covers the same glyphs, and a click alone is a no-op.
    try s.mouse("0;3;1M");
    try s.mouse("32;1;1M");
    try s.mouse("0;1;1m");
    try std.testing.expectEqualStrings("已复制 2 个字符", s.notice[0..s.notice_len]);
    try s.mouse("0;1;1M");
    try s.mouse("0;1;1m");
    try std.testing.expectEqual(s.selection_start, s.selection_end);
}

test "visual history rows count wrapping, CJK and ANSI without splitting UTF-8" {
    const a = std.testing.allocator;
    const rows = try visualRows(a, "\x1b[31m你好ab\x1b[0m\nlast\n", 4);
    defer a.free(rows);
    try std.testing.expectEqualSlices(usize, &.{ 0, 11, 18, 23 }, rows);
}

test "worker progress reserves a transient row above input without entering history" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var s = Screen.init(a, io, false);
    defer s.deinit();
    s.rows = 16;
    s.input_rows = 3;
    try std.testing.expectEqual(@as(usize, 13), s.logBottom());
    s.setProgress("thinking… 1s · in 10 · out 0");
    try std.testing.expectEqual(@as(usize, 0), s.progress_len);
    try std.testing.expect(try s.drain());
    try std.testing.expectEqualStrings("thinking… 1s · in 10 · out 0", s.progress[0..s.progress_len]);
    try std.testing.expectEqual(@as(usize, 12), s.logBottom());
    try std.testing.expectEqual(@as(usize, 14), s.inputTop());
    try std.testing.expectEqual(@as(usize, 0), s.transcript.items.len);
    try std.testing.expect(!try s.drain());
    s.setProgress("");
    try std.testing.expect(try s.drain());
    try std.testing.expectEqual(@as(usize, 0), s.progress_len);
    try std.testing.expectEqual(@as(usize, 13), s.logBottom());
    try std.testing.expectEqual(@as(usize, 14), s.inputTop());
}

test "wheel scrolls three visual rows while keyboard scrolls a page" {
    var s = Screen.init(std.testing.allocator, std.testing.io, false);
    defer s.deinit();
    s.rows = 12;
    for (0..40) |_| try s.transcript.appendSlice(s.allocator, "line\n");

    try s.scroll(true, false);
    try std.testing.expectEqual(@as(usize, 3), s.scroll_rows);
    try s.scroll(true, false);
    try std.testing.expectEqual(@as(usize, 6), s.scroll_rows);
    try s.scroll(false, false);
    try std.testing.expectEqual(@as(usize, 3), s.scroll_rows);
    try s.scroll(true, true);
    try std.testing.expectEqual(@as(usize, 13), s.scroll_rows);
    try s.scroll(false, true);
    try std.testing.expectEqual(@as(usize, 3), s.scroll_rows);
    try s.scroll(false, true);
    try std.testing.expectEqual(@as(usize, 0), s.scroll_rows);

    for (0..20) |_| try s.scroll(true, false);
    const offsets = try visualRows(s.allocator, s.transcript.items, s.cols);
    defer s.allocator.free(offsets);
    try std.testing.expectEqual(offsets.len - s.logBottom(), s.scroll_rows);
    for (0..20) |_| try s.scroll(false, false);
    try std.testing.expectEqual(@as(usize, 0), s.scroll_rows);
}

test "buffered output is drained by the UI and keeps a scrolled viewport anchored" {
    const a = std.testing.allocator;
    var s = Screen.init(a, std.testing.io, true);
    defer s.transcript.deinit(a);
    defer s.queued.deinit(a);
    s.rows = 5;
    s.cols = 20;
    s.buffered = true;
    try s.writeLog("one\ntwo\nthree\nfour\nfive\nsix");
    try std.testing.expectEqual(@as(usize, 0), s.transcript.items.len);
    try std.testing.expect(try s.drain());
    try s.scroll(true, false);
    try std.testing.expectEqual(@as(usize, 2), s.scroll_rows);
    try s.writeLog("\nseven\neight");
    try std.testing.expect(try s.drain());
    try std.testing.expectEqual(@as(usize, 4), s.scroll_rows);
    try s.scroll(false, false);
    try s.scroll(false, false);
    try std.testing.expectEqual(@as(usize, 0), s.scroll_rows);
    try std.testing.expect(!try s.drain());
}

test "the log region keeps at least one row above the input" {
    var s: Screen = .{ .allocator = std.testing.allocator, .io = std.testing.io, .out = undefined, .active = false };
    s.rows = 24;
    s.input_rows = 1;
    try expectEqual(23, s.logBottom());
    try expectEqual(24, s.inputTop());
    s.input_rows = 23;
    try expectEqual(1, s.logBottom());
    s.input_rows = 40;
    try expectEqual(1, s.logBottom());
}

/// Read what a screen wrote to its temporary output file.
fn readOutput(dir: std.Io.Dir, allocator: std.mem.Allocator) ![]u8 {
    return dir.readFileAlloc(std.testing.io, "out", allocator, .limited(1 << 20));
}

test "the conversation is drawn in a region above the reserved input row" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "out", .{});
    defer file.close(std.testing.io);

    var s = Screen.init(allocator, std.testing.io, true);
    defer s.transcript.deinit(allocator);
    s.out = file;
    s.cols = 40;

    try s.writeLog("hello\n");
    try s.writeLog("world\n");
    try std.testing.expectEqualStrings("hello\nworld\n", s.transcript.items);

    const written = try readOutput(tmp.dir, allocator);
    defer allocator.free(written);
    // The log lives in rows 1..23 of a 24-row screen; row 24 is the prompt.
    try expect(std.mem.indexOf(u8, written, "\x1b[1;23r") != null);
    try expect(std.mem.indexOf(u8, written, "hello\nworld\n") != null);
    try expect(std.mem.indexOf(u8, written, "\x1b[24;1H\x1b[0J") != null);

    // A later repaint writes the transcript with CRLF: the editor turns off
    // output post-processing, so a bare newline would not return to column 1.
    try s.reserveInput(3, false);
    const repainted = try readOutput(tmp.dir, allocator);
    defer allocator.free(repainted);
    try expect(std.mem.indexOf(u8, repainted, "hello\r\nworld\r\n") != null);

    // Finishing the read clears the prompt rows and leaves the log cursor.
    // `prepareInput` saves that cursor; `endInput` must restore it rather than
    // save the editor's own position over it.
    try s.prepareInput();
    const saved = try readOutput(tmp.dir, allocator);
    defer allocator.free(saved);
    try expect(std.mem.endsWith(u8, saved, SAVE_CURSOR));
    const mark = saved.len;

    try s.endInput();
    const after = try readOutput(tmp.dir, allocator);
    defer allocator.free(after);
    const cleared = after[mark..];
    // The rows of the input block are handed back, and the only cursor save is
    // the one `prepareInput` wrote: saving here would strand the next write in
    // the prompt rows, where the following draw erases it.
    try expect(std.mem.indexOf(u8, cleared, SAVE_CURSOR) == null);
    try expect(std.mem.endsWith(u8, cleared, "\x1b[24;1H\x1b[0J\x1b8"));

    // The question is written straight after the restore, so it appears in the
    // conversation immediately instead of waiting for a full repaint.
    try s.writeLog("hello\n");
    const echoed = try readOutput(tmp.dir, allocator);
    defer allocator.free(echoed);
    try expect(std.mem.endsWith(u8, echoed, "\x1b[24;1H\x1b[0J\x1b8hello\n"));
}

test "a multi-row input is handed back and the next write repaints the log" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "out", .{});
    defer file.close(std.testing.io);

    var s = Screen.init(allocator, std.testing.io, true);
    defer s.transcript.deinit(allocator);
    s.out = file;
    s.cols = 40;

    try s.writeLog("question\n");
    try s.reserveInput(3, false);
    try s.endInput();

    const cleared = try readOutput(tmp.dir, allocator);
    defer allocator.free(cleared);
    // The rows of the three-row input block are cleared.
    try expect(std.mem.endsWith(u8, cleared, "\x1b[22;1H\x1b[0J\x1b8"));
    try expect(s.dirty);

    // The next write gives the rows back with a one-row prompt at the bottom.
    try s.writeLog("answer\n");
    const repainted = try readOutput(tmp.dir, allocator);
    defer allocator.free(repainted);
    try expect(std.mem.indexOf(u8, repainted, "\x1b[1;23r") != null);
    try expect(std.mem.indexOf(u8, repainted, "question\r\n") != null);
    try expect(std.mem.endsWith(u8, repainted, "answer\n"));
}

test "a taller input repaints the log in a shorter region" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "out", .{});
    defer file.close(std.testing.io);

    var s = Screen.init(allocator, std.testing.io, true);
    defer s.transcript.deinit(allocator);
    s.out = file;
    s.cols = 40;

    try s.writeLog("answer\n");
    try s.reserveInput(3, false);

    const written = try readOutput(tmp.dir, allocator);
    defer allocator.free(written);
    try expect(std.mem.indexOf(u8, written, "\x1b[1;21r") != null);
    // The transcript is written again so the newest line stays above the input.
    try expectEqual(1, std.mem.count(u8, written, "answer\r\n"));
    try expectEqual(1, std.mem.count(u8, written, "answer\n"));
    try expect(std.mem.indexOf(u8, written, "\x1b[22;1H\x1b[0J") != null);
}
