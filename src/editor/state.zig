const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const File = std.Io.File;
const math = std.math;

const Linenoise = @import("main.zig").Linenoise;
const History = @import("history.zig").History;
const unicode = @import("unicode.zig");
const width = unicode.width;
const term = @import("term.zig");
const getColumns = term.getColumns;

const key_tab = 9;
const key_esc = 27;

const Bias = enum {
    left,
    right,
};

fn binarySearchBestEffort(
    comptime T: type,
    key: T,
    items: []const T,
    context: anytype,
    comptime compareFn: fn (context: @TypeOf(context), lhs: T, rhs: T) math.Order,
    bias: Bias,
) usize {
    var left: usize = 0;
    var right: usize = items.len;

    while (left < right) {
        // Avoid overflowing in the midpoint calculation
        const mid = left + (right - left) / 2;
        // Compare the key with the midpoint element
        switch (compareFn(context, key, items[mid])) {
            .eq => return mid,
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    }

    // At this point, it is guaranteed that left >= right. In order
    // for the bias to work, we need to return the exact opposite
    return switch (bias) {
        .left => right,
        .right => left,
    };
}

fn compareLeft(context: []const u8, avail_space: usize, index: usize) math.Order {
    const width_slice = width(context[0..index]);
    return math.order(avail_space, width_slice);
}

fn compareRight(context: []const u8, avail_space: usize, index: usize) math.Order {
    const width_slice = width(context[index..]);
    return math.order(width_slice, avail_space);
}

const StartOrEnd = enum {
    start,
    end,
};

/// Start mode: Calculates the optimal start position such that
/// buf[start..] fits in the available space taking into account
/// unicode codepoint widths
///
/// xxxxxxxxxxxxxxxxxxxxxxx buf
///    [------------------] available_space
///    ^                    start
///
/// End mode: Calculates the optimal end position so that buf[0..end]
/// fits
///
/// xxxxxxxxxxxxxxxxxxxxxxx buf
/// [----------]            available_space
///            ^            end
fn calculateStartOrEnd(
    allocator: Allocator,
    comptime mode: StartOrEnd,
    buf: []const u8,
    avail_space: usize,
) !usize {
    // Create a mapping from unicode codepoint indices to buf
    // indices
    var map = try ArrayList(usize).initCapacity(allocator, buf.len);
    defer map.deinit(allocator);

    var utf8 = (try std.unicode.Utf8View.init(buf)).iterator();
    while (utf8.nextCodepointSlice()) |codepoint| {
        map.appendAssumeCapacity(@intFromPtr(codepoint.ptr) - @intFromPtr(buf.ptr));
    }

    const codepoint_start = binarySearchBestEffort(
        usize,
        avail_space,
        map.items,
        buf,
        switch (mode) {
            .start => compareRight,
            .end => compareLeft,
        },
        // When calculating start or end, if in doubt, choose a
        // smaller buffer as we don't want to overflow the line. For
        // calculating start, this means that we would rather have an
        // index more to the right.
        switch (mode) {
            .start => .right,
            .end => .left,
        },
    );
    return map.items[codepoint_start];
}

pub const LinenoiseState = struct {
    allocator: Allocator,
    ln: *Linenoise,

    stdin: File,
    stdout: File,
    buf: ArrayList(u8) = .empty,
    prompt: []const u8,
    pos: usize = 0,
    cursor_row: usize = 0,
    cols: usize,
    max_rows: usize = 0,
    viewport_start: usize = 0,
    popup_items: []@import("main.zig").PopupItem = &.{},
    popup_selected: usize = 0,
    popup_rows: usize = 0,
    /// Recalled commands must not divert subsequent arrows into completion.
    history_navigation: bool = false,
    /// Ctrl-L asked the host to draw its log again.
    force_repaint: bool = false,

    const Self = @This();

    pub fn init(ln: *Linenoise, in: File, out: File, prompt: []const u8) Self {
        return Self{
            .allocator = ln.allocator,
            .ln = ln,

            .stdin = in,
            .stdout = out,
            .prompt = prompt,
            .cols = @max(getColumns(ln.io, in, out) catch 80, 4),
        };
    }

    pub fn deinitPopup(self: *Self) void {
        self.clearPopup() catch {};
        self.freePopup();
    }

    fn freePopup(self: *Self) void {
        for (self.popup_items) |item| item.deinit(self.allocator);
        if (self.popup_items.len > 0) self.allocator.free(self.popup_items);
        self.popup_items = &.{};
    }

    fn clearPopup(self: *Self) !void {
        // At the bottom of the screen the whole input block is drawn again on
        // every refresh, so there is nothing to erase here.
        if (self.ln.bottom_anchor) {
            self.popup_rows = 0;
            return;
        }
        if (self.popup_rows == 0) return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try aw.writer.writeAll("\x1b7");
        for (0..self.popup_rows) |_| try aw.writer.writeAll("\r\n\x1b[2K");
        try aw.writer.writeAll("\x1b8");
        try self.stdout.writeStreamingAll(self.ln.io, aw.written());
        self.popup_rows = 0;
    }

    fn popupText(writer: *std.Io.Writer, text: []const u8, remaining: *usize) !void {
        var offset: usize = 0;
        while (offset < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
            if (offset + length > text.len) break;
            const slice = text[offset..][0..length];
            offset += length;
            if (!std.unicode.utf8ValidateSlice(slice)) continue;
            if (length == 1 and (slice[0] < 32 or slice[0] == 127)) continue;
            const columns = width(slice);
            if (columns > remaining.*) break;
            try writer.writeAll(slice);
            remaining.* -= columns;
        }
    }

    fn drawPopup(self: *Self) !void {
        // Drawn by refreshBottom, above the input: there is no room below it.
        if (self.ln.bottom_anchor) return;
        if (self.popup_items.len == 0) return;
        const visible = @min(self.popup_items.len, 6);
        const first = @min(self.popup_selected -| (visible / 2), self.popup_items.len - visible);
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        for (first..first + visible) |index| {
            try aw.writer.writeAll("\r\n\x1b[2K");
            const selected = index == self.popup_selected;
            if (selected) try aw.writer.writeAll("\x1b[1;36m");
            var remaining = self.cols -| 1;
            try popupText(&aw.writer, if (selected) " > " else "   ", &remaining);
            try popupText(&aw.writer, self.popup_items[index].label, &remaining);
            try popupText(&aw.writer, "  ", &remaining);
            try popupText(&aw.writer, self.popup_items[index].description, &remaining);
            try aw.writer.writeAll("\x1b[0m");
        }
        try aw.writer.writeAll("\r\n\x1b[2K");
        var remaining = self.cols -| 1;
        try popupText(&aw.writer, " ↑/↓ select · Tab/Enter insert · Esc close", &remaining);
        try aw.writer.print("\x1b[{d}A\r", .{visible + 1});
        try self.stdout.writeStreamingAll(self.ln.io, aw.written());
        self.popup_rows = visible + 1;
        // Redraw the input after relative movement, including when the popup
        // scrolled at the bottom of the terminal.
        try self.refreshSingleLine();
    }

    pub fn movePopup(self: *Self, forward: bool) !void {
        const count = self.popup_items.len;
        if (count == 0) return;
        self.popup_selected = if (forward) (self.popup_selected + 1) % count else (self.popup_selected + count - 1) % count;
        if (self.ln.bottom_anchor) {
            // Keep the items: only the highlighted row moved.
            self.popup_rows = 0;
            return self.refreshBottom(false);
        }
        try self.clearPopup();
        try self.drawPopup();
    }

    pub fn dismissPopup(self: *Self) !void {
        if (self.ln.bottom_anchor) {
            self.freePopup();
            self.popup_rows = 0;
            return self.refreshBottom(false);
        }
        try self.clearPopup();
        self.freePopup();
    }

    pub fn acceptPopup(self: *Self) !void {
        const value = self.popup_items[self.popup_selected].value orelse {
            try self.dismissPopup();
            return;
        };
        var replacement: ArrayList(u8) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.appendSlice(self.allocator, value);
        try replacement.appendSlice(self.allocator, self.buf.items[self.pos..]);
        const new_pos = value.len;
        if (self.ln.bottom_anchor) {
            self.freePopup();
            self.popup_rows = 0;
            self.buf.deinit(self.allocator);
            self.buf = replacement;
            self.pos = new_pos;
            return self.refreshBottom(false);
        }
        try self.clearPopup();
        self.freePopup();
        self.buf.deinit(self.allocator);
        self.buf = replacement;
        self.pos = new_pos;
        try self.refreshSingleLine();
    }

    pub fn browseCompletions(self: *Self) !?u8 {
        var input_buf: [1]u8 = undefined;
        var c: ?u8 = null;

        const fun = self.ln.completions_callback orelse return null;
        const completions = try fun(self.allocator, self.buf.items);
        defer {
            for (completions) |x| self.allocator.free(x);
            self.allocator.free(completions);
        }

        if (completions.len == 0) {
            try term.beep(self.ln.io);
        } else {
            var finished = false;
            var i: usize = 0;

            while (!finished) {
                if (i < completions.len) {
                    // Change to completion nr. i
                    // First, save buffer so we can restore it later
                    const old_buf = try self.buf.toOwnedSlice(self.allocator);
                    const old_pos = self.pos;

                    // Show suggested completion
                    self.buf = .empty;
                    try self.buf.appendSlice(self.allocator, completions[i]);
                    self.pos = self.buf.items.len;

                    try self.refreshLine();

                    // Restore original buffer into state
                    self.buf.deinit(self.allocator);
                    self.buf = .fromOwnedSlice(old_buf);
                    self.pos = old_pos;
                } else {
                    // Return to original line
                    try self.refreshLine();
                }

                // Read next key
                const nread = try term.read(self.ln.io, self.stdin, &input_buf);
                c = if (nread == 1) input_buf[0] else return error.NothingRead;

                switch (c.?) {
                    key_tab => {
                        // Next completion
                        i = (i + 1) % (completions.len + 1);
                        if (i == completions.len) try term.beep(self.ln.io);
                    },
                    key_esc => {
                        // Stop browsing completions, return to buffer displayed
                        // prior to browsing completions
                        if (i < completions.len) try self.refreshLine();
                        finished = true;
                    },
                    else => {
                        // Stop browsing completions, potentially use suggested
                        // completion
                        if (i < completions.len) {
                            // Replace buffer with text in the selected
                            // completion
                            self.buf.deinit(self.allocator);
                            self.buf = .empty;
                            try self.buf.appendSlice(self.allocator, completions[i]);

                            self.pos = self.buf.items.len;
                        }
                        finished = true;
                    },
                }
            }
        }

        return c;
    }

    fn getHint(self: *Self) !?[]const u8 {
        if (self.ln.hints_callback) |fun| {
            return try fun(self.allocator, self.buf.items);
        }

        return null;
    }

    fn refreshSingleLine(self: *Self) !void {
        // File.writer() needs an explicit buffer and hands back a File.Writer;
        // the Io.Writer API lives on its `interface` field.
        var write_buf: [4096]u8 = undefined;
        var file_writer = self.stdout.writer(self.ln.io, &write_buf);
        const writer = &file_writer.interface;

        const hint = try self.getHint();
        defer if (hint) |str| self.allocator.free(str);

        // Calculate widths
        const pos = width(self.buf.items[0..self.pos]);
        const prompt_width = width(self.prompt);
        const hint_width = if (hint) |str| width(str) else 0;
        const buf_width = width(self.buf.items);

        // Don't show hint/prompt when there is no space
        const show_prompt = prompt_width < self.cols;
        const display_prompt_width = if (show_prompt) prompt_width else 0;
        const show_hint = display_prompt_width + hint_width < self.cols;
        const display_hint_width = if (show_hint) hint_width else 0;

        // buffer -> display_buf mapping
        const avail_space = self.cols - display_prompt_width - display_hint_width - 1;
        const whole_buffer_fits = buf_width <= avail_space;
        var start: usize = undefined;
        var end: usize = undefined;
        if (whole_buffer_fits) {
            start = 0;
            end = self.buf.items.len;
        } else {
            if (pos < avail_space) {
                start = 0;
                end = try calculateStartOrEnd(
                    self.allocator,
                    .end,
                    self.buf.items,
                    avail_space,
                );
            } else {
                end = self.pos;
                start = try calculateStartOrEnd(
                    self.allocator,
                    .start,
                    self.buf.items[0..end],
                    avail_space,
                );
            }
        }
        const display_buf = self.buf.items[start..end];

        // Move cursor to left edge
        try writer.writeAll("\r");

        // Write prompt
        if (show_prompt) try writer.writeAll(self.prompt);

        // Write current buffer content
        if (self.ln.mask_mode) {
            for (display_buf) |_| {
                try writer.writeAll("*");
            }
        } else {
            try writer.writeAll(display_buf);
        }

        // Show hints
        if (show_hint) {
            if (hint) |str| {
                try writer.writeAll(str);
            }
        }

        // Erase to the right
        try writer.writeAll("\x1b[0K");

        // Move cursor to original position
        const cursor_pos = if (pos > avail_space) self.cols - display_hint_width - 1 else display_prompt_width + pos;
        try writer.print("\r\x1b[{}C", .{cursor_pos});

        // Write buffer
        try writer.flush();
    }

    fn usesMultiLine(self: *Self) bool {
        return self.ln.multiline_mode and (self.max_rows > 0 or
            std.mem.indexOfScalar(u8, self.buf.items, '\n') != null or
            width(self.prompt) + width(self.buf.items) >= self.cols -| 1);
    }

    const Position = struct {
        row: usize = 0,
        col: usize = 0,

        fn advance(self: *Position, cells: usize, columns: usize) bool {
            if (self.col + cells > columns) {
                self.row += 1;
                self.col = 0;
                self.col += cells;
                return true;
            }
            self.col += cells;
            return false;
        }
    };

    /// Explicit CRLF and wrapping share the same layout used for the cursor.
    fn writeInput(writer: *std.Io.Writer, bytes: []const u8, position: *Position, columns: usize, masked: bool) !void {
        var iter = (try std.unicode.Utf8View.init(bytes)).iterator();
        while (iter.nextCodepointSlice()) |cp| {
            if (cp.len == 1 and cp[0] == '\n') {
                try writer.writeAll("\r\n");
                position.row += 1;
                position.col = 0;
            } else {
                const cells = if (masked) 1 else width(cp);
                if (position.advance(cells, columns)) try writer.writeAll("\r\n");
                try writer.writeAll(if (masked) "*" else cp);
            }
        }
    }

    pub fn finishEdit(self: *Self) !void {
        if (self.ln.bottom_anchor) {
            // The host clears the input rows and owns the cursor; moving down
            // here would overwrite the reserved area or scroll the layout.
            self.freePopup();
            self.popup_rows = 0;
            return;
        }
        try self.clearPopup();
        if (self.max_rows > self.cursor_row + 1) {
            var buf: [64]u8 = undefined;
            const move = try std.fmt.bufPrint(&buf, "\x1b[{d}B", .{self.max_rows - self.cursor_row - 1});
            try self.stdout.writeStreamingAll(self.ln.io, move);
        }
    }

    fn refreshMultiLine(self: *Self) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;
        if (self.cursor_row > 0) try writer.print("\x1b[{d}A", .{self.cursor_row});
        try writer.writeAll("\r");
        for (0..self.max_rows) |row| {
            try writer.writeAll("\x1b[2K");
            if (row + 1 < self.max_rows) try writer.writeAll("\x1b[1B");
        }
        if (self.max_rows > 1) try writer.print("\x1b[{d}A", .{self.max_rows - 1});

        // Lay out the full input, then show only a screenful around the cursor.
        // This keeps a large pasted file from moving above the terminal screen.
        const columns = @max(self.cols -| 1, 2);
        var layout: std.Io.Writer.Allocating = .init(self.allocator);
        defer layout.deinit();
        var position: Position = .{ .col = width(self.prompt) };
        try layout.writer.writeAll(self.prompt);
        try writeInput(&layout.writer, self.buf.items[0..self.pos], &position, columns, self.ln.mask_mode);
        const cursor = position;
        try writeInput(&layout.writer, self.buf.items[self.pos..], &position, columns, self.ln.mask_mode);
        const height = @max(term.getRows(self.stdout) -| 2, 1);
        if (cursor.row < self.viewport_start) self.viewport_start = cursor.row;
        if (cursor.row >= self.viewport_start + height) self.viewport_start = cursor.row - height + 1;
        self.viewport_start = @min(self.viewport_start, (position.row + 1) -| height);
        var lines = std.mem.splitSequence(u8, layout.written(), "\r\n");
        var row: usize = 0;
        var visible: usize = 0;
        while (lines.next()) |line| : (row += 1) {
            if (row < self.viewport_start) continue;
            if (visible == height) break;
            if (visible > 0) try writer.writeAll("\r\n");
            try writer.writeAll(line);
            visible += 1;
        }
        const cursor_row = cursor.row - self.viewport_start;
        if (visible > cursor_row + 1) try writer.print("\x1b[{d}A", .{visible - cursor_row - 1});
        try writer.writeAll("\r");
        if (cursor.col > 0) try writer.print("\x1b[{d}C", .{cursor.col});
        self.cursor_row = cursor_row;
        self.max_rows = visible;
        try self.stdout.writeStreamingAll(self.ln.io, aw.written());
    }

    /// Lay the input out into display rows and note where the cursor lands.
    const BottomLayout = struct {
        bytes: std.Io.Writer.Allocating,
        cursor: Position,
        total_rows: usize,
    };

    fn bottomLayout(self: *Self) !BottomLayout {
        var layout: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer layout.deinit();
        const columns = @max(self.cols -| 1, 2);
        var position: Position = .{ .col = width(self.prompt) };
        try layout.writer.writeAll(self.prompt);
        try writeInput(&layout.writer, self.buf.items[0..self.pos], &position, columns, self.ln.mask_mode);
        const cursor = position;
        try writeInput(&layout.writer, self.buf.items[self.pos..], &position, columns, self.ln.mask_mode);
        return .{ .bytes = layout, .cursor = cursor, .total_rows = position.row + 1 };
    }

    /// Draw the editor anchored to the bottom of the screen.
    ///
    /// Absolute cursor addressing is used throughout: the block may grow or
    /// shrink, and relative movement would depend on where the previous draw
    /// left the cursor, which the conversation scrolling above it can change.
    /// `recompute_popup` is false when only the highlight moved or the popup
    /// was just dismissed.
    pub fn refreshBottom(self: *Self, recompute_popup: bool) !void {
        const rows = @max(term.getRows(self.stdout), 2);
        // The window can change while a line is being edited; the host repaints
        // when it does, and the editor must wrap for the new width.
        self.cols = @max(getColumns(self.ln.io, self.stdin, self.stdout) catch self.cols, 4);
        if (recompute_popup) {
            self.freePopup();
            self.popup_rows = 0;
        }

        var layout = try self.bottomLayout();
        defer layout.bytes.deinit();
        const cursor = layout.cursor;
        const total_rows = layout.total_rows;

        // The popup only appears above a single, unwrapped line, as inline.
        if (recompute_popup and !self.history_navigation and !self.ln.mask_mode and total_rows == 1) {
            if (self.ln.popup_callback) |callback| {
                self.popup_items = try callback(self.allocator, self.ln.io, self.buf.items[0..self.pos]);
                self.popup_selected = 0;
            }
        }
        const popup_wanted: usize = if (self.popup_items.len > 0) @min(self.popup_items.len, 6) + 1 else 0;
        // A short terminal may not have room for the whole popup; drop it
        // rather than let the input block start above the screen.
        const popup_visible = @min(popup_wanted, rows -| 2);

        // Keep at least one row of conversation above the input.
        const max_input = @max(rows -| 1 - popup_visible, 1);
        const visible = @min(total_rows, max_input);
        if (cursor.row < self.viewport_start) self.viewport_start = cursor.row;
        if (cursor.row >= self.viewport_start + visible) self.viewport_start = cursor.row - visible + 1;
        self.viewport_start = @min(self.viewport_start, total_rows -| visible);
        const cursor_row = cursor.row - self.viewport_start;

        const reserved = visible + popup_visible;
        // Hide before the layout callback can move into the log/status area,
        // and only show again once the input cursor is in its final position.
        // Publish the host repaint and input together, never a hidden cursor
        // between them. The host must not end this synchronized frame early.
        try self.stdout.writeStreamingAll(self.ln.io, "\x1b[?2026h\x1b[?25l");
        errdefer self.stdout.writeStreamingAll(self.ln.io, "\x1b[?25h\x1b[?2026l") catch {};
        if (self.ln.layout_callback) |callback| {
            try callback(self.ln.layout_context, reserved, self.force_repaint);
        }
        self.force_repaint = false;
        const input_top = rows - reserved + 1;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const writer = &aw.writer;

        if (popup_visible > 0) {
            const item_rows = popup_visible - 1;
            if (item_rows > 0) {
                const first = @min(self.popup_selected -| (item_rows / 2), self.popup_items.len - item_rows);
                for (first..first + item_rows) |index| {
                    try writer.print("\x1b[{d};1H\x1b[2K", .{input_top + index - first});
                    const selected = index == self.popup_selected;
                    if (selected) try writer.writeAll("\x1b[1;36m");
                    var remaining = self.cols -| 1;
                    try popupText(writer, if (selected) " > " else "   ", &remaining);
                    try popupText(writer, self.popup_items[index].label, &remaining);
                    try popupText(writer, "  ", &remaining);
                    try popupText(writer, self.popup_items[index].description, &remaining);
                    try writer.writeAll("\x1b[0m");
                }
            }
            try writer.print("\x1b[{d};1H\x1b[2K", .{input_top + item_rows});
            var remaining = self.cols -| 1;
            try popupText(writer, " ↑/↓ select · Tab/Enter insert · Esc close", &remaining);
            self.popup_rows = popup_visible;
        }

        var lines = std.mem.splitSequence(u8, layout.bytes.written(), "\r\n");
        var row: usize = 0;
        var drawn: usize = 0;
        while (lines.next()) |line| : (row += 1) {
            if (row < self.viewport_start) continue;
            if (drawn == visible) break;
            try writer.print("\x1b[{d};1H", .{input_top + popup_visible + drawn});
            try writer.writeAll(line);
            try writer.writeAll("\x1b[0K");
            drawn += 1;
        }
        try writer.print("\x1b[{d};{d}H", .{
            input_top + popup_visible + cursor_row,
            @min(cursor.col + 1, self.cols),
        });
        try writer.writeAll("\x1b[?25h\x1b[?2026l");
        try self.stdout.writeStreamingAll(self.ln.io, aw.written());

        self.max_rows = visible;
        self.cursor_row = cursor_row;
    }

    pub fn refreshLine(self: *Self) !void {
        if (self.ln.bottom_anchor) return self.refreshBottom(true);
        try self.clearPopup();
        self.freePopup();
        if (self.usesMultiLine()) {
            try self.refreshMultiLine();
        } else {
            try self.refreshSingleLine();
        }
        // The popup occupies rows below a horizontally scrolling input.
        if (!self.history_navigation and !self.usesMultiLine() and !self.ln.mask_mode) {
            if (self.ln.popup_callback) |callback| {
                self.popup_items = try callback(self.allocator, self.ln.io, self.buf.items[0..self.pos]);
                self.popup_selected = 0;
                try self.drawPopup();
            }
        }
    }

    pub fn editInsert(self: *Self, c: []const u8) !void {
        self.history_navigation = false;
        try self.buf.resize(self.allocator, self.buf.items.len + c.len);
        if (self.buf.items.len > 0 and self.pos < self.buf.items.len - c.len) {
            std.mem.copyBackwards(
                u8,
                self.buf.items[self.pos + c.len .. self.buf.items.len],
                self.buf.items[self.pos .. self.buf.items.len - c.len],
            );
        }

        @memcpy(self.buf.items[self.pos..][0..c.len], c);
        self.pos += c.len;
        try self.refreshLine();
    }

    fn prevCodepointLen(self: *Self, pos: usize) usize {
        if (pos >= 1 and @clz(~self.buf.items[pos - 1]) == 0) {
            return 1;
        } else if (pos >= 2 and @clz(~self.buf.items[pos - 2]) == 2) {
            return 2;
        } else if (pos >= 3 and @clz(~self.buf.items[pos - 3]) == 3) {
            return 3;
        } else if (pos >= 4 and @clz(~self.buf.items[pos - 4]) == 4) {
            return 4;
        } else {
            return 0;
        }
    }

    pub fn editMoveLeft(self: *Self) !void {
        if (self.pos == 0) return;
        self.pos -= self.prevCodepointLen(self.pos);
        try self.refreshLine();
    }

    pub fn editMoveRight(self: *Self) !void {
        if (self.pos < self.buf.items.len) {
            const utf8_len = std.unicode.utf8ByteSequenceLength(self.buf.items[self.pos]) catch 1;
            self.pos += utf8_len;
            try self.refreshLine();
        }
    }

    pub fn editMoveWordEnd(self: *Self) !void {
        if (self.pos < self.buf.items.len) {
            while (self.pos < self.buf.items.len and self.buf.items[self.pos] == ' ')
                self.pos += 1;
            while (self.pos < self.buf.items.len and self.buf.items[self.pos] != ' ')
                self.pos += 1;
            try self.refreshLine();
        }
    }

    pub fn editMoveWordStart(self: *Self) !void {
        if (self.buf.items.len > 0 and self.pos > 0) {
            while (self.pos > 0 and self.buf.items[self.pos - 1] == ' ')
                self.pos -= 1;
            while (self.pos > 0 and self.buf.items[self.pos - 1] != ' ')
                self.pos -= 1;
            try self.refreshLine();
        }
    }

    pub fn editMoveVertical(self: *Self, forward: bool) !void {
        const bytes = self.buf.items;
        if (std.mem.indexOfScalar(u8, bytes, '\n') == null)
            return self.editHistoryNext(if (forward) .next else .prev);
        const start = if (std.mem.lastIndexOfScalar(u8, bytes[0..self.pos], '\n')) |index| index + 1 else 0;
        const column = width(bytes[start..self.pos]);
        var target_start: usize = undefined;
        var target_end: usize = undefined;
        if (forward) {
            const end = std.mem.indexOfScalarPos(u8, bytes, self.pos, '\n') orelse return;
            target_start = end + 1;
            target_end = std.mem.indexOfScalarPos(u8, bytes, target_start, '\n') orelse bytes.len;
        } else {
            if (start == 0) return;
            target_end = start - 1;
            target_start = if (std.mem.lastIndexOfScalar(u8, bytes[0..target_end], '\n')) |index| index + 1 else 0;
        }
        var pos = target_start;
        var cells: usize = 0;
        while (pos < target_end) {
            const length = try std.unicode.utf8ByteSequenceLength(bytes[pos]);
            const next = width(bytes[pos..][0..length]);
            if (cells + next > column) break;
            cells += next;
            pos += length;
        }
        self.pos = pos;
        try self.refreshLine();
    }

    pub fn editMoveHome(self: *Self) !void {
        if (self.pos > 0) {
            self.pos = 0;
            try self.refreshLine();
        }
    }

    pub fn editMoveEnd(self: *Self) !void {
        if (self.pos < self.buf.items.len) {
            self.pos = self.buf.items.len;
            try self.refreshLine();
        }
    }

    pub const HistoryDirection = enum {
        next,
        prev,
    };

    pub fn editHistoryNext(self: *Self, dir: HistoryDirection) !void {
        self.history_navigation = true;
        if (self.ln.history.hist.items.len > 0) {
            // Update the current history with the current line
            const old_index = self.ln.history.current;
            const current_entry = self.ln.history.hist.items[old_index];
            self.ln.history.allocator.free(current_entry);
            self.ln.history.hist.items[old_index] = try self.ln.history.allocator.dupe(u8, self.buf.items);

            // Update history index
            const new_index = switch (dir) {
                .next => if (old_index < self.ln.history.hist.items.len - 1) old_index + 1 else self.ln.history.hist.items.len - 1,
                .prev => if (old_index > 0) old_index - 1 else 0,
            };
            self.ln.history.current = new_index;

            // Copy history entry to the current line buffer
            self.buf.deinit(self.allocator);
            self.buf = .empty;
            try self.buf.appendSlice(self.allocator, self.ln.history.hist.items[new_index]);
            self.pos = self.buf.items.len;

            try self.refreshLine();
        }
    }

    pub fn editDelete(self: *Self) !void {
        self.history_navigation = false;
        if (self.buf.items.len == 0 or self.pos >= self.buf.items.len) return;

        const utf8_len = std.unicode.utf8ByteSequenceLength(self.buf.items[self.pos]) catch 1;
        std.mem.copyForwards(
            u8,
            self.buf.items[self.pos .. self.buf.items.len - utf8_len],
            self.buf.items[self.pos + utf8_len .. self.buf.items.len],
        );
        try self.buf.resize(self.allocator, self.buf.items.len - utf8_len);
        try self.refreshLine();
    }

    pub fn editBackspace(self: *Self) !void {
        self.history_navigation = false;
        if (self.buf.items.len == 0 or self.pos == 0) return;

        const utf8_len = self.prevCodepointLen(self.pos);
        std.mem.copyForwards(
            u8,
            self.buf.items[self.pos - utf8_len .. self.buf.items.len - utf8_len],
            self.buf.items[self.pos..self.buf.items.len],
        );
        self.pos -= utf8_len;
        try self.buf.resize(self.allocator, self.buf.items.len - utf8_len);
        try self.refreshLine();
    }

    pub fn editSwapPrev(self: *Self) !void {
        self.history_navigation = false;
        //    aaa bb            =>   bb aaa
        //   ^   ^  ^- pos_end      ^  ^   ^- pos_end
        //   |   |                  |  |
        //   |   pos_1              |  pos_2
        // pos_begin            pos_begin

        const pos_end = self.pos;
        const b_len = self.prevCodepointLen(pos_end);
        const pos_1 = pos_end - b_len;
        const a_len = self.prevCodepointLen(pos_1);
        const pos_begin = pos_1 - a_len;
        const pos_2 = pos_begin + b_len;

        if (a_len == 0 or b_len == 0) return;

        // save both codepoints
        var tmp: [8]u8 = undefined;
        @memcpy(
            tmp[0 .. a_len + b_len],
            self.buf.items[pos_begin..pos_end],
        );
        // write b from tmp
        @memcpy(
            self.buf.items[pos_begin..pos_2],
            tmp[a_len .. a_len + b_len],
        );
        // write a from tmp
        @memcpy(
            self.buf.items[pos_2..pos_end],
            tmp[0..a_len],
        );

        try self.refreshLine();
    }

    pub fn editDeletePrevWord(self: *Self) !void {
        self.history_navigation = false;
        if (self.buf.items.len == 0 or self.pos == 0) return;

        const old_pos = self.pos;
        while (self.pos > 0 and self.buf.items[self.pos - 1] == ' ')
            self.pos -= 1;
        while (self.pos > 0 and self.buf.items[self.pos - 1] != ' ')
            self.pos -= 1;

        const diff = old_pos - self.pos;
        const new_len = self.buf.items.len - diff;
        std.mem.copyForwards(
            u8,
            self.buf.items[self.pos..new_len],
            self.buf.items[old_pos..self.buf.items.len],
        );
        try self.buf.resize(self.allocator, new_len);
        try self.refreshLine();
    }

    pub fn editKillLineForward(self: *Self) !void {
        self.history_navigation = false;
        try self.buf.resize(self.allocator, self.pos);
        try self.refreshLine();
    }

    pub fn editKillLineBackward(self: *Self) !void {
        self.history_navigation = false;
        const new_len = self.buf.items.len - self.pos;
        std.mem.copyForwards(
            u8,
            self.buf.items[0..new_len],
            self.buf.items[self.pos..self.buf.items.len],
        );
        self.pos = 0;
        try self.buf.resize(self.allocator, new_len);
        try self.refreshLine();
    }
};

test "multiline layout tracks CJK wrapping, blank lines and cursor splits" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var position: LinenoiseState.Position = .{ .col = 2 };
    try LinenoiseState.writeInput(&output.writer, "你好ab", &position, 7, false);
    try std.testing.expectEqual(1, position.row);
    try std.testing.expectEqual(1, position.col);
    try LinenoiseState.writeInput(&output.writer, "\n\n中", &position, 7, false);
    try std.testing.expectEqual(3, position.row);
    try std.testing.expectEqual(2, position.col);
    try std.testing.expectEqualStrings("你好a\r\nb\r\n\r\n中", output.written());
}

test "large multiline input stays inside viewport and supports Unicode editing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try tmp.dir.createFile(std.testing.io, "output", .{});
    defer out.close(std.testing.io);
    var ln: Linenoise = .{
        .allocator = allocator,
        .io = std.testing.io,
        .env = undefined,
        .history = History.empty(allocator),
        .multiline_mode = true,
    };
    defer ln.deinit();
    var state: LinenoiseState = .{
        .allocator = allocator,
        .ln = &ln,
        .stdin = out,
        .stdout = out,
        .prompt = "> ",
        .cols = 20,
    };
    defer state.buf.deinit(allocator);
    for (0..60) |_| try state.buf.appendSlice(allocator, "你好\n");
    state.pos = state.buf.items.len;
    try state.refreshLine();
    try std.testing.expectEqual(22, state.max_rows);
    try std.testing.expectEqual(21, state.cursor_row);
    try std.testing.expect(state.viewport_start > 0);
    try state.editMoveVertical(false);
    try std.testing.expectEqual(state.buf.items.len - 7, state.pos);
    try state.editMoveRight();
    try state.editBackspace();
    try std.testing.expectEqualStrings("好\n", state.buf.items[state.pos..]);
    try state.editMoveHome();
    try std.testing.expectEqual(0, state.cursor_row);
    try std.testing.expectEqual(0, state.viewport_start);
}

const LayoutRecord = struct {
    rows: usize = 0,
    repaint: bool = false,
    calls: usize = 0,
};

fn recordLayout(context: ?*anyopaque, rows: usize, repaint: bool) anyerror!void {
    const record: *LayoutRecord = @ptrCast(@alignCast(context));
    record.rows = rows;
    record.repaint = repaint;
    record.calls += 1;
}

fn testPopup(allocator: Allocator, io: std.Io, input: []const u8) ![]@import("main.zig").PopupItem {
    _ = io;
    _ = input;
    const items = try allocator.alloc(@import("main.zig").PopupItem, 2);
    items[0] = .{
        .value = try allocator.dupe(u8, "@a"),
        .label = try allocator.dupe(u8, "alpha.zig"),
        .description = try allocator.dupe(u8, "File"),
    };
    items[1] = .{
        .value = try allocator.dupe(u8, "@b"),
        .label = try allocator.dupe(u8, "beta.zig"),
        .description = try allocator.dupe(u8, "File"),
    };
    return items;
}

test "a bottom anchored input is drawn on the last rows and asks for its height" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try tmp.dir.createFile(std.testing.io, "output", .{});
    defer out.close(std.testing.io);

    var ln: Linenoise = .{
        .allocator = allocator,
        .io = std.testing.io,
        .env = undefined,
        .history = History.empty(allocator),
        .multiline_mode = true,
        .bottom_anchor = true,
    };
    defer ln.deinit();
    var record = LayoutRecord{};
    ln.layout_callback = recordLayout;
    ln.layout_context = &record;

    var state: LinenoiseState = .{
        .allocator = allocator,
        .ln = &ln,
        .stdin = out,
        .stdout = out,
        .prompt = "> ",
        .cols = 20,
    };
    defer state.buf.deinit(allocator);
    try state.buf.appendSlice(allocator, "abc\ndef");
    state.pos = state.buf.items.len;
    try state.refreshLine();

    // Two display rows, so the editor asks the host for two of them.
    try std.testing.expectEqual(@as(usize, 2), record.rows);
    try std.testing.expectEqual(@as(usize, 1), record.calls);
    try std.testing.expectEqual(@as(usize, 2), state.max_rows);
    try std.testing.expectEqual(@as(usize, 1), state.cursor_row);

    const written = try tmp.dir.readFileAlloc(std.testing.io, "output", allocator, .limited(1 << 16));
    defer allocator.free(written);
    // getRows has no ioctl to read on a file and falls back to 24 rows.
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[23;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "> abc\x1b[0K") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[24;1Hdef\x1b[0K") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[24;4H") != null);
    const hidden = std.mem.indexOf(u8, written, "\x1b[?25l") orelse return error.TestUnexpectedResult;
    const draw = std.mem.indexOf(u8, written, "\x1b[23;1H") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hidden < draw);
    try std.testing.expect(std.mem.indexOf(u8, written, "\x1b[?2026h\x1b[?25l") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\x1b[24;4H\x1b[?25h\x1b[?2026l"));
}

test "a bottom anchored popup sits above the input and keeps its items while moving" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try tmp.dir.createFile(std.testing.io, "output", .{});
    defer out.close(std.testing.io);

    var ln: Linenoise = .{
        .allocator = allocator,
        .io = std.testing.io,
        .env = undefined,
        .history = History.empty(allocator),
        .bottom_anchor = true,
        .popup_callback = testPopup,
    };
    defer ln.deinit();
    var record = LayoutRecord{};
    ln.layout_callback = recordLayout;
    ln.layout_context = &record;

    var state: LinenoiseState = .{
        .allocator = allocator,
        .ln = &ln,
        .stdin = out,
        .stdout = out,
        .prompt = "> ",
        .cols = 20,
    };
    defer state.buf.deinit(allocator);
    defer state.deinitPopup();
    try state.buf.appendSlice(allocator, "@");
    state.pos = 1;
    try state.refreshLine();

    // Two items plus the key hint, above one input row.
    try std.testing.expectEqual(@as(usize, 4), record.rows);
    try std.testing.expectEqual(@as(usize, 3), state.popup_rows);
    try std.testing.expectEqual(@as(usize, 2), state.popup_items.len);

    try state.movePopup(true);
    try std.testing.expectEqual(@as(usize, 2), record.calls);
    try std.testing.expectEqual(@as(usize, 1), state.popup_selected);
    try std.testing.expectEqual(@as(usize, 4), record.rows);

    try state.dismissPopup();
    try std.testing.expectEqual(@as(usize, 1), record.rows);
    try std.testing.expectEqual(@as(usize, 0), state.popup_items.len);
}
