const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "ask_user",
    .description = "Ask the user to choose between concrete options when the request is ambiguous or a decision only they can make blocks progress. Several such calls sent together are put to the user as one form.",
    .parameters_json =
    \\{"type":"object","properties":{"question":{"type":"string","description":"The decision that is needed, in one sentence"},"options":{"type":"array","description":"Two to four concrete choices","items":{"type":"object","properties":{"label":{"type":"string","description":"Short name of the choice"},"description":{"type":"string","description":"One sentence on what this choice means"},"recommended":{"type":"boolean","description":"True for the option you would pick"}},"required":["label"]}}},"required":["question","options"]}
    ,
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return agent.askUser(args, ctx.answers, ctx.index);
}
