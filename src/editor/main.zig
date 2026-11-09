const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const File = std.Io.File;

const LinenoiseState = @import("state.zig").LinenoiseState;
pub const History = @import("history.zig").History;
const term = @import("term.zig");
const isUnsupportedTerm = term.isUnsupportedTerm;
const enableRawMode = term.enableRawMode;
const disableRawMode = term.disableRawMode;
const getColumns = term.getColumns;

pub const HintsCallback = *const fn (Allocator, []const u8) Allocator.Error!?[]const u8;
pub const CompletionsCallback = *const fn (Allocator, []const u8) Allocator.Error![]const []const u8;

pub const PopupItem = struct {
    /// Replaces the input before the cursor; null denotes an informational row.
    value: ?[]const u8,
    label: []const u8,
    description: []const u8,

    pub fn deinit(self: PopupItem, allocator: Allocator) void {
        if (self.value) |value| allocator.free(value);
        allocator.free(self.label);
        allocator.free(self.description);
    }
};
pub const PopupCallback = *const fn (Allocator, Io, []const u8) Allocator.Error![]PopupItem;

/// Tells the host how many rows the editor needs at the bottom of the screen.
///
/// The host repaints the conversation above them when the number changes, or
/// when `repaint` is set (Ctrl-L and a resize). It also remembers where the
/// log ended, because the editor moves the cursor away from it.
pub const LayoutCallback = *const fn (context: ?*anyopaque, rows: usize, repaint: bool) anyerror!void;

/// A scoped raw terminal for widgets that do not edit a line.
pub const RawTerminal = struct {
    io: Io,
    input: File,
    output: File,
    original: @typeInfo(@typeInfo(@TypeOf(enableRawMode)).@"fn".return_type.?).error_union.payload,

    pub fn init(io: Io, input: File, output: File) !RawTerminal {
        return .{ .io = io, .input = input, .output = output, .original = try enableRawMode(input, output) };
    }

    pub fn deinit(self: RawTerminal) void {
        disableRawMode(self.input, self.output, self.original);
    }

    pub fn readByte(self: RawTerminal) !?u8 {
        var byte: [1]u8 = undefined;
        return if (try term.read(self.io, self.input, &byte) == 0) null else byte[0];
    }
};

const key_null = 0;
const key_ctrl_a = 1;
const key_ctrl_b = 2;
const key_ctrl_c = 3;
const key_ctrl_d = 4;
const key_ctrl_e = 5;
const key_ctrl_f = 6;
const key_ctrl_h = 8;
const key_tab = 9;
const key_ctrl_k = 11;
const key_ctrl_l = 12;
const key_enter = 13;
const key_ctrl_n = 14;
const key_ctrl_p = 16;
const key_ctrl_t = 20;
const key_ctrl_u = 21;
const key_ctrl_w = 23;
const key_ctrl_z = 26;
const key_esc = 27;
const key_backspace = 127;

fn linenoiseEdit(ln: *Linenoise, in: File, out: File, prompt: []const u8) !?[]const u8 {
    var state = LinenoiseState.init(ln, in, out, prompt);
    defer state.buf.deinit(state.allocator);
    defer state.deinitPopup();
    defer state.finishEdit() catch {};

    // A line suspended with Ctrl-Z comes back with the editor, so the user
    // does not lose what they had typed while looking at the shell.
    if (ln.pending_input) |pending| {
        defer ln.allocator.free(pending);
        ln.pending_input = null;
        try state.buf.appendSlice(state.allocator, pending);
        state.pos = pending.len;
    }

    try state.ln.history.add("");
    state.ln.history.current = state.ln.history.hist.items.len - 1;
    try state.refreshLine();

    while (true) {
        if (ln.tick_callback) |tick| {
            if (try tick(ln.layout_context)) try state.refreshLine();
            if (@import("builtin").os.tag != .windows) {
                var fds = [_]std.posix.pollfd{.{ .fd = in.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                if (try std.posix.poll(&fds, 100) == 0) continue;
            }
        }
        var input_buf: [1]u8 = undefined;
        if ((try term.read(ln.io, in, &input_buf)) < 1) return null;
        var c = input_buf[0];

        // Browse completions before editing
        if (c == key_tab and ln.popup_callback == null) {
            if (try state.browseCompletions()) |new_c| {
                c = new_c;
            }
        }

        if (state.popup_items.len > 0) {
            if (c == key_tab or c == key_enter) {
                try state.acceptPopup();
                continue;
            }
            if (c == key_ctrl_n or c == key_ctrl_p) {
                try state.movePopup(c == key_ctrl_n);
                continue;
            }
        }

        switch (c) {
            key_null, key_tab => {},
            key_ctrl_a => try state.editMoveHome(),
            key_ctrl_b => try state.editMoveLeft(),
            key_ctrl_c => {
                // The empty entry added below stands in for the line being
                // edited; it is not history until Enter accepts it. Dropping it
                // here mirrors Ctrl+D, and keeps an abandoned line out of a
                // history that is saved to disk.
                state.ln.history.pop();
                return error.CtrlC;
            },
            key_ctrl_d => {
                if (state.buf.items.len > 0) {
                    try state.editDelete();
                } else {
                    state.ln.history.pop();
                    return null;
                }
            },
            key_ctrl_e => try state.editMoveEnd(),
            key_ctrl_f => try state.editMoveRight(),
            key_ctrl_k => try state.editKillLineForward(),
            key_ctrl_l => {
                if (ln.bottom_anchor) {
                    // The host owns the screen; ask it to draw the log again
                    // instead of clearing the terminal behind its back.
                    state.force_repaint = true;
                } else {
                    try term.clearScreen(ln.io);
                    state.cursor_row = 0;
                    state.max_rows = 0;
                    state.popup_rows = 0;
                }
                try state.refreshLine();
            },
            10 => try state.editInsert("\n"), // Ctrl+J
            key_enter => {
                state.ln.history.pop();
                return try ln.allocator.dupe(u8, state.buf.items);
            },
            key_ctrl_n => try state.editHistoryNext(.next),
            key_ctrl_p => try state.editHistoryNext(.prev),
            key_ctrl_t => try state.editSwapPrev(),
            key_ctrl_u => try state.editKillLineBackward(),
            key_ctrl_w => try state.editDeletePrevWord(),
            key_ctrl_z => {
                // Suspend through the caller: it knows how to hand the
                // terminal back and draw the conversation again on resume.
                // Popping the placeholder keeps the abandoned line out of the
                // history, the same way Ctrl+C and Ctrl+D do.
                state.ln.history.pop();
                if (state.ln.pending_input) |old| state.ln.allocator.free(old);
                state.ln.pending_input = try state.ln.allocator.dupe(u8, state.buf.items);
                return error.Suspend;
            },
            key_esc => {
                if ((try term.readEscape(ln.io, in, &input_buf)) < 1) {
                    try state.dismissPopup();
                    continue;
                }
                switch (input_buf[0]) {
                    key_enter, 10 => try state.editInsert("\n"), // Alt+Enter
                    'b' => try state.editMoveWordStart(),
                    'f' => try state.editMoveWordEnd(),
                    '[' => {
                        if ((try term.read(ln.io, in, &input_buf)) < 1) return null;
                        switch (input_buf[0]) {
                            '<' => {
                                // SGR mouse reports: consume clicks/releases too,
                                // so coordinates can never enter the input buffer.
                                var report: [64]u8 = undefined;
                                var length: usize = 0;
                                while (length < report.len) {
                                    if ((try term.read(ln.io, in, &input_buf)) < 1) return null;
                                    report[length] = input_buf[0];
                                    length += 1;
                                    if (input_buf[0] >= 0x40 and input_buf[0] <= 0x7e) break;
                                }
                                if (mouseWheel(report[0..length])) |up| {
                                    if (ln.scroll_callback) |scroll| {
                                        try scroll(ln.layout_context, up);
                                        // Scrolling must not reopen a dismissed popup.
                                        if (ln.bottom_anchor) try state.refreshBottom(false) else try state.refreshLine();
                                    }
                                }
                            },
                            '0'...'9' => |num| {
                                var sequence: [32]u8 = undefined;
                                sequence[0] = num;
                                var length: usize = 1;
                                while (length < sequence.len) {
                                    if ((try term.read(ln.io, in, &input_buf)) < 1) return null;
                                    sequence[length] = input_buf[0];
                                    length += 1;
                                    if (input_buf[0] >= 0x40 and input_buf[0] <= 0x7e) break;
                                }
                                const code = sequence[0..length];
                                if (std.mem.eql(u8, code, "200~")) {
                                    const pasted = try readPaste(ln, in);
                                    defer ln.allocator.free(pasted);
                                    try state.editInsert(pasted);
                                } else if (length == 2 and code[1] == '~') {
                                    switch (num) {
                                        '1', '7' => try state.editMoveHome(),
                                        '3' => try state.editDelete(),
                                        '4', '8' => try state.editMoveEnd(),
                                        '5', '6' => {
                                            if (ln.scroll_callback) |scroll| {
                                                try scroll(ln.layout_context, num == '5');
                                                try state.refreshLine();
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            },
                            'A' => if (state.popup_items.len > 0) try state.movePopup(false) else try state.editMoveVertical(false),
                            'B' => if (state.popup_items.len > 0) try state.movePopup(true) else try state.editMoveVertical(true),
                            'Z' => if (state.popup_items.len > 0) try state.movePopup(false),
                            'C' => try state.editMoveRight(),
                            'D' => try state.editMoveLeft(),
                            'H' => try state.editMoveHome(),
                            'F' => try state.editMoveEnd(),
                            else => {},
                        }
                    },
                    'O', '0' => {
                        if ((try term.read(ln.io, in, &input_buf)) < 1) return null;
                        switch (input_buf[0]) {
                            'H' => try state.editMoveHome(),
                            'F' => try state.editMoveEnd(),
                            'A' => if (state.popup_items.len > 0) try state.movePopup(false) else try state.editMoveVertical(false),
                            'B' => if (state.popup_items.len > 0) try state.movePopup(true) else try state.editMoveVertical(true),
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            key_backspace, key_ctrl_h => try state.editBackspace(),
            else => {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8ByteSequenceLength(c) catch continue;

                utf8_buf[0] = c;
                if (utf8_len > 1 and (try term.read(ln.io, in, utf8_buf[1..utf8_len])) < utf8_len - 1) return null;

                try state.editInsert(utf8_buf[0..utf8_len]);
            },
        }
    }
}

/// SGR report after CSI '<'. Only vertical wheel presses scroll the log.
fn mouseWheel(report: []const u8) ?bool {
    if (report.len == 0 or report[report.len - 1] != 'M') return null;
    var fields = std.mem.splitScalar(u8, report[0 .. report.len - 1], ';');
    const button = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    _ = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    _ = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) return null;
    // Strip Shift/Alt/Ctrl modifiers, not motion or horizontal-wheel bits.
    return switch (button & ~@as(u16, 4 | 8 | 16)) {
        64 => true,
        65 => false,
        else => null,
    };
}

test "SGR mouse wheel is distinct from clicks, releases and horizontal scrolling" {
    try std.testing.expectEqual(true, mouseWheel("64;10;20M").?);
    try std.testing.expectEqual(false, mouseWheel("65;10;20M").?);
    try std.testing.expectEqual(true, mouseWheel("80;10;20M").?);
    for ([_][]const u8{ "0;10;20M", "64;10;20m", "66;10;20M", "96;10;20M", "64;10M", "64;x;20M", "64;1;2;3M", "" }) |report| {
        try std.testing.expectEqual(@as(?bool, null), mouseWheel(report));
    }
}

/// Read a line with custom line editing mechanics. This includes hints,
/// completions and history
fn linenoiseRaw(ln: *Linenoise, in: File, out: File, prompt: []const u8) !?[]const u8 {
    // At the bottom of the screen a newline would scroll the whole layout, and
    // the caller clears the input rows itself. Inline, it is what finishes the
    // line the user just submitted.
    defer if (!ln.bottom_anchor) out.writeStreamingAll(ln.io, "\n") catch {};

    const orig = try enableRawMode(in, out);
    defer disableRawMode(in, out, orig);
    try out.writeStreamingAll(ln.io, "\x1b[?2004h");
    defer out.writeStreamingAll(ln.io, "\x1b[?2004l") catch {};

    return try linenoiseEdit(ln, in, out, prompt);
}

/// Consume a bracketed paste as text, never as editor commands.
fn readPaste(ln: *Linenoise, input: File) ![]u8 {
    const end = "\x1b[201~";
    var bytes: ArrayList(u8) = .empty;
    defer bytes.deinit(ln.allocator);
    var matched: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        if (try term.read(ln.io, input, &byte) == 0) return error.EndOfStream;
        if (byte[0] == end[matched]) {
            matched += 1;
            if (matched == end.len) break;
        } else {
            try bytes.appendSlice(ln.allocator, end[0..matched]);
            matched = 0;
            if (byte[0] == end[0]) {
                matched = 1;
            } else {
                try bytes.append(ln.allocator, byte[0]);
            }
        }
    }
    return normalizePaste(ln.allocator, bytes.items);
}

fn normalizePaste(allocator: Allocator, bytes: []const u8) ![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '\r') {
            try result.append(allocator, '\n');
            i += if (i + 1 < bytes.len and bytes[i + 1] == '\n') @as(usize, 2) else 1;
        } else if (c == '\t') {
            try result.appendSlice(allocator, "    ");
            i += 1;
        } else if (c == '\n' or (c >= 32 and c < 127)) {
            try result.append(allocator, c);
            i += 1;
        } else {
            const length = std.unicode.utf8ByteSequenceLength(c) catch {
                i += 1;
                continue;
            };
            if (i + length <= bytes.len) {
                const cp = std.unicode.utf8Decode(bytes[i..][0..length]) catch {
                    i += 1;
                    continue;
                };
                if (cp >= 0xa0) try result.appendSlice(allocator, bytes[i..][0..length]);
                i += length;
            } else i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Read a line with no special features (no hints, no completions, no history)
fn linenoiseNoTTY(io: Io, allocator: Allocator, stdin: File) !?[]const u8 {
    const max_line_len = std.math.maxInt(usize);
    return term.readLineAlloc(io, allocator, stdin, max_line_len);
}

pub const Linenoise = struct {
    allocator: Allocator,
    io: Io,
    /// Used only to detect terminals that cannot do line editing (`TERM=dumb`
    /// and friends).
    env: *const std.process.Environ.Map,
    history: History,
    multiline_mode: bool = false,
    mask_mode: bool = false,
    is_tty: bool = false,
    term_supported: bool = false,
    hints_callback: ?HintsCallback = null,
    completions_callback: ?CompletionsCallback = null,
    popup_callback: ?PopupCallback = null,
    /// Keep the prompt and input at the last rows of the screen, with the
    /// conversation scrolling above them, instead of drawing at the cursor.
    bottom_anchor: bool = false,
    /// How the host is told how many bottom rows the editor needs.
    layout_callback: ?LayoutCallback = null,
    layout_context: ?*anyopaque = null,
    tick_callback: ?*const fn (?*anyopaque) anyerror!bool = null,
    scroll_callback: ?*const fn (?*anyopaque, bool) anyerror!void = null,
    /// The line being edited when Ctrl-Z suspended it, restored and freed by
    /// the next `linenoise` call.
    pending_input: ?[]u8 = null,

    const Self = @This();

    /// Initialize a linenoise struct
    pub fn init(allocator: Allocator, io: Io, env: *const std.process.Environ.Map) Self {
        var self = Self{
            .allocator = allocator,
            .io = io,
            .env = env,
            .history = History.empty(allocator),
        };
        self.examineStdIo();
        return self;
    }

    /// Free all resources occupied by this struct
    pub fn deinit(self: *Self) void {
        self.history.deinit();
        if (self.pending_input) |pending| self.allocator.free(pending);
    }

    /// Re-examine (currently) stdin and environment variables to
    /// check if line editing and prompt printing should be
    /// enabled or not.
    pub fn examineStdIo(self: *Self) void {
        const stdin_file = File.stdin();
        self.is_tty = stdin_file.isTty(self.io) catch false;
        self.term_supported = !isUnsupportedTerm(self.env);
    }

    /// Reads a line from the terminal. Caller owns returned memory
    pub fn linenoise(self: *Self, prompt: []const u8) !?[]const u8 {
        const stdin_file = File.stdin();
        const stdout_file = File.stdout();

        if (self.is_tty and !self.term_supported) {
            try stdout_file.writeStreamingAll(self.io, prompt);
        }

        return if (self.is_tty and self.term_supported)
            try linenoiseRaw(self, stdin_file, stdout_file, prompt)
        else
            try linenoiseNoTTY(self.io, self.allocator, stdin_file);
    }
};

test "all" {
    _ = @import("unicode.zig");
    _ = @import("history.zig");
    _ = @import("state.zig");
}

test "pasted text preserves lines and Unicode without terminal controls" {
    const result = try normalizePaste(std.testing.allocator, "你好\r\n/quit\r下一行\n\tend\x03\x1b\xff");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("你好\n/quit\n下一行\n    end", result);
}

test "bracketed paste consumes embedded Enter and editor commands as text" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try tmp.dir.createFile(std.testing.io, "paste", .{});
    try output.writeStreamingAll(std.testing.io, "first\r\n/quit\n\x03你好\x1b[201~\r");
    output.close(std.testing.io);
    const file = try tmp.dir.openFile(std.testing.io, "paste", .{});
    defer file.close(std.testing.io);
    var ln: Linenoise = .{
        .allocator = allocator,
        .io = std.testing.io,
        .env = undefined,
        .history = History.empty(allocator),
    };
    defer ln.deinit();
    const result = try readPaste(&ln, file);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("first\n/quit\n你好", result);
    var next: [1]u8 = undefined;
    try std.testing.expectEqual(1, try term.read(std.testing.io, file, &next));
    try std.testing.expectEqual(@as(u8, '\r'), next[0]);
}
