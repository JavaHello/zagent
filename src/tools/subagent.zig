const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "subagent",
    .description = "Hand one self-contained task to a sub-agent that works on its own and returns a short report. The sub-agent does not read this conversation, cannot ask the user and cannot change the plan, so the task must carry everything it needs. Give it a 'title' — a one-line summary of the task, fewer than 80 characters — because that is what the terminal shows while the run works. Use it for a step whose tool output would flood this conversation; verify its work yourself before marking a plan step done. The sub-agent has no limits of its own: you watch it instead. 'checkin_seconds' is how long it works before it is asked for a progress report, and the call returns with that report, the final report, or the end of the run. A run that reported is paused: call subagent again with its 'id' to let it carry on, or subagent_stop with its 'id' to stop it and take its final report.",
    .parameters_json =
    \\{"type":"object","properties":{"task":{"type":"string","description":"One self-contained task: what to do and how it is verified, in full, since the sub-agent does not read this conversation. Omit it to resume or to start a second sub-agent by 'id'."},"title":{"type":"string","maxLength":79,"description":"One-line summary of the task, fewer than 80 Unicode characters: the terminal shows it on the call's line and while the run works. Omit it and that line falls back to the task itself."},"context":{"type":"string","description":"Optional facts the sub-agent needs: file paths, decisions already made, the shape of the expected change. Keep it short."},"id":{"type":"string","description":"The id of a sub-agent that is paused at a progress report: the call lets it carry on and returns its next report or its final one. Omit it to start a new sub-agent with 'task'."},"checkin_seconds":{"type":"integer","minimum":0,"maximum":3600,"description":"How long the sub-agent works before it is asked for a progress report, default 300. It is not a limit on the work: at the check-in the run pauses with that report, and you decide whether to go on. 0 asks for the report at the next request boundary."}},"required":[]}
    ,
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return agent.subagentTool(args);
}
