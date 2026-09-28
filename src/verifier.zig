const std = @import("std");
const openai = @import("openai.zig");
const menu = @import("menu.zig");

/// Longest tool arguments and tool results the judge is shown. It needs to
/// know what was done, not to read the full output a second time.
const max_argument_bytes = 300;
const max_result_bytes = 200;

pub const SYSTEM_PROMPT =
    \\You are the completion checker for zagent, a command-line AI agent. You
    \\are given the user's request and a summary of the work the agent did.
    \\
    \\Decide whether the request has been carried out. Judge only whether the
    \\agent did what was asked, not whether the work could be improved.
    \\
    \\Answer with one JSON object and nothing else:
    \\{"complete": true, "reason": "<one sentence>"}
    \\{"complete": false, "reason": "<one sentence>", "next_step": "<one concrete action>"}
    \\
    \\Set "complete" to true when the request was carried out or when the answer
    \\explains a genuine blocker — a missing credential, an unreachable service,
    \\a command that failed after reasonable retries. A blocker that is reported
    \\to the user is a finished turn, not a reason to try again.
    \\
    \\When work is still outstanding, name the single most important missing
    \\step in "next_step". When the only remaining step is a decision the user
    \\has to make, also add "needs_user_decision": true, "question": "<what to
    \\ask>", and two to four "options": [{"label": "...", "description": "...",
    \\"recommended": true}], with at most one option marked recommended.
;

pub const Verdict = struct {
    complete: bool,
    /// Empty when the judge gave no reason.
    reason: []const u8,
    next_step: ?[]const u8,
    /// The judge decided the work is blocked on the user.
    needs_user_decision: bool,
    question: ?[]const u8,
    options: menu.Options,

    pub fn deinit(self: Verdict, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        if (self.next_step) |value| allocator.free(value);
        if (self.question) |value| allocator.free(value);
        self.options.deinit(allocator);
    }
};

/// Parse the judge's reply. The JSON is usually the whole message, but models
/// wrap it in a code fence or a sentence often enough to be worth tolerating.
pub fn parseVerdict(allocator: std.mem.Allocator, content: []const u8) !Verdict {
    const json = extractJsonObject(content) orelse return error.InvalidVerdict;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidVerdict;
    const root = parsed.value;

    const complete = root.object.get("complete") orelse return error.InvalidVerdict;
    if (complete != .bool) return error.InvalidVerdict;

    const reason = try allocator.dupe(u8, stringField(root, "reason") orelse "");
    errdefer allocator.free(reason);

    const next_step = if (stringField(root, "next_step")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (next_step) |value| allocator.free(value);

    const question = if (stringField(root, "question")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (question) |value| allocator.free(value);

    const needs_user_decision = if (root.object.get("needs_user_decision")) |value|
        value == .bool and value.bool
    else
        false;

    // A malformed options list must not sink an otherwise readable verdict.
    const options = if (root.object.get("options")) |value|
        menu.parseOptions(allocator, value) catch menu.Options.none()
    else
        menu.Options.none();

    return .{
        .complete = complete.bool,
        .reason = reason,
        .next_step = next_step,
        .needs_user_decision = needs_user_decision,
        .question = question,
        .options = options,
    };
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .string or field.string.len == 0) return null;
    return field.string;
}

/// Slice out the first balanced JSON object, dropping the code fence or prose
/// a model sometimes wraps it in. Braces inside strings do not count.
fn extractJsonObject(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return null;

    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text[start..], start..) |byte, i| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Condense one turn into the text the judge reads. The user's request is
/// passed separately; the user messages that appear here are the automatic
/// self-check follow-ups and the answers the user gave to a menu, which the
/// judge needs in order to stop asking for a decision already made.
pub fn summarize(allocator: std.mem.Allocator, messages: []const openai.Message, max_bytes: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var truncated = false;
    for (messages) |message| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        defer line.deinit();
        if (!try writeLine(&line.writer, message)) continue;

        if (out.written().len + line.written().len > max_bytes) {
            truncated = true;
            break;
        }
        try out.writer.writeAll(line.written());
    }

    if (truncated) try out.writer.writeAll("... (earlier work omitted)\n");

    return out.toOwnedSlice();
}

fn writeLine(w: *std.Io.Writer, message: openai.Message) !bool {
    var wrote = false;

    if (std.mem.eql(u8, message.role, "assistant")) {
        if (message.tool_calls) |calls| {
            for (calls) |call| {
                try w.print("tool call: {s} {s}\n", .{ call.name, truncateUtf8(call.arguments, max_argument_bytes) });
                wrote = true;
            }
        }
        if (message.content) |content| {
            try w.print("answer: {s}\n", .{content});
            wrote = true;
        }
        return wrote;
    }

    if (std.mem.eql(u8, message.role, "tool")) {
        if (message.content) |content| {
            try w.print("result: {s}\n", .{truncateUtf8(content, max_result_bytes)});
            return true;
        }
        return false;
    }

    if (std.mem.eql(u8, message.role, "user")) {
        if (message.content) |content| {
            try w.print("follow-up: {s}\n", .{truncateUtf8(content, max_argument_bytes)});
            return true;
        }
    }

    return false;
}

/// Cut `text` to at most `max_bytes`, never splitting a UTF-8 character.
fn truncateUtf8(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;

    var cut = max_bytes;
    while (cut > 0 and !std.unicode.utf8ValidateSlice(text[0..cut])) : (cut -= 1) {}
    return text[0..cut];
}

/// The request the judge is asked to check, wrapped around the summary.
pub fn buildPrompt(allocator: std.mem.Allocator, request: []const u8, summary: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "User request:\n{s}\n\nWork performed:\n{s}",
        .{ request, summary },
    );
}

/// The user-role message that sends an unfinished turn back to the agent. It
/// is phrased as an instruction so the model is not left thinking the user
/// spoke when the checker did.
pub fn buildFollowUp(allocator: std.mem.Allocator, verdict: Verdict) ![]u8 {
    const reason = if (verdict.reason.len > 0) verdict.reason else "the request is not fully carried out";

    if (verdict.next_step) |next_step| {
        return std.fmt.allocPrint(
            allocator,
            "[automatic self-check] This turn is not finished: {s}\nNext step: {s}\nContinue working on it, and do not repeat work that is already done.",
            .{ reason, next_step },
        );
    }

    if (verdict.needs_user_decision) {
        return std.fmt.allocPrint(
            allocator,
            "[automatic self-check] This turn is not finished: {s}\nThe remaining step is a decision only the user can make: {s}\nUse the ask_user tool to present the options.",
            .{ reason, verdict.question orelse "how to proceed" },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "[automatic self-check] This turn is not finished: {s}\nContinue working on it, and do not repeat work that is already done.",
        .{reason},
    );
}

test "a complete verdict needs only a reason" {
    const allocator = std.testing.allocator;
    const verdict = try parseVerdict(allocator, "{\"complete\":true,\"reason\":\"The file was written.\"}");
    defer verdict.deinit(allocator);

    try std.testing.expect(verdict.complete);
    try std.testing.expectEqualStrings("The file was written.", verdict.reason);
    try std.testing.expectEqual(@as(?[]const u8, null), verdict.next_step);
    try std.testing.expectEqual(@as(usize, 0), verdict.options.items.len);
}

test "an incomplete verdict names the next step" {
    const allocator = std.testing.allocator;
    const verdict = try parseVerdict(
        allocator,
        "{\"complete\":false,\"reason\":\"The tests were never run.\",\"next_step\":\"Run zig build test.\"}",
    );
    defer verdict.deinit(allocator);

    try std.testing.expect(!verdict.complete);
    try std.testing.expectEqualStrings("Run zig build test.", verdict.next_step.?);
}

test "a verdict may carry choices for the user" {
    const allocator = std.testing.allocator;
    const verdict = try parseVerdict(allocator,
        \\```json
        \\{"complete": false, "reason": "The output path is the user's call.",
        \\ "needs_user_decision": true,
        \\ "question": "Where should the report go?",
        \\ "options": [{"label":"docs/report.md","description":"Matches the docs layout.","recommended":true},
        \\             {"label":"report.md"}]}
        \\```
    );
    defer verdict.deinit(allocator);

    try std.testing.expect(!verdict.complete);
    try std.testing.expect(verdict.needs_user_decision);
    try std.testing.expectEqualStrings("Where should the report go?", verdict.question.?);
    try std.testing.expectEqual(@as(usize, 2), verdict.options.items.len);
    try std.testing.expect(verdict.options.items[0].recommended);
    try std.testing.expectEqualStrings("report.md", verdict.options.items[1].label);
}

test "a verdict wrapped in prose is still read" {
    const allocator = std.testing.allocator;
    const verdict = try parseVerdict(
        allocator,
        "Here is my verdict:\n{\"complete\":true,\"reason\":\"Done: {not a brace}\"}\nHope that helps.",
    );
    defer verdict.deinit(allocator);

    try std.testing.expect(verdict.complete);
    try std.testing.expectEqualStrings("Done: {not a brace}", verdict.reason);
}

test "a verdict without a boolean complete is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidVerdict, parseVerdict(allocator, "{\"reason\":\"Done.\"}"));
    try std.testing.expectError(error.InvalidVerdict, parseVerdict(allocator, "{\"complete\":\"yes\"}"));
    try std.testing.expectError(error.InvalidVerdict, parseVerdict(allocator, "no json at all"));
}

test "extract json object ignores braces inside strings" {
    const json = extractJsonObject("prefix {\"reason\":\"a } b\",\"complete\":true} suffix").?;
    try std.testing.expectEqualStrings("{\"reason\":\"a } b\",\"complete\":true}", json);
    try std.testing.expectEqual(@as(?[]const u8, null), extractJsonObject("no braces here"));
}

test "the summary lists tool calls and shortens long results" {
    const allocator = std.testing.allocator;
    const long_result = "x" ** (max_result_bytes * 2);
    var calls = [_]openai.ToolCallData{
        .{ .id = "1", .name = "shell", .arguments = "{\"command\":\"ls\"}" },
    };
    const messages = [_]openai.Message{
        .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null },
        .{ .role = "tool", .content = long_result, .reasoning_content = null, .tool_calls = null, .tool_call_id = "1" },
        .{ .role = "assistant", .content = "Two files.", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "user", .content = "[automatic self-check] This turn is not finished.", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };

    const summary = try summarize(allocator, &messages, 8000);
    defer allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "tool call: shell {\"command\":\"ls\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "answer: Two files.") != null);
    // A follow-up carries what the user answered at a menu, which is what
    // stops the judge from asking for the same decision again.
    try std.testing.expect(std.mem.indexOf(u8, summary, "follow-up: [automatic self-check]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "x" ** max_result_bytes) != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "x" ** (max_result_bytes + 1)) == null);
}

test "the summary stops at its size limit" {
    const allocator = std.testing.allocator;
    const messages = [_]openai.Message{
        .{ .role = "assistant", .content = "a" ** 200, .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "b" ** 200, .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };

    const summary = try summarize(allocator, &messages, 250);
    defer allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "... (earlier work omitted)") != null);
    try std.testing.expect(summary.len < 400);
}

test "truncating never splits a utf8 character" {
    const text = "你好世界";
    try std.testing.expectEqualStrings("你好", truncateUtf8(text, 7));
    try std.testing.expectEqualStrings(text, truncateUtf8(text, 12));
}

test "the follow up names the next step" {
    const allocator = std.testing.allocator;

    const with_step = try buildFollowUp(allocator, .{
        .complete = false,
        .reason = "The tests were never run.",
        .next_step = "Run zig build test.",
        .needs_user_decision = false,
        .question = null,
        .options = menu.Options.none(),
    });
    defer allocator.free(with_step);
    try std.testing.expect(std.mem.indexOf(u8, with_step, "Run zig build test.") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_step, "[automatic self-check]") != null);

    const decision = try buildFollowUp(allocator, .{
        .complete = false,
        .reason = "Only the user can pick the path.",
        .next_step = null,
        .needs_user_decision = true,
        .question = "Where should the report go?",
        .options = menu.Options.none(),
    });
    defer allocator.free(decision);
    try std.testing.expect(std.mem.indexOf(u8, decision, "ask_user") != null);
    try std.testing.expect(std.mem.indexOf(u8, decision, "Where should the report go?") != null);
}
