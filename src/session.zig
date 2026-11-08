//! Opt-in durable conversations. API configuration and credentials are excluded.
const std = @import("std");
const openai = @import("openai.zig");
const Message = openai.Message;
const Snapshot = struct { version: u32 = 1, workspace: []const u8, messages: []Message };

pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, messages: []Message) !void {
    const cwd = std.Io.Dir.cwd();
    const workspace = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    const data = try std.json.Stringify.valueAlloc(allocator, Snapshot{ .workspace = workspace, .messages = messages }, .{});
    defer allocator.free(data);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    if (std.fs.path.dirname(path)) |parent| try cwd.createDirPath(io, parent);
    const file = try cwd.createFile(io, temporary, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer cwd.deleteFile(io, temporary) catch {};
    try file.writeStreamingAll(io, data);
    try cwd.rename(temporary, cwd, path, io);
}

/// Returns an owned list with canonical static role strings, ready for Agent.
/// A missing session is a new conversation. A corrupt/wrong-workspace one fails.
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(Message) {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => return err,
    };
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, data, .{});
    defer parsed.deinit();
    if (parsed.value.version != 1) return error.UnsupportedSessionVersion;
    const workspace = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    if (!std.mem.eql(u8, workspace, parsed.value.workspace)) return error.SessionWorkspaceMismatch;
    var messages: std.ArrayList(Message) = .empty;
    errdefer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit(allocator);
    }
    // Only checkpoint complete tool batches: unmatched calls indicate corrupt input.
    var pending: ?[]openai.ToolCallData = null;
    var next_tool: usize = 0;
    for (parsed.value.messages) |source| {
        var message: Message = .{ .role = undefined, .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = null };
        errdefer message.deinit(allocator);
        message.role = if (std.mem.eql(u8, source.role, "user")) "user" else if (std.mem.eql(u8, source.role, "assistant")) "assistant" else if (std.mem.eql(u8, source.role, "tool")) "tool" else return error.InvalidSessionRole;
        if (pending) |calls| {
            if (!std.mem.eql(u8, message.role, "tool") or source.tool_call_id == null or !std.mem.eql(u8, calls[next_tool].id, source.tool_call_id.?)) return error.InvalidSessionToolSequence;
            next_tool += 1;
            if (next_tool == calls.len) pending = null;
        } else if (std.mem.eql(u8, message.role, "tool")) return error.InvalidSessionToolSequence;
        if (source.content) |v| message.content = try allocator.dupe(u8, v);
        if (source.reasoning_content) |v| message.reasoning_content = try allocator.dupe(u8, v);
        if (source.response_items) |v| message.response_items = try allocator.dupe(u8, v);
        if (source.tool_call_id) |v| message.tool_call_id = try allocator.dupe(u8, v);
        if (source.tool_calls) |calls| {
            if (!std.mem.eql(u8, message.role, "assistant") or calls.len == 0) return error.InvalidSessionToolSequence;
            const owned = try allocator.alloc(openai.ToolCallData, calls.len);
            var copied: usize = 0;
            errdefer {
                for (owned[0..copied]) |call| call.deinit(allocator);
                allocator.free(owned);
            }
            for (calls, 0..) |call, i| {
                const id = try allocator.dupe(u8, call.id);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, call.name);
                errdefer allocator.free(name);
                owned[i] = .{ .id = id, .name = name, .arguments = try allocator.dupe(u8, call.arguments) };
                copied += 1;
            }
            message.tool_calls = owned;
            pending = calls;
            next_tool = 0;
        }
        try messages.append(allocator, message);
    }
    if (pending != null) return error.InvalidSessionToolSequence;
    return messages;
}

test "session roundtrip retains tool calls and reasoning" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "session.json" });
    defer allocator.free(path);
    var calls = [_]openai.ToolCallData{.{ .id = "1", .name = "shell", .arguments = "{}" }};
    var messages = [_]Message{
        .{ .role = "assistant", .content = null, .reasoning_content = "plan", .tool_calls = &calls, .tool_call_id = null, .response_items = "[{\"type\":\"reasoning\",\"id\":\"rs1\",\"summary\":[],\"encrypted_content\":\"opaque-token\"},{\"type\":\"function_call\",\"call_id\":\"1\",\"name\":\"shell\",\"arguments\":\"{}\"}]" },
        .{ .role = "tool", .content = "done", .reasoning_content = null, .tool_calls = null, .tool_call_id = "1" },
    };
    try save(io, allocator, path, &messages);
    var loaded = try load(io, allocator, path);
    defer {
        for (loaded.items) |message| message.deinit(allocator);
        loaded.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
    try std.testing.expectEqualStrings("plan", loaded.items[0].reasoning_content.?);
    try std.testing.expectEqualStrings(messages[0].response_items.?, loaded.items[0].response_items.?);
    try std.testing.expectEqualStrings("shell", loaded.items[0].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("done", loaded.items[1].content.?);
    try save(io, allocator, path, messages[0..1]);
    try std.testing.expectError(error.InvalidSessionToolSequence, load(io, allocator, path));
}
