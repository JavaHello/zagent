const std = @import("std");
const ansi = @import("../ui/style.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const File = std.Io.File;

const LinenoiseState = @import("state.zig").LinenoiseState;
pub const History = @import("history.zig").History;
const term = @import("term.zig");
const isUnsupportedTerm = term.isUnsupportedTerm;
const enableRawMode = term.enableRawMode;
const enableRawModeKeepingInput = term.enableRawModeKeepingInput;
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

    /// Same, but bytes already typed stay readable: this terminal takes over
    /// from the line editor, so the key the user pressed just as the takeover
    /// happened is theirs to read, not type-ahead to throw away.
    pub fn initKeepingInput(io: Io, input: File, output: File) !RawTerminal {
        return .{ .io = io, .input = input, .output = output, .original = try enableRawModeKeepingInput(input, output) };
    }

    pub fn deinit(self: RawTerminal) void {
        disableRawMode(self.input, self.output, self.original);
    }

    pub fn readByte(self: RawTerminal) !?u8 {
        var byte: [1]u8 = undefined;
        return if (try term.read(self.io, self.input, &byte) == 0) null else byte[0];
    }

    /// Whether another byte arrives within `timeout_ms`. Nothing is consumed:
    /// this is how a lone Esc is told from the start of an escape sequence.
    pub fn waitReadable(self: RawTerminal, io: Io, timeout_ms: i32) !bool {
        _ = io;
        if (@import("builtin").os.tag == .windows) return true;
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.input.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        return try std.posix.poll(&fds, timeout_ms) > 0;
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

/// Whether the terminal has been handed to something that needs it right now,
/// such as a question to answer. The line being edited is parked so the next
/// read puts it back, untouched.
fn handOff(state: *LinenoiseState) !bool {
    const ln = state.ln;
    const handoff = ln.handoff_callback orelse return false;
    if (!try handoff(ln.layout_context)) return false;
    ln.history.pop();
    if (ln.pending_input) |old| ln.allocator.free(old);
    ln.pending_input = try ln.allocator.dupe(u8, state.buf.items);
    return true;
}

/// A cursor key, as the letter a `CSI` sequence reports it with: the arrows,
/// Home and End, and Shift+Tab walking a popup back.
fn cursorKey(state: *LinenoiseState, byte: u8) !void {
    switch (byte) {
        'A' => if (state.popup_items.len > 0) try state.movePopup(false) else try state.editMoveVertical(false),
        'B' => if (state.popup_items.len > 0) try state.movePopup(true) else try state.editMoveVertical(true),
        'Z' => if (state.popup_items.len > 0) try state.movePopup(false),
        'C' => try state.editMoveRight(),
        'D' => try state.editMoveLeft(),
        'H' => try state.editMoveHome(),
        'F' => try state.editMoveEnd(),
        else => {},
    }
}

/// Esc on its own: step back out of a popup, or stop what is running.
fn escapePressed(state: *LinenoiseState, ln: *Linenoise) !void {
    // The free-text row of a question is not a place to interrupt the run: Esc
    // steps back to the option list, so the read ends and the caller draws the
    // menu again.
    if (ln.question_input) {
        ln.history.pop();
        return error.Escaped;
    }
    // A question can take the keyboard in the moment this Esc is pressed. The
    // menu comes first, and the run it belongs to must not be killed by the
    // answer to its own dismissal.
    if (try handOff(state)) return error.Handoff;
    try ln.escape(state.popup_items.len > 0);
    try state.dismissPopup();
    try state.refreshLine();
}

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

    // The one byte a reported key stands for, waiting for the loop to act on it.
    var pushed: ?u8 = null;

    while (true) {
        // A question is put to the user in front of this line: hand the
        // terminal over before waiting for a key, keeping what was typed.
        if (try handOff(&state)) return error.Handoff;
        if (ln.tick_callback) |tick| {
            if (try tick(ln.layout_context)) {
                // Background repaint is not an edit: do not reopen a popup
                // just accepted/dismissed between consecutive key presses.
                if (ln.bottom_anchor) {
                    try state.refreshBottom(false);
                } else {
                    try state.refreshLine();
                }
            }
            // A key already waiting in `pushed` is read at once: polling for
            // the next one would hold it back until the user typed again.
            if (pushed == null and @import("builtin").os.tag != .windows) {
                var fds = [_]std.posix.pollfd{.{ .fd = in.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                if (try std.posix.poll(&fds, 100) == 0) continue;
            }
        }
        // The wait above may have been woken by a question rather than by an
        // edit: the menu takes the keyboard first and the key that woke us
        // stays in the terminal for it, instead of being acted on here. Esc is
        // the case that matters — at the prompt it stops the task, and a
        // question must not swallow that answer to its own dismissal.
        if (try handOff(&state)) return error.Handoff;
        var input_buf: [1]u8 = undefined;
        // A key the terminal reported with its modifiers is taken as the byte
        // it used to arrive as; it waits here for the turn of the loop that
        // acts on it, so one switch handles both encodings.
        if (pushed) |byte| input_buf[0] = byte else if ((try term.read(ln.io, in, &input_buf)) < 1) return null;
        pushed = null;
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
                // A question has no way out on Ctrl+C: the key is pressed by
                // habit, so it is ignored there rather than throwing the
                // question away.
                if (ln.question_input) continue;
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
            10 => try state.editInsert("\n"), // Ctrl+J, and Shift+Enter where it is reported
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
                    try escapePressed(&state, ln);
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
                                if (mouseWheel(report[0..length]) == null) {
                                    if (ln.mouse_callback) |mouse| {
                                        try mouse(ln.layout_context, report[0..length]);
                                        try state.refreshLine();
                                    }
                                }
                                if (mouseWheel(report[0..length])) |up| {
                                    if (ln.scroll_callback) |scroll| {
                                        try scroll(ln.layout_context, up, false);
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
                                // Lock keys are reported like modifiers, which is
                                // what turns the arrows into `CSI 1;129A` while
                                // num lock is on: read them as the key they are.
                                var unlocked: [16]u8 = undefined;
                                const code = withoutLocks(sequence[0..length], &unlocked) orelse sequence[0..length];
                                if (std.mem.eql(u8, code, "200~")) {
                                    const pasted = try readPaste(ln, in);
                                    defer ln.allocator.free(pasted);
                                    try state.editInsert(pasted);
                                } else if (code.len > 2 and code[code.len - 1] == 'u') {
                                    // A key reported with its modifiers, which is
                                    // how Shift+Enter is told from Enter.
                                    if (decodeReported(code[0 .. code.len - 1])) |reported| switch (reported) {
                                        .escape => try escapePressed(&state, ln),
                                        .byte => |byte| pushed = byte,
                                        // Shift+Tab, the popup's way back.
                                        .popup_back => try cursorKey(&state, 'Z'),
                                    };
                                } else if (code.len == 2 and code[1] == '~') {
                                    switch (num) {
                                        '1', '7' => try state.editMoveHome(),
                                        '3' => try state.editDelete(),
                                        '4', '8' => try state.editMoveEnd(),
                                        '5', '6' => {
                                            if (ln.scroll_callback) |scroll| {
                                                try scroll(ln.layout_context, num == '5', true);
                                                try state.refreshLine();
                                            }
                                        },
                                        else => {},
                                    }
                                } else if (code.len == 1) {
                                    // A cursor key whose only modifiers were the
                                    // lock keys: the bare form the editor reads.
                                    try cursorKey(&state, code[0]);
                                }
                            },
                            'A', 'B', 'C', 'D', 'H', 'F', 'Z' => try cursorKey(&state, input_buf[0]),
                            else => {},
                        }
                    },
                    'O', '0' => {
                        if ((try term.read(ln.io, in, &input_buf)) < 1) return null;
                        try cursorKey(&state, input_buf[0]);
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

/// A key the terminal reports as `CSI <code>;<modifier> u` once the keyboard
/// protocol is on.
const Reported = union(enum) {
    /// Esc on its own, which a byte of its own would only become after waiting
    /// out the escape timeout.
    escape,
    /// A key the editor knows, as the byte it arrives as without the protocol.
    byte: u8,
    /// Shift+Tab, the popup's way back and nothing else's.
    popup_back,
};

/// The key `body` names, where the terminal sent `CSI <body> u` — the parameters
/// between `CSI` and the final `u` — or null for the keys that arrive as text
/// and for modifiers the editor has no use for. The protocol reports with its
/// modifiers every key that shares a byte, so the editor reads them back as the
/// byte it was written for: Ctrl+M is Enter, Ctrl+J breaks the line, Alt+B and
/// Alt+F walk by words.
fn decodeReported(body: []const u8) ?Reported {
    var fields = std.mem.splitScalar(u8, body, ';');
    const code = std.fmt.parseInt(u21, fields.next() orelse return null, 10) catch return null;
    const modifier = if (fields.next()) |text| (std.fmt.parseInt(u8, text, 10) catch return null) else 1;
    // A third field is the event type, which is only reported when it is asked
    // for: a key being released is not a key being pressed.
    if (fields.next() != null or modifier == 0) return null;
    const held: u8 = modifier - 1; // 1 shift, 2 alt, 4 ctrl, 8 super
    const ctrl = held & 4 != 0 and held & 2 == 0;
    const alt = held & 2 != 0 and held & 4 == 0;
    switch (code) {
        // Ctrl+[ is the Esc key too, and Shift+Esc was always Esc.
        27 => return if (alt) null else .escape,
        13 => return .{ .byte = if (held == 0) key_enter else 10 },
        9 => return if (held & 1 != 0 and !ctrl and !alt) .popup_back else null,
        else => {},
    }
    if (ctrl) {
        // The letter held, as the control byte it used to be sent as.
        const letter: u8 = if (code >= 'a' and code <= 'z')
            @intCast(code)
        else if (code >= '@' and code <= '_')
            @intCast(code)
        else
            return null;
        const byte = letter & 0x1f;
        return if (byte == 0) null else .{ .byte = byte };
    }
    if (alt and code >= 'a' and code <= 'z') return .{ .byte = @intCast(code) };
    return null;
}

test "a reported key reads back as the key it was before the protocol" {
    // Shift+Enter breaks the line, and Enter is still Enter.
    try std.testing.expectEqual(@as(?Reported, .{ .byte = 10 }), decodeReported("13;2"));
    try std.testing.expectEqual(@as(?Reported, .{ .byte = key_enter }), decodeReported("13"));
    // Alt+Enter, and Ctrl+J, which the protocol reports instead of the 0x0a.
    try std.testing.expectEqual(@as(?Reported, .{ .byte = 10 }), decodeReported("13;3"));
    try std.testing.expectEqual(@as(?Reported, .{ .byte = 10 }), decodeReported("106;5"));
    // Esc on its own, Ctrl+[ , and Shift+Esc.
    try std.testing.expectEqual(@as(?Reported, Reported.escape), decodeReported("27"));
    try std.testing.expectEqual(@as(?Reported, Reported.escape), decodeReported("27;5"));
    try std.testing.expectEqual(@as(?Reported, Reported.escape), decodeReported("27;2"));
    // Shift+Tab, and the letters held with a modifier.
    try std.testing.expectEqual(@as(?Reported, Reported.popup_back), decodeReported("9;2"));
    try std.testing.expectEqual(@as(?Reported, .{ .byte = key_ctrl_p }), decodeReported("112;5"));
    try std.testing.expectEqual(@as(?Reported, .{ .byte = 'b' }), decodeReported("98;3"));
    // A key released, a modifier the editor has nothing for, and a key that
    // arrives as text anyway.
    try std.testing.expectEqual(@as(?Reported, null), decodeReported("13;2;3"));
    try std.testing.expectEqual(@as(?Reported, null), decodeReported("98;9"));
    try std.testing.expectEqual(@as(?Reported, null), decodeReported("98;2"));
    try std.testing.expectEqual(@as(?Reported, null), decodeReported("9;6"));
    try std.testing.expectEqual(@as(?Reported, null), decodeReported("32;5"));
    try std.testing.expectEqual(@as(?Reported, null), decodeReported(""));
    try std.testing.expectEqual(@as(?Reported, null), decodeReported("13;x"));
}

/// The key `sequence` names with the lock keys taken out of its modifiers, or
/// null when no lock is held and it can be used as it came. Caps lock and num
/// lock are reported like any other modifier, which is what a num lock turns
/// the up arrow into: `CSI 1;129A` where `CSI A` is meant, and `CSI 3;65~` for
/// Delete. The locks are dropped from the modifier field, and the field itself
/// once nothing is left of it, so what stays is the sequence this editor was
/// reading before the keyboard protocol was asked for.
fn withoutLocks(sequence: []const u8, buffer: *[16]u8) ?[]const u8 {
    if (sequence.len < 3) return null;
    const final = sequence[sequence.len - 1];
    var fields = std.mem.splitScalar(u8, sequence[0 .. sequence.len - 1], ';');
    const first = fields.next() orelse return null;
    const modifier = fields.next() orelse return null;
    if (fields.next() != null) return null;
    const reported = std.fmt.parseInt(u16, modifier, 10) catch return null;
    // 64 is caps lock and 128 is num lock; without them no lock is held.
    if (reported == 0) return null;
    const locks = (reported - 1) & @as(u16, 64 | 128);
    const held = (reported - 1) & ~@as(u16, 64 | 128);
    // A modifier the editor has no use for, and no lock to take out of it.
    if (held != 0 and locks == 0) return null;
    // A key reported with a code of its own keeps one: only the cursor keys and
    // their `CSI <code> <letter>` form can lose the whole modifier field.
    if (final == 'u') return std.fmt.bufPrint(buffer, "{s};{d}u", .{ first, held + 1 }) catch null;
    if (held != 0) return std.fmt.bufPrint(buffer, "{s};{d}{c}", .{ first, held + 1, final }) catch null;
    if (final == '~') return std.fmt.bufPrint(buffer, "{s}~", .{first}) catch null;
    return std.fmt.bufPrint(buffer, "{c}", .{final}) catch null;
}

test "a lock key does not turn the keys into ones nobody reads" {
    var buffer: [16]u8 = undefined;
    // The arrows, Home and End under num lock, and Delete under caps lock.
    try std.testing.expectEqualStrings("A", withoutLocks("1;129A", &buffer).?);
    try std.testing.expectEqualStrings("B", withoutLocks("1;129B", &buffer).?);
    try std.testing.expectEqualStrings("H", withoutLocks("1;193H", &buffer).?);
    try std.testing.expectEqualStrings("3~", withoutLocks("3;65~", &buffer).?);
    try std.testing.expectEqualStrings("5~", withoutLocks("5;193~", &buffer).?);
    // The cursor key a terminal spells out with no modifier at all.
    try std.testing.expectEqualStrings("A", withoutLocks("1;1A", &buffer).?);
    try std.testing.expectEqualStrings("3~", withoutLocks("3;1~", &buffer).?);
    // A real modifier next to the lock is kept where it was, so a key held with
    // Shift stays the key the editor ignores.
    try std.testing.expectEqualStrings("1;2A", withoutLocks("1;130A", &buffer).?);
    // A reported key keeps its modifier field, with only the lock taken out.
    try std.testing.expectEqualStrings("13;2u", withoutLocks("13;130u", &buffer).?);
    try std.testing.expectEqualStrings("13;1u", withoutLocks("13;129u", &buffer).?);
    // Nothing to take out: the sequence is used as it came.
    try std.testing.expectEqual(@as(?[]const u8, null), withoutLocks("1;2A", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), withoutLocks("13;2u", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), withoutLocks("200~", &buffer));
    try std.testing.expectEqual(@as(?[]const u8, null), withoutLocks("1;2;3A", &buffer));
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
    try out.writeStreamingAll(ln.io, ansi.PASTE_ON);
    defer out.writeStreamingAll(ln.io, ansi.PASTE_OFF) catch {};
    // Asked for here rather than for the whole session: the line editor is the
    // reader that has a use for the modifiers, and a menu handed the keyboard
    // mid-line reads the keys it was written for.
    try out.writeStreamingAll(ln.io, ansi.KEYS_ON);
    defer out.writeStreamingAll(ln.io, ansi.KEYS_OFF) catch {};

    return try linenoiseEdit(ln, in, out, prompt);
}

/// Consume a bracketed paste as text, never as editor commands.
fn readPaste(ln: *Linenoise, input: File) ![]u8 {
    const end = ansi.PASTE_END;
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
    /// Asked before every key: true means something else needs the terminal
    /// right now (a question to answer), so this read parks the typed text and
    /// lets the caller draw. It comes back with the next `linenoise` call.
    handoff_callback: ?*const fn (?*anyopaque) anyerror!bool = null,
    interrupt_callback: ?*const fn (?*anyopaque) anyerror!void = null,

    /// Direction (up) and whether to scroll a page rather than wheel lines.
    scroll_callback: ?*const fn (?*anyopaque, bool, bool) anyerror!void = null,
    mouse_callback: ?*const fn (?*anyopaque, []const u8) anyerror!void = null,
    /// The line being edited when Ctrl-Z suspended it, restored and freed by
    /// the next `linenoise` call.
    pending_input: ?[]u8 = null,
    /// Set while the free-text row of a question is being read. There the keys
    /// do not mean what they mean at the prompt: Ctrl+C is ignored instead of
    /// abandoning the line, and a lone Esc steps back to the option list
    /// (`error.Escaped`) instead of interrupting the run.
    question_input: bool = false,

    /// A completion popup gets first refusal; escape sequences never call this.
    pub fn escape(self: *Linenoise, popup_open: bool) !void {
        if (!popup_open) {
            if (self.interrupt_callback) |interrupt| try interrupt(self.layout_context);
        }
    }

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
