const tool = @import("tool.zig");
pub const spec: tool.Tool = .{
    .name = "load_mcp_tools",
    .description = "Load a relevant MCP server's tools before using them. Choose an exact server name from the MCP service directory only when needed for the user's request. Loaded tools become available on the next request.",
    .parameters_json =
    \\{"type":"object","properties":{"server":{"type":"string","description":"Exact MCP server name from the directory"}},"required":["server"],"additionalProperties":false}
    ,
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return agent.mcp_registry.loadTools(ctx.allocator, args);
}
