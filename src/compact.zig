//! Context compaction: token estimation, the safe place to cut a
//! conversation, and the material a model is asked to summarize.
//!
//! The conversation is a sequence a Responses request replays; cutting it in
//! the middle of a tool call would leave a result without its call. The
//! functions here only choose boundaries that keep every kept tool result
//! attached to the assistant message that produced it.
const std = @import("std");
const openai = @import("openai.zig");
const Message = openai.Message;

/// Per-message budget when rendering a transcript for the summarizer. The
/// model needs the gist, not a second copy of every file it already read.
pub const max_message_bytes: usize = 2_000;
pub const max_tool_result_bytes: usize = 600;
/// Largest transcript sent in one summarization request. Longer ranges are
/// summarized in several passes, each carrying the summary so far.
pub const max_chunk_bytes: usize = 24_000;
/// Longest summary kept in the history. A summary longer than this would
/// defeat the purpose of compacting.
pub const max_summary_bytes: usize = 6_000;
/// A range must contain at least this many messages before it is worth
/// replacing with a summary.
pub const min_messages_to_compact: usize = 2;

pub const SUMMARY_SYSTEM_PROMPT =
    \\You compress the earlier part of a conversation between a user and
    \\zagent, a command-line AI coding agent. You are given a summary so far
    \\(possibly empty) and the next segment of the conversation. Return an
    \\updated summary that preserves everything needed to continue the work.
    \\
    \\Keep:
    \\- the user's goals, constraints, preferences and decisions
    \\- file paths, commands, code changes, errors and their outcomes
    \\- open tasks and the single next concrete step
    \\- durable facts the user asked to remember
    \\Drop:
    \\- greetings, repetition, and tool output whose details no longer matter
    \\
    \\Write compact prose or bullets. Reply with the summary only, no preamble,
    \\and keep it under about 400 words.
;

/// Roughly how many tokens a conversation will cost. This uses the same
/// byte-based estimate as the live token counter, so the compaction threshold
/// and the number on the status line agree.
pub fn estimateTokens(messages: []const Message) u64 {
    var tokens: u64 = 0;
    for (messages) |message| {
        if (message.content) |content| {
            if (content.len > 0) tokens += openai.estimateTokens(content);
        }
        if (message.reasoning_content) |content| {
            if (content.len > 0) tokens += openai.estimateTokens(content);
        }
        if (message.tool_call_id) |id| {
            if (id.len > 0) tokens += openai.estimateTokens(id);
        }
        if (message.response_items) |items| {
            if (items.len > 0) tokens += openai.estimateTokens(items);
        }
        if (message.tool_calls) |calls| {
            for (calls) |call| {
                if (call.name.len > 0) tokens += openai.estimateTokens(call.name);
                if (call.arguments.len > 0) tokens += openai.estimateTokens(call.arguments);
                if (call.id.len > 0) tokens += openai.estimateTokens(call.id);
            }
        }
    }
    return tokens;
}

/// Whether the conversation has grown past the configured budget. A zero
/// threshold switches automatic compaction off.
pub fn needsCompaction(messages: []const Message, threshold_tokens: u32) bool {
    if (threshold_tokens == 0) return false;
    return estimateTokens(messages) >= threshold_tokens;
}

/// True when a conversation may be split before `index` without separating a
/// tool result from its assistant call.
fn safeBoundary(messages: []const Message, index: usize) bool {
    // A kept range cannot start with a result whose call was summarized.
    if (std.mem.eql(u8, messages[index].role, "tool")) return false;
    // Nor directly after an assistant call whose results were, in a valid
    // history, the messages this boundary would skip over.
    if (index > 1) {
        const previous = messages[index - 1];
        if (std.mem.eql(u8, previous.role, "assistant") and previous.tool_calls != null) return false;
    }
    return true;
}

/// The index messages before which should be replaced by a summary, or null
/// when there is nothing safe and worthwhile to compact.
///
/// The newest `keep_messages` messages are kept. A user boundary is preferred,
/// because a range that starts with a fresh request reads naturally to the
/// model; any other safe boundary is a fallback for a tool-heavy turn where
/// the only user messages are far behind. Index 0, the system prompt, is never
/// summarized.
pub fn findCut(messages: []const Message, keep_messages: u32) ?usize {
    if (messages.len <= min_messages_to_compact + 1) return null;
    // Asking to keep at least as many messages as there are means there is
    // nothing this compaction may summarize.
    if (keep_messages >= messages.len) return null;

    var target: usize = messages.len - keep_messages;
    if (target < 2) target = 2;
    if (target >= messages.len) return null;

    var fallback: ?usize = null;
    var index = target;
    while (index < messages.len) : (index += 1) {
        if (index < 1 + min_messages_to_compact) continue;
        if (!safeBoundary(messages, index)) continue;
        if (std.mem.eql(u8, messages[index].role, "user")) return index;
        if (fallback == null) fallback = index;
    }
    return fallback;
}

/// An estimate of how many bytes one message contributes to a transcript,
/// capped the way `renderTranscript` caps it. Used to keep each summarization
/// request inside `max_chunk_bytes`.
pub fn messageWeight(message: Message) usize {
    var weight: usize = 16;
    if (std.mem.eql(u8, message.role, "tool")) {
        if (message.content) |content| weight += @min(content.len, max_tool_result_bytes);
        return weight;
    }
    if (message.content) |content| weight += @min(content.len, max_message_bytes);
    if (message.tool_calls) |calls| {
        for (calls) |call| {
            weight += @min(call.arguments.len, max_message_bytes) + call.name.len + 16;
        }
    }
    return weight;
}

/// Render messages `[from, to)` as plain text for a summarizer or a memory
/// extractor. Long values are truncated, not dropped: what was done matters
/// more than every byte of its output.
pub fn renderTranscript(
    allocator: std.mem.Allocator,
    messages: []const Message,
    from: usize,
    to: usize,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    for (messages[from..to]) |message| {
        if (std.mem.eql(u8, message.role, "user")) {
            if (message.content) |content| {
                try w.writeAll("User: ");
                try writeTruncated(w, content, max_message_bytes);
                try w.writeAll("\n\n");
            }
            continue;
        }
        if (std.mem.eql(u8, message.role, "tool")) {
            if (message.content) |content| {
                try w.writeAll("Tool result: ");
                try writeTruncated(w, content, max_tool_result_bytes);
                try w.writeAll("\n\n");
            }
            continue;
        }
        if (std.mem.eql(u8, message.role, "assistant")) {
            if (message.tool_calls) |calls| {
                for (calls) |call| {
                    try w.print("Assistant called {s}: ", .{call.name});
                    try writeTruncated(w, call.arguments, max_message_bytes);
                    try w.writeAll("\n");
                }
            }
            if (message.content) |content| {
                try w.writeAll("Assistant: ");
                try writeTruncated(w, content, max_message_bytes);
                try w.writeAll("\n\n");
            }
        }
    }
    return aw.toOwnedSlice();
}

fn writeTruncated(w: *std.Io.Writer, text: []const u8, max_bytes: usize) !void {
    if (text.len <= max_bytes) return w.writeAll(text);
    const marker = " … [truncated]";
    if (max_bytes <= marker.len) return w.writeAll(truncateUtf8(text, max_bytes));
    try w.writeAll(truncateUtf8(text, max_bytes - marker.len));
    try w.writeAll(marker);
}

/// Cut `text` to at most `max_bytes`, never splitting a UTF-8 character.
fn truncateUtf8(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var cut = max_bytes;
    while (cut > 0 and !std.unicode.utf8ValidateSlice(text[0..cut])) : (cut -= 1) {}
    return text[0..cut];
}

/// Trim a model's summary and keep it inside the history budget.
pub fn sanitizeSummary(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return error.EmptySummary;
    return allocator.dupe(u8, truncateUtf8(trimmed, max_summary_bytes));
}

/// The two messages that ask for the next summary. The segment is owned by the
/// caller; `freeSummaryMessages` releases what is allocated here.
pub fn buildSummaryMessages(
    allocator: std.mem.Allocator,
    previous: ?[]const u8,
    segment: []const u8,
) ![]Message {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (previous) |summary| {
        try w.writeAll("Summary so far:\n");
        try w.writeAll(summary);
        try w.writeAll("\n\n");
    }
    try w.writeAll("Next part of the conversation:\n");
    try w.writeAll(segment);
    const prompt = try aw.toOwnedSlice();
    errdefer allocator.free(prompt);

    const messages = try allocator.alloc(Message, 2);
    errdefer allocator.free(messages);
    messages[0] = .{
        .role = "system",
        .content = try allocator.dupe(u8, SUMMARY_SYSTEM_PROMPT),
        .reasoning_content = null,
        .tool_calls = null,
        .tool_call_id = null,
    };
    errdefer allocator.free(messages[0].content.?);
    messages[1] = .{
        .role = "user",
        .content = prompt,
        .reasoning_content = null,
        .tool_calls = null,
        .tool_call_id = null,
    };
    return messages;
}

pub fn freeSummaryMessages(allocator: std.mem.Allocator, messages: []Message) void {
    for (messages) |message| message.deinit(allocator);
    allocator.free(messages);
}

/// Replace `history[1..cut]` with one assistant message carrying `summary`.
/// The summary sits at index 1, so the kept conversation shifts down by
/// `cut - 2`. Returns that shift, which is how callers update any index they
/// were holding into the history.
pub fn install(allocator: std.mem.Allocator, history: *std.ArrayList(Message), cut: usize, summary: []const u8) !usize {
    std.debug.assert(cut >= 2 and cut < history.items.len);
    const content = try std.fmt.allocPrint(allocator, "[Earlier conversation summary]\n{s}", .{summary});
    errdefer allocator.free(content);

    for (history.items[1..cut]) |message| message.deinit(allocator);
    const kept = history.items.len - cut;
    std.mem.copyForwards(Message, history.items[2 .. 2 + kept], history.items[cut..]);
    history.items[1] = .{
        .role = "assistant",
        .content = content,
        .reasoning_content = null,
        .tool_calls = null,
        .tool_call_id = null,
    };
    history.items.len = 2 + kept;
    return cut - 2;
}

test "a conversation under budget needs no compaction" {
    var messages = [_]Message{
        .{ .role = "system", .content = "sys", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    try std.testing.expect(!needsCompaction(&messages, 10_000));
    // Zero disables automatic compaction rather than meaning "always".
    try std.testing.expect(!needsCompaction(&messages, 0));
    try std.testing.expect(needsCompaction(&messages, 1));
}

test "a cut never separates a tool result from its call" {
    var calls = [_]openai.ToolCallData{.{ .id = "1", .name = "shell", .arguments = "{}" }};
    const messages = [_]Message{
        .{ .role = "system", .content = "sys", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "user", .content = "q1", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null },
        .{ .role = "tool", .content = "out", .reasoning_content = null, .tool_calls = null, .tool_call_id = "1" },
        .{ .role = "assistant", .content = "a1", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "user", .content = "q2", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "a2", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const cut = findCut(&messages, 3).?;
    // The boundary skips the bare tool result and lands on the next user turn.
    try std.testing.expectEqual(@as(usize, 5), cut);
    try std.testing.expectEqualStrings("user", messages[cut].role);

    // Keeping more messages than exist leaves nothing to summarize.
    try std.testing.expectEqual(@as(?usize, null), findCut(&messages, messages.len));
}

test "installing a summary keeps the recent messages and shifts indices" {
    const allocator = std.testing.allocator;
    var history: std.ArrayList(Message) = .empty;
    defer {
        for (history.items) |message| message.deinit(allocator);
        history.deinit(allocator);
    }
    try history.append(allocator, .{ .role = "system", .content = try allocator.dupe(u8, "sys"), .reasoning_content = null, .tool_calls = null, .tool_call_id = null });
    try history.append(allocator, .{ .role = "user", .content = try allocator.dupe(u8, "old"), .reasoning_content = null, .tool_calls = null, .tool_call_id = null });
    try history.append(allocator, .{ .role = "assistant", .content = try allocator.dupe(u8, "old answer"), .reasoning_content = null, .tool_calls = null, .tool_call_id = null });
    try history.append(allocator, .{ .role = "user", .content = try allocator.dupe(u8, "new"), .reasoning_content = null, .tool_calls = null, .tool_call_id = null });

    const shift = try install(allocator, &history, 3, "the old exchange");
    try std.testing.expectEqual(@as(usize, 1), shift);
    try std.testing.expectEqual(@as(usize, 3), history.items.len);
    try std.testing.expectEqualStrings("system", history.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, history.items[1].content.?, "the old exchange") != null);
    try std.testing.expectEqualStrings("new", history.items[2].content.?);
}

test "a transcript keeps both sides and truncates long tool output" {
    const allocator = std.testing.allocator;
    const long = try allocator.alloc(u8, 2_000);
    defer allocator.free(long);
    @memset(long, 'x');
    const messages = [_]Message{
        .{ .role = "user", .content = "fix it", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "tool", .content = long, .reasoning_content = null, .tool_calls = null, .tool_call_id = "1" },
    };
    const rendered = try renderTranscript(allocator, &messages, 0, messages.len);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "User: fix it") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[truncated]") != null);
    try std.testing.expect(rendered.len < long.len);
}

test "compaction triggers exactly at the token budget" {
    const messages = [_]Message{.{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null }};
    const tokens: u32 = @intCast(estimateTokens(&messages));
    try std.testing.expect(tokens > 0);
    try std.testing.expect(needsCompaction(&messages, tokens));
    try std.testing.expect(!needsCompaction(&messages, tokens + 1));
    try std.testing.expectEqual(@as(u64, 0), estimateTokens(&.{}));
}

test "short histories and keeping the entire history cannot be compacted" {
    const messages = [_]Message{
        .{ .role = "system", .content = "sys", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "user", .content = "q", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "a", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    try std.testing.expectEqual(@as(?usize, null), findCut(&.{}, 0));
    for (0..messages.len + 1) |len| {
        try std.testing.expectEqual(@as(?usize, null), findCut(messages[0..len], 0));
    }
    try std.testing.expectEqual(@as(?usize, null), findCut(&messages, std.math.maxInt(u32)));
}

test "UTF8 truncation handles every boundary of mixed width text" {
    const input = "a中🙂b";
    const expected = [_][]const u8{ "", "a", "a", "a", "a中", "a中", "a中", "a中", "a中🙂", input };
    for (expected, 0..) |value, limit| {
        const actual = truncateUtf8(input, limit);
        try std.testing.expectEqualStrings(value, actual);
        try std.testing.expect(std.unicode.utf8ValidateSlice(actual));
    }
}

test "summary sanitization rejects whitespace and trims without changing text" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", " \t\r\n" }) |input| {
        try std.testing.expectError(error.EmptySummary, sanitizeSummary(allocator, input));
    }
    const summary = try sanitizeSummary(allocator, " \t\r\n保留  内容\n下一步 \t\r\n");
    defer allocator.free(summary);
    try std.testing.expectEqualStrings("保留  内容\n下一步", summary);
}

test "summary byte limit never splits a multibyte character" {
    const allocator = std.testing.allocator;
    const prefix = try allocator.alloc(u8, max_summary_bytes - 1);
    defer allocator.free(prefix);
    @memset(prefix, 'x');
    const input = try std.fmt.allocPrint(allocator, "{s}🙂tail", .{prefix});
    defer allocator.free(input);
    const summary = try sanitizeSummary(allocator, input);
    defer allocator.free(summary);
    try std.testing.expectEqualStrings(prefix, summary);
    try std.testing.expect(std.unicode.utf8ValidateSlice(summary));
}

test "transcript renders only the requested range and preserves tool arguments" {
    const allocator = std.testing.allocator;
    var calls = [_]openai.ToolCallData{.{ .id = "1", .name = "shell", .arguments = "{\"command\":\"zig build test\"}" }};
    const messages = [_]Message{
        .{ .role = "system", .content = "secret", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "checking", .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null },
        .{ .role = "user", .content = "outside range", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const transcript = try renderTranscript(allocator, &messages, 1, 2);
    defer allocator.free(transcript);
    try std.testing.expectEqualStrings("Assistant called shell: {\"command\":\"zig build test\"}\nAssistant: checking\n\n", transcript);
    const empty = try renderTranscript(allocator, &messages, 2, 2);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "summary requests include previous context only when supplied" {
    const allocator = std.testing.allocator;
    const fresh = try buildSummaryMessages(allocator, null, "new segment");
    defer freeSummaryMessages(allocator, fresh);
    try std.testing.expectEqual(@as(usize, 2), fresh.len);
    try std.testing.expectEqualStrings("system", fresh[0].role);
    try std.testing.expectEqualStrings(SUMMARY_SYSTEM_PROMPT, fresh[0].content.?);
    try std.testing.expectEqualStrings("user", fresh[1].role);
    try std.testing.expectEqualStrings("Next part of the conversation:\nnew segment", fresh[1].content.?);
    const continued = try buildSummaryMessages(allocator, "earlier facts", "new segment");
    defer freeSummaryMessages(allocator, continued);
    try std.testing.expectEqualStrings("Summary so far:\nearlier facts\n\nNext part of the conversation:\nnew segment", continued[1].content.?);
}

fn checkSummaryAllocationFailures(allocator: std.mem.Allocator) !void {
    const messages = try buildSummaryMessages(allocator, "previous", "segment");
    defer freeSummaryMessages(allocator, messages);
}

test "summary request construction releases allocations on every failure path" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSummaryAllocationFailures, .{});
}
