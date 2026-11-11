//! The plan the agent keeps for work that takes more than one step.
//!
//! The checklist lives in memory for the life of the process and is written
//! into the session snapshot — it is not a file of its own. The conversation
//! and the plan travel together: a cleared history keeps the plan, a resumed
//! session brings it back, and a new session starts without one.
const std = @import("std");
const text = @import("../util/text.zig");

pub const max_steps: usize = 50;
pub const max_title_bytes: usize = 200;
pub const max_note_bytes: usize = 300;

pub const Status = enum {
    pending,
    active,
    done,
    blocked,

    /// Accept the spelling a model is likely to send, exactly or in any case.
    pub fn parse(name: []const u8) ?Status {
        var buf: [16]u8 = undefined;
        if (name.len > buf.len) return null;
        return std.meta.stringToEnum(Status, std.ascii.lowerString(&buf, name));
    }

    /// The mark this status is rendered with.
    pub fn mark(self: Status) []const u8 {
        return switch (self) {
            .pending => "[ ]",
            .active => "[~]",
            .done => "[x]",
            .blocked => "[!]",
        };
    }
};

/// One step as the model sends it: the status arrives as text, and is read
/// with `Status.parse` so the error can name what was wrong.
pub const ArgumentStep = struct {
    title: []const u8,
    status: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

/// The arguments of a `plan` call.
pub const Arguments = struct {
    steps: ?[]const ArgumentStep = null,
    index: ?usize = null,
    status: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const Step = struct {
    title: []u8,
    status: Status = .pending,
    /// One optional line, kept under the step: why it is blocked, what was
    /// decided, what is left.
    note: ?[]u8 = null,
};

/// A step as a caller hands it over: borrowed strings, status optional.
pub const NewStep = struct {
    title: []const u8,
    status: ?Status = null,
    note: ?[]const u8 = null,
};

/// A step as a session snapshot stores it: borrowed strings, both ways. It is
/// the wire shape of a plan, so the session module never has to know how a
/// step is held in memory.
pub const Stored = struct {
    title: []const u8,
    status: Status = .pending,
    note: ?[]const u8 = null,
};

pub const Tally = struct {
    total: usize = 0,
    done: usize = 0,
    blocked: usize = 0,
    /// 1-based number of the step to take next: the first active one, else the
    /// first pending one, and null when no step is open.
    next: ?usize = null,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(Step) = .empty,

    pub fn init(allocator: std.mem.Allocator) Plan {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Plan) void {
        freeSteps(self.allocator, self.steps.items);
        self.steps.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn tally(self: *const Plan) Tally {
        var result: Tally = .{ .total = self.steps.items.len };
        for (self.steps.items, 0..) |step, i| {
            switch (step.status) {
                .done => result.done += 1,
                .blocked => result.blocked += 1,
                .active => if (result.next == null) {
                    result.next = i + 1;
                },
                .pending => {},
            }
        }
        if (result.next == null) {
            for (self.steps.items, 0..) |step, i| {
                if (step.status == .pending) {
                    result.next = i + 1;
                    break;
                }
            }
        }
        return result;
    }

    /// Replace the whole plan. The new list is built before the old one is
    /// dropped, so a rejected step leaves the plan as it was.
    pub fn setSteps(self: *Plan, raw: []const NewStep) !void {
        if (raw.len > max_steps) return error.TooManySteps;
        var staged: std.ArrayList(Step) = .empty;
        errdefer {
            freeSteps(self.allocator, staged.items);
            staged.deinit(self.allocator);
        }
        for (raw) |item| {
            const step = try allocStep(self.allocator, item);
            errdefer freeStep(self.allocator, step);
            try staged.append(self.allocator, step);
        }
        freeSteps(self.allocator, self.steps.items);
        self.steps.deinit(self.allocator);
        self.steps = staged;
    }

    /// Change one step by its 1-based number, keeping the rest untouched. The
    /// strings of the other steps are not copied: only the named step moves.
    pub fn update(self: *Plan, index: usize, status: ?Status, note: ?[]const u8) !void {
        if (index == 0 or index > self.steps.items.len) return error.NoSuchStep;
        const target = &self.steps.items[index - 1];
        if (status) |value| target.status = value;
        if (note) |value| {
            const cleaned = try normalize(self.allocator, value, max_note_bytes);
            if (target.note) |old| self.allocator.free(old);
            if (cleaned.len == 0) {
                // An empty note is how a note is taken off a step: the reason
                // no longer holds, and leaving the old text would say it does.
                self.allocator.free(cleaned);
                target.note = null;
            } else {
                target.note = cleaned;
            }
        }
    }

    pub fn clear(self: *Plan) void {
        freeSteps(self.allocator, self.steps.items);
        self.steps.clearRetainingCapacity();
    }

    /// The plan as a session snapshot writes it: an array of borrowed views,
    /// freed by the caller once the snapshot is on disk.
    pub fn stored(self: *const Plan, allocator: std.mem.Allocator) ![]Stored {
        const view = try allocator.alloc(Stored, self.steps.items.len);
        for (self.steps.items, 0..) |step, i| {
            view[i] = .{ .title = step.title, .status = step.status, .note = step.note };
        }
        return view;
    }

    /// Replace the plan with what a session snapshot holds. The steps are
    /// cleaned the way a tool call is, and a step this program cannot use is
    /// skipped rather than failing the whole resume.
    pub fn restore(self: *Plan, items: []const Stored) !void {
        var staged: std.ArrayList(Step) = .empty;
        errdefer {
            freeSteps(self.allocator, staged.items);
            staged.deinit(self.allocator);
        }
        for (items) |item| {
            if (staged.items.len == max_steps) break;
            const step = allocStep(self.allocator, .{ .title = item.title, .status = item.status, .note = item.note }) catch |err| switch (err) {
                error.EmptyStepTitle => continue,
                else => return err,
            };
            errdefer freeStep(self.allocator, step);
            try staged.append(self.allocator, step);
        }
        freeSteps(self.allocator, self.steps.items);
        self.steps.deinit(self.allocator);
        self.steps = staged;
    }

    /// The checklist as the model reads it back: what it is working through,
    /// where it is, and which step comes next.
    pub fn writeChecklist(self: *const Plan, w: *std.Io.Writer) !void {
        // Where the work stands comes first: a result is previewed on the
        // terminal by its opening bytes, and the steps themselves are long.
        if (self.steps.items.len == 0) {
            try w.writeAll("No plan saved yet. Save one with one short line per verifiable step.\n");
            return;
        }
        const progress = self.tally();
        if (progress.next) |next| {
            try w.print("Plan {d}/{d} done. Next: {d}. {s}\n", .{ progress.done, progress.total, next, self.steps.items[next - 1].title });
        } else if (progress.blocked > 0) {
            try w.print("Plan {d}/{d} done. No open step; {d} blocked.\n", .{ progress.done, progress.total, progress.blocked });
        } else {
            try w.print("Plan {d}/{d} done. All steps complete.\n", .{ progress.done, progress.total });
        }
        for (self.steps.items, 0..) |step, i| {
            try w.print("{d}. {s} {s}\n", .{ i + 1, step.status.mark(), step.title });
            if (step.note) |note| try w.print("   note: {s}\n", .{note});
        }
    }

    pub fn describe(self: *const Plan, allocator: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try self.writeChecklist(&aw.writer);
        return aw.toOwnedSlice();
    }

    /// The one bullet the system prompt carries about the plan. Short on
    /// purpose: it is sent with every request.
    pub fn writePromptNote(self: *const Plan, w: *std.Io.Writer) !void {
        if (self.steps.items.len == 0) {
            try w.writeAll(
                "\n- No plan is saved yet. Before the first edit of work with several steps, save one with" ++
                    " **plan** — one short line per verifiable step — and mark each step as it is verified." ++
                    " The plan belongs to the session: it is saved with it and comes back when the session is" ++
                    " resumed, while **/new** starts without one.\n",
            );
            return;
        }
        const progress = self.tally();
        if (progress.next) |next| {
            try w.print(
                "\n- The plan is in progress ({d}/{d} done, next: {d}. {s}). It is kept in memory and saved" ++
                    " with this session, so a cleared conversation and a resumed session still have it: read it" ++
                    " with **plan** before choosing the next step, and keep it current as steps are verified.\n",
                .{ progress.done, progress.total, next, self.steps.items[next - 1].title },
            );
            return;
        }
        try w.print(
            "\n- The plan has no open step ({d}/{d} done). Write the plan for the next piece of work with" ++
                " **plan**, or clear it once the task is finished.\n",
            .{ progress.done, progress.total },
        );
    }
};

/// What a `plan` call is doing, in one line for the terminal: the arguments
/// are a whole checklist, and the JSON would take ten times the room to say
/// the same thing. Returns false when they are not a call this program can
/// read, so the caller can show what actually came in.
pub fn writeCallSummary(w: *std.Io.Writer, allocator: std.mem.Allocator, arguments_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(Arguments, allocator, arguments_json, .{}) catch return false;
    defer parsed.deinit();
    const args = parsed.value;
    if (args.steps) |steps| {
        try w.print("{d} steps", .{steps.len});
        for (steps, 0..) |step, i| {
            if (i == 3) {
                try w.writeAll(", …");
                break;
            }
            try w.writeAll(if (i == 0) ": " else ", ");
            try writeOnOneLine(w, step.title);
        }
        return true;
    }
    if (args.index) |index| {
        try w.print("step {d}", .{index});
        if (args.status) |status| {
            try w.writeAll(" → ");
            try writeOnOneLine(w, status);
        }
        if (args.note) |note| {
            try w.writeAll(" · ");
            try writeOnOneLine(w, note);
        }
        return true;
    }
    try w.writeAll("read");
    return true;
}

fn freeStep(a: std.mem.Allocator, step: Step) void {
    a.free(step.title);
    if (step.note) |note| a.free(note);
}

/// Sanitised text from the model, held to one line: a title carrying a newline
/// would otherwise draw over the line the call is announced on.
fn writeOnOneLine(w: *std.Io.Writer, raw: []const u8) !void {
    var start: usize = 0;
    for (raw, 0..) |byte, i| {
        if (byte != '\n' and byte != '\r' and byte != '\t') continue;
        try text.writeSanitized(w, raw[start..i]);
        try w.writeByte(' ');
        start = i + 1;
    }
    try text.writeSanitized(w, raw[start..]);
}

fn freeSteps(a: std.mem.Allocator, steps: []const Step) void {
    for (steps) |step| freeStep(a, step);
}

fn allocStep(a: std.mem.Allocator, raw: NewStep) !Step {
    const title = try normalize(a, raw.title, max_title_bytes);
    errdefer a.free(title);
    if (title.len == 0) return error.EmptyStepTitle;
    var note: ?[]u8 = null;
    if (raw.note) |value| {
        const cleaned = try normalize(a, value, max_note_bytes);
        if (cleaned.len == 0) {
            a.free(cleaned);
        } else {
            note = cleaned;
        }
    }
    return .{ .title = title, .status = raw.status orelse .pending, .note = note };
}

/// One line, trimmed, whitespace collapsed into single spaces, and cut to
/// `limit` bytes on a character boundary. A title with a newline would become
/// two lines in a rendering, so it is flattened here.
fn normalize(a: std.mem.Allocator, raw: []const u8, limit: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var words = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (words.next()) |word| {
        if (aw.written().len > 0) try aw.writer.writeByte(' ');
        if (aw.written().len + word.len > limit) break;
        try aw.writer.writeAll(word);
    }
    return aw.toOwnedSlice();
}

test "steps are normalised, marked and tallied" {
    const a = std.testing.allocator;
    var plan = Plan.init(a);
    defer plan.deinit();

    try plan.setSteps(&.{
        .{ .title = "  read\tthe  schemas ", .status = .done },
        .{ .title = "write plan.zig", .status = .active },
        .{ .title = "wire the tool", .note = "  after   the schema  " },
        .{ .title = "blocked step", .status = .blocked },
    });
    try std.testing.expectEqualStrings("read the schemas", plan.steps.items[0].title);
    try std.testing.expectEqualStrings("after the schema", plan.steps.items[2].note.?);
    const progress = plan.tally();
    try std.testing.expectEqual(@as(usize, 4), progress.total);
    try std.testing.expectEqual(@as(usize, 1), progress.done);
    try std.testing.expectEqual(@as(usize, 1), progress.blocked);
    // An active step outranks an earlier pending one: it is the work in hand.
    try std.testing.expectEqual(@as(?usize, 2), progress.next);

    // A rejected step leaves the plan the model already has.
    try std.testing.expectError(error.EmptyStepTitle, plan.setSteps(&.{.{ .title = "   " }}));
    try std.testing.expectEqual(@as(usize, 4), plan.steps.items.len);

    const rendered = try plan.describe(a);
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2. [~] write plan.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Plan 1/4 done. Next: 2. write plan.zig\n") != null);
}

test "a plan is stepped, cleared and restored from its stored form" {
    const a = std.testing.allocator;
    var plan = Plan.init(a);
    defer plan.deinit();
    try plan.setSteps(&.{
        .{ .title = "read the code", .status = .done },
        .{ .title = "write the module", .status = .active },
        .{ .title = "run the tests" },
    });
    try std.testing.expectError(error.NoSuchStep, plan.update(9, .done, null));
    try std.testing.expectError(error.NoSuchStep, plan.update(0, .done, null));

    try plan.update(2, .done, "compiles");
    try plan.update(3, .blocked, "waits for the fixture");
    try std.testing.expectEqualStrings("compiles", plan.steps.items[1].note.?);

    // The stored form is the one a session snapshot carries, and it comes back
    // with titles, statuses and notes intact.
    const stored = try plan.stored(a);
    defer a.free(stored);
    var restored = Plan.init(a);
    defer restored.deinit();
    try restored.restore(stored);
    try std.testing.expectEqual(@as(usize, 3), restored.steps.items.len);
    try std.testing.expectEqual(Status.done, restored.steps.items[1].status);
    try std.testing.expectEqualStrings("waits for the fixture", restored.steps.items[2].note.?);

    restored.clear();
    try std.testing.expectEqual(@as(usize, 0), restored.tally().total);
    // Clearing a note empties it, rather than keeping the old text.
    try restored.setSteps(&.{.{ .title = "one", .note = "why" }});
    try restored.update(1, null, "");
    try std.testing.expectEqual(@as(?[]u8, null), restored.steps.items[0].note);

    // Snapshot data from elsewhere is cleaned like a tool call, and a step
    // this program cannot use is skipped instead of failing the session.
    try restored.restore(&.{
        .{ .title = "  still   here ", .status = .done },
        .{ .title = "   " },
        .{ .title = "blocked", .status = .blocked, .note = " reason " },
    });
    try std.testing.expectEqual(@as(usize, 2), restored.steps.items.len);
    try std.testing.expectEqualStrings("still here", restored.steps.items[0].title);
    try std.testing.expectEqualStrings("reason", restored.steps.items[1].note.?);
}

test "the prompt follows the plan" {
    const a = std.testing.allocator;
    var plan = Plan.init(a);
    defer plan.deinit();
    try plan.setSteps(&.{
        .{ .title = "done already", .status = .done },
        .{ .title = "in hand", .status = .active },
        .{ .title = "plain line" },
    });

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try plan.writePromptNote(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "1/3 done, next: 2. in hand") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "saved with this session") != null);

    plan.clear();
    aw.clearRetainingCapacity();
    try plan.writePromptNote(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "No plan is saved yet") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "**plan**") != null);
}

test "a plan call is summarised for the terminal on one line" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();

    // A title arrives as model text: a newline in it is flattened, not drawn.
    try std.testing.expect(try writeCallSummary(&aw.writer, a, "{\"steps\":[{\"title\":\"one\\ntwo\"},{\"title\":\"b\"}]}"));
    try std.testing.expectEqualStrings("2 steps: one two, b", aw.written());
    aw.clearRetainingCapacity();
    try std.testing.expect(try writeCallSummary(&aw.writer, a, "{\"index\":2,\"status\":\"done\",\"note\":\"ok\"}"));
    try std.testing.expectEqualStrings("step 2 → done · ok", aw.written());
    aw.clearRetainingCapacity();
    try std.testing.expect(try writeCallSummary(&aw.writer, a, "{}"));
    try std.testing.expectEqualStrings("read", aw.written());
    aw.clearRetainingCapacity();
    // Not a plan call this program can read: the caller shows what came in.
    try std.testing.expect(!try writeCallSummary(&aw.writer, a, "{\"title\":\"x\"}"));
}
