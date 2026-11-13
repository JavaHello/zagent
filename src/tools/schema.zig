const std = @import("std");
const dispatch = @import("dispatch.zig");
const tool_mod = @import("tool.zig");

/// A built-in tool definition, independent of any request or tool selection.
/// parameters_json is parsed before embedding, never spliced into JSON output.
/// Tests validate every built-in schema.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,

    /// Parse parameters_json into the typed wire shape. A request-scoped arena
    /// allocator keeps the parsed schema alive until serialization finishes.
    pub fn function(self: ToolDefinition, allocator: std.mem.Allocator) !Function {
        const parameters = try std.json.parseFromSliceLeaky(std.json.Value, allocator, self.parameters_json, .{});
        if (parameters != .object) return error.InvalidToolSchema;
        return .{ .name = self.name, .description = self.description, .parameters = parameters };
    }
};

/// Responses API function schema; parameters may contain arbitrary JSON Schema.
pub const Function = struct {
    type: []const u8 = "function",
    strict: bool = false,
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: std.json.Value,
};

test "tool definitions serialize strings and reject non-object schemas" {
    const a = std.testing.allocator;
    const tool: ToolDefinition = .{
        .name = "echo\"\\\n测试",
        .description = "quoted \"description\"\nnext line",
        .parameters_json = "{\n\"type\":\"object\",\"default\":null}",
    };
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const function = try tool.function(arena_state.allocator());
    const output = try std.json.Stringify.valueAlloc(a, function, .{ .emit_null_optional_fields = false });
    defer a.free(output);
    const decoded = try std.json.parseFromSlice(Function, a, output, .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings(tool.name, decoded.value.name);
    try std.testing.expectEqualStrings(tool.description, decoded.value.description.?);
    try std.testing.expect(decoded.value.parameters.object.get("default").? == .null);
    try std.testing.expect(std.mem.indexOfScalar(u8, output, '\n') == null);
    var invalid = tool;
    invalid.parameters_json = "[]";
    try std.testing.expectError(error.InvalidToolSchema, invalid.function(arena_state.allocator()));
    invalid.parameters_json = "{} , \"injected\":true";
    try std.testing.expectError(error.SyntaxError, invalid.function(arena_state.allocator()));
}

/// The definition the model is given of a host tool, taken from the spec the
/// tool's own file declares. The list the model is offered is built from the
/// same specs a call is dispatched through, so a tool cannot be advertised
/// without being runnable, or run without being advertised.
fn hostDefinition(comptime spec: tool_mod.Tool) ToolDefinition {
    return .{
        .name = spec.name,
        .description = spec.description,
        .parameters_json = spec.parameters_json,
    };
}

// The host tools: the ones `tools/dispatch.zig` runs, each described in the
// file that implements it.
pub const bash = hostDefinition(dispatch.specOf("bash"));
pub const ccr_retrieve = hostDefinition(dispatch.specOf("ccr_retrieve"));
pub const read = hostDefinition(dispatch.specOf("read"));
pub const write = hostDefinition(dispatch.specOf("write"));
pub const edit = hostDefinition(dispatch.specOf("edit"));
pub const apply_patch = hostDefinition(dispatch.specOf("apply_patch"));
pub const ls = hostDefinition(dispatch.specOf("ls"));
pub const rg = hostDefinition(dispatch.specOf("rg"));
pub const fd = hostDefinition(dispatch.specOf("fd"));
pub const grep = hostDefinition(dispatch.specOf("grep"));
pub const find = hostDefinition(dispatch.specOf("find"));
pub const http = hostDefinition(dispatch.specOf("http"));

// Session tools use the same specs as dispatch, while their implementations
// delegate the session-state work to Agent.
pub const memory_search = hostDefinition(dispatch.specOf("memory_search"));

pub const ask_user = hostDefinition(dispatch.specOf("ask_user"));

pub const announce_task = hostDefinition(dispatch.specOf("announce_task"));

pub const memory_save = hostDefinition(dispatch.specOf("memory_save"));

pub const plan = hostDefinition(dispatch.specOf("plan"));

pub const subagent = hostDefinition(dispatch.specOf("subagent"));

pub const report = hostDefinition(dispatch.specOf("report"));

pub const load_mcp_tools = hostDefinition(dispatch.specOf("load_mcp_tools"));

/// Ordered default set. Copy individual definitions into arrays or ArrayLists
/// to compose a different set without changing the definitions themselves.
pub const builtin = [_]ToolDefinition{
    memory_search, bash, read,     write,  edit,         apply_patch, ls,
    rg,            fd,   grep,     find,   http,         ask_user,    memory_save,
    announce_task, plan, subagent, report, ccr_retrieve,
};

test "write and edit have separate required arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try write.function(arena.allocator());
    const e = try edit.function(arena.allocator());
    const wr = w.parameters.object.get("required").?.array.items;
    const er = e.parameters.object.get("required").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), wr.len);
    try std.testing.expectEqualStrings("path", wr[0].string);
    try std.testing.expectEqualStrings("content", wr[1].string);
    try std.testing.expectEqual(@as(usize, 3), er.len);
    try std.testing.expectEqualStrings("path", er[0].string);
    try std.testing.expectEqualStrings("old_text", er[1].string);
    try std.testing.expectEqualStrings("new_text", er[2].string);
    try std.testing.expect(!w.parameters.object.get("properties").?.object.contains("old_text"));
    try std.testing.expect(!e.parameters.object.get("properties").?.object.contains("content"));
}

test "built-in definitions have valid schemas and unique names" {
    const allocator = std.testing.allocator;
    var names: std.StringHashMap(void) = .init(allocator);
    defer names.deinit();
    for (builtin) |tool| {
        try std.testing.expect(tool.name.len > 0);
        try std.testing.expect(tool.description.len > 0);
        try std.testing.expect(!names.contains(tool.name));
        try names.put(tool.name, {});
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, tool.parameters_json, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("object", parsed.value.object.get("type").?.string);
        const properties = parsed.value.object.get("properties").?.object;
        for (parsed.value.object.get("required").?.array.items) |required| {
            try std.testing.expect(properties.contains(required.string));
        }
    }
}

test "every host tool the model is offered is one dispatch runs" {
    for (dispatch.all) |spec| {
        // The MCP loader is advertised only when a service has tools.
        if (std.mem.eql(u8, spec.name, load_mcp_tools.name)) continue;
        var listed = false;
        for (builtin) |definition| {
            if (std.mem.eql(u8, definition.name, spec.name)) listed = true;
        }
        try std.testing.expect(listed);
    }
}
