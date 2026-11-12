const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "plan",
    .description = "Read or update the plan for the work in progress: with no arguments it returns the complete plan, with 'steps' it replaces the whole plan (an empty array clears it), and with 'index' plus 'status' or 'note' it updates one step. Successful updates return only a brief change acknowledgement, not the checklist; call with no arguments to read it. The plan belongs to the session — it is saved with it and restored when it is resumed — so it, not the message history, is the map of long work.",
    .parameters_json =
    \\{"type":"object","properties":{"steps":{"type":"array","description":"The complete ordered plan, replacing the current one: one short line per step that can be verified on its own. At most 50 steps.","maxItems":50,"items":{"type":"object","properties":{"title":{"type":"string","description":"One line: what this step accomplishes"},"status":{"type":"string","enum":["pending","in_progress","completed","blocked"],"description":"Defaults to pending; at most one step is in_progress"},"note":{"type":"string","description":"Optional one-line reason kept under the step, for example why it is blocked"}},"required":["title"]}},"index":{"type":"integer","minimum":1,"description":"1-based step to update, when 'steps' is omitted"},"status":{"type":"string","enum":["pending","in_progress","completed","blocked"],"description":"New status for that step"},"note":{"type":"string","description":"New note for that step; an empty string removes the old one"}},"required":[]}
    ,
    .label = "plan…",
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return agent.planTool(args);
}
