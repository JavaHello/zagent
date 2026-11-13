const std = @import("std");
const term = @import("term.zig");
const sanitize = @import("../util/terminal/sanitize.zig");
const RawTerminal = @import("../editor/linenoise.zig").RawTerminal;

// ANSI colour codes
const sgr = @import("style.zig");
const RESET = sgr.RESET;
const BOLD = sgr.BOLD;
const DIM = sgr.DIM;

/// One choice offered to the user. Whoever holds the `Options` owns the slices.
pub const Option = struct {
    label: []const u8,
    /// Empty when the model described nothing.
    description: []const u8,
    recommended: bool,

    pub fn deinit(self: Option, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.description);
    }
};

/// A parsed list of choices, owning its backing slice.
pub const Options = struct {
    items: []Option,

    pub fn none() Options {
        return .{ .items = &.{} };
    }

    pub fn deinit(self: Options, allocator: std.mem.Allocator) void {
        for (self.items) |option| option.deinit(allocator);
        if (self.items.len > 0) allocator.free(self.items);
    }
};

/// What the user did at a menu.
pub const Answer = union(enum) {
    /// Index into the offered options.
    option: usize,
    /// The user's own words, borrowed from the line that was read.
    custom: []const u8,
    /// Nothing to go on: Enter with no recommendation to fall back on.
    skip,
};

pub fn recommendedIndex(options: []const Option) ?usize {
    for (options, 0..) |option, i| {
        if (option.recommended) return i;
    }
    return null;
}

/// One question in a form, together with the answer given to it so far. The
/// slices belong to the caller; the form only moves the answer around, which is
/// what lets the user Tab back and change a question already answered.
pub const Slot = struct {
    text: []const u8,
    options: []const Option,
    /// Index into `options`, or `options.len` for the free-text row.
    selected: usize = 0,
    /// The user's own words, when they took the free-text row. Borrowed, and
    /// cleared as soon as an option row is chosen instead.
    custom: ?[]const u8 = null,
    /// Confirmed with Enter. Tab can still come back to it.
    answered: bool = false,

    /// A question starts on its recommendation, or on the first option.
    pub fn init(text: []const u8, options: []const Option) Slot {
        return .{ .text = text, .options = options, .selected = recommendedIndex(options) orelse 0 };
    }

    /// How many rows this question offers: its options, plus the free-text row
    /// when the form has one.
    fn rowCount(self: Slot, allow_custom: bool) usize {
        return self.options.len + @as(usize, @intFromBool(allow_custom));
    }

    /// What the user answered, for `describeAnswer`.
    pub fn answer(self: Slot) Answer {
        if (self.custom) |text| return .{ .custom = text };
        if (self.options.len == 0) return .skip;
        return .{ .option = @min(self.selected, self.options.len - 1) };
    }
};

/// The rows of the tab that ends the form: send the answers as they stand, or
/// add words of the user's own for the model. Neither is marked recommended, so
/// the markers the option rows carry stay off the confirmation.
const confirm_options = [_]Option{
    .{ .label = "Submit", .description = "Send the answers as they stand", .recommended = false },
    .{ .label = "Supplement", .description = "Type your own words to add", .recommended = false },
};

/// Keyboard state is independent of reads: a partial escape sequence never
/// requires a blocking second read, and both CSI and application arrows work.
/// Each question in `slots` keeps its own selection, so moving between them
/// loses nothing.
const Form = struct {
    slots: []Slot,
    /// The tab the keyboard belongs to: a question, or `slots.len` for the tab
    /// that submits the answers.
    focus: usize = 0,
    /// A closed form has no free-text row: the trust prompt only offers labels.
    allow_custom: bool = true,
    /// Whether the tab strip ends on the confirmation. The trust prompt is a
    /// one-key decision, so it submits on Enter instead.
    confirm_tab: bool = false,
    /// The confirmation's own selection, kept off the questions so Tab-ing back
    /// and forth loses nothing.
    submit: Slot = .{ .text = "Confirm", .options = &confirm_options },
    escape: enum { none, start, sequence } = .none,

    const Action = union(enum) {
        redraw,
        /// Type the answer to question `custom` by hand; the form is drawn
        /// again once that line has been read.
        custom: usize,
        /// Type the words that go with the answers, chosen on the last tab.
        supplement,
        /// Every question is answered and the answers were submitted.
        finish,
        /// Esc: the user backed out, and the run stops with the questions.
        cancel,
        /// Ctrl+D or end of input: the form is dismissed, the run carries on.
        dismiss,
        ignore,
    };

    fn key(self: *Form, byte: u8) Action {
        // Ctrl+C is not a way out of a question: it is pressed by habit, so it
        // is ignored here and the question stays open. Ctrl+D keeps its
        // end-of-input meaning, and the read loop turns a lone Esc into the
        // cancellation that stops the run.
        if (byte == 4) return .dismiss;
        if (byte == '\r' or byte == '\n') return self.confirm();
        if (byte == 0x1b) {
            self.escape = .start;
            return .ignore;
        }
        if (self.escape == .start and (byte == '[' or byte == 'O')) {
            self.escape = .sequence;
            return .ignore;
        }
        if (self.escape == .sequence) {
            if (byte < 0x40 or byte > 0x7e) return .ignore;
            self.escape = .none;
            switch (byte) {
                'A' => return self.move(-1),
                'B' => return self.move(1),
                // Shift+Tab and the other backwards keys: the previous question.
                'Z' => return self.step(-1),
                'H' => return self.jump(0),
                'F' => return self.jump(self.rows() - 1),
                else => return .ignore,
            }
        }
        self.escape = .none;
        switch (byte) {
            // Tab and Shift+Tab walk the questions, which is the point of
            // drawing them together: an earlier answer can be revised.
            '\t', 14 => return self.step(1),
            'k', 16 => return self.move(-1),
            'j' => return self.move(1),
            '1'...'9' => {
                const index: usize = byte - '1';
                if (index >= self.rows()) return .ignore;
                self.focused().selected = index;
            },
            else => return .ignore,
        }
        return .redraw;
    }

    fn rows(self: *Form) usize {
        return self.focused().rowCount(self.freeText());
    }

    fn move(self: *Form, delta: isize) Action {
        const slot = self.focused();
        const count: isize = @intCast(slot.rowCount(self.freeText()));
        slot.selected = @intCast(@mod(@as(isize, @intCast(slot.selected)) + delta, count));
        return .redraw;
    }

    fn jump(self: *Form, index: usize) Action {
        self.focused().selected = index;
        return .redraw;
    }

    /// Move the keyboard to another tab, wrapping around: the questions in
    /// order, then the confirmation once every question has an answer. Until
    /// then the questions are all there is to walk: a form with a question left
    /// open has nothing to submit, and its two rows would only dismiss what was
    /// never asked.
    fn step(self: *Form, delta: isize) Action {
        const count: isize = @intCast(self.reachableTabs());
        self.focus = @intCast(@mod(@as(isize, @intCast(self.focus)) + delta, count));
        return .redraw;
    }

    /// Enter: take the focused row as this question's answer and move on to the
    /// next question still without one. The last answer hands the keyboard to
    /// the confirmation, where Enter submits the answers.
    fn confirm(self: *Form) Action {
        if (self.onConfirm()) {
            // Submit sends the answers as they stand; Supplement asks for a
            // line of the user's own words to send with them.
            return if (self.submit.selected > 0) .supplement else .finish;
        }
        const slot = self.focused();
        if (self.freeText() and slot.selected >= slot.options.len) return .{ .custom = self.focus };
        slot.custom = null;
        slot.answered = true;
        if (self.nextUnanswered()) |index| {
            self.focus = index;
            return .redraw;
        }
        if (self.confirm_tab) {
            self.focus = self.slots.len;
            return .redraw;
        }
        return .finish;
    }

    /// How many tabs the strip has: one per question, plus the confirmation.
    fn tabs(self: *const Form) usize {
        return self.slots.len + @intFromBool(self.confirm_tab);
    }

    /// How many of them the keyboard can reach. The confirmation is drawn from
    /// the start so the form says how the answers are sent, but it cannot be
    /// walked to while a question is still without an answer: Tab then cycles
    /// the questions, where the free-text row is the way to answer in words of
    /// the user's own.
    fn reachableTabs(self: *const Form) usize {
        return self.slots.len + @intFromBool(self.confirm_tab and self.allAnswered());
    }

    fn onConfirm(self: *const Form) bool {
        return self.confirm_tab and self.focus >= self.slots.len;
    }

    /// The tab the keyboard belongs to, question or confirmation.
    fn focused(self: *Form) *Slot {
        return if (self.onConfirm()) &self.submit else &self.slots[self.focus];
    }

    /// The same tab, for drawing it.
    fn focusedSlot(self: *const Form) *const Slot {
        return if (self.onConfirm()) &self.submit else &self.slots[self.focus];
    }

    /// The free-text row closes each question's options; the confirmation has
    /// only its own two rows.
    fn freeText(self: *const Form) bool {
        return self.allow_custom and !self.onConfirm();
    }

    fn allAnswered(self: *const Form) bool {
        for (self.slots) |slot| {
            if (!slot.answered) return false;
        }
        return true;
    }

    /// The next question without an answer, searching from the focused one, or
    /// null when every question has one. The focused question is included: it
    /// is only skipped when it has just been answered.
    fn nextUnanswered(self: *Form) ?usize {
        for (0..self.slots.len) |offset| {
            const index = (self.focus + offset) % self.slots.len;
            if (!self.slots[index].answered) return index;
        }
        return null;
    }
};

/// Flatten and bound every row so wrapping or embedded controls cannot break
/// cursor movement, including with Chinese labels and narrow terminals.
fn writeRow(w: *std.Io.Writer, allocator: std.mem.Allocator, raw: []const u8, columns: usize) !void {
    var clean: std.Io.Writer.Allocating = .init(allocator);
    defer clean.deinit();
    try sanitize.writeSanitized(&clean.writer, raw);
    for (clean.written()) |*byte| {
        if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') byte.* = ' ';
    }
    const bytes = clean.written();
    const limit = columns -| 1;
    const candidate = term.takeFit(bytes, limit);
    const end = if (term.width(bytes[0..candidate]) <= limit) candidate else 0;
    try w.writeAll(bytes[0..end]);
    try w.writeAll(RESET ++ sgr.ERASE_LINE_END ++ "\r\n");
}

/// What the user did at a menu. The free-text row, when offered, is the last
/// one and comes back as `custom`.
pub const Choice = union(enum) {
    /// Index into the offered options.
    option: usize,
    /// The user chose to type their own answer.
    custom,
    /// Ctrl+D or Esc on its own: this question is dismissed. Ctrl+C is not one
    /// of the ways out of a question.
    cancel,
};

/// What reading the line for a free-text row produced.
pub const Line = union(enum) {
    /// The text the user typed. Owned by the caller of the reader.
    answer: []u8,
    /// Esc went back to the form: draw it again.
    back,
    /// End of input, or a line with nothing on it.
    none,
};

/// How one question of a form was answered.
pub const Reply = union(enum) {
    /// Index into the question's options.
    option: usize,
    /// The user's own words. Owned by whoever holds the reply.
    custom: []u8,
    /// The form was dismissed before this question was answered.
    dismissed,
};

/// The answers to a form, one per question, in the order they were asked.
pub const Replies = struct {
    items: []Reply,
    /// Words the user typed on the confirmation's Supplement row, to send with
    /// the answers. Owned here.
    note: ?[]u8 = null,
    /// Esc backed out of the questions: the caller stops the run with them.
    canceled: bool = false,

    pub fn deinit(self: Replies, allocator: std.mem.Allocator) void {
        for (self.items) |reply| {
            if (reply == .custom) allocator.free(reply.custom);
        }
        if (self.note) |note| allocator.free(note);
        allocator.free(self.items);
    }
};

/// The answers to `slots`, owned by the caller. A question still without an
/// answer comes back dismissed, so answers given before the form was backed out
/// of are kept rather than thrown away with it.
pub fn repliesFrom(allocator: std.mem.Allocator, slots: []const Slot) !Replies {
    const items = try allocator.alloc(Reply, slots.len);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |reply| {
            if (reply == .custom) allocator.free(reply.custom);
        }
        allocator.free(items);
    }
    for (slots, 0..) |slot, i| {
        items[i] = if (!slot.answered) .dismissed else switch (slot.answer()) {
            .option => |index| .{ .option = index },
            .custom => |text| .{ .custom = try allocator.dupe(u8, text) },
            .skip => .dismissed,
        };
        filled += 1;
    }
    return .{ .items = items };
}

/// Every question dismissed, which is what a form nobody could answer comes to.
pub fn dismissedReplies(allocator: std.mem.Allocator, count: usize) !Replies {
    const items = try allocator.alloc(Reply, count);
    @memset(items, .dismissed);
    return .{ .items = items };
}

/// The line describing one reply for the model, or null when the question was
/// dismissed and the model has to decide on its own.
pub fn describeReply(allocator: std.mem.Allocator, reply: Reply, options: []const Option) !?[]u8 {
    return switch (reply) {
        .option => |index| try describeAnswer(allocator, .{ .option = index }, options),
        .custom => |text| try describeAnswer(allocator, .{ .custom = text }, options),
        .dismissed => null,
    };
}

/// A lone Esc is told apart from an arrow key by waiting this long for the rest
/// of the sequence. It matches the wait the line editor uses for the same
/// question, so one key is never read as a sequence here and as Esc there.
const escape_timeout_ms = 100;

/// What the form came to.
pub const Outcome = union(enum) {
    /// Every question has an answer: read `Slot.answer` for each one.
    answered,
    /// The user chose to type the answer to question `custom`: read the line,
    /// store it on that slot, and call `form` again.
    custom: usize,
    /// The confirmation's Supplement row: read a line of the user's own words
    /// to send with the answers.
    supplement,
    /// Esc: the user backed out of the questions, and the run stops with them.
    cancel,
    /// Ctrl+D or end of input: the form is dismissed and the run carries on.
    dismiss,
};

/// The most option rows one question shows at a time; more scroll inside it.
const visible_window: usize = 5;

/// Tabs (when needed), focused tab, largest row window, and help. A stable
/// reservation avoids shifting the log when focus changes.
pub fn formRows(slots: []const Slot, allow_custom: bool, confirm_tab: bool) usize {
    var options: usize = 1;
    for (slots) |slot| {
        const rows = @min(slot.rowCount(allow_custom), visible_window);
        if (rows > options) options = rows;
    }
    // The confirmation offers Submit and Supplement, whatever the questions do.
    if (confirm_tab) options = @max(options, confirm_options.len);
    return @as(usize, @intFromBool(slots.len > 1 or confirm_tab)) + options + 2;
}

/// Put one or more questions to the user and let the form own the keyboard
/// until every question is answered or the form is dismissed. Draw on stderr so
/// redirected stdout receives no cursor control sequences.
///
/// The questions of one message are drawn together: Tab and Shift+Tab move
/// between them, so an answer given to a question further up can still be
/// changed before the form is submitted. The free-text row is not typed here —
/// choosing it returns `custom` and the caller reads the line, which is how Esc
/// in that line gets back to the form.
///
/// `confirm_tab` closes the strip with a tab that submits the answers or takes
/// words of the user's own to send with them; the trust prompt leaves it off,
/// because it is one keypress rather than a form. It is drawn from the start
/// but only reachable once every question has an answer: a form that still has
/// an open question has nothing to submit.
///
/// `focus` is the tab the keyboard starts on: a question index, or `slots.len`
/// for the confirmation. Null starts on the first question still without an
/// answer.
pub fn form(allocator: std.mem.Allocator, io: std.Io, slots: []Slot, allow_custom: bool, confirm_tab: bool, focus: ?usize) !Outcome {
    return runForm(allocator, io, slots, allow_custom, confirm_tab, focus, null);
}

pub const Viewport = struct { top: usize, height: usize, columns: usize };
pub const Dock = struct {
    context: *anyopaque,
    prepare: *const fn (*anyopaque, usize) anyerror!Viewport,
};

pub fn formDocked(allocator: std.mem.Allocator, io: std.Io, slots: []Slot, allow_custom: bool, confirm_tab: bool, focus: ?usize, dock: Dock) !Outcome {
    return runForm(allocator, io, slots, allow_custom, confirm_tab, focus, dock);
}

fn runForm(allocator: std.mem.Allocator, io: std.Io, slots: []Slot, allow_custom: bool, confirm_tab: bool, focus: ?usize, dock: ?Dock) !Outcome {
    if (slots.len == 0) return .cancel;
    var state = Form{ .slots = slots, .allow_custom = allow_custom, .confirm_tab = confirm_tab };
    if (focus) |index| {
        // `slots.len` is the confirmation, which a form with one only reaches
        // once every question has an answer.
        state.focus = @min(index, state.reachableTabs() - 1);
    } else if (state.nextUnanswered()) |index| {
        // Start on the first question still without an answer, so a form
        // entered again after an answer was typed carries on where the user
        // left off.
        state.focus = index;
    } else if (confirm_tab) {
        // Every question has an answer: they are submitted from the
        // confirmation, which is drawn once more for the user to add words to
        // them or to send them as they stand.
        state.focus = slots.len;
    } else {
        return .answered;
    }

    const out = std.Io.File.stderr();
    var raw = try RawTerminal.initKeepingInput(io, std.Io.File.stdin(), out);
    defer raw.deinit();
    try out.writeStreamingAll(io, sgr.HIDE_CURSOR);
    defer out.writeStreamingAll(io, RESET ++ sgr.SHOW_CURSOR) catch {};

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var drawn: usize = 0;
    while (true) {
        aw.clearRetainingCapacity();
        if (dock) |target| {
            const view = try target.prepare(target.context, formRows(slots, allow_custom, confirm_tab));
            try aw.writer.writeAll(sgr.SYNC_BEGIN ++ sgr.HIDE_CURSOR);
            try drawDocked(allocator, &aw.writer, &state, view);
            try aw.writer.writeAll(sgr.RESTORE_CURSOR ++ sgr.SYNC_END);
        } else {
            if (drawn > 0) try aw.writer.print(sgr.CURSOR_UP ++ "\r", .{drawn});
            const rows = try drawForm(allocator, &aw.writer, &state, term.columns(out), formRows(slots, allow_custom, confirm_tab));
            // Clear the tail of a taller standalone form.
            if (drawn > rows) {
                for (0..drawn - rows) |_| try aw.writer.writeAll(sgr.ERASE_LINE_END ++ "\r\n");
                try aw.writer.print(sgr.CURSOR_UP ++ "\r", .{drawn - rows});
            }
            drawn = rows;
        }
        try out.writeStreamingAll(io, aw.written());

        while (true) {
            // Poll only in screen mode so resize and queued panel updates are
            // serviced even when the user has not pressed another key.
            if (dock != null and !try raw.waitReadable(io, 100)) break;
            const byte = try raw.readByte() orelse return .dismiss;
            // Esc opens a sequence only when more bytes follow; on its own it
            // cancels the questions, and the run stops with them, as Esc at the
            // prompt stops a task.
            if (byte == 0x1b and !try raw.waitReadable(io, escape_timeout_ms)) return .cancel;
            switch (state.key(byte)) {
                .finish => return .answered,
                .custom => |index| return .{ .custom = index },
                .supplement => return .supplement,
                .cancel => return .cancel,
                .dismiss => return .dismiss,
                .redraw => break,
                .ignore => {},
            }
        }
    }
}

/// Draw a form and read the line a free-text row asks for. Both the plain
/// terminal and the full-screen runtime hand in their own pair, so a form is
/// answered the same way in either.
pub const Reader = struct {
    context: *anyopaque,
    /// Put `slots` to the user with the keyboard on `focus` first — a question
    /// index, `slots.len` for the confirmation, or null when the form should
    /// start on the first unanswered question — and take the keys until one
    /// question is acted on.
    present: *const fn (*anyopaque, []Slot, ?usize) anyerror!Outcome,
    /// Read the line of a free-text row, or the words added to the answers.
    read: *const fn (*anyopaque) anyerror!Line,
};

/// Answer the questions of one form. The free-text row is resolved here rather
/// than in `form`, which is what keeps Esc in that line returning to the form:
/// the questions stay open until every one is answered or the form is left.
pub fn resolve(allocator: std.mem.Allocator, slots: []Slot, reader: Reader) !Replies {
    // The typed answers live here, not on the stack of one iteration: the form
    // keeps showing them, and they must stay valid until the replies are made.
    var typed: std.ArrayList([]u8) = .empty;
    // The words typed on the confirmation's Supplement row, which go with the
    // answers rather than answering a question of their own.
    var note: ?[]u8 = null;
    defer {
        for (typed.items) |text| allocator.free(text);
        typed.deinit(allocator);
        if (note) |text| allocator.free(text);
    }

    // Which tab the keyboard goes back to when the form is drawn again, or null
    // to carry on at the first question still without an answer.
    var focus: ?usize = null;

    loop: while (true) {
        switch (try reader.present(reader.context, slots, focus)) {
            // Submit, from the last tab: the answers as they stand.
            .answered => return submitted(allocator, slots, &note),
            // Supplement, from the same tab: the words typed there go with the
            // answers rather than answering a question of their own.
            .supplement => switch (try reader.read(reader.context)) {
                .answer => |text| {
                    if (note) |old| allocator.free(old);
                    note = text;
                    return submitted(allocator, slots, &note);
                },
                // Esc in that line goes back to the confirmation, where the
                // answers can still be submitted as they stand.
                .back => focus = slots.len,
                // A line with nothing on it adds nothing: submit what was
                // answered.
                .none => return submitted(allocator, slots, &note),
            },
            .custom => |index| switch (try reader.read(reader.context)) {
                .answer => |text| {
                    typed.append(allocator, text) catch |err| {
                        allocator.free(text);
                        return err;
                    };
                    const slot = &slots[index];
                    slot.custom = text;
                    slot.selected = slot.options.len;
                    slot.answered = true;
                    focus = null;
                },
                // Esc in the free-text row: back to the options of the same
                // question, where Enter lands on the recommendation rather
                // than asking for the same line again.
                .back => {
                    const slot = &slots[index];
                    slot.selected = recommendedIndex(slot.options) orelse 0;
                    focus = index;
                },
                // End of input: take the recommendation when the question has
                // one, so a half-typed form still settles instead of stalling.
                .none => {
                    const slot = &slots[index];
                    if (recommendedIndex(slot.options)) |option| {
                        slot.selected = option;
                        slot.answered = true;
                        focus = null;
                        continue :loop;
                    }
                    return repliesFrom(allocator, slots);
                },
            },
            // Esc at the questions: the answers given so far go with them, and
            // the caller stops the run.
            .cancel => {
                var replies = try repliesFrom(allocator, slots);
                replies.canceled = true;
                return replies;
            },
            // Ctrl+D or end of input: the form is dismissed, the run carries on.
            .dismiss => return repliesFrom(allocator, slots),
        }
    }
}

/// The replies of a submitted form, taking over the supplement the user typed
/// so it is freed with them.
fn submitted(allocator: std.mem.Allocator, slots: []const Slot, note: *?[]u8) !Replies {
    var replies = try repliesFrom(allocator, slots);
    replies.note = note.*;
    note.* = null;
    return replies;
}

/// The strip is indented like the question header and the hint below it: a
/// strip that starts in the first column reads as a row of the log rather than
/// as part of the form.
const tabs_indent = "  ";

/// Theme-palette tabs: cyan underline is focus, green check is answered,
/// dim dot is pending. The confirmation closes the strip, so the form always
/// shows how the answers are sent. Windowed around focus on narrow terminals.
fn drawTabs(allocator: std.mem.Allocator, w: *std.Io.Writer, state: *const Form, columns: usize) !void {
    _ = allocator;
    const limit = columns -| 1;
    const indent: usize = @min(tabs_indent.len, limit);
    const count = state.tabs();
    var first = state.focus;
    var used: usize = indent;
    while (first > 0) {
        var buf: [64]u8 = undefined;
        const label = try tabLabel(&buf, state, first - 1);
        if (used + term.width(label) + 7 > limit) break;
        used += term.width(label) + 1;
        first -= 1;
    }
    try w.writeAll(tabs_indent[0..indent]);
    used = indent;
    for (first..count) |i| {
        var buf: [64]u8 = undefined;
        const label = try tabLabel(&buf, state, i);
        if (used + term.width(label) > limit) break;
        try w.writeAll(tabStyle(state, i));
        try w.writeAll(label);
        try w.writeAll(RESET);
        used += term.width(label);
        if (used < limit) {
            try w.writeByte(' ');
            used += 1;
        }
    }
    try w.writeAll(RESET ++ sgr.ERASE_LINE_END ++ "\r\n");
}

/// One tab's text: the mark of its state and its number for a question, the
/// word itself for the confirmation, which checks off once every question has
/// an answer.
fn tabLabel(buf: []u8, state: *const Form, index: usize) ![]const u8 {
    if (state.confirm_tab and index >= state.slots.len) {
        return std.fmt.bufPrint(buf, " {s} Confirm ", .{if (state.allAnswered()) "✓" else "·"});
    }
    const slot = state.slots[index];
    return std.fmt.bufPrint(buf, " {s} {d} ", .{ if (slot.answered) "✓" else "·", index + 1 });
}

fn tabStyle(state: *const Form, index: usize) []const u8 {
    if (index == state.focus) return sgr.BOLD_CYAN ++ sgr.UNDERLINE;
    const answered = if (state.confirm_tab and index >= state.slots.len) state.allAnswered() else state.slots[index].answered;
    return if (answered) sgr.GREEN else DIM;
}

/// Convert logical rows to absolute screen coordinates. In particular, never
/// emit the last row's newline into the status bar or the log scroll region.
fn drawDocked(allocator: std.mem.Allocator, w: *std.Io.Writer, state: *const Form, view: Viewport) !void {
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    _ = try drawForm(allocator, &content.writer, state, view.columns, view.height);
    var lines = std.mem.splitSequence(u8, content.written(), "\r\n");
    for (0..view.height) |row| {
        try w.print(sgr.ROW_START ++ sgr.CLEAR_LINE, .{view.top + row});
        if (lines.next()) |line| try w.writeAll(line);
    }
}

/// Draw the question tabs and the focused tab with its rows, returning the
/// number of terminal rows used.
fn drawForm(allocator: std.mem.Allocator, w: *std.Io.Writer, state: *const Form, columns: usize, height: usize) !usize {
    if (height == 0) return 0;
    const show_tabs = state.tabs() > 1 and height >= 4;
    var rows: usize = 0;
    if (show_tabs) {
        try drawTabs(allocator, w, state, columns);
        rows += 1;
    }
    const slot = state.focusedSlot().*;
    var header: std.Io.Writer.Allocating = .init(allocator);
    defer header.deinit();
    try header.writer.writeAll("  ");
    if (state.slots.len > 1 and !state.onConfirm()) try header.writer.print("{d}/{d} ", .{ state.focus + 1, state.slots.len });
    try header.writer.writeAll(slot.text);
    if (slot.answered) {
        if (slot.custom) |text|
            try header.writer.print("  → {s}", .{text})
        else if (slot.options.len > 0)
            try header.writer.print("  → {s}", .{slot.options[@min(slot.selected, slot.options.len - 1)].label});
    }
    if (height >= 2) {
        try w.writeAll(BOLD);
        try writeRow(w, allocator, header.written(), columns);
        rows += 1;
    }
    const show_help = height >= 3;
    const count = slot.rowCount(state.freeText());
    const visible = @min(@min(count, visible_window), height - rows - @intFromBool(show_help));
    const first = @min(slot.selected -| (visible / 2), count - visible);
    for (first..first + visible) |i| {
        var row: std.Io.Writer.Allocating = .init(allocator);
        defer row.deinit();
        try row.writer.print("    {s} {d}) ", .{ if (i == slot.selected) ">" else " ", i + 1 });
        if (i < slot.options.len) {
            const option = slot.options[i];
            try row.writer.writeAll(option.label);
            if (recommendedIndex(slot.options) == i) try row.writer.writeAll(" (recommended)");
            if (option.description.len > 0) try row.writer.print("  " ++ DIM ++ "{s}" ++ RESET, .{option.description});
        } else try row.writer.writeAll("Other / 自定义回答");
        if (i == slot.selected) try w.writeAll(sgr.BOLD_CYAN);
        try writeRow(w, allocator, row.written(), columns);
        rows += 1;
    }

    if (!show_help) return rows;
    var hint: std.Io.Writer.Allocating = .init(allocator);
    defer hint.deinit();
    try hint.writer.writeAll("  ");
    if (show_tabs) try hint.writer.writeAll("Tab/Shift+Tab · ");
    try hint.writer.writeAll(if (state.onConfirm())
        "↑/↓ select · Enter submit · Esc cancel"
    else
        "↑/↓ select · Enter confirm · Esc cancel");
    try w.writeAll(DIM);
    try writeRow(w, allocator, hint.written(), columns);
    return rows + 1;
}

/// A closed menu with no free-text row; defaults to the first option. The
/// ask_user questions go through `resolve` instead, because an answer typed at
/// them has to be read back with the line editor.
pub fn selectOnly(allocator: std.mem.Allocator, io: std.Io, question: []const u8, options: []const Option) !Choice {
    var slots = [_]Slot{Slot.init(question, options)};
    return switch (try form(allocator, io, &slots, false, false, null)) {
        .answered => switch (slots[0].answer()) {
            .option => |index| .{ .option = index },
            .custom => .cancel,
            .skip => .cancel,
        },
        // Without a free-text row and without a confirmation, there is nothing
        // to type here.
        .custom, .supplement, .cancel, .dismiss => .cancel,
    };
}

/// Write the numbered menu. Only the first option marked recommended is
/// flagged, so a model that marks several cannot produce a contradictory list.
pub fn writeMenu(w: *std.Io.Writer, question: []const u8, options: []const Option) !void {
    const recommended = recommendedIndex(options);

    try w.writeByte('\n');
    try w.print("  {s}\n", .{question});
    for (options, 0..) |option, i| {
        try w.print("    {d}) {s}", .{ i + 1, option.label });
        if (option.description.len > 0) {
            try w.print("  " ++ DIM ++ "{s}" ++ RESET, .{option.description});
        }
        if (recommended != null and recommended.? == i) {
            try w.writeAll(" " ++ BOLD ++ "(recommended)" ++ RESET);
        }
        try w.writeByte('\n');
    }
}

/// Interpret one line typed at a menu. An empty answer takes the recommended
/// option; a number or the option's own label picks by position; anything else
/// is handed back as the user's own words.
pub fn parseAnswer(raw: []const u8, options: []const Option, recommended: ?usize) Answer {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0) return if (recommended) |i| .{ .option = i } else .skip;

    // Accept "2", "2)" and "2." — the numbering is what the menu shows.
    const digits = std.mem.trimEnd(u8, line, ").");
    if (std.fmt.parseInt(usize, digits, 10)) |number| {
        if (number >= 1 and number <= options.len) return .{ .option = number - 1 };
    } else |_| {}

    for (options, 0..) |option, i| {
        if (std.ascii.eqlIgnoreCase(line, option.label)) return .{ .option = i };
    }

    return .{ .custom = line };
}

/// One line describing the outcome, for the model to read. Owned by the caller.
pub fn describeAnswer(allocator: std.mem.Allocator, answer: Answer, options: []const Option) ![]u8 {
    return switch (answer) {
        .option => |i| blk: {
            const option = options[i];
            const separator = if (option.description.len > 0) " — " else "";
            if (option.recommended) {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "User selected the recommended option: {s}{s}{s}",
                    .{ option.label, separator, option.description },
                );
            }
            break :blk try std.fmt.allocPrint(
                allocator,
                "User selected: {s}{s}{s}",
                .{ option.label, separator, option.description },
            );
        },
        .custom => |text| std.fmt.allocPrint(
            allocator,
            "The user did not pick one of the options and answered: {s}",
            .{text},
        ),
        .skip => allocator.dupe(
            u8,
            "The user pressed Enter without choosing, and no option was marked recommended. Decide yourself and continue.",
        ),
    };
}

const test_options = [_]Option{
    .{ .label = "Add tests", .description = "Covers the new branch.", .recommended = true },
    .{ .label = "Skip tests", .description = "", .recommended = false },
};

fn expectAction(expected: std.meta.Tag(Form.Action), action: Form.Action) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(action));
}

const two_options_a = [_]Option{
    .{ .label = "Alpha", .description = "", .recommended = false },
    .{ .label = "Beta", .description = "", .recommended = true },
};
const two_options_b = [_]Option{
    .{ .label = "Gamma", .description = "", .recommended = false },
    .{ .label = "Delta", .description = "", .recommended = true },
};

test "the form navigates options, arrows and both tabs" {
    var slots = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    var state = Form{ .slots = &slots };
    // Each question starts on its recommendation.
    try std.testing.expectEqual(@as(usize, 1), slots[0].selected);
    try std.testing.expectEqual(@as(usize, 1), slots[1].selected);

    // Arrows, vim keys and numbers move inside the focused question only.
    for ("\x1b[A") |byte| _ = state.key(byte);
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);
    try expectAction(.redraw, state.key('2'));
    try std.testing.expectEqual(@as(usize, 1), slots[0].selected);
    _ = state.key('j');
    try std.testing.expectEqual(@as(usize, 2), slots[0].selected);
    _ = state.key('j');
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);

    // Tab goes to the next question, Shift+Tab back to the previous one.
    try expectAction(.redraw, state.key('\t'));
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try expectAction(.redraw, state.key('j'));
    try std.testing.expectEqual(@as(usize, 2), slots[1].selected);
    // The first question kept the selection it had when the keyboard left it.
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);
    for ("\x1b[Z") |byte| _ = state.key(byte);
    try std.testing.expectEqual(@as(usize, 0), state.focus);
    // Tab wraps around, so the last question leads back to the first.
    for ("\x1b[Z") |byte| _ = state.key(byte);
    try std.testing.expectEqual(@as(usize, 1), state.focus);

    // A habitual Ctrl+C leaves the form alone; Ctrl+D dismisses it.
    try expectAction(.ignore, state.key(3));
    try expectAction(.dismiss, state.key(4));
}

test "an answered question can be changed before the form is submitted" {
    var slots = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    var state = Form{ .slots = &slots };

    // Enter answers the focused question and moves on to the next unanswered.
    try expectAction(.redraw, state.key('\r'));
    try std.testing.expect(slots[0].answered);
    try std.testing.expectEqual(@as(usize, 1), state.focus);

    // Shift+Tab goes back, the answer is still the one given, and it can be
    // replaced without the form forgetting the question already answered.
    for ("\x1b[Z") |byte| _ = state.key(byte);
    try std.testing.expectEqual(@as(usize, 0), state.focus);
    _ = state.key('1');
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);
    try expectAction(.redraw, state.key('\r'));
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);

    // The last answer finishes the form.
    try expectAction(.finish, state.key('\r'));
    try std.testing.expect(slots[1].answered);
}

test "the last answer hands the keyboard to the confirmation" {
    var slots = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    var state = Form{ .slots = &slots, .confirm_tab = true };

    // Enter answers the questions, and the last answer stops on the
    // confirmation instead of sending them off.
    _ = state.key('\r');
    try expectAction(.redraw, state.key('\r'));
    try std.testing.expect(slots[1].answered);
    try std.testing.expectEqual(slots.len, state.focus);
    try std.testing.expect(state.onConfirm());

    // It starts on Submit, which Enter takes; Tab and Shift+Tab still walk back
    // to the questions, whose answers are unchanged.
    try std.testing.expectEqual(@as(usize, 0), state.submit.selected);
    for ("\x1b[Z") |byte| _ = state.key(byte);
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try expectAction(.redraw, state.key('\t'));
    try std.testing.expectEqual(slots.len, state.focus);
    try expectAction(.finish, state.key('\r'));
}

test "the confirmation waits until every question has an answer" {
    var slots = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    var state = Form{ .slots = &slots, .confirm_tab = true };

    // While a question is still open, Tab and Shift+Tab cycle the questions:
    // there is nothing to submit, and no answer for words of the user's own to
    // be added to. Answering in words is a question's free-text row instead.
    try expectAction(.redraw, state.key('\t'));
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try expectAction(.redraw, state.key('\t'));
    try std.testing.expectEqual(@as(usize, 0), state.focus);
    for ("\x1b[Z") |byte| _ = state.key(byte);
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try std.testing.expect(!state.onConfirm());

    // The last answer hands the keyboard to the confirmation, which Tab then
    // reaches like any other tab.
    slots[0].answered = true;
    try expectAction(.redraw, state.key('\r'));
    try std.testing.expectEqual(slots.len, state.focus);
    try std.testing.expect(state.onConfirm());
    try expectAction(.redraw, state.key('\t'));
    try std.testing.expectEqual(@as(usize, 0), state.focus);
    try expectAction(.redraw, state.key('\t'));
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try expectAction(.redraw, state.key('\t'));
    try std.testing.expectEqual(slots.len, state.focus);
}

test "the confirmation offers the words to add instead of submitting" {
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots, .confirm_tab = true };
    _ = state.key('\r');
    try std.testing.expectEqual(@as(usize, 1), state.focus);

    // Down and the number both land on Supplement, which asks for a line
    // rather than sending the answers.
    for ("\x1b[B") |byte| _ = state.key(byte);
    try std.testing.expectEqual(@as(usize, 1), state.submit.selected);
    try expectAction(.supplement, state.key('\r'));
    _ = state.key('1');
    try std.testing.expectEqual(@as(usize, 0), state.submit.selected);
    // The confirmation has two rows even when the questions have a free-text
    // row: down from Submit reaches Supplement and no further.
    try expectAction(.redraw, state.key('j'));
    _ = state.key('j');
    try std.testing.expectEqual(@as(usize, 0), state.submit.selected);
}

test "the free-text row asks the caller for a line instead of answering" {
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots };
    // Two options plus the free-text row, which is row 3.
    _ = state.key('3');
    try std.testing.expectEqual(@as(usize, 2), slots[0].selected);
    const action = state.key('\r');
    try expectAction(.custom, action);
    try std.testing.expectEqual(@as(usize, 0), switch (action) {
        .custom => |index| index,
        else => unreachable,
    });
    try std.testing.expect(!slots[0].answered);
}

test "a typed answer is the slot's answer until an option replaces it" {
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    slots[0].custom = "my own words";
    slots[0].answered = true;
    try std.testing.expectEqualStrings("my own words", slots[0].answer().custom);

    // Choosing an option row again drops the typed answer.
    var state = Form{ .slots = &slots };
    _ = state.key('1');
    _ = state.key('\r');
    try std.testing.expect(slots[0].custom == null);
    try std.testing.expectEqual(Answer{ .option = 0 }, slots[0].answer());
}

test "the form draws horizontal tabs and only the focused question" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{
        Slot.init("First question?", &two_options_a),
        Slot.init("Second question?", &two_options_b),
    };
    var state = Form{ .slots = &slots };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    // The tabs, focused header, two options, free-text row, and hint.
    try std.testing.expectEqual(@as(usize, 6), try drawForm(allocator, &aw.writer, &state, 80, 20));

    const text = aw.written();
    // The strip is indented like the header and the hint under it, so it reads
    // as part of the form rather than as a row of the log.
    try std.testing.expect(std.mem.startsWith(u8, text, tabs_indent ++ sgr.BOLD_CYAN ++ sgr.UNDERLINE ++ " · 1 "));
    try std.testing.expect(std.mem.indexOf(u8, text, "1/2 First question?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, sgr.BOLD_CYAN ++ sgr.UNDERLINE ++ " · 1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second question?") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1) Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Other / 自定义回答") != null);
    // Only the focused question shows its rows.
    try std.testing.expect(std.mem.indexOf(u8, text, "1) Gamma") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tab/Shift+Tab · ↑/↓ select") != null);

    // An answered question shows what it was answered with.
    slots[0].answered = true;
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "First question?  → Beta") != null);
}

test "the strip ends on the confirmation, which submits or takes the words" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots, .confirm_tab = true, .focus = slots.len };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Focused, it is cyan and underlined like a question, and it draws its own
    // two rows: nothing is submitted until Enter is pressed here.
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, sgr.BOLD_CYAN ++ sgr.UNDERLINE ++ " · Confirm ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  Confirm") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "> 1) Submit") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2) Supplement") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Type your own words to add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Enter submit") != null);
    // The free-text row belongs to the questions, not to the confirmation.
    try std.testing.expect(std.mem.indexOf(u8, text, "Other / 自定义回答") == null);

    // Pending while a question is open, ready once every one has an answer.
    state.focus = 0;
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), DIM ++ " · Confirm ") != null);
    slots[0].answered = true;
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), sgr.GREEN ++ " ✓ Confirm ") != null);
}

test "question tabs follow keyboard focus and keep it visible on narrow terminals" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{
        Slot.init("First?", &two_options_a),
        Slot.init("Second?", &two_options_a),
        Slot.init("Third?", &two_options_a),
        Slot.init("Fourth?", &two_options_a),
    };
    var state = Form{ .slots = &slots, .focus = 2 };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try drawTabs(allocator, &aw.writer, &state, 80);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), sgr.BOLD_CYAN ++ sgr.UNDERLINE ++ " · 3 ") != null);
    aw.clearRetainingCapacity();
    try drawTabs(allocator, &aw.writer, &state, 18);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), sgr.BOLD_CYAN ++ sgr.UNDERLINE ++ " · 3 ") != null);
    _ = state.key('\t');
    aw.clearRetainingCapacity();
    try drawTabs(allocator, &aw.writer, &state, 18);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), sgr.BOLD_CYAN ++ sgr.UNDERLINE ++ " · 4 ") != null);
}

test "question dock stays inside its rows without newlines into status" {
    const a = std.testing.allocator;
    var slots = [_]Slot{
        Slot.init("First\nquestion\r\x1b[2J?", &two_options_a),
        Slot.init("第二个问题?", &two_options_b),
    };
    var state = Form{ .slots = &slots, .confirm_tab = true, .focus = 1 };
    slots[1].selected = slots[1].rowCount(true) - 1;
    var dock: std.Io.Writer.Allocating = .init(a);
    defer dock.deinit();
    var logical: std.Io.Writer.Allocating = .init(a);
    defer logical.deinit();
    var expected: std.Io.Writer.Allocating = .init(a);
    defer expected.deinit();
    // Every tab is drawn in the same rows: the questions, including the one
    // whose free-text row is selected, and the confirmation.
    for (0..state.tabs()) |tab| {
        state.focus = tab;
        for (0..9) |height| {
            for (0..21) |columns| {
                dock.clearRetainingCapacity();
                logical.clearRetainingCapacity();
                expected.clearRetainingCapacity();
                const view = Viewport{ .top = 2, .height = height, .columns = columns };
                try drawDocked(a, &dock.writer, &state, view);
                try std.testing.expect(std.mem.indexOfAny(u8, dock.written(), "\r\n") == null);
                const rows = try drawForm(a, &logical.writer, &state, columns, height);
                try std.testing.expect(rows <= height);
                var lines = std.mem.splitSequence(u8, logical.written(), "\r\n");
                for (0..height) |row| {
                    try expected.writer.print(sgr.ROW_START ++ sgr.CLEAR_LINE, .{view.top + row});
                    if (lines.next()) |line| {
                        // Leave the rightmost cell unused, even at widths 0 and 1.
                        try std.testing.expect(term.width(line) <= columns -| 1);
                        try expected.writer.writeAll(line);
                    }
                }
                try std.testing.expectEqualStrings(expected.written(), dock.written());
            }
        }
    }
}

test "short question forms keep the selected option and omit tabs before options" {
    const a = std.testing.allocator;
    var slots = [_]Slot{
        Slot.init("First?", &two_options_a),
        Slot.init("Second?", &two_options_b),
    };
    slots[1].selected = 1;
    var state = Form{ .slots = &slots, .focus = 1, .allow_custom = false };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    for (1..4) |height| {
        aw.clearRetainingCapacity();
        try std.testing.expectEqual(height, try drawForm(a, &aw.writer, &state, 80, height));
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "> 2)") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), sgr.UNDERLINE) == null);
        try std.testing.expectEqual(height >= 2, std.mem.indexOf(u8, aw.written(), "Second?") != null);
        try std.testing.expectEqual(height >= 3, std.mem.indexOf(u8, aw.written(), "Esc cancel") != null);
    }
}

test "menu rows fit CJK text and flatten model control characters" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRow(&aw.writer, std.testing.allocator, "你\n好\x1b[2J世界", 7);
    try std.testing.expectEqualStrings("你 好" ++ RESET ++ "\x1b[K\r\n", aw.written());
}

test "a numbered answer picks that option" {
    try std.testing.expectEqual(Answer{ .option = 1 }, parseAnswer("2", &test_options, 0));
    try std.testing.expectEqual(Answer{ .option = 0 }, parseAnswer(" 1) ", &test_options, null));
    try std.testing.expectEqual(Answer{ .option = 0 }, parseAnswer("1.", &test_options, null));
}

test "an empty answer takes the recommendation" {
    try std.testing.expectEqual(Answer{ .option = 0 }, parseAnswer("\n", &test_options, 0));
    // With nothing marked, Enter leaves the decision to the model.
    try std.testing.expectEqual(Answer.skip, parseAnswer("", &test_options, null));
}

test "an answer may repeat an option label" {
    try std.testing.expectEqual(Answer{ .option = 1 }, parseAnswer("skip TESTS", &test_options, 0));
}

test "anything else is the user's own words" {
    try std.testing.expectEqualStrings("do neither", parseAnswer("do neither", &test_options, 0).custom);
    try std.testing.expectEqualStrings("9", parseAnswer("9", &test_options, 0).custom);
}

test "the menu marks only the first recommended option" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const options = [_]Option{
        .{ .label = "A", .description = "first", .recommended = true },
        .{ .label = "B", .description = "", .recommended = true },
    };
    try writeMenu(&aw.writer, "Which one?", &options);

    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "Which one?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1) A") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2) B") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "(recommended)"));
}

test "the description names the recommendation" {
    const allocator = std.testing.allocator;

    const chosen = try describeAnswer(allocator, .{ .option = 0 }, &test_options);
    defer allocator.free(chosen);
    try std.testing.expectEqualStrings(
        "User selected the recommended option: Add tests — Covers the new branch.",
        chosen,
    );

    const other = try describeAnswer(allocator, .{ .option = 1 }, &test_options);
    defer allocator.free(other);
    try std.testing.expectEqualStrings("User selected: Skip tests", other);

    const custom = try describeAnswer(allocator, .{ .custom = "neither" }, &test_options);
    defer allocator.free(custom);
    try std.testing.expectEqualStrings("The user did not pick one of the options and answered: neither", custom);
}

/// A stand-in for the terminal: it answers the first question still without an
/// answer, and hands back the scripted lines for the free-text row.
const FakeReader = struct {
    /// One entry per free-text read: the line to type, or null for Esc.
    lines: []const ?[]const u8 = &.{},
    /// What the first presentation comes to, for the confirmation's own line
    /// and for backing out of the form. The rest answer the questions.
    first: ?Outcome = null,
    allocator: std.mem.Allocator = std.testing.allocator,
    reads: usize = 0,
    calls: usize = 0,
    /// The tab the form was last asked to start on.
    focus: ?usize = null,

    fn present(context: *anyopaque, slots: []Slot, focus: ?usize) anyerror!Outcome {
        const self: *FakeReader = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.focus = focus;
        if (self.first) |outcome| {
            self.first = null;
            return outcome;
        }
        // A form told to go back to its confirmation submits the answers.
        if (focus) |index| {
            if (index >= slots.len) return .answered;
            // The form is asked to start on a question: answer that one, the
            // way Enter on it would.
            const slot = &slots[index];
            slot.answered = true;
            return .answered;
        }
        for (slots, 0..) |*slot, i| {
            if (slot.answered) continue;
            if (slot.selected >= slot.options.len) return .{ .custom = i };
            slot.answered = true;
            return .answered;
        }
        return .answered;
    }

    fn read(context: *anyopaque) anyerror!Line {
        const self: *FakeReader = @ptrCast(@alignCast(context));
        const line = if (self.reads < self.lines.len) self.lines[self.reads] else null;
        self.reads += 1;
        const typed = line orelse return .back;
        return .{ .answer = try self.allocator.dupe(u8, typed) };
    }
};

test "typed answers are freed when resolve allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
            slots[0].selected = 2;
            var reader = FakeReader{ .lines = &.{"custom"}, .allocator = allocator };
            const replies = try resolve(allocator, &slots, .{
                .context = &reader,
                .present = FakeReader.present,
                .read = FakeReader.read,
            });
            defer replies.deinit(allocator);
            try std.testing.expectEqualStrings("custom", replies.items[0].custom);
        }
    }.run, .{});
}

test "a typed answer is the reply, and Esc in that line goes back to the options" {
    const allocator = std.testing.allocator;

    // Typed text answers the question.
    var typed_slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    typed_slots[0].selected = 2;
    var typed_reader = FakeReader{ .lines = &.{"my own words"} };
    const typed = try resolve(allocator, &typed_slots, .{
        .context = &typed_reader,
        .present = FakeReader.present,
        .read = FakeReader.read,
    });
    defer typed.deinit(allocator);
    try std.testing.expectEqualStrings("my own words", typed.items[0].custom);
    try std.testing.expect(typed_slots[0].answered);

    // Esc returns to the options, where Enter takes the recommendation.
    var escaped_slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    escaped_slots[0].selected = 2;
    var escaped_reader = FakeReader{ .lines = &.{null} };
    const escaped = try resolve(allocator, &escaped_slots, .{
        .context = &escaped_reader,
        .present = FakeReader.present,
        .read = FakeReader.read,
    });
    defer escaped.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), escaped_reader.calls);
    // The keyboard went back to the same question, not to the first one.
    try std.testing.expectEqual(@as(?usize, 0), escaped_reader.focus);
    try std.testing.expectEqual(@as(usize, 1), escaped_slots[0].selected);
    try std.testing.expectEqual(@as(usize, 1), switch (escaped.items[0]) {
        .option => |index| index,
        else => unreachable,
    });
}

test "the confirmation submits with the words the user added" {
    const allocator = std.testing.allocator;

    // Supplement: the line read at the confirmation travels with the answers
    // instead of answering a question of its own.
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    slots[0].answered = true;
    var reader = FakeReader{ .first = .supplement, .lines = &.{"and mind the tests"} };
    const replies = try resolve(allocator, &slots, .{
        .context = &reader,
        .present = FakeReader.present,
        .read = FakeReader.read,
    });
    defer replies.deinit(allocator);
    try std.testing.expectEqualStrings("and mind the tests", replies.note.?);
    try std.testing.expect(!replies.canceled);
    try std.testing.expectEqual(@as(usize, 1), replies.items.len);
    try std.testing.expect(switch (replies.items[0]) {
        .option => true,
        else => false,
    });

    // Submit, with nothing typed: the answers stand on their own.
    var plain_slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var plain_reader = FakeReader{};
    const plain = try resolve(allocator, &plain_slots, .{
        .context = &plain_reader,
        .present = FakeReader.present,
        .read = FakeReader.read,
    });
    defer plain.deinit(allocator);
    try std.testing.expect(plain.note == null);

    // Esc in the supplement line goes back to the confirmation, which then
    // submits the answers as they stand.
    var back_slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    back_slots[0].answered = true;
    var back_reader = FakeReader{ .first = .supplement };
    const back = try resolve(allocator, &back_slots, .{
        .context = &back_reader,
        .present = FakeReader.present,
        .read = FakeReader.read,
    });
    defer back.deinit(allocator);
    try std.testing.expectEqual(@as(?usize, back_slots.len), back_reader.focus);
    try std.testing.expect(back.note == null);
    try std.testing.expect(switch (back.items[0]) {
        .option => true,
        else => false,
    });
}

test "Esc cancels the questions and asks the caller to stop the run" {
    const allocator = std.testing.allocator;

    // The answer given before Esc is kept in the replies, so the record shows
    // what was cancelled, but the caller is told to stop.
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    slots[0].answered = true;
    var reader = FakeReader{ .first = .cancel };
    const replies = try resolve(allocator, &slots, .{
        .context = &reader,
        .present = FakeReader.present,
        .read = FakeReader.read,
    });
    defer replies.deinit(allocator);
    try std.testing.expect(replies.canceled);
    try std.testing.expectEqual(@as(usize, 1), switch (replies.items[0]) {
        .option => |index| index,
        else => unreachable,
    });

    // Ctrl+D only dismisses the form: the run carries on.
    var dismissed_slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var dismissed_reader = FakeReader{ .first = .dismiss };
    const dismissed = try resolve(allocator, &dismissed_slots, .{
        .context = &dismissed_reader,
        .present = FakeReader.present,
        .read = FakeReader.read,
    });
    defer dismissed.deinit(allocator);
    try std.testing.expect(!dismissed.canceled);
    try std.testing.expect(dismissed.items[0] == .dismissed);
}

test "replies keep the answers given before the form was left" {
    const allocator = std.testing.allocator;
    // The first question was answered, the second was not: leaving the form
    // must not throw the first answer away.
    var slots = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    slots[0].answered = true;
    const replies = try repliesFrom(allocator, &slots);
    defer replies.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), switch (replies.items[0]) {
        .option => |index| index,
        else => unreachable,
    });
    try std.testing.expect(switch (replies.items[1]) {
        .dismissed => true,
        else => false,
    });
}

test "the form asks for the rows it draws, however many options there are" {
    var one = [_]Slot{Slot.init("Which?", &two_options_a)};
    // Question, options (including free text when allowed), and help.
    try std.testing.expectEqual(@as(usize, 5), formRows(&one, true, false));
    try std.testing.expectEqual(@as(usize, 4), formRows(&one, false, false));

    // More than one question adds one tab strip, not one row per question.
    var two = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    try std.testing.expectEqual(@as(usize, 6), formRows(&two, true, false));

    // The confirmation is a tab of its own, with two rows of its own: the
    // reservation covers the taller of the tabs, not their sum.
    try std.testing.expectEqual(@as(usize, 6), formRows(&one, true, true));
    try std.testing.expectEqual(@as(usize, 6), formRows(&two, true, true));
    // Two options and no free-text row is all a question has, so the
    // confirmation still asks for the same rows.
    try std.testing.expectEqual(@as(usize, 5), formRows(&one, false, true));

    // The visible window stops at five option rows; more options scroll inside
    // it, so a long list does not push the conversation off the screen.
    const many = [_]Option{
        .{ .label = "1", .description = "", .recommended = false },
        .{ .label = "2", .description = "", .recommended = false },
        .{ .label = "3", .description = "", .recommended = false },
        .{ .label = "4", .description = "", .recommended = false },
        .{ .label = "5", .description = "", .recommended = false },
        .{ .label = "6", .description = "", .recommended = false },
        .{ .label = "7", .description = "", .recommended = false },
        .{ .label = "8", .description = "", .recommended = false },
        .{ .label = "9", .description = "", .recommended = false },
    };
    var wide = [_]Slot{Slot.init("Which one?", &many)};
    try std.testing.expectEqual(@as(usize, 7), formRows(&wide, true, false));
}
