//! Durable conversations. API configuration and credentials are excluded.
const std = @import("std");
const openai = @import("../model/openai.zig");
const plan_mod = @import("plan.zig");
const Message = openai.Message;
// Persisted fields are required: old snapshot shapes are not migrated.
const StoredMessage = struct {
    role: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    tool_calls: ?[]openai.ToolCallData,
    tool_call_id: ?[]const u8,
    response_items: ?[]const u8,
    tool_status: ?@import("../tools/mod.zig").ToolStatus,
};
/// The plan travels with the conversation: it is state of the session, not a
/// file of its own, so the snapshot carries it next to the messages.
const Snapshot = struct {
    version: u32,
    workspace: []const u8,
    messages: []StoredMessage,
    plan: []plan_mod.Stored,
    child: ?Child = null,
};

/// Child identity is scoped to the parent snapshot's path.
pub const Child = struct {
    parent: []const u8,
    id: []const u8,
    title: []const u8,
    status: enum { running, interrupted, completed, failed } = .running,
};
/// Bumped when a field is added, so an older snapshot is refused instead of
/// resumed with half its state.
const schema_version: u32 = 2;

/// What a session holds: its messages and the plan of the work in progress.
pub const Loaded = struct {
    messages: std.ArrayList(Message),
    plan: plan_mod.Plan,
    child: ?Child = null,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| message.deinit(allocator);
        self.messages.deinit(allocator);
        self.plan.deinit();
        if (self.child) |child| {
            allocator.free(child.parent);
            allocator.free(child.id);
            allocator.free(child.title);
        }
        self.* = undefined;
    }
};

pub fn newId(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.Io.random(io, &bytes);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(bytes, .lower)});
}

pub fn validateId(id: []const u8) !void {
    if (id.len != 32) return error.InvalidSessionId;
    for (id) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidSessionId;
    }
}

test "child pending tools become unknown outcomes and running becomes interrupted" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "child.json" });
    defer a.free(path);
    var plan = plan_mod.Plan.init(a);
    defer plan.deinit();
    var calls = [_]openai.ToolCallData{.{ .id = "unknown", .name = "bash", .arguments = "{}" }};
    var messages = [_]Message{.{ .role = "assistant", .content = null, .reasoning_content = "thinking", .tool_calls = &calls, .tool_call_id = null }};
    try saveChild(io, a, path, &messages, &plan, .{ .parent = "parent", .id = "s7", .title = "child title" });
    var loaded = try load(io, a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqualStrings("parent", loaded.child.?.parent);
    try std.testing.expectEqualStrings("s7", loaded.child.?.id);
    try std.testing.expectEqualStrings("child title", loaded.child.?.title);
    try std.testing.expect(loaded.child.?.status == .interrupted);
    try std.testing.expectEqual(@as(usize, 2), loaded.messages.items.len);
    try std.testing.expectEqualStrings("unknown", loaded.messages.items[1].tool_call_id.?);
    try std.testing.expect(loaded.messages.items[1].tool_status.?.is_error);
    try std.testing.expect(std.mem.indexOf(u8, loaded.messages.items[1].content.?, "NOT replayed") != null);
    try saveChild(io, a, path, loaded.messages.items, &plan, .{ .parent = "parent", .id = "s7", .title = "child title", .status = .completed });
    var again = try load(io, a, path);
    defer again.deinit(a);
    try std.testing.expect(again.child.?.status == .completed);
    try std.testing.expectEqual(@as(usize, 2), again.messages.items.len);
}

test "session IDs are unique and cannot escape the session directory" {
    const a = std.testing.allocator;
    const first = try newId(std.testing.io, a);
    defer a.free(first);
    const second = try newId(std.testing.io, a);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try validateId(first);
    try std.testing.expectError(error.InvalidSessionId, validateId("../session"));
    try std.testing.expectError(error.InvalidSessionId, validateId("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
}

pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, messages: []Message, plan: *const plan_mod.Plan) !void {
    return saveChild(io, allocator, path, messages, plan, null);
}

pub fn saveChild(io: std.Io, allocator: std.mem.Allocator, path: []const u8, messages: []Message, plan: *const plan_mod.Plan, child: ?Child) !void {
    const cwd = std.Io.Dir.cwd();
    const workspace = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    const steps = try plan.stored(allocator);
    defer allocator.free(steps);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    if (std.fs.path.dirname(path)) |parent| try cwd.createDirPath(io, parent);
    const file = try cwd.createFile(io, temporary, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer cwd.deleteFile(io, temporary) catch {};
    // Written straight to the file: a checkpoint is as large as the whole
    // conversation, and holding a serialized copy of it as well would double
    // that peak on every save.
    var buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    try std.json.Stringify.value(.{
        .version = schema_version,
        .workspace = workspace,
        .messages = messages,
        .plan = steps,
        .child = child,
    }, .{}, &file_writer.interface);
    try file_writer.interface.flush();
    try cwd.rename(temporary, cwd, path, io);
}

/// Returns owned messages with canonical static role strings, ready for Agent,
/// together with the plan the session carries.
/// A missing session is a new conversation. A corrupt/wrong-workspace one fails.
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Loaded {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .messages = .empty, .plan = plan_mod.Plan.init(allocator) },
        else => return err,
    };
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, data, .{});
    defer parsed.deinit();
    if (parsed.value.version != schema_version) return error.UnsupportedSessionVersion;
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
        message.tool_status = source.tool_status;
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
    if (pending) |calls| {
        if (parsed.value.child == null) return error.InvalidSessionToolSequence;
        // Never replay an unacknowledged side effect. Close the protocol with
        // an explicit unknown outcome; the model must inspect before retrying.
        for (calls[next_tool..]) |call| {
            const content = try allocator.dupe(u8, "Interrupted before confirmation. Outcome unknown; inspect state before retrying. This tool was NOT replayed.");
            errdefer allocator.free(content);
            const id = try allocator.dupe(u8, call.id);
            errdefer allocator.free(id);
            try messages.append(allocator, .{ .role = "tool", .content = content, .reasoning_content = null, .tool_calls = null, .tool_call_id = id, .tool_status = .{ .is_error = true } });
        }
    }
    const plan = restored: {
        var value = plan_mod.Plan.init(allocator);
        errdefer value.deinit();
        try value.restore(parsed.value.plan);
        break :restored value;
    };
    var child = parsed.value.child;
    if (child) |*value| {
        const parent = try allocator.dupe(u8, value.parent);
        errdefer allocator.free(parent);
        const id = try allocator.dupe(u8, value.id);
        errdefer allocator.free(id);
        value.title = try allocator.dupe(u8, value.title);
        value.parent = parent;
        value.id = id;
        if (value.status == .running) value.status = .interrupted;
    }
    return .{ .messages = messages, .plan = plan, .child = child };
}

test "session roundtrip retains tool calls, reasoning and the plan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "session.json" });
    defer allocator.free(path);
    var plan = plan_mod.Plan.init(allocator);
    defer plan.deinit();
    try plan.setSteps(&.{
        .{ .title = "read the code", .status = .completed },
        .{ .title = "write the module", .status = .in_progress, .note = "half way" },
    });
    var calls = [_]openai.ToolCallData{.{ .id = "1", .name = "shell", .arguments = "{}" }};
    var messages = [_]Message{
        .{ .role = "assistant", .content = null, .reasoning_content = "plan", .tool_calls = &calls, .tool_call_id = null, .response_items = "[{\"type\":\"reasoning\",\"id\":\"rs1\",\"summary\":[],\"encrypted_content\":\"opaque-token\"},{\"type\":\"function_call\",\"call_id\":\"1\",\"name\":\"shell\",\"arguments\":\"{}\"}]" },
        .{ .role = "tool", .content = "done", .reasoning_content = null, .tool_calls = null, .tool_call_id = "1", .tool_status = .{ .is_error = true, .exit_code = 7, .timed_out = true, .truncated = true } },
    };
    try save(io, allocator, path, &messages, &plan);
    var loaded = try load(io, allocator, path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.messages.items.len);
    try std.testing.expectEqualStrings("plan", loaded.messages.items[0].reasoning_content.?);
    try std.testing.expectEqualStrings(messages[0].response_items.?, loaded.messages.items[0].response_items.?);
    try std.testing.expectEqualStrings("shell", loaded.messages.items[0].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("done", loaded.messages.items[1].content.?);
    try std.testing.expectEqualDeep(messages[1].tool_status, loaded.messages.items[1].tool_status);
    try std.testing.expectEqual(@as(usize, 2), loaded.plan.steps.items.len);
    try std.testing.expectEqual(plan_mod.Status.in_progress, loaded.plan.steps.items[1].status);
    try std.testing.expectEqualStrings("half way", loaded.plan.steps.items[1].note.?);
    try save(io, allocator, path, messages[0..1], &plan);
    try std.testing.expectError(error.InvalidSessionToolSequence, load(io, allocator, path));
}

test "snapshots reject removed fields and require the current schema" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(StoredMessage, a, "{\"role\":\"tool\",\"content\":\"old\",\"reasoning_content\":null,\"tool_calls\":null,\"tool_call_id\":\"1\"}", .{}));
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Snapshot, a, "{\"version\":2,\"workspace\":\"\",\"messages\":[],\"plan\":[],\"scratch_dirs\":[]}", .{}));
    // Replaced plan enum values are not migrated or silently discarded.
    inline for (.{ "active", "done" }) |status| {
        try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Snapshot, a, "{\"version\":2,\"workspace\":\"\",\"messages\":[],\"plan\":[{\"title\":\"old step\",\"status\":\"" ++ status ++ "\"}]}", .{}));
    }
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Snapshot, a, "{\"workspace\":\"\",\"messages\":[],\"plan\":[]}", .{}));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Snapshot, a, "{\"version\":2,\"workspace\":\"\",\"messages\":[]}", .{}));
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
    try std.testing.expectEqual(@as(usize, 0), loaded.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.plan.steps.items.len);
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
        .{ .data = "{\"version\":3,\"workspace\":\"\",\"messages\":[],\"plan\":[]}", .expected = error.UnsupportedSessionVersion },
        // A snapshot from before the plan was part of the session is refused,
        // not resumed without the state it never had.
        .{ .data = "{\"version\":1,\"workspace\":\"\",\"messages\":[]}", .expected = error.MissingField },
        .{ .data = "{\"version\":2,\"workspace\":\"\",\"messages\":[],\"plan\":[]}", .expected = error.SessionWorkspaceMismatch },
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
    var plan = plan_mod.Plan.init(a);
    defer plan.deinit();
    var messages = [_]Message{
        .{ .role = "user", .content = "调查问题", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "检查完成", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    try save(io, a, path, &messages, &plan);
    // A shorter snapshot must replace the old data without trailing bytes.
    try save(io, a, path, messages[0..1], &plan);
    var loaded = try load(io, a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try std.testing.expectEqualStrings("调查问题", loaded.messages.items[0].content.?);
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
    var plan = plan_mod.Plan.init(a);
    defer plan.deinit();
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
        try save(io, a, path, messages, &plan);
        try std.testing.expectError(error.InvalidSessionToolSequence, load(io, a, path));
    }
    try save(io, a, path, &invalid_role, &plan);
    try std.testing.expectError(error.InvalidSessionRole, load(io, a, path));

    var valid = [_]Message{ assistant, first, second, .{ .role = "assistant", .content = "完成 ✓", .reasoning_content = null, .tool_calls = null, .tool_call_id = null } };
    try save(io, a, path, &valid, &plan);
    var loaded = try load(io, a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), loaded.messages.items.len);
    try std.testing.expectEqualStrings("first", loaded.messages.items[1].tool_call_id.?);
    try std.testing.expectEqualStrings("second", loaded.messages.items[2].tool_call_id.?);
    try std.testing.expectEqualStrings("完成 ✓", loaded.messages.items[3].content.?);
}
