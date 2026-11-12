//! Context rewriting: read output a model would otherwise be handed twice.
//!
//! The conversation is a sequence a Responses request replays, so every
//! replacement here swaps a result's content in place; no message is added or
//! removed, and a result keeps the call that produced it.
const std = @import("std");
const openai = @import("../model/openai.zig");
const Message = openai.Message;

/// The marker standing in for a read whose output is already in the history.
/// The reference it carries is only a pointer, which is why the original
/// result it names is never treated as a cache hit.
const duplicate_marker = "[Duplicate read omitted: same path, page and content SHA-256={s}. See earlier tool result {s} in this context.]";

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
                        const marker = try std.fmt.allocPrint(allocator, duplicate_marker, .{ std.fmt.bytesToHex(content_digest, .lower), id });
                        if (marker.len < content.len) return marker;
                        allocator.free(marker);
                        return allocator.dupe(u8, content);
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
    const page = @import("../tools/mod.zig").parseReadPage(allocator, call.arguments) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(path.string);
    // A length prefix prevents a path from being confused with page bytes.
    var fields: [24]u8 = undefined;
    std.mem.writeInt(u64, fields[0..8], @intCast(path.string.len), .little);
    std.mem.writeInt(u64, fields[8..16], @intCast(page.offset), .little);
    // 0 is a limit no caller can ask for, so it marks the page that has none.
    std.mem.writeInt(u64, fields[16..24], @intCast(page.limit orelse 0), .little);
    hash.update(&fields);
    hash.update(content);
    return hash.finalResult();
}

test "read deduplication compares effective arguments and contents only in live history" {
    const a = std.testing.allocator;
    const long_content = "file contents: abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    var calls = [_]openai.ToolCallData{.{ .id = "original", .name = "read", .arguments = "{\"path\":\"a.zig\"}" }};
    const messages = [_]Message{
        .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null },
        .{ .role = "tool", .content = long_content, .reasoning_content = null, .tool_calls = null, .tool_call_id = "original" },
    };
    const duplicate = try deduplicateReadResult(a, &messages, .{
        .id = "new",
        .name = "read",
        .arguments = "{ \"offset\": 1, \"path\": \"a.zig\" }",
    }, long_content, false);
    defer a.free(duplicate);
    try std.testing.expect(std.mem.startsWith(u8, duplicate, "[Duplicate read omitted:"));
    try std.testing.expect(std.mem.indexOf(u8, duplicate, "original") != null);

    const Case = struct { name: []const u8 = "read", args: []const u8 = "{\"path\":\"a.zig\"}", content: []const u8 = long_content, is_error: bool = false };
    for ([_]Case{
        .{ .args = "{\"path\":\"b.zig\"}" },
        .{ .args = "{\"path\":\"a.zig\",\"offset\":2}" },
        .{ .args = "{\"path\":\"a.zig\",\"limit\":1}" },
        .{ .args = "{\"path\":\"a.zig\",\"offset\":1,\"limit\":5}" },
        .{ .content = "changed contents" },
        .{ .is_error = true },
        .{ .name = "bash" },
        .{ .args = "invalid json" },
        .{ .args = "{\"path\":\"a.zig\",\"offset\":0}" },
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
    const reread = try deduplicateReadResult(a, &compacted, calls[0], long_content, false);
    defer a.free(reread);
    try std.testing.expectEqualStrings(long_content, reread);
    const empty = try deduplicateReadResult(a, &.{}, calls[0], long_content, false);
    defer a.free(empty);
    try std.testing.expectEqualStrings(long_content, empty);

    // Even identical reads must not grow the context (including equal sizes).
    const boundary = try std.fmt.allocPrint(a, duplicate_marker, .{ "0000000000000000000000000000000000000000000000000000000000000000", "original" });
    defer a.free(boundary);
    for ([_][]const u8{ "", "short", boundary }) |content| {
        const short_messages = [_]Message{
            messages[0],
            .{ .role = "tool", .content = content, .reasoning_content = null, .tool_calls = null, .tool_call_id = "original" },
        };
        const result = try deduplicateReadResult(a, &short_messages, calls[0], content, false);
        defer a.free(result);
        try std.testing.expectEqualStrings(content, result);
    }
}
