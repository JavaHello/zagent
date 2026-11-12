const std = @import("std");
const Agent = @import("../agent/mod.zig").Agent;
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "announce_task",
    .description = "Announce the task being started: a short title for the terminal and a description of the goal and approach, in the user's language. Call it before the first tool call of every turn that does work, including a task that follows chat.",
    .parameters_json =
    \\{"type":"object","properties":{"title":{"type":"string","minLength":1,"maxLength":79,"description":"Concise task title, fewer than 80 Unicode characters, not the user's raw text"},"description":{"type":"string","minLength":1,"description":"Brief goal and practical approach shown to the user"}},"required":["title","description"],"additionalProperties":false}
    ,
    .quiet = true,
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args);
}

pub fn execute(self: *Agent, arguments: []const u8) !tool.ToolResult {
    if (self.role == .subagent) return .{
        .content = try self.allocator.dupe(u8, "A sub-agent does not announce tasks: the agent that called you owns the terminal and the plan. Report back instead."),
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
    return .{ .content = try self.allocator.dupe(u8, "Task announced; the description is shown to the user."), .is_error = false };
}
