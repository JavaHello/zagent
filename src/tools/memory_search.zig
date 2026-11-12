const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "memory_search",
    .description = "Search durable workspace notes by keyword and return the ranked matches. Lexical matching for Chinese and English, not semantic.",
    .parameters_json =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Short keywords, non-empty UTF-8, at most 512 bytes"},"limit":{"type":"integer","minimum":1,"maximum":10,"description":"Maximum notes to return, default 5"}},"required":["query"]}
    ,
    .label = "searching memory…",
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return agent.memorySearchTool(args);
}
