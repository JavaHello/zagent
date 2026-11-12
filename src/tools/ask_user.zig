const std = @import("std");
const menu = @import("../ui/menu.zig");
const Agent = @import("../agent/mod.zig").Agent;
const dismissed_question_message = @import("../agent/prompt.zig").dismissed_question_message;
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "ask_user",
    .description = "Ask the user to choose between concrete options when the request is ambiguous or a decision only they can make blocks progress. Several such calls sent together are put to the user as one form.",
    .parameters_json =
    \\{"type":"object","properties":{"question":{"type":"string","description":"The decision that is needed, in one sentence"},"options":{"type":"array","description":"Two to four concrete choices","items":{"type":"object","properties":{"label":{"type":"string","description":"Short name of the choice"},"description":{"type":"string","description":"One sentence on what this choice means"},"recommended":{"type":"boolean","description":"True for the option you would pick"}},"required":["label"]}}},"required":["question","options"]}
    ,
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args, ctx.answers, ctx.index);
}

/// Answers aligned with the tool calls in one model message.
pub const QuestionAnswers = struct {
    items: []Slot,

    pub const Content = struct { text: []const u8, is_error: bool };
    pub const Slot = union(enum) {
        /// Not a question of this form: dispatch the call as usual.
        none,
        /// Owned here until dispatch takes it.
        content: Content,
    };

    pub fn deinit(self: QuestionAnswers, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            switch (item) {
                .content => |content| allocator.free(content.text),
                .none => {},
            }
        }
        allocator.free(self.items);
    }

    /// Transfer a prepared result to dispatch, which then owns its text.
    pub fn take(self: *QuestionAnswers, index: usize) ?Content {
        if (index >= self.items.len) return null;
        switch (self.items[index]) {
            .none => return null,
            .content => |content| {
                self.items[index] = .none;
                return content;
            },
        }
    }
};

/// Put all valid questions in one form, allowing revisions before submission.
/// Invalid calls are left for execute to report when dispatched.
pub fn askQuestions(self: *Agent, calls: []const @import("../model/openai.zig").ToolCallData) !?QuestionAnswers {
    // A sub-agent must not draw on a terminal it does not own.
    if (self.role == .subagent) return null;
    var questions_in_message: usize = 0;
    for (calls) |call| {
        if (std.mem.eql(u8, call.name, "ask_user")) questions_in_message += 1;
    }
    if (questions_in_message == 0) return null;

    const items = try self.allocator.alloc(QuestionAnswers.Slot, calls.len);
    @memset(items, .none);
    var answers = QuestionAnswers{ .items = items };
    errdefer answers.deinit(self.allocator);

    var questions: std.ArrayList(Question) = .empty;
    defer {
        for (questions.items) |question| question.deinit(self.allocator);
        questions.deinit(self.allocator);
    }
    var slots: std.ArrayList(menu.Slot) = .empty;
    defer slots.deinit(self.allocator);
    var indexes: std.ArrayList(usize) = .empty;
    defer indexes.deinit(self.allocator);

    for (calls, 0..) |call, i| {
        if (!std.mem.eql(u8, call.name, "ask_user")) continue;
        const question = parseAskUser(self.allocator, call.arguments) catch continue;
        // The array does not own it until the append succeeds.
        questions.append(self.allocator, question) catch |err| {
            question.deinit(self.allocator);
            return err;
        };
        try slots.append(self.allocator, menu.Slot.init(question.text, question.options.items));
        try indexes.append(self.allocator, i);
    }
    if (slots.items.len == 0) return answers;

    const replies = try self.askForm(slots.items);
    defer replies.deinit(self.allocator);
    for (replies.items, slots.items, indexes.items) |reply, slot, index| {
        const result = try questionResult(self, reply, slot.options);
        answers.items[index] = .{ .content = .{ .text = result.content, .is_error = result.is_error } };
    }
    return answers;
}

pub fn execute(self: *Agent, arguments: []const u8, answers: ?*QuestionAnswers, index: usize) !tool.ToolResult {
    if (self.role == .subagent) return .{
        .content = try self.allocator.dupe(u8, "No user is available to a sub-agent. Decide from what the task gives you, or report what blocks it."),
        .is_error = true,
    };
    if (answers) |prepared| {
        if (prepared.take(index)) |content| return .{ .content = content.text, .is_error = content.is_error };
    }
    const question = parseAskUser(self.allocator, arguments) catch {
        return .{
            .content = try self.allocator.dupe(u8, "Error: ask_user needs a 'question' and a non-empty 'options' array"),
            .is_error = true,
        };
    };
    defer question.deinit(self.allocator);
    var slots = [_]menu.Slot{menu.Slot.init(question.text, question.options.items)};
    const replies = try self.askForm(&slots);
    defer replies.deinit(self.allocator);
    return questionResult(self, replies.items[0], question.options.items);
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

/// Normalize malformed model arguments to InvalidQuestion, preserving OOM.
pub fn parseAskUser(allocator: std.mem.Allocator, arguments_json: []const u8) !Question {
    return parseAskUserInner(allocator, arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidQuestion,
    };
}

fn parseAskUserInner(allocator: std.mem.Allocator, arguments_json: []const u8) !Question {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidQuestion;
    const question_val = parsed.value.object.get("question") orelse return error.InvalidQuestion;
    if (question_val != .string) return error.InvalidQuestion;
    const options_val = parsed.value.object.get("options") orelse return error.InvalidQuestion;

    const options = try parseOptions(allocator, options_val);
    errdefer options.deinit(allocator);

    return .{
        .text = try allocator.dupe(u8, question_val.string),
        .options = options,
    };
}

/// Models also send bare strings; skip malformed entries rather than failing
/// an otherwise usable question.
pub fn parseOptions(allocator: std.mem.Allocator, value: std.json.Value) !menu.Options {
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
        .string => |text| label = text,
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

test "parse ask_user arguments" {
    const allocator = std.testing.allocator;
    const question = try parseAskUser(allocator,
        \\{"question":"How should I test this?","options":[{"label":"Add tests","description":"Covers the new branch.","recommended":true},{"label":"Skip tests"}]}
    );
    defer question.deinit(allocator);

    try std.testing.expectEqualStrings("How should I test this?", question.text);
    try std.testing.expectEqual(@as(usize, 2), question.options.items.len);
    try std.testing.expectEqualStrings("Add tests", question.options.items[0].label);
    try std.testing.expectEqualStrings("Covers the new branch.", question.options.items[0].description);
    try std.testing.expect(question.options.items[0].recommended);
    try std.testing.expectEqualStrings("", question.options.items[1].description);
    try std.testing.expect(!question.options.items[1].recommended);
}

test "parse options accepts bare strings and skips malformed entries" {
    const allocator = std.testing.allocator;
    const options = try parseAskUser(allocator,
        \\{"question":"Which?","options":["alpha",{"label":"beta"},42]}
    );
    defer options.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), options.options.items.len);
    try std.testing.expectEqualStrings("alpha", options.options.items[0].label);
    try std.testing.expectEqualStrings("beta", options.options.items[1].label);
}

test "prepared question answers transfer each result only once" {
    const allocator = std.testing.allocator;
    const items = try allocator.alloc(QuestionAnswers.Slot, 3);
    items[0] = .none;
    items[1] = .{ .content = .{ .text = try allocator.dupe(u8, "chosen"), .is_error = false } };
    items[2] = .{ .content = .{ .text = try allocator.dupe(u8, "dismissed"), .is_error = true } };
    var answers = QuestionAnswers{ .items = items };
    defer answers.deinit(allocator);

    try std.testing.expect(answers.take(0) == null);
    try std.testing.expect(answers.take(3) == null);
    const content = answers.take(1).?;
    defer allocator.free(content.text);
    try std.testing.expectEqualStrings("chosen", content.text);
    try std.testing.expect(!content.is_error);
    try std.testing.expect(answers.take(1) == null);
    // deinit still owns and releases the result which was not taken.
}

test "ask_user arguments without options are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidQuestion, parseAskUser(allocator, "{\"question\":\"Which?\"}"));
    try std.testing.expectError(error.InvalidQuestion, parseAskUser(allocator, "{\"question\":\"Which?\",\"options\":[]}"));
    try std.testing.expectError(error.InvalidQuestion, parseAskUser(allocator, "not json"));
}

pub fn questionResult(self: *Agent, reply: menu.Reply, options: []const menu.Option) !tool.ToolResult {
    if (try menu.describeReply(self.allocator, reply, options)) |line| return .{ .content = line, .is_error = false };
    return .{ .content = try self.allocator.dupe(u8, dismissed_question_message), .is_error = true };
}
