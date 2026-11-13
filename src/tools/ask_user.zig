const std = @import("std");
const menu = @import("../ui/menu.zig");
const sanitize = @import("../util/terminal/sanitize.zig");
const Agent = @import("../agent/mod.zig").Agent;
const dismissed_question_message = @import("../agent/prompt.zig").dismissed_question_message;
const tool = @import("tool.zig");

/// The line that carries the words typed on the confirmation's Supplement row,
/// which add to the answers rather than answering a question.
const note_line = "The user added: ";

pub const spec: tool.Tool = .{
    .name = "ask_user",
    .description = "Ask the user to choose between concrete options when the request is ambiguous or a decision only they can make blocks progress. Pass every question you need answered in one call: they are put to the user as one form, so a question whose answer depends on another belongs in a later call, once the answers are in.",
    .parameters_json =
    \\{"type":"object","properties":{"questions":{"type":"array","minItems":1,"description":"The questions to put to the user, in the order they should be answered","items":{"type":"object","properties":{"question":{"type":"string","description":"The decision that is needed, in one sentence"},"options":{"type":"array","description":"Two to four concrete choices","items":{"type":"object","properties":{"label":{"type":"string","description":"Short name of the choice"},"description":{"type":"string","description":"One sentence on what this choice means"},"recommended":{"type":"boolean","description":"True for the option you would pick"}},"required":["label"]}}},"required":["question","options"]}}},"required":["questions"]}
    ,
    .summary = writeSummary,
    .run = run,
};

/// The call is named by the questions it asks: the form draws them in full a
/// moment later, so the line only has to say what is being asked.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments_json: []const u8) !bool {
    const questions = parseQuestions(ctx.allocator, arguments_json) catch return false;
    defer questions.deinit(ctx.allocator);
    if (questions.items.len == 1) {
        try sanitize.writeOnOneLine(w, questions.items[0].text);
        return true;
    }
    try w.print("{d} questions: ", .{questions.items.len});
    for (questions.items, 0..) |question, index| {
        if (index > 0) try w.writeAll(" · ");
        try sanitize.writeOnOneLine(w, question.text);
    }
    return true;
}

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args);
}

/// Put every question of the call in one form, so the answers can be revised
/// before the form is submitted, and report what each question was answered
/// with. One call carries all of them, which is why dispatch needs nothing
/// special for this tool: it is answered like any other.
fn execute(self: *Agent, arguments: []const u8) !tool.ToolResult {
    if (self.role == .subagent) return .{
        .output = try self.allocator.dupe(u8, "No user is available to a sub-agent. Decide from what the task gives you, or report what blocks it."),
        .is_error = true,
    };
    const questions = parseQuestions(self.allocator, arguments) catch {
        return .{
            .output = try self.allocator.dupe(u8, "Error: ask_user needs a non-empty 'questions' array, each entry with a 'question' and a non-empty 'options' array"),
            .is_error = true,
        };
    };
    defer questions.deinit(self.allocator);

    const slots = try self.allocator.alloc(menu.Slot, questions.items.len);
    defer self.allocator.free(slots);
    for (questions.items, slots) |question, *slot| slot.* = menu.Slot.init(question.text, question.options.items);

    const replies = try self.askForm(slots);
    defer replies.deinit(self.allocator);
    return answersResult(self, questions.items, replies);
}

/// Parsed tool arguments own their text; menu owns only presentation types.
/// In particular, Options stays in menu so its UI types never depend on Question.
pub const Question = struct {
    text: []const u8,
    options: menu.Options,

    pub fn deinit(self: Question, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.options.deinit(allocator);
    }
};

/// The questions of one call, in the order the user answers them.
pub const Questions = struct {
    items: []Question,

    pub fn deinit(self: Questions, allocator: std.mem.Allocator) void {
        for (self.items) |question| question.deinit(allocator);
        allocator.free(self.items);
    }
};

/// Normalize malformed model arguments to InvalidQuestion, preserving OOM.
fn parseQuestions(allocator: std.mem.Allocator, arguments_json: []const u8) !Questions {
    return parseQuestionsInner(allocator, arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidQuestion,
    };
}

fn parseQuestionsInner(allocator: std.mem.Allocator, arguments_json: []const u8) !Questions {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidQuestion;
    const value = parsed.value.object.get("questions") orelse return error.InvalidQuestion;
    if (value != .array) return error.InvalidQuestion;

    var items: std.ArrayList(Question) = .empty;
    errdefer {
        for (items.items) |question| question.deinit(allocator);
        items.deinit(allocator);
    }

    // One unusable question does not cost the user the others: the form is
    // drawn from what can be asked, and a call with nothing usable is refused
    // below with the sentence the model needs.
    for (value.array.items) |entry| {
        const question = (try buildQuestion(allocator, entry)) orelse continue;
        errdefer question.deinit(allocator);
        try items.append(allocator, question);
    }

    if (items.items.len == 0) return error.InvalidQuestion;
    return .{ .items = try items.toOwnedSlice(allocator) };
}

fn buildQuestion(allocator: std.mem.Allocator, value: std.json.Value) !?Question {
    if (value != .object) return null;
    const asked = value.object.get("question") orelse return null;
    if (asked != .string) return null;
    const trimmed = std.mem.trim(u8, asked.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    const options_value = value.object.get("options") orelse return null;

    const options = parseOptions(allocator, options_value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    errdefer options.deinit(allocator);

    return .{
        .text = try allocator.dupe(u8, trimmed),
        .options = options,
    };
}

/// Models also send bare strings; skip malformed entries rather than failing
/// an otherwise usable question.
fn parseOptions(allocator: std.mem.Allocator, value: std.json.Value) !menu.Options {
    if (value != .array) return error.InvalidOptions;

    var items: std.ArrayList(menu.Option) = .empty;
    errdefer {
        for (items.items) |option| option.deinit(allocator);
        items.deinit(allocator);
    }

    for (value.array.items) |entry| {
        const option = (try buildOption(allocator, entry)) orelse continue;
        errdefer option.deinit(allocator);
        try items.append(allocator, option);
    }

    if (items.items.len == 0) return error.InvalidOptions;
    return .{ .items = try items.toOwnedSlice(allocator) };
}

fn buildOption(allocator: std.mem.Allocator, value: std.json.Value) !?menu.Option {
    var label: []const u8 = undefined;
    var description: []const u8 = "";
    var recommended = false;

    switch (value) {
        .string => |text_value| label = text_value,
        .object => |obj| {
            const label_val = obj.get("label") orelse return null;
            if (label_val != .string) return null;
            label = label_val.string;
            if (obj.get("description")) |description_val| {
                if (description_val == .string) description = description_val.string;
            }
            if (obj.get("recommended")) |recommended_val| {
                if (recommended_val == .bool) recommended = recommended_val.bool;
            }
        },
        else => return null,
    }

    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    return .{
        .label = owned_label,
        .description = try allocator.dupe(u8, description),
        .recommended = recommended,
    };
}

/// What the model reads back. One question answers as it always has; several
/// are one line each, naming the question the answer belongs to, because the
/// model has to know which decision each answer settles. Words the user added
/// at the confirmation follow, on a line of their own.
fn answersResult(self: *Agent, questions: []const Question, replies: menu.Replies) !tool.ToolResult {
    if (questions.len == 1) return questionResult(self, replies.items[0], questions[0].options.items, replies.note);

    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    var dismissed = false;
    for (questions, replies.items) |question, reply| {
        const answer = try menu.describeReply(self.allocator, reply, question.options.items);
        defer if (answer) |line| self.allocator.free(line);
        if (answer == null) dismissed = true;
        try aw.writer.print("{s} → {s}\n", .{ question.text, answer orelse dismissed_question_message });
    }
    if (replies.note) |note| try aw.writer.print("{s}{s}\n", .{ note_line, note });
    // A dismissed question leaves the model a decision to make, which is what
    // an error result tells it: the same as a lone dismissed question.
    return .{ .output = try aw.toOwnedSlice(), .is_error = dismissed };
}

fn questionResult(self: *Agent, reply: menu.Reply, options: []const menu.Option, note: ?[]const u8) !tool.ToolResult {
    const line = try menu.describeReply(self.allocator, reply, options);
    // The answer is the described reply, or the sentence a dismissal reads as.
    const answer = line orelse try self.allocator.dupe(u8, dismissed_question_message);
    defer self.allocator.free(answer);
    const output = if (note) |text|
        try std.fmt.allocPrint(self.allocator, "{s}\n{s}{s}", .{ answer, note_line, text })
    else
        try self.allocator.dupe(u8, answer);
    return .{ .output = output, .is_error = line == null };
}

test "the call line names the questions it asks" {
    const allocator = std.testing.allocator;
    const ctx: tool.Context = .{ .io = std.testing.io, .allocator = allocator };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try std.testing.expect(try writeSummary(ctx, &aw.writer, "{\"questions\":[{\"question\":\"Which?\",\"options\":[\"a\"]}]}"));
    try std.testing.expectEqualStrings("Which?", aw.written());

    // Several questions are counted and named, so the line says what the form
    // that is about to be drawn is going to ask.
    aw.clearRetainingCapacity();
    try std.testing.expect(try writeSummary(ctx, &aw.writer,
        \\{"questions":[{"question":"First?","options":["a"]},{"question":"Second?","options":["b"]}]}
    ));
    try std.testing.expectEqualStrings("2 questions: First? · Second?", aw.written());

    // A call the parser refuses leaves the raw arguments on the line: the tool
    // answers it with the sentence saying what to fix.
    aw.clearRetainingCapacity();
    try std.testing.expect(!try writeSummary(ctx, &aw.writer, "{}"));
}

test "parse the questions of one call" {
    const allocator = std.testing.allocator;
    const questions = try parseQuestions(allocator,
        \\{"questions":[{"question":"How should I test this?","options":[{"label":"Add tests","description":"Covers the new branch.","recommended":true},{"label":"Skip tests"}]},{"question":"Which branch?","options":["main"]}]}
    );
    defer questions.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), questions.items.len);
    const first = questions.items[0];
    try std.testing.expectEqualStrings("How should I test this?", first.text);
    try std.testing.expectEqual(@as(usize, 2), first.options.items.len);
    try std.testing.expectEqualStrings("Add tests", first.options.items[0].label);
    try std.testing.expectEqualStrings("Covers the new branch.", first.options.items[0].description);
    try std.testing.expect(first.options.items[0].recommended);
    try std.testing.expectEqualStrings("", first.options.items[1].description);
    try std.testing.expect(!first.options.items[1].recommended);
    try std.testing.expectEqualStrings("Which branch?", questions.items[1].text);
    try std.testing.expectEqualStrings("main", questions.items[1].options.items[0].label);
}

test "parse options accepts bare strings and skips malformed entries" {
    const allocator = std.testing.allocator;
    const questions = try parseQuestions(allocator,
        \\{"questions":[{"question":"Which?","options":["alpha",{"label":"beta"},42]}]}
    );
    defer questions.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), questions.items[0].options.items.len);
    try std.testing.expectEqualStrings("alpha", questions.items[0].options.items[0].label);
    try std.testing.expectEqualStrings("beta", questions.items[0].options.items[1].label);
}

test "a question without usable options is skipped, and none leaves the call refused" {
    const allocator = std.testing.allocator;
    const questions = try parseQuestions(allocator,
        \\{"questions":[{"question":"no options"},{"question":"  ","options":["a"]},{"options":["a"]},{"question":"Which?","options":[]},{"question":"  Kept  ","options":["only"]}]}
    );
    defer questions.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), questions.items.len);
    try std.testing.expectEqualStrings("Kept", questions.items[0].text);

    for ([_][]const u8{
        "{}",
        "{\"question\":\"Which?\",\"options\":[\"a\"]}",
        "{\"questions\":[]}",
        "{\"questions\":\"Which?\"}",
        "{\"questions\":[{\"question\":\"Which?\"}]}",
        "not json",
    }) |arguments| {
        try std.testing.expectError(error.InvalidQuestion, parseQuestions(allocator, arguments));
    }
}

test "several questions answer as one line each, and a dismissal is an error" {
    const allocator = std.testing.allocator;
    // Only the allocator is read: the answers are built without a terminal.
    var agent: Agent = undefined;
    agent.allocator = allocator;

    const questions = try parseQuestions(allocator,
        \\{"questions":[{"question":"First?","options":[{"label":"Alpha"},{"label":"Beta","recommended":true}]},{"question":"Second?","options":["Gamma"]}]}
    );
    defer questions.deinit(allocator);

    const items = try allocator.alloc(menu.Reply, questions.items.len);
    items[0] = .{ .option = 1 };
    items[1] = .dismissed;
    const replies = menu.Replies{ .items = items };
    defer replies.deinit(allocator);

    const result = try answersResult(&agent, questions.items, replies);
    defer result.deinit(allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings(
        "First? → User selected the recommended option: Beta\n" ++
            "Second? → " ++ dismissed_question_message ++ "\n",
        result.output,
    );

    // Answers to every question are not an error, and a lone question keeps the
    // result it has always had.
    const answered = try allocator.alloc(menu.Reply, questions.items.len);
    answered[0] = .{ .option = 0 };
    answered[1] = .{ .custom = try allocator.dupe(u8, "my own words") };
    var all = menu.Replies{ .items = answered };
    defer all.deinit(allocator);
    const full = try answersResult(&agent, questions.items, all);
    defer full.deinit(allocator);
    try std.testing.expect(!full.is_error);
    try std.testing.expect(std.mem.indexOf(u8, full.output, "First? → User selected: Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, full.output, "answered: my own words") != null);

    const single = try answersResult(&agent, questions.items[0..1], all);
    defer single.deinit(allocator);
    try std.testing.expectEqualStrings("User selected: Alpha", single.output);

    // Words the user added at the confirmation follow the answers, so the model
    // reads them as part of the same decision.
    all.note = try allocator.dupe(u8, "and keep the change small");
    const noted = try answersResult(&agent, questions.items, all);
    defer noted.deinit(allocator);
    try std.testing.expect(std.mem.endsWith(u8, noted.output, "The user added: and keep the change small\n"));
    try std.testing.expect(std.mem.indexOf(u8, noted.output, "Second? → The user did not pick one of the options and answered: my own words") != null);

    const noted_single = try answersResult(&agent, questions.items[0..1], all);
    defer noted_single.deinit(allocator);
    try std.testing.expectEqualStrings(
        "User selected: Alpha\nThe user added: and keep the change small",
        noted_single.output,
    );
}
