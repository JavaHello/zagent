const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "memory_save",
    .description = "Save one durable note to memory so it survives this session: add a note, or replace or delete an exact existing one.",
    .parameters_json =
    \\{"type":"object","properties":{"text":{"type":"string","description":"Note to add, new note for replace, or exact existing note for delete"},"action":{"type":"string","enum":["add","replace","delete"],"description":"Default add; replace and delete require an exact existing note"},"old_text":{"type":"string","description":"Exact existing note to replace; required only for replace"}},"required":["text"]}
    ,
    .label = "saving memory…",
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return agent.memorySaveTool(args);
}
