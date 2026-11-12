const std = @import("std");
const memory = @import("../state/memory.zig");
const Agent = @import("../agent/mod.zig").Agent;
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
    return execute(agent, args);
}

pub fn execute(self: *Agent, arguments: []const u8) !tool.ToolResult {
    const parsed = std.json.parseFromSlice(struct {
        query: []const u8,
        limit: usize = 5,
    }, self.allocator, arguments, .{}) catch {
        return .{ .content = try self.allocator.dupe(u8, "Error: memory_search requires a query string and an optional integer limit (1-10)."), .is_error = true };
    };
    defer parsed.deinit();
    const args = parsed.value;
    if (std.mem.trim(u8, args.query, " \t\r\n").len == 0 or args.query.len > 512 or
        !std.unicode.utf8ValidateSlice(args.query) or args.limit < 1 or args.limit > 10)
    {
        return .{ .content = try self.allocator.dupe(u8, "Error: query must be non-empty UTF-8 (at most 512 bytes); limit must be 1-10."), .is_error = true };
    }
    return .{
        .content = try self.memory.search(self.allocator, args.query, args.limit, memory.search_budget),
        .is_error = !self.memory.enabled,
    };
}
