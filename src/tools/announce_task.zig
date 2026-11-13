const std = @import("std");
const sanitize = @import("../util/terminal/sanitize.zig");
const Agent = @import("../agent/mod.zig").Agent;
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "announce_task",
    .description = "Announce the task being started: a short title for the terminal and a description of the goal and approach, in the user's language. Call it before the first tool call of every turn that does work, including a task that follows chat.",
    .parameters_json =
    \\{"type":"object","properties":{"title":{"type":"string","minLength":1,"maxLength":79,"description":"Concise task title, fewer than 80 Unicode characters, not the user's raw text"},"description":{"type":"string","minLength":1,"description":"Brief goal and practical approach shown to the user"}},"required":["title","description"],"additionalProperties":false}
    ,
    .summary = writeSummary,
    .run = run,
};

/// The call is named by the title it announces: the description is the part
/// the user is shown, so repeating it as escaped JSON on the call's own line
/// would say the same thing twice.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(struct { title: []const u8 }, ctx.allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    if (parsed.value.title.len == 0) return false;
    try sanitize.writeOnOneLine(w, parsed.value.title);
    return true;
}

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args);
}

pub fn execute(self: *Agent, arguments: []const u8) !tool.ToolResult {
    if (self.role == .subagent) return .{
        .output = try self.allocator.dupe(u8, "A sub-agent does not announce tasks: the agent that called you owns the terminal and the plan. Report back instead."),
        .is_error = true,
    };
    const parsed = try std.json.parseFromSlice(struct { title: []const u8, description: []const u8 }, self.allocator, arguments, .{});
    defer parsed.deinit();
    const title = std.mem.trim(u8, parsed.value.title, " \t\r\n");
    const description = std.mem.trim(u8, parsed.value.description, " \t\r\n");
    const count = std.unicode.utf8CountCodepoints(title) catch return error.InvalidTaskTitle;
    if (count == 0 or count >= 80 or description.len == 0 or !std.unicode.utf8ValidateSlice(description)) return error.InvalidTaskMetadata;
    const owned = try self.allocator.dupe(u8, title);
    if (self.current_task.len > 0) self.allocator.free(self.current_task);
    self.current_task = owned;
    self.terminal_title.update("thinking…", self.current_task);
    try self.writeAnswer(description);
    return .{ .output = try self.allocator.dupe(u8, "Task announced; the description is shown to the user."), .is_error = false };
}

test "the call line names the task, not its JSON arguments" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const ctx: tool.Context = .{ .io = std.testing.io, .allocator = std.testing.allocator };

    try std.testing.expect(try writeSummary(ctx, &aw.writer, "{\"title\":\"调整\\nTUI 通知\",\"description\":\"说明\"}"));
    // The title is model output, and the line is one line.
    try std.testing.expectEqualStrings("调整 TUI 通知", aw.written());

    // Arguments without a title leave the raw arguments on the line instead of
    // an empty one: the tool refuses them a moment later.
    aw.clearRetainingCapacity();
    try std.testing.expect(!try writeSummary(ctx, &aw.writer, "{}"));
}

test "task metadata requires title and description and fewer than 80 Unicode characters" {
    const allocator = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    // Only the announcement's dependencies are initialized: no client, process,
    // scratch directory, or terminal is needed for this tool-local test.
    var agent: Agent = undefined;
    agent.allocator = allocator;
    agent.role = .main;
    agent.current_task = "";
    agent.terminal_title = .{ .io = std.testing.io, .enabled = false };
    agent.render_markdown = false;
    agent.capture = &output;
    defer if (agent.current_task.len > 0) allocator.free(agent.current_task);

    for ([_][]const u8{ "{}", "{\"title\":\"t\"}", "{\"title\":\"\",\"description\":\"d\"}", "{\"title\":\"t\",\"description\":\" \"}" }) |args| {
        if (execute(&agent, args)) |result| {
            result.deinit(allocator);
            return error.ExpectedInvalidMetadata;
        } else |_| {}
        try std.testing.expectEqualStrings("", agent.current_task);
        try std.testing.expectEqualStrings("", output.items);
    }
    var title: std.ArrayList(u8) = .empty;
    defer title.deinit(allocator);
    for (0..79) |_| try title.appendSlice(allocator, "题");
    const valid = try std.json.Stringify.valueAlloc(allocator, .{ .title = title.items, .description = "测试" }, .{});
    defer allocator.free(valid);
    const result = try execute(&agent, valid);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings(title.items, agent.current_task);
    try std.testing.expectEqualStrings("测试", output.items);
    try title.appendSlice(allocator, "题");
    const invalid = try std.json.Stringify.valueAlloc(allocator, .{ .title = title.items, .description = "测试" }, .{});
    defer allocator.free(invalid);
    try std.testing.expectError(error.InvalidTaskMetadata, execute(&agent, invalid));
    try std.testing.expectEqualStrings(title.items[0 .. 79 * "题".len], agent.current_task);
    try std.testing.expectEqualStrings("测试", output.items);
}
