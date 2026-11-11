//! Context rewriting: the tool results a model asks to drop, and the read
//! output it would otherwise be handed twice.
//!
//! The conversation is a sequence a Responses request replays, so every
//! replacement here swaps a result's content in place; no message is added or
//! removed, and a result keeps the call that produced it.
const std = @import("std");
const openai = @import("openai.zig");
const Message = openai.Message;

/// The marker standing in for a read whose output is already in the history.
/// The reference it carries is why `dropToolResults` refuses to replace the
/// original result it points at.
const duplicate_marker = "[Duplicate read omitted: same path, line range and content SHA-256={s}. See earlier tool result {s} in this context.]";
const reference_prefix = "See earlier tool result ";
const reference_suffix = " in this context.]";

/// The marker standing in place of a dropped tool result. It keeps the call id
/// so the model can run the tool again, and it stays short: the point of a drop
/// is that what it replaced cost more than this.
const dropped_marker = "[Tool result dropped by the model: {s} (call {s}) is no longer in context. Call the tool again if you need this output.]";
const dropped_prefix = "[Tool result dropped by the model: ";

/// Cut `text` to at most `max_bytes`, never splitting a UTF-8 character.
fn truncateUtf8(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var cut = max_bytes;
    while (cut > 0 and !std.unicode.utf8ValidateSlice(text[0..cut])) : (cut -= 1) {}
    return text[0..cut];
}

/// Keep one full copy of identical read output in the live context. Do not
/// treat a marker as a cache hit: once the original result is gone, the model
/// must receive the contents again rather than a reference to a missing
/// message. The returned string is owned by the caller, just like a normal
/// tool result.
pub fn deduplicateReadResult(
    allocator: std.mem.Allocator,
    messages: []const Message,
    call: openai.ToolCallData,
    content: []const u8,
    is_error: bool,
) ![]u8 {
    const key = if (!is_error) try readKey(allocator, call, content) else null;
    if (key) |digest| {
        for (messages, 0..) |message, index| {
            if (!std.mem.eql(u8, message.role, "tool")) continue;
            const id = message.tool_call_id orelse continue;
            const previous_content = message.content orelse continue;
            // A duplicate marker cannot stand in for a full result.
            if (!std.mem.eql(u8, previous_content, content)) continue;
            var previous_index = index;
            while (previous_index > 0) {
                previous_index -= 1;
                const calls = messages[previous_index].tool_calls orelse continue;
                for (calls) |previous_call| {
                    if (!std.mem.eql(u8, previous_call.id, id)) continue;
                    const previous_key = try readKey(allocator, previous_call, previous_content) orelse break;
                    if (std.mem.eql(u8, &digest, &previous_key)) {
                        var content_digest: [32]u8 = undefined;
                        std.crypto.hash.sha2.Sha256.hash(content, &content_digest, .{});
                        return std.fmt.allocPrint(allocator, duplicate_marker, .{ std.fmt.bytesToHex(content_digest, .lower), id });
                    }
                    break;
                }
            }
        }
    }
    return allocator.dupe(u8, content);
}

/// Hash the effective read arguments plus output, not the JSON spelling.
/// Path spelling is intentionally exact: resolving aliases could conflate
/// paths whose targets change between reads.
fn readKey(allocator: std.mem.Allocator, call: openai.ToolCallData, content: []const u8) !?[32]u8 {
    if (!std.mem.eql(u8, call.name, "read")) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path = parsed.value.object.get("path") orelse return null;
    if (path != .string) return null;
    const range = @import("tools.zig").parseReadRange(allocator, call.arguments) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(path.string);
    // A length prefix prevents a path from being confused with range bytes.
    var fields: [32]u8 = undefined;
    std.mem.writeInt(u64, fields[0..8], @intCast(path.string.len), .little);
    std.mem.writeInt(u64, fields[8..16], @intCast(range.start_line), .little);
    std.mem.writeInt(u64, fields[16..24], @intCast(range.end_line orelse 0), .little);
    std.mem.writeInt(u64, fields[24..32], @intCast(range.start_column), .little);
    hash.update(&fields);
    hash.update(content);
    return hash.finalResult();
}

/// How a `drop_context` request resolved. The model asked for ids, so the
/// result has to say what each of them became rather than repeat the request.
pub const DropReport = struct {
    /// Results replaced by the dropped marker.
    dropped: usize = 0,
    /// Results already carrying it: a second drop of one call is a no-op.
    repeated: usize = 0,
    /// Ids no live tool result answers: a typo, or a call that never ran.
    unknown: usize = 0,
    /// Results kept because a deduplicated read later in the history points
    /// at them; replacing one would leave that pointer empty.
    referenced: usize = 0,
    /// Bytes the dropped results contributed, after subtracting the markers
    /// that took their place.
    freed_bytes: usize = 0,
};

/// Replace the output of the tool results `ids` name with a short marker, so
/// later requests stop paying for output the model no longer needs.
///
/// Both halves of the pairing stay. A Responses request must answer every
/// function_call with its function_call_output, and an assistant message
/// replays the exact output items it was given, so deleting either side would
/// break the next request. Only the result text changes, which is also what
/// keeps a restored session replayable.
///
/// Markers are built before any message is touched, so a failed allocation
/// leaves the history whole rather than half dropped.
pub fn dropToolResults(
    allocator: std.mem.Allocator,
    messages: []Message,
    ids: []const []const u8,
) !DropReport {
    const Replacement = struct { index: usize, content: []u8 };

    var report: DropReport = .{};
    var replacements: std.ArrayList(Replacement) = .empty;
    var applied: usize = 0;
    defer {
        for (replacements.items[applied..]) |replacement| allocator.free(replacement.content);
        replacements.deinit(allocator);
    }
    try replacements.ensureTotalCapacity(allocator, ids.len);

    for (ids) |id| {
        const index = findToolResult(messages, id) orelse {
            report.unknown += 1;
            continue;
        };
        // A result with no body has nothing to free, which is the same no-op
        // as dropping one that was already dropped.
        const content = messages[index].content orelse {
            report.repeated += 1;
            continue;
        };
        if (std.mem.startsWith(u8, content, dropped_prefix) or queued(replacements.items, index)) {
            report.repeated += 1;
            continue;
        }
        if (referencedLater(messages, index, id)) {
            report.referenced += 1;
            continue;
        }
        const name = droppedCallName(messages, index, id) orelse "tool";
        const marker = try std.fmt.allocPrint(allocator, dropped_marker, .{
            truncateUtf8(name, 64),
            truncateUtf8(id, 128),
        });
        replacements.appendAssumeCapacity(.{ .index = index, .content = marker });
        report.dropped += 1;
        report.freed_bytes += content.len -| marker.len;
    }

    for (replacements.items) |replacement| {
        const message = &messages[replacement.index];
        if (message.content) |old| allocator.free(old);
        message.content = replacement.content;
        applied += 1;
    }
    return report;
}

fn findToolResult(messages: []const Message, id: []const u8) ?usize {
    for (messages, 0..) |message, index| {
        if (!std.mem.eql(u8, message.role, "tool")) continue;
        const call_id = message.tool_call_id orelse continue;
        if (std.mem.eql(u8, call_id, id)) return index;
    }
    return null;
}

fn queued(replacements: anytype, index: usize) bool {
    for (replacements) |replacement| {
        if (replacement.index == index) return true;
    }
    return false;
}

/// A result message carries only the call id; the tool that produced it is
/// named on the nearest preceding assistant call, which is the only place the
/// dropped marker can learn what it is telling the model to run again.
fn droppedCallName(messages: []const Message, index: usize, id: []const u8) ?[]const u8 {
    var position = index;
    while (position > 0) {
        position -= 1;
        const calls = messages[position].tool_calls orelse continue;
        for (calls) |call| {
            if (std.mem.eql(u8, call.id, id)) return call.name;
        }
    }
    return null;
}

/// A deduplicated read points at the original output instead of repeating it.
/// Dropping that original would leave the model following an empty pointer, so
/// a referenced result is kept and reported as such.
fn referencedLater(messages: []const Message, index: usize, id: []const u8) bool {
    for (messages[index + 1 ..]) |message| {
        if (!std.mem.eql(u8, message.role, "tool")) continue;
        const content = message.content orelse continue;
        const found = std.mem.indexOf(u8, content, reference_prefix) orelse continue;
        const rest = content[found + reference_prefix.len ..];
        if (!std.mem.startsWith(u8, rest, id)) continue;
        if (std.mem.eql(u8, rest[id.len..], reference_suffix)) return true;
    }
    return false;
}

test "read deduplication compares effective arguments and contents only in live history" {
    const a = std.testing.allocator;
    var calls = [_]openai.ToolCallData{.{ .id = "original", .name = "read", .arguments = "{\"path\":\"a.zig\"}" }};
    const messages = [_]Message{
        .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null },
        .{ .role = "tool", .content = "file contents", .reasoning_content = null, .tool_calls = null, .tool_call_id = "original" },
    };
    const duplicate = try deduplicateReadResult(a, &messages, .{
        .id = "new",
        .name = "read",
        .arguments = "{ \"start_line\": 1, \"path\": \"a.zig\" }",
    }, "file contents", false);
    defer a.free(duplicate);
    try std.testing.expect(std.mem.startsWith(u8, duplicate, "[Duplicate read omitted:"));
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "original") != null);

    const Case = struct { name: []const u8 = "read", args: []const u8 = "{\"path\":\"a.zig\"}", content: []const u8 = "file contents", is_error: bool = false };
    for ([_]Case{
        .{ .args = "{\"path\":\"b.zig\"}" },
        .{ .args = "{\"path\":\"a.zig\",\"start_line\":2}" },
        .{ .args = "{\"path\":\"a.zig\",\"start_column\":2}" },
        .{ .args = "{\"path\":\"a.zig\",\"end_line\":5}" },
        .{ .content = "changed contents" },
        .{ .is_error = true },
        .{ .name = "bash" },
        .{ .args = "invalid json" },
        .{ .args = "{\"path\":\"a.zig\",\"start_line\":0}" },
    }) |case| {
        const result = try deduplicateReadResult(a, &messages, .{ .id = "new", .name = case.name, .arguments = case.args }, case.content, case.is_error);
        defer a.free(result);
        try std.testing.expectEqualStrings(case.content, result);
    }

    // The original result is gone. A remaining marker is not a cache hit.
    const compacted = [_]Message{
        messages[0],
        .{ .role = "tool", .content = duplicate, .reasoning_content = null, .tool_calls = null, .tool_call_id = "original" },
    };
    const reread = try deduplicateReadResult(a, &compacted, calls[0], "file contents", false);
    defer a.free(reread);
    try std.testing.expectEqualStrings("file contents", reread);
    const empty = try deduplicateReadResult(a, &.{}, calls[0], "file contents", false);
    defer a.free(empty);
    try std.testing.expectEqualStrings("file contents", empty);
}

/// Bytes of message content in the history: what a drop can shrink.
fn contentBytes(messages: []const Message) usize {
    var total: usize = 0;
    for (messages) |message| total += if (message.content) |content| content.len else 0;
    return total;
}

/// A history entry that owns its strings, the way the agent builds one. The
/// dropped-result tests need messages `Message.deinit` can free.
fn testMessage(allocator: std.mem.Allocator, role: []const u8, content: ?[]const u8) !Message {
    return .{
        .role = role,
        .content = if (content) |value| try allocator.dupe(u8, value) else null,
        .reasoning_content = null,
        .tool_calls = null,
        .tool_call_id = null,
    };
}

/// One assistant call whose strings the history owns, so dropping can be
/// tested against the same ownership rules the agent uses.
fn testCall(allocator: std.mem.Allocator, id: []const u8, name: []const u8, arguments: []const u8) ![]openai.ToolCallData {
    const calls = try allocator.alloc(openai.ToolCallData, 1);
    errdefer allocator.free(calls);
    calls[0] = .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .arguments = try allocator.dupe(u8, arguments),
    };
    return calls;
}

fn freeMessages(allocator: std.mem.Allocator, history: *std.ArrayList(Message)) void {
    for (history.items) |message| message.deinit(allocator);
    history.deinit(allocator);
}

test "dropping a tool result keeps the call and its pairing" {
    const allocator = std.testing.allocator;
    const output = try allocator.alloc(u8, 4_000);
    defer allocator.free(output);
    @memset(output, 'x');

    var history: std.ArrayList(Message) = .empty;
    defer freeMessages(allocator, &history);
    try history.append(allocator, try testMessage(allocator, "system", "sys"));
    try history.append(allocator, try testMessage(allocator, "user", "build it"));
    var call = try testMessage(allocator, "assistant", null);
    call.tool_calls = try testCall(allocator, "call-1", "bash", "{\"command\":\"zig build test\"}");
    try history.append(allocator, call);
    var result = try testMessage(allocator, "tool", output);
    result.tool_call_id = try allocator.dupe(u8, "call-1");
    try history.append(allocator, result);

    const before = contentBytes(history.items);
    const report = try dropToolResults(allocator, history.items, &.{"call-1"});

    try std.testing.expectEqual(@as(usize, 1), report.dropped);
    try std.testing.expect(report.freed_bytes > 3_000);
    try std.testing.expect(contentBytes(history.items) < before);
    // Nothing moved: the call still answers, and the result still belongs to it.
    try std.testing.expectEqual(@as(usize, 4), history.items.len);
    try std.testing.expectEqualStrings("call-1", history.items[2].tool_calls.?[0].id);
    try std.testing.expectEqualStrings("call-1", history.items[3].tool_call_id.?);
    const marker = history.items[3].content.?;
    try std.testing.expect(std.mem.indexOf(u8, marker, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, marker, "call-1") != null);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try openai.writeInput(allocator, &aw.writer, history.items);
    const wire = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, wire, "function_call_output") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, output) == null);
}

test "dropping reports repeats and ids no live result answers" {
    const allocator = std.testing.allocator;
    var history: std.ArrayList(Message) = .empty;
    defer freeMessages(allocator, &history);
    try history.append(allocator, try testMessage(allocator, "system", "sys"));
    var call = try testMessage(allocator, "assistant", null);
    call.tool_calls = try testCall(allocator, "call-1", "read", "{\"path\":\"a.zig\"}");
    try history.append(allocator, call);
    var result = try testMessage(allocator, "tool", "file contents");
    result.tool_call_id = try allocator.dupe(u8, "call-1");
    try history.append(allocator, result);

    const report = try dropToolResults(allocator, history.items, &.{ "call-1", "call-1", "gone" });
    try std.testing.expectEqual(@as(usize, 1), report.dropped);
    try std.testing.expectEqual(@as(usize, 1), report.repeated);
    try std.testing.expectEqual(@as(usize, 1), report.unknown);

    // Dropping again changes nothing more: the marker is already there.
    const again = try dropToolResults(allocator, history.items, &.{"call-1"});
    try std.testing.expectEqual(@as(usize, 0), again.dropped);
    try std.testing.expectEqual(@as(usize, 1), again.repeated);
    try std.testing.expectEqual(@as(usize, 0), again.freed_bytes);
}

test "a result a deduplicated read points at is kept" {
    const allocator = std.testing.allocator;
    var history: std.ArrayList(Message) = .empty;
    defer freeMessages(allocator, &history);
    try history.append(allocator, try testMessage(allocator, "system", "sys"));
    var first = try testMessage(allocator, "assistant", null);
    first.tool_calls = try testCall(allocator, "call-1", "read", "{\"path\":\"a.zig\"}");
    try history.append(allocator, first);
    var original = try testMessage(allocator, "tool", "file contents");
    original.tool_call_id = try allocator.dupe(u8, "call-1");
    try history.append(allocator, original);
    var second = try testMessage(allocator, "assistant", null);
    second.tool_calls = try testCall(allocator, "call-2", "read", "{\"path\":\"a.zig\"}");
    try history.append(allocator, second);
    const reference = try std.fmt.allocPrint(allocator, duplicate_marker, .{ "00", "call-1" });
    var duplicate = try testMessage(allocator, "tool", reference);
    allocator.free(reference);
    duplicate.tool_call_id = try allocator.dupe(u8, "call-2");
    try history.append(allocator, duplicate);

    const report = try dropToolResults(allocator, history.items, &.{"call-1"});
    try std.testing.expectEqual(@as(usize, 0), report.dropped);
    try std.testing.expectEqual(@as(usize, 1), report.referenced);
    try std.testing.expectEqualStrings("file contents", history.items[2].content.?);
}
