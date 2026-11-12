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

// The tools the agent itself answers. They work on the session's own state —
// its memory, its plan, its second agents, its questions to the user — so they
// are methods of the agent rather than files under `tools/`, and their
// definitions are written here.
pub const memory_search = ToolDefinition{
    .name = "memory_search",
    .description = "Search durable workspace notes by keyword and return the ranked matches. Lexical matching for Chinese and English, not semantic.",
    .parameters_json =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Short keywords, non-empty UTF-8, at most 512 bytes"},"limit":{"type":"integer","minimum":1,"maximum":10,"description":"Maximum notes to return, default 5"}},"required":["query"]}
    ,
};

pub const ask_user = ToolDefinition{
    .name = "ask_user",
    .description = "Ask the user to choose between concrete options when the request is ambiguous or a decision only they can make blocks progress. Several such calls sent together are put to the user as one form.",
    .parameters_json =
    \\{"type":"object","properties":{"question":{"type":"string","description":"The decision that is needed, in one sentence"},"options":{"type":"array","description":"Two to four concrete choices","items":{"type":"object","properties":{"label":{"type":"string","description":"Short name of the choice"},"description":{"type":"string","description":"One sentence on what this choice means"},"recommended":{"type":"boolean","description":"True for the option you would pick"}},"required":["label"]}}},"required":["question","options"]}
    ,
};

pub const announce_task = ToolDefinition{
    .name = "announce_task",
    .description = "Announce the task being started: a short title for the terminal and a description of the goal and approach, in the user's language. Call it before the first tool call of every turn that does work, including a task that follows chat.",
    .parameters_json =
    \\{"type":"object","properties":{"title":{"type":"string","minLength":1,"maxLength":79,"description":"Concise task title, fewer than 80 Unicode characters, not the user's raw text"},"description":{"type":"string","minLength":1,"description":"Brief goal and practical approach shown to the user"}},"required":["title","description"],"additionalProperties":false}
    ,
};

pub const memory_save = ToolDefinition{
    .name = "memory_save",
    .description = "Save one durable note to memory so it survives this session: add a note, or replace or delete an exact existing one.",
    .parameters_json =
    \\{"type":"object","properties":{"text":{"type":"string","description":"Note to add, new note for replace, or exact existing note for delete"},"action":{"type":"string","enum":["add","replace","delete"],"description":"Default add; replace and delete require an exact existing note"},"old_text":{"type":"string","description":"Exact existing note to replace; required only for replace"}},"required":["text"]}
    ,
};

pub const plan = ToolDefinition{
    .name = "plan",
    .description = "Read or update the plan for the work in progress: with no arguments it returns the complete plan, with 'steps' it replaces the whole plan (an empty array clears it), and with 'index' plus 'status' or 'note' it updates one step. Successful updates return only a brief change acknowledgement, not the checklist; call with no arguments to read it. The plan belongs to the session — it is saved with it and restored when it is resumed — so it, not the message history, is the map of long work.",
    .parameters_json =
    \\{"type":"object","properties":{"steps":{"type":"array","description":"The complete ordered plan, replacing the current one: one short line per step that can be verified on its own. At most 50 steps.","maxItems":50,"items":{"type":"object","properties":{"title":{"type":"string","description":"One line: what this step accomplishes"},"status":{"type":"string","enum":["pending","in_progress","completed","blocked"],"description":"Defaults to pending; at most one step is in_progress"},"note":{"type":"string","description":"Optional one-line reason kept under the step, for example why it is blocked"}},"required":["title"]}},"index":{"type":"integer","minimum":1,"description":"1-based step to update, when 'steps' is omitted"},"status":{"type":"string","enum":["pending","in_progress","completed","blocked"],"description":"New status for that step"},"note":{"type":"string","description":"New note for that step; an empty string removes the old one"}},"required":[]}
    ,
};

pub const subagent = ToolDefinition{
    .name = "subagent",
    .description = "Hand one self-contained task to a sub-agent that works on its own and returns a short report. The sub-agent does not read this conversation, cannot ask the user and cannot change the plan, so the task must carry everything it needs. Give it a 'title' — a one-line summary of the task, fewer than 80 characters — because that is what the terminal shows while the run works. Use it for a step whose tool output would flood this conversation; verify its work yourself before marking a plan step done. The sub-agent has no limits of its own: you watch it instead. 'checkin_seconds' is how long it works before it is asked for a progress report, and the call returns with that report, the final report, or the end of the run. A run that reported is paused: call subagent again with its 'id' to let it carry on, or subagent_stop with its 'id' to stop it and take its final report.",
    .parameters_json =
    \\{"type":"object","properties":{"task":{"type":"string","description":"One self-contained task: what to do and how it is verified, in full, since the sub-agent does not read this conversation. Omit it to resume or to start a second sub-agent by 'id'."},"title":{"type":"string","maxLength":79,"description":"One-line summary of the task, fewer than 80 Unicode characters: the terminal shows it on the call's line and while the run works. Omit it and that line falls back to the task itself."},"context":{"type":"string","description":"Optional facts the sub-agent needs: file paths, decisions already made, the shape of the expected change. Keep it short."},"id":{"type":"string","description":"The id of a sub-agent that is paused at a progress report: the call lets it carry on and returns its next report or its final one. Omit it to start a new sub-agent with 'task'."},"checkin_seconds":{"type":"integer","minimum":0,"maximum":3600,"description":"How long the sub-agent works before it is asked for a progress report, default 300. It is not a limit on the work: at the check-in the run pauses with that report, and you decide whether to go on. 0 asks for the report at the next request boundary."}},"required":[]}
    ,
};

pub const report = ToolDefinition{
    .name = "report",
    .description = "Send the agent that called you a short progress report and wait for its decision. It is how a check-in is answered: the caller reads the report, then either tells you to continue or stops the task and asks for your final report. Keep it to a status line — what is done, what you ran, what is left — not the final answer.",
    .parameters_json =
    \\{"type":"object","properties":{"summary":{"type":"string","description":"Short progress report: what you have done and changed, what you ran and what it printed, what is verified, and what is left"}},"required":["summary"]}
    ,
};

pub const subagent_stop = ToolDefinition{
    .name = "subagent_stop",
    .description = "Stop a sub-agent that is paused at a progress report and take its final report as the tool result. It gets one last turn to write that report and does no new work, so anything unfinished is named as unfinished.",
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string","description":"The id of the paused sub-agent, as its progress report named it"}},"required":["id"]}
    ,
};

/// Ordered default set. Copy individual definitions into arrays or ArrayLists
/// to compose a different set without changing the definitions themselves.
pub const builtin = [_]ToolDefinition{
    memory_search, bash, read,     write,         edit,   apply_patch,  ls,
    rg,            fd,   grep,     find,          http,   ask_user,     memory_save,
    announce_task, plan, subagent, subagent_stop, report, ccr_retrieve,
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
        var listed = false;
        for (builtin) |definition| {
            if (std.mem.eql(u8, definition.name, spec.name)) listed = true;
        }
        try std.testing.expect(listed);
    }
}
