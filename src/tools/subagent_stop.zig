const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "subagent_stop",
    .description = "Stop a sub-agent that is paused at a progress report and take its final report as the tool result. It gets one last turn to write that report and does no new work, so anything unfinished is named as unfinished.",
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string","description":"The id of the paused sub-agent, as its progress report named it"}},"required":["id"]}
    ,
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return agent.subagentStopTool(args);
}
