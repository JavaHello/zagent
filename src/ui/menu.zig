const std = @import("std");
const term = @import("term.zig");
const sanitize = @import("../util/text.zig");
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

/// Compatibility alias; the tool owns its JSON protocol, not the UI.
pub const Question = @import("../tools/ask_user.zig").Question;

/// What the user did at a menu.
pub const Answer = union(enum) {
    /// Index into the offered options.
    option: usize,
    /// The user's own words, borrowed from the line that was read.
    custom: []const u8,
    /// Nothing to go on: Enter with no recommendation to fall back on.
    skip,
};

/// Compatibility forwards for callers of the former menu parser API.
pub const parseAskUser = @import("../tools/ask_user.zig").parseAskUser;
pub const parseOptions = @import("../tools/ask_user.zig").parseOptions;

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

/// Keyboard state is independent of reads: a partial escape sequence never
/// requires a blocking second read, and both CSI and application arrows work.
/// Each question in `slots` keeps its own selection, so moving between them
/// loses nothing.
const Form = struct {
    slots: []Slot,
    /// The question the keyboard belongs to.
    focus: usize = 0,
    /// A closed form has no free-text row: the trust prompt only offers labels.
    allow_custom: bool = true,
    escape: enum { none, start, sequence } = .none,

    const Action = union(enum) {
        redraw,
        /// Type the answer to question `custom` by hand; the form is drawn
        /// again once that line has been read.
        custom: usize,
        /// Every question is answered.
        finish,
        cancel,
        ignore,
    };

    fn key(self: *Form, byte: u8) Action {
        // Ctrl+C is not a way out of a question: it is pressed by habit, so it
        // is ignored here and the question stays open. Ctrl+D keeps its
        // end-of-input meaning, and the read loop turns a lone Esc into a
        // cancellation.
        if (byte == 4) return .cancel;
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
                self.slots[self.focus].selected = index;
            },
            else => return .ignore,
        }
        return .redraw;
    }

    fn rows(self: *Form) usize {
        return self.slots[self.focus].rowCount(self.allow_custom);
    }

    fn move(self: *Form, delta: isize) Action {
        const slot = &self.slots[self.focus];
        const count: isize = @intCast(slot.rowCount(self.allow_custom));
        slot.selected = @intCast(@mod(@as(isize, @intCast(slot.selected)) + delta, count));
        return .redraw;
    }

    fn jump(self: *Form, index: usize) Action {
        self.slots[self.focus].selected = index;
        return .redraw;
    }

    /// Move the keyboard to another question, wrapping around.
    fn step(self: *Form, delta: isize) Action {
        const count: isize = @intCast(self.slots.len);
        self.focus = @intCast(@mod(@as(isize, @intCast(self.focus)) + delta, count));
        return .redraw;
    }

    /// Enter: take the focused row as this question's answer and move on to the
    /// next question still without one. The last answer finishes the form.
    fn confirm(self: *Form) Action {
        const slot = &self.slots[self.focus];
        if (self.allow_custom and slot.selected >= slot.options.len) return .{ .custom = self.focus };
        slot.custom = null;
        slot.answered = true;
        if (self.nextUnanswered()) |index| {
            self.focus = index;
            return .redraw;
        }
        return .finish;
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
    const limit = @max(columns -| 1, 1);
    const end = term.takeFit(bytes, limit);
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

    pub fn deinit(self: Replies, allocator: std.mem.Allocator) void {
        for (self.items) |reply| {
            if (reply == .custom) allocator.free(reply.custom);
        }
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
    /// Ctrl+D or Esc: the whole form is dismissed.
    cancel,
};

/// The most option rows one question shows at a time; more scroll inside it.
const visible_window: usize = 5;

/// How many rows a form draws: the blank line it starts with, a header per
/// question, the option rows of the widest question, and the hint line.
/// Reserving for the widest question keeps the reservation valid while the
/// keyboard moves between them.
pub fn formRows(slots: []const Slot, allow_custom: bool) usize {
    var options: usize = 1;
    for (slots) |slot| {
        const rows = @min(slot.rowCount(allow_custom), visible_window);
        if (rows > options) options = rows;
    }
    return slots.len + options + 2;
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
/// `focus` is the question the keyboard starts on, which is the one the user was
/// on when the form was last left. Null starts on the first question still
/// without an answer.
pub fn form(allocator: std.mem.Allocator, io: std.Io, slots: []Slot, allow_custom: bool, focus: ?usize) !Outcome {
    if (slots.len == 0) return .cancel;
    var state = Form{ .slots = slots, .allow_custom = allow_custom };
    if (focus) |index| {
        state.focus = @min(index, slots.len - 1);
    } else {
        // Start on the first question still without an answer, so a form
        // entered again after an answer was typed carries on where the user
        // left off.
        state.focus = state.nextUnanswered() orelse return .answered;
    }

    const out = std.Io.File.stderr();
    var raw = try RawTerminal.initKeepingInput(io, std.Io.File.stdin(), out);
    defer raw.deinit();
    try out.writeStreamingAll(io, sgr.HIDE_CURSOR);
    defer out.writeStreamingAll(io, RESET ++ sgr.SHOW_CURSOR) catch {};

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("\r\n");

    var drawn: usize = 0;
    while (true) {
        aw.clearRetainingCapacity();
        if (drawn > 0) try aw.writer.print(sgr.CURSOR_UP ++ "\r", .{drawn});
        const rows = try drawForm(allocator, &aw.writer, &state, term.columns(out));
        // A shorter form leaves the tail of the taller one it replaces behind.
        if (drawn > rows) {
            for (0..drawn - rows) |_| try aw.writer.writeAll(sgr.ERASE_LINE_END ++ "\r\n");
            try aw.writer.print(sgr.CURSOR_UP ++ "\r", .{drawn - rows});
        }
        try out.writeStreamingAll(io, aw.written());
        drawn = rows;

        while (true) {
            const byte = try raw.readByte() orelse return .cancel;
            // Esc opens a sequence only when more bytes follow; on its own it
            // dismisses the form, like the other ways out of a menu. Esc stops
            // the task at the prompt instead: a question is a detour in the
            // run, and backing out of it should not throw the run away.
            if (byte == 0x1b and !try raw.waitReadable(io, escape_timeout_ms)) return .cancel;
            switch (state.key(byte)) {
                .finish => return .answered,
                .custom => |index| return .{ .custom = index },
                .cancel => return .cancel,
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
    /// Put `slots` to the user with the keyboard on `focus` first — null when
    /// the form should start on the first unanswered question — and take the
    /// keys until one question is acted on.
    present: *const fn (*anyopaque, []Slot, ?usize) anyerror!Outcome,
    /// Read the line of a free-text row.
    read: *const fn (*anyopaque) anyerror!Line,
};

/// Answer the questions of one form. The free-text row is resolved here rather
/// than in `form`, which is what keeps Esc in that line returning to the form:
/// the questions stay open until every one is answered or the form is left.
pub fn resolve(allocator: std.mem.Allocator, slots: []Slot, reader: Reader) !Replies {
    // The typed answers live here, not on the stack of one iteration: the form
    // keeps showing them, and they must stay valid until the replies are made.
    var typed: std.ArrayList([]u8) = .empty;
    defer {
        for (typed.items) |text| allocator.free(text);
        typed.deinit(allocator);
    }

    // Which question the keyboard goes back to when the form is drawn again.
    // Null lets the form carry on at the first question still without an answer.
    var focus: ?usize = null;

    loop: while (true) {
        switch (try reader.present(reader.context, slots, focus)) {
            .answered => return repliesFrom(allocator, slots),
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
            .cancel => return repliesFrom(allocator, slots),
        }
    }
}

/// Draw every question, with the option rows of the one that has the keyboard,
/// and return how many rows were drawn.
fn drawForm(allocator: std.mem.Allocator, w: *std.Io.Writer, state: *const Form, columns: usize) !usize {
    var rows: usize = 0;
    for (state.slots, 0..) |slot, i| {
        var header: std.Io.Writer.Allocating = .init(allocator);
        defer header.deinit();
        try header.writer.writeAll("  ");
        if (state.slots.len > 1) try header.writer.print("{d}/{d} ", .{ i + 1, state.slots.len });
        try header.writer.writeAll(slot.text);
        // An answered question shows its answer, which is what makes a wrong one
        // visible before the form is submitted.
        if (slot.answered) {
            if (slot.custom) |text|
                try header.writer.print("  → {s}", .{text})
            else if (slot.options.len > 0)
                try header.writer.print("  → {s}", .{slot.options[@min(slot.selected, slot.options.len - 1)].label});
        }
        if (i == state.focus) try w.writeAll(sgr.BOLD_CYAN);
        try writeRow(w, allocator, header.written(), columns);
        rows += 1;
    }

    const slot = state.slots[state.focus];
    const count = slot.rowCount(state.allow_custom);
    const visible = @min(count, visible_window);
    const first = @min(slot.selected -| (visible / 2), count - visible);
    for (first..first + visible) |i| {
        var row: std.Io.Writer.Allocating = .init(allocator);
        defer row.deinit();
        try row.writer.print("    {s} {d}) ", .{ if (i == slot.selected) ">" else " ", i + 1 });
        if (i < slot.options.len) {
            const option = slot.options[i];
            try row.writer.writeAll(option.label);
            if (recommendedIndex(slot.options) == i) try row.writer.writeAll(" (recommended)");
            if (option.description.len > 0) try row.writer.print("  {s}", .{option.description});
        } else try row.writer.writeAll("Other / 自定义回答");
        if (i == slot.selected) try w.writeAll(sgr.BOLD_CYAN);
        try writeRow(w, allocator, row.written(), columns);
        rows += 1;
    }

    var hint: std.Io.Writer.Allocating = .init(allocator);
    defer hint.deinit();
    try hint.writer.writeAll("  ");
    if (state.slots.len > 1) try hint.writer.writeAll("Tab/Shift+Tab question · ");
    try hint.writer.writeAll("↑/↓ select · Enter confirm · Esc cancel");
    try writeRow(w, allocator, hint.written(), columns);
    return rows + 1;
}

/// A closed menu with no free-text row; defaults to the first option. The
/// ask_user questions go through `resolve` instead, because an answer typed at
/// them has to be read back with the line editor.
pub fn selectOnly(allocator: std.mem.Allocator, io: std.Io, question: []const u8, options: []const Option) !Choice {
    var slots = [_]Slot{Slot.init(question, options)};
    return switch (try form(allocator, io, &slots, false, null)) {
        .answered => switch (slots[0].answer()) {
            .option => |index| .{ .option = index },
            .custom => .cancel,
            .skip => .cancel,
        },
        // Without a free-text row there is nothing to type.
        .custom => .cancel,
        .cancel => .cancel,
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
    try expectAction(.cancel, state.key(4));
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

test "the form draws every question and the options of the focused one" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{
        Slot.init("First question?", &two_options_a),
        Slot.init("Second question?", &two_options_b),
    };
    var state = Form{ .slots = &slots };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    // Two headers, the two option rows and the free-text row of the focused
    // question, and the hint.
    try std.testing.expectEqual(@as(usize, 6), try drawForm(allocator, &aw.writer, &state, 80));

    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "1/2 First question?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2/2 Second question?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1) Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Other / 自定义回答") != null);
    // Only the focused question shows its rows.
    try std.testing.expect(std.mem.indexOf(u8, text, "1) Gamma") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tab/Shift+Tab question") != null);

    // An answered question shows what it was answered with.
    slots[0].answered = true;
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 80);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "First question?  → Beta") != null);
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
    allocator: std.mem.Allocator = std.testing.allocator,
    reads: usize = 0,
    calls: usize = 0,
    /// The question the form was last asked to start on.
    focus: ?usize = null,

    fn present(context: *anyopaque, slots: []Slot, focus: ?usize) anyerror!Outcome {
        const self: *FakeReader = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.focus = focus;
        // The form is asked to start on a question: answer that one, the way
        // Enter on it would.
        if (focus) |index| {
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
    // The blank line, the question, its two options and the free-text row, and
    // the hint.
    try std.testing.expectEqual(@as(usize, 6), formRows(&one, true));
    try std.testing.expectEqual(@as(usize, 5), formRows(&one, false));

    // Every question gets a header of its own.
    var two = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    try std.testing.expectEqual(@as(usize, 7), formRows(&two, true));

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
    try std.testing.expectEqual(@as(usize, 8), formRows(&wide, true));
}
