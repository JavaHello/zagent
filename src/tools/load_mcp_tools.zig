const std = @import("std");
const Registry = @import("../mcp/mod.zig").Registry;
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
    return execute(agent.mcp_registry, ctx.allocator, args);
}

pub fn execute(self: *Registry, allocator: std.mem.Allocator, arguments_json: []const u8) !tool.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch {
        return errorResult(allocator, "Expected an object with a server name.", .{});
    };
    defer parsed.deinit();
    if (parsed.value != .object) return errorResult(allocator, "Expected an object with a server name.", .{});
    const name = parsed.value.object.get("server") orelse return errorResult(allocator, "Missing server name.", .{});
    if (name != .string) return errorResult(allocator, "Server name must be a string.", .{});
    for (self.servers) |*server| {
        if (!std.mem.eql(u8, server.config.name, name.string)) continue;
        if (server.failure != null or server.connection == null or server.tool_count == 0)
            return errorResult(allocator, "MCP server '{s}' has no available tools.", .{name.string});
        const was_loaded = server.loaded;
        server.loaded = true;
        self.refreshFunctions() catch |err| {
            server.loaded = was_loaded;
            return err;
        };
        const note = server.connection.?.instructions orelse "";
        return .{ .is_error = false, .content = try std.fmt.allocPrint(
            allocator,
            "Loaded {d} tools from MCP server '{s}'. They are now available.\nService instructions:\n{s}",
            .{ server.tool_count, name.string, note },
        ) };
    }
    return errorResult(allocator, "Unknown MCP server '{s}'. Use an exact name from the service directory.", .{name.string});
}

fn errorResult(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !tool.ToolResult {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}
