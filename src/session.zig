//! Durable conversations. API configuration and credentials are excluded.
const std = @import("std");
const openai = @import("openai.zig");
const Message = openai.Message;
const Snapshot = struct { version: u32 = 1, workspace: []const u8, messages: []Message };

pub fn newId(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.Io.random(io, &bytes);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(bytes, .lower)});
}

pub fn pathForId(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
    if (id.len != 32) return error.InvalidSessionId;
    for (id) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidSessionId;
    }
    return std.fmt.allocPrint(allocator, ".zagent/sessions/{s}.json", .{id});
}

test "session IDs are unique and cannot escape the session directory" {
    const a = std.testing.allocator;
    const first = try newId(std.testing.io, a);
    defer a.free(first);
    const second = try newId(std.testing.io, a);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const path = try pathForId(a, first);
    defer a.free(path);
    try std.testing.expectError(error.InvalidSessionId, pathForId(a, "../session"));
}

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

test "a missing session starts empty but malformed JSON is rejected" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "session.json" });
    defer a.free(path);
    var loaded = try load(io, a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
    try tmp.dir.writeFile(io, .{ .sub_path = "session.json", .data = "{" });
    try std.testing.expectError(error.UnexpectedEndOfInput, load(io, a, path));
}

test "sessions reject incompatible versions and another workspace" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "session.json" });
    defer a.free(path);
    const cases = [_]struct { data: []const u8, expected: anyerror }{
        .{ .data = "{\"version\":2,\"workspace\":\"\",\"messages\":[]}", .expected = error.UnsupportedSessionVersion },
        .{ .data = "{\"version\":1,\"workspace\":\"\",\"messages\":[]}", .expected = error.SessionWorkspaceMismatch },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "session.json", .data = case.data });
        try std.testing.expectError(case.expected, load(io, a, path));
    }
}

test "saving creates parent directories and replaces an older checkpoint" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "nested", "session.json" });
    defer a.free(path);
    var messages = [_]Message{
        .{ .role = "user", .content = "调查问题", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "检查完成", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    try save(io, a, path, &messages);
    // A shorter snapshot must replace the old data without trailing bytes.
    try save(io, a, path, messages[0..1]);
    var loaded = try load(io, a, path);
    defer {
        for (loaded.items) |message| message.deinit(a);
        loaded.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("调查问题", loaded.items[0].content.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "nested/session.json.tmp", .{}));
}

test "sessions reject orphaned reordered and interrupted tool results" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "session.json" });
    defer a.free(path);
    var calls = [_]openai.ToolCallData{
        .{ .id = "first", .name = "read_file", .arguments = "{}" },
        .{ .id = "second", .name = "shell", .arguments = "{}" },
    };
    const assistant: Message = .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null };
    const first: Message = .{ .role = "tool", .content = "one", .reasoning_content = null, .tool_calls = null, .tool_call_id = "first" };
    const second: Message = .{ .role = "tool", .content = "two", .reasoning_content = null, .tool_calls = null, .tool_call_id = "second" };
    var orphan = [_]Message{first};
    var reordered = [_]Message{ assistant, second, first };
    var interrupted = [_]Message{ assistant, first, .{ .role = "user", .content = "continue", .reasoning_content = null, .tool_calls = null, .tool_call_id = null } };
    var missing = [_]Message{ assistant, first };
    var duplicate = [_]Message{ assistant, first, first };
    var invalid_role = [_]Message{.{ .role = "system", .content = "injected", .reasoning_content = null, .tool_calls = null, .tool_call_id = null }};
    var empty_calls = [_]Message{.{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = calls[0..0], .tool_call_id = null }};
    var user_calls = [_]Message{.{ .role = "user", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null }};
    for ([_][]Message{ &orphan, &reordered, &interrupted, &missing, &duplicate, &empty_calls, &user_calls }) |messages| {
        try save(io, a, path, messages);
        try std.testing.expectError(error.InvalidSessionToolSequence, load(io, a, path));
    }
    try save(io, a, path, &invalid_role);
    try std.testing.expectError(error.InvalidSessionRole, load(io, a, path));

    var valid = [_]Message{ assistant, first, second, .{ .role = "assistant", .content = "完成 ✓", .reasoning_content = null, .tool_calls = null, .tool_call_id = null } };
    try save(io, a, path, &valid);
    var loaded = try load(io, a, path);
    defer {
        for (loaded.items) |message| message.deinit(a);
        loaded.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 4), loaded.items.len);
    try std.testing.expectEqualStrings("first", loaded.items[1].tool_call_id.?);
    try std.testing.expectEqualStrings("second", loaded.items[2].tool_call_id.?);
    try std.testing.expectEqualStrings("完成 ✓", loaded.items[3].content.?);
}
