const std = @import("std");
const Agent = @import("../agent/mod.zig").Agent;
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "subagent_stop",
    .description = "Stop a sub-agent that is paused at a progress report and take its final report as the tool result. It gets one last turn to write that report and does no new work, so anything unfinished is named as unfinished.",
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string","description":"The id of the paused sub-agent, as its progress report named it"}},"required":["id"]}
    ,
    .run = run,
    .delegated = true,
    .progress = writeProgress,
};

fn writeProgress(ctx: tool.Context, buf: *std.Io.Writer.Allocating, arguments: []const u8) !?[]const u8 {
    try buf.writer.writeAll("subagent · ");
    const id = @import("../model/openai.zig").extractStringArg(ctx.allocator, arguments, "id") catch null;
    defer if (id) |value| ctx.allocator.free(value);
    if (ctx.agent) |agent| {
        const stopped = if (id) |value| agent.findRun(std.mem.trim(u8, value, " \t\r\n")) else null;
        if (stopped) |run_state| {
            if (run_state.title.len > 0) {
                try @import("subagent.zig").writeCallBrief(&buf.writer, run_state.title);
                try buf.writer.writeAll(" · ");
            }
        }
    }
    try buf.writer.writeAll("stopping…");
    return buf.written();
}

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args);
}

pub fn execute(self: *Agent, arguments: []const u8) anyerror!tool.ToolResult {
    if (self.role == .subagent) return .{
        .content = try self.allocator.dupe(u8, "A sub-agent cannot stop a run: its own task ends when its caller says so."),
        .is_error = true,
    };
    const parsed = std.json.parseFromSlice(struct { id: []const u8 }, self.allocator, arguments, .{}) catch {
        return .{
            .content = try self.allocator.dupe(u8, "Error: subagent_stop takes the 'id' the run's progress report named."),
            .is_error = true,
        };
    };
    defer parsed.deinit();
    const child = self.findRun(parsed.value.id) orelse return .{
        .content = try std.fmt.allocPrint(self.allocator, "Error: no sub-agent has the id \"{s}\"; one that has finished is gone.", .{parsed.value.id}),
        .is_error = true,
    };
    return self.stopRun(child);
}
