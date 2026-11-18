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

/// The row of the confirmation that takes the user's own words. Enter on it
/// types them into the row itself, as Enter on a question's free-text row does,
/// and the answers are submitted with them.
const supplement_row: usize = 1;

/// The row typed into where it is drawn: a question's free-text row, or the
/// confirmation's Supplement row. It belongs to the form for as long as the form
/// is open, so Esc can go back to the rows and Enter can open the row again on
/// what was typed before.
const Edit = struct {
    /// The tab whose row the words are for: a question index, or `slots.len`
    /// for the confirmation's Supplement row.
    slot: usize = 0,
    /// What has been typed, as it stands.
    text: std.ArrayList(u8) = .empty,
    /// Byte offset in `text` the next character goes at. It is always on a
    /// codepoint boundary, so a two-cell character is never half-deleted.
    caret: usize = 0,
    /// A character still arriving: its bytes so far. A redraw shows what is in
    /// `text`, so half of a Chinese one is never drawn as a stray byte.
    pending: [4]u8 = undefined,
    pending_len: usize = 0,
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
    /// Where the words typed into a free-text row are kept, and where the caret
    /// in them sits. Owned here; freed by `deinit`.
    edit: Edit = .{},
    /// Whether the keyboard goes to that text rather than to the rows.
    typing: bool = false,
    /// Where drawing put the caret of that row: the real cursor is moved there,
    /// because the cell the terminal says the cursor is in is where an input
    /// method hangs its candidate window. Set by the read loop, written by
    /// `drawForm`.
    caret_report: ?*?Cell = null,
    /// What the words typed into that text are held in. The form is given the
    /// allocator of the run it belongs to; the default keeps a form built by a
    /// test that never types from having to name one.
    allocator: std.mem.Allocator = std.heap.page_allocator,

    fn deinit(self: *Form) void {
        self.edit.text.deinit(self.allocator);
        self.edit.text = .empty;
    }

    const Action = union(enum) {
        redraw,
        /// The answer typed into question `custom`'s free-text row, with the
        /// words it was answered in. Owned by whoever holds the action.
        custom: Typed,
        /// The words typed on the confirmation's Supplement row, with which the
        /// answers are sent. Owned by whoever holds the action.
        supplement: []u8,
        /// Every question is answered and the answers were submitted.
        finish,
        /// Esc: the user backed out, and the run stops with the questions.
        cancel,
        /// Ctrl+D or end of input: the form is dismissed, the run carries on.
        dismiss,
        ignore,
    };

    fn key(self: *Form, byte: u8) !Action {
        // The free-text row takes the keys it is being typed into: arrows move
        // inside the text there instead of between the rows.
        if (self.typing) return self.editKey(byte);
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

    /// One key while the free-text row has the keyboard. Enter answers with the
    /// words as they stand and Esc — the lone one the read loop sees — goes
    /// back to the options; nothing else leaves the row, so a letter that means
    /// something among the rows is just a letter here.
    fn editKey(self: *Form, byte: u8) !Action {
        if (byte == 4) return .dismiss;
        if (byte == '\r' or byte == '\n') return self.commitEdit();
        if (byte == 0x1b) {
            self.escape = .start;
            return .ignore;
        }
        if (self.escape == .start and (byte == '[' or byte == 'O')) {
            self.escape = .sequence;
            return .ignore;
        }
        if (self.escape == .sequence) {
            // A sequence this row does not know, such as Delete or Page Up,
            // ends here and leaves the text alone.
            if (byte < 0x40 or byte > 0x7e) return .ignore;
            self.escape = .none;
            switch (byte) {
                'A', 'H' => self.edit.caret = 0,
                'B', 'F' => self.edit.caret = self.edit.text.items.len,
                'C' => self.caretRight(),
                'D' => self.caretLeft(),
                else => return .ignore,
            }
            return .redraw;
        }
        self.escape = .none;
        // A key that is not a text byte ends a character that was still
        // arriving, so no half of one is left waiting for the rest.
        if (byte < 0x20 or byte == 0x7f) self.edit.pending_len = 0;
        switch (byte) {
            0x7f, 0x08 => self.deleteBack(),
            // The keys the line editor gives the same meanings to.
            0x15 => {
                self.edit.text.clearRetainingCapacity();
                self.edit.caret = 0;
            },
            0x01 => self.edit.caret = 0,
            0x05 => self.edit.caret = self.edit.text.items.len,
            // Text goes in where the caret is, a character at a time: a byte
            // that starts one is held until the last of it has come.
            0x20...0x7e, 0x80...0xff => return self.insertText(byte),
            else => return .ignore,
        }
        return .redraw;
    }

    /// Take one byte of text. Nothing is drawn until it makes a whole
    /// character: the row would otherwise show the `\xE8` of a Chinese one for
    /// as long as the terminal takes to send the rest of it.
    fn insertText(self: *Form, byte: u8) !Action {
        const edit = &self.edit;
        // A plain byte is a character of its own, and it ends whatever
        // unfinished sequence came before it.
        if (byte < 0x80) {
            edit.pending_len = 0;
            try self.insert(byte);
            return .redraw;
        }
        if (edit.pending_len == 0) {
            edit.pending[0] = byte;
            edit.pending_len = 1;
            const expected = std.unicode.utf8ByteSequenceLength(byte) catch {
                // Not the lead byte of anything: it goes in as it came, and
                // the row shows it the way any other stray byte is shown.
                edit.pending_len = 0;
                try self.insert(byte);
                return .redraw;
            };
            // Nothing has changed yet: the rest of the character is what the
            // row is waiting for.
            if (expected > 1) return .ignore;
            try self.releasePending();
            return .redraw;
        }
        edit.pending[edit.pending_len] = byte;
        edit.pending_len += 1;
        const expected = std.unicode.utf8ByteSequenceLength(edit.pending[0]) catch {
            // The first byte held settled this, so it cannot fail here; the
            // bytes go in rather than being lost if it ever does.
            try self.releasePending();
            return .redraw;
        };
        if (edit.pending_len < expected) return .ignore;
        try self.releasePending();
        return .redraw;
    }

    /// Hand the bytes of a character that has fully arrived to the text.
    fn releasePending(self: *Form) !void {
        for (self.edit.pending[0..self.edit.pending_len]) |held| try self.insert(held);
        self.edit.pending_len = 0;
    }

    /// Put one byte of text where the caret is and step over it.
    fn insert(self: *Form, byte: u8) !void {
        try self.edit.text.insert(self.allocator, self.edit.caret, byte);
        self.edit.caret += 1;
    }

    /// The offset the character before `offset` starts at.
    fn codepointStart(self: *const Form, offset: usize) usize {
        var i = @min(offset, self.edit.text.items.len);
        if (i == 0) return 0;
        i -= 1;
        while (i > 0 and (self.edit.text.items[i] & 0xc0) == 0x80) i -= 1;
        return i;
    }

    fn caretLeft(self: *Form) void {
        self.edit.caret = self.codepointStart(self.edit.caret);
    }

    fn caretRight(self: *Form) void {
        const items = self.edit.text.items;
        if (self.edit.caret >= items.len) return;
        var i = self.edit.caret + 1;
        while (i < items.len and (items[i] & 0xc0) == 0x80) i += 1;
        self.edit.caret = i;
    }

    /// Backspace: the character before the caret goes whole, rather than a byte
    /// of a Chinese one.
    fn deleteBack(self: *Form) void {
        if (self.edit.caret == 0) return;
        const start = self.codepointStart(self.edit.caret);
        self.edit.text.replaceRangeAssumeCapacity(start, self.edit.caret - start, &.{});
        self.edit.caret = start;
    }

    /// Enter on a row that takes words of the user's own: the keys go to that
    /// text from now on, and the answer is given there rather than on a line
    /// read below the form.
    fn openEdit(self: *Form) void {
        // Words typed for one question do not answer the next one.
        if (self.edit.slot != self.focus) {
            self.edit.text.clearRetainingCapacity();
            self.edit.caret = 0;
        }
        self.edit.slot = self.focus;
        self.edit.caret = @min(self.edit.caret, self.edit.text.items.len);
        self.typing = true;
    }

    /// Esc in that row: back to the rows, with the words kept for another try
    /// at them. The keyboard lands on the recommendation — Submit, on the
    /// confirmation — rather than on the row that asks for words again, so
    /// Enter after Esc answers the question or submits the form instead of
    /// reopening the text.
    fn closeEdit(self: *Form) void {
        self.typing = false;
        self.edit.pending_len = 0;
        self.escape = .none;
        const slot = self.focused();
        slot.selected = recommendedIndex(slot.options) orelse 0;
    }

    /// Enter in a row being typed into: the words as they stand are the answer.
    /// On a question the form is left as it is for any other answer, which is
    /// the caller drawing it again and landing on the next question still
    /// without one; on the confirmation the words go with the answers, so the
    /// form is done once they are given.
    fn commitEdit(self: *Form) !Action {
        // An empty row is no answer at all: Enter there stays where it is
        // rather than answering with nothing.
        if (self.edit.text.items.len == 0) return .ignore;
        const text = try self.edit.text.toOwnedSlice(self.allocator);
        self.edit.text = .empty;
        self.edit.caret = 0;
        self.edit.pending_len = 0;
        self.typing = false;
        self.escape = .none;
        if (self.onConfirm()) return .{ .supplement = text };
        const index = self.focus;
        const slot = self.focused();
        slot.custom = text;
        slot.selected = slot.options.len;
        slot.answered = true;
        return .{ .custom = .{ .index = index, .text = text } };
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
    /// the confirmation, where Enter on Submit sends the answers.
    fn confirm(self: *Form) Action {
        const slot = self.focused();
        if (self.editRow()) |row| {
            if (slot.selected == row) {
                // Enter on a row that takes the user's own words hands the keys
                // to that row: the words are typed where they will be shown,
                // not read on a line below the form.
                self.openEdit();
                return .redraw;
            }
        }
        if (self.onConfirm()) {
            // Submit sends the answers as they stand; the words that go with
            // them are typed into the Supplement row itself.
            return .finish;
        }
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
    /// only its own two rows, the second of which takes the user's own words.
    fn freeText(self: *const Form) bool {
        return self.allow_custom and !self.onConfirm();
    }

    /// The row of the focused tab that is typed into: a question's free-text
    /// row, which closes its options, or the confirmation's Supplement row.
    /// Null when the tab takes no words of the user's own.
    fn editRow(self: *const Form) ?usize {
        if (self.onConfirm()) return supplement_row;
        return if (self.allow_custom) self.focusedSlot().options.len else null;
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

/// One styled run of a row: `style` is the SGR written before `text`, and the
/// row resets the terminal at the end of every line it draws. Rows are built
/// from these instead of hand-made escape strings so that styling survives
/// wrapping, and so that only the styles named in this file reach the terminal.
const Span = struct {
    style: []const u8 = "",
    text: []const u8 = "",
};

/// A cell of the drawn form: the line it is on, counted from the form's first
/// line, and the column in it. Both are 0-based, which is what the terminal
/// needs to put the real cursor there.
const Cell = struct {
    line: usize = 0,
    column: usize = 0,
};

/// What one row came to: the terminal lines it took, and whether it had more
/// text than the lines it was allowed to take. `mark` is the cell the row was
/// asked to report, when it was drawn at all.
const Row = struct {
    lines: usize = 1,
    clipped: bool = false,
    mark: ?Cell = null,
};

/// Write one logical row, wrapped onto as many lines as its text needs, and
/// answer how many terminal lines it took.
///
/// A long question, option label or description continues on the next line,
/// indented by `indent` spaces so that it lines up under the row's own text
/// instead of under its marker. Text is sanitized as it is written, so a run
/// may be model text as it arrives: controls are flattened and every sequence
/// that is not one of ours is dropped, which keeps cursor movement exact even
/// with Chinese labels and a narrow terminal.
///
/// `max_lines` bounds the height a row may take, and a row that is still not
/// done when the lines run out ends with an ellipsis: pushing the rows below it
/// out of the form would hide what the keys act on.
fn writeRow(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    spans: []const Span,
    columns: usize,
    indent: usize,
    max_lines: usize,
) !Row {
    return writeRowMarked(w, allocator, spans, columns, indent, max_lines, null);
}

/// `writeRow`, also saying where the first cell of span `mark_span` was drawn.
/// The row being typed into needs the real cursor on its caret, because the
/// cell the terminal thinks the cursor is in is where an input method puts its
/// candidate window.
fn writeRowMarked(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    spans: []const Span,
    columns: usize,
    indent: usize,
    max_lines: usize,
    mark_span: ?usize,
) !Row {
    // The rightmost cell stays empty: a line that fills the terminal leaves it
    // in the pending-wrap state, where the following newline moves down two
    // rows on several emulators.
    const limit = columns -| 1;
    const continuation = @min(indent, limit -| 1);
    var lines: usize = 1;
    var col: usize = 0;
    var style: []const u8 = "";
    var clipped = false;
    var mark: ?Cell = null;
    var clean: std.Io.Writer.Allocating = .init(allocator);
    defer clean.deinit();
    if (limit == 0) {
        // A terminal this narrow has no room for text, and drawing it anyway
        // would wrap the form into rows it never counted.
        try w.writeAll(RESET ++ sgr.ERASE_LINE_END ++ "\r\n");
        return .{};
    }

    outer: for (spans, 0..) |span, index| {
        if (span.text.len == 0) continue;
        clean.clearRetainingCapacity();
        try sanitize.writeSanitized(&clean.writer, span.text);
        for (clean.written()) |*byte| {
            if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') byte.* = ' ';
        }
        // A run with no style of its own ends the one before it, so a plain
        // sentence after a bold label does not come out bold.
        if (!std.mem.eql(u8, span.style, style)) {
            try w.writeAll(if (span.style.len > 0) span.style else RESET);
            style = span.style;
        }
        var rest: []const u8 = clean.written();
        var started = false;
        while (rest.len > 0) {
            // A codepoint wider than the whole line fits nowhere: the row ends
            // here rather than drawing past the terminal's edge.
            if (term.codepointWidth(term.decodeAt(rest, 0)) > limit) {
                clipped = true;
                break :outer;
            }
            const room = limit -| col;
            const take = term.takeFit(rest, room);
            // A wide codepoint with only one cell left is wrapped to the next
            // line rather than overflowing into the row below it.
            const fits = col == 0 or term.width(rest[0..take]) <= room;
            if (fits) {
                var chunk: []const u8 = rest[0..take];
                var next: []const u8 = rest[take..];
                // Break between words when the line has a space to break at,
                // so Latin text wraps the way it reads; Chinese and long paths
                // break wherever the line ends.
                if (next.len > 0) {
                    if (std.mem.lastIndexOfScalar(u8, chunk, ' ')) |space| {
                        if (space > 0) {
                            chunk = rest[0..space];
                            next = rest[space..];
                        }
                    }
                    // Spaces the line was broken at leave nothing behind: they
                    // are trailing blanks, and the next line is indented.
                    chunk = std.mem.trimEnd(u8, chunk, " ");
                }
                // Where the marked run starts is the cell it was asked for,
                // after the row has wrapped to get there.
                if (!started and mark == null) {
                    if (mark_span) |asked| {
                        if (asked == index) mark = .{ .line = lines - 1, .column = col };
                    }
                }
                started = true;
                try w.writeAll(chunk);
                col += term.width(chunk);
                rest = next;
                if (rest.len == 0) break;
            }
            if (lines == max_lines) {
                clipped = true;
                break :outer;
            }
            try w.writeAll(RESET ++ sgr.ERASE_LINE_END ++ "\r\n");
            lines += 1;
            col = continuation;
            for (0..continuation) |_| try w.writeByte(' ');
            if (style.len > 0) try w.writeAll(style);
            // The space the line was broken at does not start the next one.
            while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        }
    }
    if (clipped and col < limit) try w.writeAll("…");
    try w.writeAll(RESET ++ sgr.ERASE_LINE_END ++ "\r\n");
    return .{ .lines = lines, .clipped = clipped, .mark = mark };
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

/// The answer typed into a question's free-text row: where it goes, and the
/// words it was answered in. The words are owned by whoever holds this.
pub const Typed = struct {
    /// Index of the question the free-text row belongs to.
    index: usize,
    text: []u8,
};

/// What the form came to.
pub const Outcome = union(enum) {
    /// Every question has an answer: read `Slot.answer` for each one.
    answered,
    /// The user typed the answer to question `index` into the free-text row
    /// itself. The words are owned here: store them on that slot, and draw the
    /// form again.
    custom: Typed,
    /// The words typed into the confirmation's Supplement row, to send with the
    /// answers. Owned here: `resolve` takes them as the replies' note.
    supplement: []u8,
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

/// The rows the form needs to draw every tab in full at `columns`: the strip,
/// the question, all of its rows as they wrap, and the hint.
///
/// `formRows` counts rows, not lines, and is the floor a form asks for; this is
/// what it asks for when the text does not fit a line. The dock gives what the
/// screen can spare, and a form that has less than this draws what does fit.
fn naturalRows(allocator: std.mem.Allocator, state: *Form, columns: usize) !usize {
    const focus = state.focus;
    defer state.focus = focus;
    var probe: std.Io.Writer.Allocating = .init(allocator);
    defer probe.deinit();
    var tallest: usize = 0;
    for (0..state.tabs()) |tab| {
        state.focus = tab;
        probe.clearRetainingCapacity();
        const body = try drawBody(allocator, &probe.writer, state, columns, no_limit, state.tabs() > 1, true, visible_window, no_limit);
        tallest = @max(tallest, body.lines);
    }
    return @as(usize, @intFromBool(state.tabs() > 1)) + tallest;
}

/// A height that bounds nothing, for the pass that measures how tall a form is
/// before the space it will be drawn in is known.
const no_limit: usize = 1_000;

/// Put one or more questions to the user and let the form own the keyboard
/// until every question is answered or the form is dismissed. Draw on stderr so
/// redirected stdout receives no cursor control sequences.
///
/// The questions of one message are drawn together: Tab and Shift+Tab move
/// between them, so an answer given to a question further up can still be
/// changed before the form is submitted. Enter on the free-text row types the
/// answer into that row, where it will be shown: the form takes the keys until
/// the words are given or Esc goes back to the options.
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
    var state = Form{ .slots = slots, .allow_custom = allow_custom, .confirm_tab = confirm_tab, .allocator = allocator };
    // The words typed into a free-text row live in the form until they are
    // answered with; a form left half-typed frees them here.
    defer state.deinit();
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
    // The line of the last form the real cursor was left on, or null when it
    // was left below the form with no caret to sit on.
    var caret_line: ?usize = null;
    // Where drawing put the caret of a row being typed into. The real cursor is
    // moved there: an input method puts its candidate window where the terminal
    // says the cursor is, and a hidden cursor leaves it nowhere to go.
    var caret_cell: ?Cell = null;
    state.caret_report = &caret_cell;
    // The height the dock was asked for last. It is carried from one redraw to
    // the next: the floor is only what tells the form the width it draws at.
    var reserved: usize = formRows(slots, allow_custom, confirm_tab);
    while (true) {
        aw.clearRetainingCapacity();
        if (dock) |target| {
            const view = try reserveDock(allocator, &state, target, &reserved);
            try aw.writer.writeAll(sgr.SYNC_BEGIN ++ sgr.HIDE_CURSOR);
            try drawDocked(allocator, &aw.writer, &state, view);
            // The screen's own cursor is restored first, so the caret the form
            // reports is what is left showing.
            try aw.writer.writeAll(sgr.RESTORE_CURSOR);
            if (caret_cell) |cell| {
                if (cell.line < view.height) {
                    try aw.writer.print(sgr.CURSOR_POSITION ++ sgr.SHOW_CURSOR, .{ view.top + cell.line, cell.column + 1 });
                }
            }
            try aw.writer.writeAll(sgr.SYNC_END);
        } else {
            if (drawn > 0) {
                // The cursor may have been left on the caret rather than below
                // the form, so it is put back there before the redraw starts.
                if (caret_line) |line| try moveBelowForm(&aw.writer, drawn, line);
                try aw.writer.print(sgr.CURSOR_UP ++ "\r", .{drawn});
            }
            const columns = term.columns(out);
            const wanted = @max(formRows(slots, allow_custom, confirm_tab), try naturalRows(allocator, &state, columns));
            // Without a screen to scroll in, a form taller than the window would
            // push its own first rows out of reach of the redraw.
            const rows = try drawForm(allocator, &aw.writer, &state, columns, @min(wanted, term.rows(out)));
            // Clear the tail of a taller standalone form.
            if (drawn > rows) {
                for (0..drawn - rows) |_| try aw.writer.writeAll(sgr.ERASE_LINE_END ++ "\r\n");
                try aw.writer.print(sgr.CURSOR_UP ++ "\r", .{drawn - rows});
            }
            drawn = rows;
            // The drawing ends one line below the form, in the first column.
            caret_line = null;
            if (caret_cell) |cell| {
                if (cell.line < rows) {
                    try showCaret(&aw.writer, rows, cell);
                    caret_line = cell.line;
                }
            }
            if (caret_line == null) try aw.writer.writeAll(sgr.HIDE_CURSOR);
        }
        try out.writeStreamingAll(io, aw.written());

        while (true) {
            // Poll only in screen mode so resize and queued panel updates are
            // serviced even when the user has not pressed another key.
            if (dock != null and !try raw.waitReadable(io, 100)) break;
            const byte = try raw.readByte() orelse return .dismiss;
            // Esc opens a sequence only when more bytes follow; on its own it
            // goes back to the options from the free-text row and cancels the
            // questions anywhere else, where the run stops with them, as Esc at
            // the prompt stops a task.
            if (byte == 0x1b and !try raw.waitReadable(io, escape_timeout_ms)) {
                if (state.typing) {
                    state.closeEdit();
                    break;
                }
                return .cancel;
            }
            switch (try state.key(byte)) {
                .finish => return .answered,
                .custom => |typed| return .{ .custom = typed },
                .supplement => |text| return .{ .supplement = text },
                .cancel => return .cancel,
                .dismiss => return .dismiss,
                .redraw => break,
                .ignore => {},
            }
        }
    }
}

/// Write the moves that put the real cursor on `cell` of a form `rows` lines
/// tall, from the line below it where drawing ends, and show it.
///
/// The cursor has to be the real one: it is the cell the terminal reports, and
/// an input method puts its candidate window beside it. A hidden cursor leaves
/// the candidate window nowhere to go.
fn showCaret(w: *std.Io.Writer, rows: usize, cell: Cell) !void {
    // A count of zero is a move of one for these sequences, so neither is
    // emitted unless it moves the cursor.
    const up = rows -| cell.line;
    if (up > 0) try w.print(sgr.CURSOR_UP, .{up});
    if (cell.column > 0) try w.print(sgr.CURSOR_RIGHT, .{cell.column});
    try w.writeAll(sgr.SHOW_CURSOR);
}

/// Write the moves that take the cursor from the caret it was left on, on line
/// `caret_line`, back to the line below the form: what a redraw of `drawn`
/// lines starts from.
fn moveBelowForm(w: *std.Io.Writer, drawn: usize, caret_line: usize) !void {
    const down = drawn -| caret_line;
    if (down > 0) try w.print(sgr.CURSOR_DOWN, .{down});
}

/// Reserve the dock for one redraw and answer the view the form is drawn in.
///
/// The first request is what tells the form the width it will be drawn at, so
/// the rows the wrapped text takes can be measured; the dock is then asked for
/// those rows, if they are not the ones it was asked for already. It gives what
/// the screen can spare, and the form draws what fits in that.
///
/// `reserved` carries the height asked for from one redraw to the next. Asking
/// for the floor first on every redraw would make a dock that cannot grant the
/// wrapped height swap between the two requests on each poll, and the screen
/// repaints itself for every request it answers: a form far taller than the
/// terminal would flicker for as long as it was open.
fn reserveDock(allocator: std.mem.Allocator, state: *Form, dock: Dock, reserved: *usize) !Viewport {
    var view = try dock.prepare(dock.context, reserved.*);
    const natural = try naturalRows(allocator, state, view.columns);
    if (natural != reserved.*) {
        reserved.* = natural;
        view = try dock.prepare(dock.context, natural);
    }
    return view;
}

/// Draw a form and take the keys until it is settled. Both the plain terminal
/// and the full-screen runtime hand in their own, so a form is answered the same
/// way in either.
pub const Reader = struct {
    context: *anyopaque,
    /// Put `slots` to the user with the keyboard on `focus` first — a question
    /// index, `slots.len` for the confirmation, or null when the form should
    /// start on the first unanswered question — and take the keys until one
    /// question is acted on.
    present: *const fn (*anyopaque, []Slot, ?usize) anyerror!Outcome,
};

/// Answer the questions of one form. Every word the user types arrives with the
/// outcome, already the user's own: an answer given in a question's free-text
/// row, and the supplement the confirmation takes. The questions stay open until
/// every one is answered or the form is left.
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

    while (true) {
        switch (try reader.present(reader.context, slots, focus)) {
            // Submit, from the last tab: the answers as they stand.
            .answered => return submitted(allocator, slots, &note),
            // Supplement, from the same tab: the words typed into that row go
            // with the answers rather than answering a question of their own.
            .supplement => |text| {
                if (note) |old| allocator.free(old);
                note = text;
                return submitted(allocator, slots, &note);
            },
            // The words typed into question `index`'s free-text row, which the
            // form hands back with the answer instead of asking for them twice.
            .custom => |answer| {
                typed.append(allocator, answer.text) catch |err| {
                    allocator.free(answer.text);
                    return err;
                };
                const slot = &slots[answer.index];
                slot.custom = answer.text;
                slot.selected = slot.options.len;
                slot.answered = true;
                // The form is drawn again, landing on the next question still
                // without an answer, or on the confirmation.
                focus = null;
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
///
/// Rows wrap, so a row can be taller than one line and the answer rows may not
/// all fit the space the form was given. The tab strip and the hint are
/// reserved first; the question and its rows are then drawn into a buffer, and
/// drawn again with one fewer option row while the row the keys act on is cut
/// short. That row is drawn whole whenever the space allows it, and a
/// neighbour that does not fit is clipped around it.
fn drawForm(allocator: std.mem.Allocator, w: *std.Io.Writer, state: *const Form, columns: usize, height: usize) !usize {
    if (state.caret_report) |report| report.* = null;
    if (height == 0) return 0;
    const show_tabs = state.tabs() > 1 and height >= 4;
    const show_help = height >= 3;
    const chrome: usize = @as(usize, @intFromBool(show_tabs)) + @intFromBool(show_help);
    // What the question and its rows share: everything but the strip and the
    // hint.
    const body_height = height -| chrome;
    // The question takes the lines its text needs, measured rather than guessed,
    // but never the ones the answers are given in: two of those always stay,
    // however long the question is.
    var probe: std.Io.Writer.Allocating = .init(allocator);
    defer probe.deinit();
    const header_natural = (try drawHeader(allocator, &probe.writer, state, columns, no_limit)).lines;
    const header_lines = @min(header_natural, @max(@as(usize, 1), body_height -| 2));
    const count = state.focusedSlot().rowCount(state.freeText());

    var visible = @min(count, visible_window);
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    var rows: usize = 0;
    var caret: ?Cell = null;
    while (true) {
        content.clearRetainingCapacity();
        const body = try drawBody(allocator, &content.writer, state, columns, body_height, show_tabs, show_help, visible, header_lines);
        rows = body.lines;
        caret = body.caret;
        if (!body.focused_cut or visible <= 1) break;
        visible -= 1;
    }

    var drawn: usize = 0;
    if (show_tabs) {
        try drawTabs(allocator, w, state, columns);
        drawn += 1;
    }
    try w.writeAll(content.written());
    // The caret counts from the form's first line, so the strip above the body
    // moves it down.
    if (state.caret_report) |report| {
        report.* = if (caret) |cell| .{ .line = cell.line + drawn, .column = cell.column } else null;
    }
    return drawn + rows;
}

/// What drawing the body came to.
const Body = struct {
    lines: usize,
    /// The row the keys act on was cut short or left out because the space ran
    /// out: one fewer option row would draw it whole.
    focused_cut: bool = false,
    /// Where the caret of the row being typed into was drawn, when that row was
    /// drawn at all: the real cursor belongs there.
    caret: ?Cell = null,
};

/// The question of the focused tab, its number in the form, and — once it has
/// an answer — what the answer was: the question carries the row's weight, the
/// answer that follows it is dimmed, and the lines the question wraps onto sit
/// under it, past the "1/2 " mark.
fn drawHeader(allocator: std.mem.Allocator, w: *std.Io.Writer, state: *const Form, columns: usize, max_lines: usize) !Row {
    const slot = state.focusedSlot().*;
    var prefix: std.Io.Writer.Allocating = .init(allocator);
    defer prefix.deinit();
    try prefix.writer.writeAll("  ");
    if (state.slots.len > 1 and !state.onConfirm()) try prefix.writer.print("{d}/{d} ", .{ state.focus + 1, state.slots.len });
    var answer: std.Io.Writer.Allocating = .init(allocator);
    defer answer.deinit();
    if (slot.answered) {
        if (slot.custom) |text|
            try answer.writer.print("  → {s}", .{text})
        else if (slot.options.len > 0)
            try answer.writer.print("  → {s}", .{slot.options[@min(slot.selected, slot.options.len - 1)].label});
    }
    const spans = [_]Span{
        .{ .text = prefix.written() },
        .{ .style = BOLD, .text = slot.text },
        .{ .style = DIM, .text = answer.written() },
    };
    return writeRow(w, allocator, &spans, columns, term.width(prefix.written()), max_lines);
}

/// The focused question, the answer rows it offers, and the hint that names the
/// keys: everything below the tab strip. `height` is the space the question and
/// its rows share and no more than that is drawn from it; the strip is drawn by
/// the caller and the hint comes on top of `height`, which is why the caller
/// keeps a row for it.
fn drawBody(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    state: *const Form,
    columns: usize,
    height: usize,
    show_tabs: bool,
    show_help: bool,
    visible: usize,
    header_lines: usize,
) !Body {
    var rows: usize = 0;
    // Whether the row the keys act on was drawn whole: the caller gives it more
    // space by drawing one fewer row.
    var focused_cut = false;
    var focused_drawn = false;
    var caret_cell: ?Cell = null;
    const slot = state.focusedSlot().*;

    if (height >= 2) rows += (try drawHeader(allocator, w, state, columns, header_lines)).lines;

    const count = slot.rowCount(state.freeText());
    // The row the keys type into, if this tab has one: a question's free-text
    // row, or the confirmation's Supplement row.
    const editable = state.editRow();
    const shown = @min(visible, count);
    const first = @min(slot.selected -| (shown / 2), count -| shown);
    for (first..first + shown) |i| {
        // A row may take what is left: the focused row is drawn whole before
        // its neighbours get anything, and the caller shrinks the window when
        // even that is not enough.
        const remaining = height -| rows;
        if (remaining == 0) break;
        const selected = i == slot.selected;
        const marker = if (selected) sgr.BOLD_CYAN else "";
        var prefix_buf: [32]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "    {s} {d}) ", .{ if (selected) ">" else " ", i + 1 });
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        var caret: std.Io.Writer.Allocating = .init(allocator);
        defer caret.deinit();
        var after: std.Io.Writer.Allocating = .init(allocator);
        defer after.deinit();
        var caret_style: []const u8 = "";
        // The style the text after the caret is drawn in: the row's own, with
        // the caret's attribute switched off again for it.
        var style_buf: [64]u8 = undefined;
        var after_style: []const u8 = marker;
        var description: std.Io.Writer.Allocating = .init(allocator);
        defer description.deinit();
        if (state.typing and editable == i) {
            // The row being typed into: the words show where they will be
            // answered, and the caret sits in them at a cell of its own, so
            // nothing shifts as it moves. They take the place of the label and
            // its description, which is what the row asks for until then.
            const text = state.edit.text.items;
            const at = @min(state.edit.caret, text.len);
            try body.writer.writeAll(text[0..at]);
            if (at < text.len) {
                const step = term.decodeAt(text, at).len;
                try caret.writer.writeAll(text[at..][0..step]);
                try after.writer.writeAll(text[at + step ..]);
                after_style = try std.fmt.bufPrint(&style_buf, "{s}{s}", .{ sgr.NO_INVERSE, marker });
            } else try caret.writer.writeAll(" ");
            caret_style = sgr.INVERSE;
        } else if (i < slot.options.len) {
            const option = slot.options[i];
            try body.writer.writeAll(option.label);
            if (recommendedIndex(slot.options) == i) try body.writer.writeAll(" (recommended)");
            if (option.description.len > 0) try description.writer.print("  {s}", .{option.description});
        } else try body.writer.writeAll("Other / 自定义回答");

        const spans = [_]Span{
            .{ .style = marker, .text = prefix },
            .{ .style = marker, .text = body.written() },
            .{ .style = if (caret_style.len > 0) caret_style else marker, .text = caret.written() },
            .{ .style = after_style, .text = after.written() },
            .{ .style = DIM, .text = description.written() },
        };
        // A wrapped label and description line up under the label, past the
        // "   > 1) " marker that tells them apart from the question above.
        // The caret of the row being typed into is the second run after the
        // prefix: where it lands is the cell the real cursor is put on.
        const marked = state.typing and editable == i;
        const row = try writeRowMarked(w, allocator, &spans, columns, term.width(prefix), remaining, if (marked) 2 else null);
        if (row.mark) |mark| caret_cell = .{ .line = rows + mark.line, .column = mark.column };
        rows += row.lines;
        if (i == slot.selected) {
            focused_drawn = true;
            focused_cut = row.clipped;
        }
    }
    // A window too tall for the space leaves the focused row out altogether,
    // which one fewer row would draw.
    if (!focused_drawn) focused_cut = true;

    if (!show_help) return .{ .lines = rows, .focused_cut = focused_cut, .caret = caret_cell };
    var hint: std.Io.Writer.Allocating = .init(allocator);
    defer hint.deinit();
    try hint.writer.writeAll("  ");
    if (state.typing) {
        // The row owns the keys while it is typed into: what is left of them
        // is answering with the words and going back to the options.
        try hint.writer.writeAll("Enter confirm · Esc back · Ctrl+U clear");
    } else {
        if (show_tabs) try hint.writer.writeAll("Tab/Shift+Tab · ");
        try hint.writer.writeAll(if (state.onConfirm())
            "↑/↓ select · Enter submit · Esc cancel"
        else
            "↑/↓ select · Enter confirm · Esc cancel");
    }
    const spans = [_]Span{.{ .style = DIM, .text = hint.written() }};
    // The hint is one line by construction: it names keys, and a wrapped copy
    // would take a row from the answers it is explaining.
    rows += (try writeRow(w, allocator, &spans, columns, 2, 1)).lines;
    return .{ .lines = rows, .focused_cut = focused_cut, .caret = caret_cell };
}

/// A closed menu with no free-text row; defaults to the first option. The
/// ask_user questions go through `resolve` instead, because an answer typed at
/// them has to be kept until the replies are made.
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
        .custom => |answer| blk: {
            allocator.free(answer.text);
            break :blk .cancel;
        },
        // A form asked here never offers the confirmation, so no words of the
        // user's own can come back to send with the answers.
        .supplement => |text| blk: {
            allocator.free(text);
            break :blk .cancel;
        },
        .cancel, .dismiss => .cancel,
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
    for ("\x1b[A") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);
    try expectAction(.redraw, try state.key('2'));
    try std.testing.expectEqual(@as(usize, 1), slots[0].selected);
    _ = try state.key('j');
    try std.testing.expectEqual(@as(usize, 2), slots[0].selected);
    _ = try state.key('j');
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);

    // Tab goes to the next question, Shift+Tab back to the previous one.
    try expectAction(.redraw, try state.key('\t'));
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try expectAction(.redraw, try state.key('j'));
    try std.testing.expectEqual(@as(usize, 2), slots[1].selected);
    // The first question kept the selection it had when the keyboard left it.
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);
    for ("\x1b[Z") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 0), state.focus);
    // Tab wraps around, so the last question leads back to the first.
    for ("\x1b[Z") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 1), state.focus);

    // A habitual Ctrl+C leaves the form alone; Ctrl+D dismisses it.
    try expectAction(.ignore, try state.key(3));
    try expectAction(.dismiss, try state.key(4));
}

test "an answered question can be changed before the form is submitted" {
    var slots = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    var state = Form{ .slots = &slots };

    // Enter answers the focused question and moves on to the next unanswered.
    try expectAction(.redraw, try state.key('\r'));
    try std.testing.expect(slots[0].answered);
    try std.testing.expectEqual(@as(usize, 1), state.focus);

    // Shift+Tab goes back, the answer is still the one given, and it can be
    // replaced without the form forgetting the question already answered.
    for ("\x1b[Z") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 0), state.focus);
    _ = try state.key('1');
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);
    try expectAction(.redraw, try state.key('\r'));
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try std.testing.expectEqual(@as(usize, 0), slots[0].selected);

    // The last answer finishes the form.
    try expectAction(.finish, try state.key('\r'));
    try std.testing.expect(slots[1].answered);
}

test "the last answer hands the keyboard to the confirmation" {
    var slots = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    var state = Form{ .slots = &slots, .confirm_tab = true };

    // Enter answers the questions, and the last answer stops on the
    // confirmation instead of sending them off.
    _ = try state.key('\r');
    try expectAction(.redraw, try state.key('\r'));
    try std.testing.expect(slots[1].answered);
    try std.testing.expectEqual(slots.len, state.focus);
    try std.testing.expect(state.onConfirm());

    // It starts on Submit, which Enter takes; Tab and Shift+Tab still walk back
    // to the questions, whose answers are unchanged.
    try std.testing.expectEqual(@as(usize, 0), state.submit.selected);
    for ("\x1b[Z") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try expectAction(.redraw, try state.key('\t'));
    try std.testing.expectEqual(slots.len, state.focus);
    try expectAction(.finish, try state.key('\r'));
}

test "the confirmation waits until every question has an answer" {
    var slots = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    var state = Form{ .slots = &slots, .confirm_tab = true };

    // While a question is still open, Tab and Shift+Tab cycle the questions:
    // there is nothing to submit, and no answer for words of the user's own to
    // be added to. Answering in words is a question's free-text row instead.
    try expectAction(.redraw, try state.key('\t'));
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try expectAction(.redraw, try state.key('\t'));
    try std.testing.expectEqual(@as(usize, 0), state.focus);
    for ("\x1b[Z") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try std.testing.expect(!state.onConfirm());

    // The last answer hands the keyboard to the confirmation, which Tab then
    // reaches like any other tab.
    slots[0].answered = true;
    try expectAction(.redraw, try state.key('\r'));
    try std.testing.expectEqual(slots.len, state.focus);
    try std.testing.expect(state.onConfirm());
    try expectAction(.redraw, try state.key('\t'));
    try std.testing.expectEqual(@as(usize, 0), state.focus);
    try expectAction(.redraw, try state.key('\t'));
    try std.testing.expectEqual(@as(usize, 1), state.focus);
    try expectAction(.redraw, try state.key('\t'));
    try std.testing.expectEqual(slots.len, state.focus);
}

test "the confirmation offers the words to add instead of submitting" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots, .confirm_tab = true, .allocator = allocator };
    defer state.deinit();
    _ = try state.key('\r');
    try std.testing.expectEqual(@as(usize, 1), state.focus);

    // Down and the number both land on Supplement, which takes words of the
    // user's own rather than sending the answers.
    for ("\x1b[B") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 1), state.submit.selected);
    _ = try state.key('1');
    try std.testing.expectEqual(@as(usize, 0), state.submit.selected);
    // The confirmation has two rows even when the questions have a free-text
    // row: down from Submit reaches Supplement and no further.
    try expectAction(.redraw, try state.key('j'));
    _ = try state.key('j');
    try std.testing.expectEqual(@as(usize, 0), state.submit.selected);

    // Enter on Supplement types into that row, where the words are shown: the
    // form is not sent off until there are words to send it with.
    _ = try state.key('j');
    try expectAction(.redraw, try state.key('\r'));
    try std.testing.expect(state.typing);
    try expectAction(.ignore, try state.key('\r'));
    for ("and mind the tests") |byte| try expectAction(.redraw, try state.key(byte));
    const action = try state.key('\r');
    try expectAction(.supplement, action);
    const words = switch (action) {
        .supplement => |text| text,
        else => unreachable,
    };
    defer allocator.free(words);
    try std.testing.expectEqualStrings("and mind the tests", words);
    try std.testing.expect(!state.typing);
}

test "Esc in the confirmation's own row keeps the words and lands on Submit" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots, .confirm_tab = true, .allocator = allocator };
    defer state.deinit();
    _ = try state.key('\r');
    _ = try state.key('2');
    try std.testing.expectEqual(@as(usize, 1), state.submit.selected);
    try expectAction(.redraw, try state.key('\r'));

    for ("draft") |byte| _ = try state.key(byte);
    try std.testing.expectEqualStrings("draft", state.edit.text.items);
    // Esc goes back to the confirmation's rows, with the words kept and the
    // keyboard on Submit: Enter then sends the answers as they stand.
    state.closeEdit();
    try std.testing.expect(!state.typing);
    try std.testing.expectEqual(@as(usize, 0), state.submit.selected);
    try expectAction(.finish, try state.key('\r'));
    // The row opens again on the words it kept.
    _ = try state.key('2');
    try expectAction(.redraw, try state.key('\r'));
    try std.testing.expectEqualStrings("draft", state.edit.text.items);
    try std.testing.expectEqual(@as(usize, 5), state.edit.caret);
}

test "the confirmation's Supplement row draws the words where they are typed" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    slots[0].answered = true;
    var state = Form{ .slots = &slots, .confirm_tab = true, .focus = 1, .allocator = allocator };
    defer state.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    // Before Enter the row says what it is for.
    _ = try drawForm(allocator, &aw.writer, &state, 100, 20);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "2) Supplement") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Type your own words to add") != null);

    // The words take the place of the label and its description, and the hint
    // names the keys that are left.
    _ = try state.key('2');
    try expectAction(.redraw, try state.key('\r'));
    for ("再看一眼测试") |byte| _ = try state.key(byte);
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 100, 20);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "2) 再看一眼测试" ++ sgr.INVERSE ++ " ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Supplement") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Type your own words to add") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Enter confirm · Esc back · Ctrl+U clear") != null);
}

test "Enter on the free-text row types in place, and Esc goes back to it" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots, .allocator = allocator };
    defer state.deinit();

    // Two options plus the free-text row, which is row 3.
    _ = try state.key('3');
    try std.testing.expectEqual(@as(usize, 2), slots[0].selected);
    // Enter on that row takes the keys into it rather than asking for a line
    // below the form.
    try expectAction(.redraw, try state.key('\r'));
    try std.testing.expect(state.typing);
    // Nothing is answered until there are words to answer with.
    try expectAction(.ignore, try state.key('\r'));
    try std.testing.expect(!slots[0].answered);

    for ("ok") |byte| try expectAction(.redraw, try state.key(byte));
    try std.testing.expectEqualStrings("ok", state.edit.text.items);
    try std.testing.expectEqual(@as(usize, 2), state.edit.caret);

    // Enter again answers the question with the words as they stand, handed to
    // the caller with the outcome.
    const action = try state.key('\r');
    try expectAction(.custom, action);
    const answer = switch (action) {
        .custom => |typed| typed,
        else => unreachable,
    };
    defer allocator.free(answer.text);
    try std.testing.expectEqual(@as(usize, 0), answer.index);
    try std.testing.expectEqualStrings("ok", answer.text);
    try std.testing.expect(slots[0].answered);
    try std.testing.expectEqualStrings("ok", slots[0].custom.?);
    try std.testing.expect(!state.typing);
}

test "the free-text row edits Chinese text, its caret and its draft" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots, .allocator = allocator };
    defer state.deinit();
    _ = try state.key('3');
    try expectAction(.redraw, try state.key('\r'));

    // A Chinese character arrives as its bytes and is one character to the
    // caret, so Backspace removes all of it and no half of it is left behind.
    for ("中文") |byte| _ = try state.key(byte);
    try std.testing.expectEqualStrings("中文", state.edit.text.items);
    try expectAction(.redraw, try state.key(0x7f));
    try std.testing.expectEqualStrings("中", state.edit.text.items);
    try std.testing.expectEqual(@as(usize, 3), state.edit.caret);

    // Left and Right walk codepoints, and text goes in where the caret is.
    for ("\x1b[D") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 0), state.edit.caret);
    for ("\x1b[C") |byte| _ = try state.key(byte);
    try std.testing.expectEqual(@as(usize, 3), state.edit.caret);
    for ("\x1b[D") |byte| _ = try state.key(byte);
    for ("ab") |byte| _ = try state.key(byte);
    try std.testing.expectEqualStrings("ab中", state.edit.text.items);
    // Back over the "b" and a character typed there lands between them.
    for ("\x1b[D") |byte| _ = try state.key(byte);
    for ("X") |byte| _ = try state.key(byte);
    try std.testing.expectEqualStrings("aXb中", state.edit.text.items);

    // Esc — the lone one the read loop closes the row with — goes back to the
    // options and keeps the words, which the row opens on again.
    state.closeEdit();
    try std.testing.expect(!state.typing);
    try std.testing.expectEqualStrings("aXb中", state.edit.text.items);
    // The keyboard lands on the recommendation rather than on the row that
    // would ask for the same words again.
    try std.testing.expectEqual(@as(usize, 1), slots[0].selected);
    // The rows, not the text, take the keys again.
    try expectAction(.redraw, try state.key('1'));
    try std.testing.expectEqualStrings("aXb中", state.edit.text.items);
    _ = try state.key('3');
    try expectAction(.redraw, try state.key('\r'));
    try std.testing.expectEqualStrings("aXb中", state.edit.text.items);

    // Tab-ing to another question leaves that draft behind rather than
    // answering the new question with it.
    var two = [_]Slot{ Slot.init("First?", &two_options_a), Slot.init("Second?", &two_options_b) };
    var other = Form{ .slots = &two, .allocator = allocator };
    defer other.deinit();
    _ = try other.key('3');
    _ = try other.key('\r');
    for ("draft") |byte| _ = try other.key(byte);
    other.closeEdit();
    _ = try other.key('\t');
    _ = try other.key('3');
    _ = try other.key('\r');
    try std.testing.expectEqualStrings("", other.edit.text.items);
}

test "a typed answer is the slot's answer until an option replaces it" {
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    slots[0].custom = "my own words";
    slots[0].answered = true;
    try std.testing.expectEqualStrings("my own words", slots[0].answer().custom);

    // Choosing an option row again drops the typed answer.
    var state = Form{ .slots = &slots };
    _ = try state.key('1');
    _ = try state.key('\r');
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
    // The question carries the row's weight, and the answer that follows it is
    // dimmed: the row is no longer one undifferentiated string.
    try std.testing.expect(std.mem.indexOf(u8, text, "1/2 " ++ BOLD ++ "First question?") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "First question?" ++ DIM ++ "  → Beta") != null);
}

test "the real cursor is moved onto the caret and back below the form" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Drawing ends one line below a six-line form, so a caret on its last line
    // is one line up, and one on its first is six.
    try showCaret(&aw.writer, 6, .{ .line = 5, .column = 0 });
    try std.testing.expectEqualStrings("\x1b[1A" ++ sgr.SHOW_CURSOR, aw.written());
    aw.clearRetainingCapacity();
    try showCaret(&aw.writer, 6, .{ .line = 0, .column = 12 });
    try std.testing.expectEqualStrings("\x1b[6A\x1b[12C" ++ sgr.SHOW_CURSOR, aw.written());

    // From that caret back to the line below the form, which is where the next
    // redraw counts its own lines from.
    aw.clearRetainingCapacity();
    try moveBelowForm(&aw.writer, 6, 0);
    try std.testing.expectEqualStrings("\x1b[6B", aw.written());
    aw.clearRetainingCapacity();
    try moveBelowForm(&aw.writer, 6, 5);
    try std.testing.expectEqualStrings("\x1b[1B", aw.written());
    // The two cancel out, which is what keeps the redraw in place.
    aw.clearRetainingCapacity();
    try moveBelowForm(&aw.writer, 6, 3);
    try showCaret(&aw.writer, 6, .{ .line = 3, .column = 0 });
    try std.testing.expectEqualStrings("\x1b[3B\x1b[3A" ++ sgr.SHOW_CURSOR, aw.written());
}

test "the cell the caret is drawn in is reported for the real cursor" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots, .allocator = allocator };
    defer state.deinit();
    var caret: ?Cell = null;
    state.caret_report = &caret;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Nothing to type: no cell to put the real cursor on, so it stays hidden.
    _ = try state.key('3');
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    try std.testing.expectEqual(@as(?Cell, null), caret);

    // Typing in the row: the cell is on the row's line, past "    > 3) " and
    // the words before the caret.
    _ = try state.key('\r');
    for ("ab") |byte| _ = try state.key(byte);
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    // Question, two options, then the row being typed into, all one line each.
    try std.testing.expectEqual(@as(usize, 3), caret.?.line);
    try std.testing.expectEqual(term.width("    > 3) ab"), caret.?.column);

    // The caret after a word that wrapped moves down with it, which is what
    // keeps the cursor — and the candidate window behind it — on the caret.
    const narrow = 20;
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, narrow, 40);
    var lines = std.mem.splitSequence(u8, aw.written(), "\r\n");
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index != caret.?.line) continue;
        // The caret's cell is the one the terminal is told about: the column of
        // the inverted character counted in cells.
        const before = line[0..std.mem.indexOf(u8, line, sgr.INVERSE).?];
        try std.testing.expectEqual(term.width(before), caret.?.column);
    }
    // Back to the options: nothing is being typed into, so nothing is reported.
    state.closeEdit();
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    try std.testing.expectEqual(@as(?Cell, null), caret);
}

test "the free-text row is drawn as it is typed into, with the caret in it" {
    const allocator = std.testing.allocator;
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    var state = Form{ .slots = &slots, .allocator = allocator };
    defer state.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Before Enter the row is the label the form offers.
    _ = try state.key('3');
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Other / 自定义回答") != null);

    // Typing happens in that row: the words take the label's place, the caret
    // is a cell of its own, and the hint names the keys that are left.
    _ = try state.key('\r');
    for ("自己的答案") |byte| _ = try state.key(byte);
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "Other / 自定义回答") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3) 自己的答案" ++ sgr.INVERSE ++ " ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Enter confirm · Esc back · Ctrl+U clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "↑/↓ select") == null);

    // Half a Chinese character is not drawn: the bytes of one are held until
    // the last of them has come, so the row does not flicker with a stray byte
    // between one keypress and the next.
    aw.clearRetainingCapacity();
    for ("\xe4") |byte| _ = try state.key(byte);
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "3) 自己的答案" ++ sgr.INVERSE ++ " ") != null);
    for ("\xb8") |byte| _ = try state.key(byte);
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\\x") == null);

    // A caret inside the words marks the character it goes before, so the text
    // does not shift as it moves.
    for ("\x1b[D\x1b[D") |byte| _ = try state.key(byte);
    aw.clearRetainingCapacity();
    _ = try drawForm(allocator, &aw.writer, &state, 80, 20);
    // The character under the caret is drawn inverted, and the ones after it
    // are not: the attribute is switched off again for them.
    try std.testing.expect(std.mem.indexOf(
        u8,
        aw.written(),
        "3) 自己的" ++ sgr.INVERSE ++ "答" ++ sgr.NO_INVERSE ++ sgr.BOLD_CYAN ++ "案",
    ) != null);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "  " ++ BOLD ++ "Confirm") != null);
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
    _ = try state.key('\t');
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

test "menu rows wrap CJK text and flatten model control characters" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Nothing is cut off at the right edge: a row that does not fit carries on
    // the next line, indented under its own text.
    const plain = [_]Span{.{ .text = "你好世界" }};
    const two = try writeRow(&aw.writer, allocator, &plain, 7, 2, 4);
    try std.testing.expectEqual(@as(usize, 2), two.lines);
    try std.testing.expect(!two.clipped);
    try std.testing.expectEqualStrings(
        "你好世" ++ RESET ++ "\x1b[K\r\n" ++ "  界" ++ RESET ++ "\x1b[K\r\n",
        aw.written(),
    );

    // Controls and escapes in model text are flattened rather than drawn, so a
    // row may carry what a model wrote without moving the cursor.
    aw.clearRetainingCapacity();
    const controls = [_]Span{.{ .text = "你\n好\x1b[2J世界" }};
    const flattened = try writeRow(&aw.writer, allocator, &controls, 80, 2, 4);
    try std.testing.expectEqual(@as(usize, 1), flattened.lines);
    try std.testing.expectEqualStrings("你 好世界" ++ RESET ++ "\x1b[K\r\n", aw.written());

    // A row that runs out of the lines it may take says so with an ellipsis,
    // instead of silently losing its tail.
    aw.clearRetainingCapacity();
    const long = [_]Span{.{ .text = "你好世界你好" }};
    const clipped = try writeRow(&aw.writer, allocator, &long, 12, 0, 1);
    try std.testing.expectEqual(@as(usize, 1), clipped.lines);
    try std.testing.expect(clipped.clipped);
    try std.testing.expectEqualStrings("你好世界你…" ++ RESET ++ "\x1b[K\r\n", aw.written());
}

test "a wrapped row breaks between words and keeps its style" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Eleven columns of room: "one two" fits, and the space it was broken at
    // does not start the next line, which is indented under the row's text.
    const words = [_]Span{.{ .style = BOLD, .text = "one two three" }};
    const broke = try writeRow(&aw.writer, allocator, &words, 12, 3, 4);
    try std.testing.expectEqual(@as(usize, 2), broke.lines);
    try std.testing.expectEqualStrings(
        BOLD ++ "one two" ++ RESET ++ "\x1b[K\r\n" ++
            "   " ++ BOLD ++ "three" ++ RESET ++ "\x1b[K\r\n",
        aw.written(),
    );

    // Each run keeps its own colour across the wrap, and the description that
    // follows it is dim: a row is no longer one undifferentiated line.
    aw.clearRetainingCapacity();
    const mixed = [_]Span{
        .{ .style = sgr.BOLD_CYAN, .text = "    > 1) Alpha" },
        .{ .style = DIM, .text = "  first choice" },
    };
    const described = try writeRow(&aw.writer, allocator, &mixed, 24, 9, 4);
    try std.testing.expectEqual(@as(usize, 2), described.lines);
    try std.testing.expectEqualStrings(
        sgr.BOLD_CYAN ++ "    > 1) Alpha" ++ DIM ++ "  first" ++ RESET ++ "\x1b[K\r\n" ++
            "         " ++ DIM ++ "choice" ++ RESET ++ "\x1b[K\r\n",
        aw.written(),
    );
}

test "the form asks for the rows long text wraps onto, and draws them all" {
    const allocator = std.testing.allocator;
    const long_options = [_]Option{
        .{
            .label = "完整实现并补测试",
            .description = "同时在 menu 与 render 两层实现换行，并补一个 pty 集成测试验证窄终端下的表现。",
            .recommended = true,
        },
        .{ .label = "只改菜单渲染", .description = "", .recommended = false },
    };
    var slots = [_]Slot{Slot.init("这个改动应该同时覆盖 macOS 与 Linux 上的换行行为，请选择你希望我采用的处理方式", &long_options)};
    var state = Form{ .slots = &slots };

    // Wrapped at a narrow width the form is taller than counting rows, not
    // lines, would have it: that is the height it asks the dock for.
    const narrow = 30;
    const natural = try naturalRows(allocator, &state, narrow);
    try std.testing.expect(natural > formRows(&slots, true, false));

    // Drawn in that space the question and the answer rows are drawn whole —
    // no ellipsis, no line wider than the terminal — and every row is there
    // rather than only the focused one. The hint is the one row that is a key
    // legend, and it is cut short instead of taking a row of its own.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.testing.expectEqual(natural, try drawForm(allocator, &aw.writer, &state, narrow, natural));
    var hint_row = false;
    var lines = std.mem.splitSequence(u8, aw.written(), "\r\n");
    while (lines.next()) |line| {
        try std.testing.expect(term.width(line) <= narrow - 1);
        if (std.mem.indexOf(u8, line, "↑/↓ select") != null) {
            hint_row = true;
            continue;
        }
        if (!hint_row) try std.testing.expect(std.mem.indexOf(u8, line, "…") == null);
    }
    try std.testing.expect(hint_row);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "只改菜单渲染") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Other / 自定义回答") != null);
}

/// A dock that grants no more than `cap` rows and records the heights it was
/// asked for, so one form's requests across redraws can be watched.
const DockProbe = struct {
    cap: usize,
    width: usize,
    asked: std.ArrayList(usize) = .empty,

    fn prepare(context: *anyopaque, wanted: usize) anyerror!Viewport {
        const self: *DockProbe = @ptrCast(@alignCast(context));
        try self.asked.append(std.testing.allocator, wanted);
        return .{ .top = 1, .height = @max(@as(usize, 1), @min(wanted, self.cap)), .columns = self.width };
    }
};

test "a form taller than the dock asks for one height, however often it is redrawn" {
    const allocator = std.testing.allocator;
    const long_options = [_]Option{
        .{ .label = "完整实现并补测试", .description = "同时在 menu 与 render 两层实现换行，并补一个集成测试。", .recommended = true },
        .{ .label = "只改菜单渲染", .description = "", .recommended = false },
    };
    var slots = [_]Slot{Slot.init("这个改动应该同时覆盖 macOS 与 Linux 上的换行行为，请选择你希望我采用的处理方式", &long_options)};
    var state = Form{ .slots = &slots };

    var probe = DockProbe{ .cap = 6, .width = 30 };
    defer probe.asked.deinit(allocator);
    const dock = Dock{ .context = &probe, .prepare = DockProbe.prepare };

    // The screen is polled while a form is open, so it is drawn again and again
    // with nothing typed in between.
    var reserved = formRows(&slots, true, false);
    for (0..3) |_| _ = try reserveDock(allocator, &state, dock, &reserved);

    // The floor comes first, because the width the form draws at is only known
    // once the dock is asked. The wrapped height follows, and every redraw
    // after that asks for the same one: a dock asked for two heights in turn
    // would repaint the whole screen on every poll.
    const natural = try naturalRows(allocator, &state, probe.width);
    try std.testing.expect(natural > probe.cap);
    try std.testing.expectEqual(4, probe.asked.items.len);
    try std.testing.expectEqual(formRows(&slots, true, false), probe.asked.items[0]);
    for (probe.asked.items[1..]) |wanted| try std.testing.expectEqual(natural, wanted);
    try std.testing.expectEqual(natural, reserved);
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
/// answer, and types `typed` into its free-text row instead of reading a line.
const FakeReader = struct {
    /// The words the free-text row is answered with.
    typed: []const u8 = "typed",
    /// What the first presentation comes to, for the confirmation and for
    /// backing out of the form. The rest answer the questions.
    first: ?Outcome = null,
    /// The words the confirmation's Supplement row is answered with, when the
    /// first presentation comes back with them instead of submitting.
    note: ?[]const u8 = null,
    allocator: std.mem.Allocator = std.testing.allocator,
    calls: usize = 0,
    /// The tab the form was last asked to start on.
    focus: ?usize = null,

    fn present(context: *anyopaque, slots: []Slot, focus: ?usize) anyerror!Outcome {
        const self: *FakeReader = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.focus = focus;
        if (self.note) |words| {
            self.note = null;
            return .{ .supplement = try self.allocator.dupe(u8, words) };
        }
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
            if (slot.selected >= slot.options.len) {
                return .{ .custom = .{ .index = i, .text = try self.allocator.dupe(u8, self.typed) } };
            }
            slot.answered = true;
            return .answered;
        }
        return .answered;
    }
};

test "typed answers are freed when resolve allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
            slots[0].selected = 2;
            var reader = FakeReader{ .typed = "custom", .allocator = allocator };
            const replies = try resolve(allocator, &slots, .{
                .context = &reader,
                .present = FakeReader.present,
            });
            defer replies.deinit(allocator);
            try std.testing.expectEqualStrings("custom", replies.items[0].custom);
        }
    }.run, .{});
}

test "the words added at the confirmation are freed when resolve allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
            slots[0].answered = true;
            var reader = FakeReader{ .note = "and mind the tests", .allocator = allocator };
            const replies = try resolve(allocator, &slots, .{
                .context = &reader,
                .present = FakeReader.present,
            });
            defer replies.deinit(allocator);
            try std.testing.expectEqualStrings("and mind the tests", replies.note.?);
        }
    }.run, .{});
}

test "a typed answer arrives with the outcome" {
    const allocator = std.testing.allocator;

    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    slots[0].selected = 2;
    var reader = FakeReader{ .typed = "my own words" };
    const replies = try resolve(allocator, &slots, .{
        .context = &reader,
        .present = FakeReader.present,
    });
    defer replies.deinit(allocator);
    try std.testing.expectEqualStrings("my own words", replies.items[0].custom);
    try std.testing.expect(slots[0].answered);
}

test "the confirmation submits with the words the user added" {
    const allocator = std.testing.allocator;

    // Supplement: the words typed into that row travel with the answers instead
    // of answering a question of their own.
    var slots = [_]Slot{Slot.init("Which?", &two_options_a)};
    slots[0].answered = true;
    var reader = FakeReader{ .note = "and mind the tests" };
    const replies = try resolve(allocator, &slots, .{
        .context = &reader,
        .present = FakeReader.present,
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
    });
    defer plain.deinit(allocator);
    try std.testing.expect(plain.note == null);
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
