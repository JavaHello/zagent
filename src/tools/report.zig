const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "report",
    .description = "Send the agent that called you a short progress report and wait for its decision. It is how a check-in is answered: the caller reads the report, then either tells you to continue or stops the task and asks for your final report. Keep it to a status line — what is done, what you ran, what is left — not the final answer.",
    .parameters_json =
    \\{"type":"object","properties":{"summary":{"type":"string","description":"Short progress report: what you have done and changed, what you ran and what it printed, what is verified, and what is left"}},"required":["summary"]}
    ,
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return agent.reportTool(args);
}
