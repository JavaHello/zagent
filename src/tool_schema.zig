const std = @import("std");

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

pub const memory_search = ToolDefinition{
    .name = "memory_search",
    .description = "Search durable workspace notes by keyword and return the ranked matches. Lexical matching for Chinese and English, not semantic.",
    .parameters_json =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Short keywords, non-empty UTF-8, at most 512 bytes"},"limit":{"type":"integer","minimum":1,"maximum":10,"description":"Maximum notes to return, default 5"}},"required":["query"]}
    ,
};

pub const bash = ToolDefinition{
    .name = "bash",
    .description = "Execute a Bash command and return its output.",
    .parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"},"timeout_seconds":{"type":"integer","minimum":1,"maximum":3600,"description":"Command time limit in seconds, default 180. Increase for long builds or tests."}},"required":["command"]}
    ,
};

pub const read = ToolDefinition{
    .name = "read",
    .description = "Read a file or one page of it, numbered by line.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"offset":{"type":"integer","minimum":1,"description":"1-based number of the first line to read; defaults to 1"},"limit":{"type":"integer","minimum":1,"description":"Number of lines to read; defaults to as many as the output page holds"}},"required":["path"]}
    ,
};

pub const write = ToolDefinition{
    .name = "write",
    .description = "Create or overwrite a file with content, or replace one exact, unique text block using old_text and new_text. Never combine the two modes; a replacement that is missing or ambiguous changes nothing.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string","description":"Entire file contents for creation or full replacement"},"old_text":{"type":"string","description":"Exact non-empty text to replace"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path"]}
    ,
};

pub const apply_patch = ToolDefinition{
    .name = "apply_patch",
    .description = "Apply a Git unified diff patch.",
    .parameters_json =
    \\{"type":"object","properties":{"patch":{"type":"string","description":"The Git Unified Diff to apply, with its newlines"}},"required":["patch"]}
    ,
};

pub const ls = ToolDefinition{
    .name = "ls",
    .description = "List directory entries in sorted order, at most 'limit' of them, each with its kind.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Directory path, defaults to the current directory","default":"."},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Most entries to list, default 100"}},"required":[]}
    ,
};

pub const rg = ToolDefinition{
    .name = "rg",
    .description = "Search file contents with a regular expression and return matching lines with file and line number. Skips binary files.",
    .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"path":{"type":"string","description":"File, directory, or shell-style path glob to search (e.g. README* or src/*.zig); defaults to the current directory. Path globs expand before searching, unlike the recursive glob filter."},"glob":{"type":"string","description":"Only search files whose names match this glob, e.g. *.zig"},"ignore_case":{"type":"boolean","description":"Match case-insensitively"},"context_lines":{"type":"integer","minimum":0,"description":"Number of surrounding lines before and after each match; defaults to 0"},"max_matches":{"type":"integer","minimum":1,"description":"Stop after this many matching lines per file (not a global limit); defaults to unlimited."},"hidden":{"type":"boolean","description":"Include hidden files (default false)"},"no_ignore":{"type":"boolean","description":"Disable ignore files (default false)"}},"required":["pattern"]}
    ,
};

pub const fd = ToolDefinition{
    .name = "fd",
    .description = "Find files and directories whose names match a glob and return their paths.",
    .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob the name must match, e.g. *.zig or *test*"},"path":{"type":"string","description":"Directory to search in, defaults to the current directory"},"hidden":{"type":"boolean","description":"Include hidden entries (default false)"},"no_ignore":{"type":"boolean","description":"Disable ignore files (default false)"}},"required":["pattern"]}
    ,
};

pub const grep = ToolDefinition{
    .name = "grep",
    .description = "Search file contents with grep extended regular expressions and return matching lines with file and line numbers. Skips binary files and .git; includes hidden files; does not read ignore files.",
    .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Extended regular expression to search for"},"path":{"type":"string","description":"File, directory, or shell-style path glob (e.g. README*); defaults to ."},"glob":{"type":"string","description":"Only search files whose names match this glob"},"ignore_case":{"type":"boolean"},"context_lines":{"type":"integer","minimum":0},"max_matches":{"type":"integer","minimum":1}},"required":["pattern"]}
    ,
};

pub const find = ToolDefinition{
    .name = "find",
    .description = "Find files and directories by name glob using find. Prunes .git; includes hidden entries; does not read ignore files.",
    .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Name glob, e.g. *.zig or *test*"},"path":{"type":"string","description":"Directory to search; defaults to ."}},"required":["pattern"]}
    ,
};

pub const http = ToolDefinition{
    .name = "http",
    .description = "Make an HTTP request and return its status line, headers and body, or save the body to a file.",
    .parameters_json =
    \\{"type":"object","properties":{"url":{"type":"string","description":"The full URL, including the scheme"},"method":{"type":"string","description":"HTTP method: GET, HEAD, POST, PUT, PATCH, DELETE, or OPTIONS. Defaults to GET"},"headers":{"type":"object","description":"Request headers as name/value pairs","additionalProperties":{"type":"string"}},"body":{"type":"string","description":"Request body, for a method that takes one"},"save_to":{"type":"string","description":"Write the response body to this file path instead of returning it"}},"required":["url"]}
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
    .description = "Announce the task being started: a short title for the terminal and a description of the goal and approach, in the user's language.",
    .parameters_json =
    \\{"type":"object","properties":{"title":{"type":"string","minLength":1,"maxLength":79,"description":"Concise task title, fewer than 80 Unicode characters, not the user's raw text"},"description":{"type":"string","minLength":1,"description":"Brief goal and practical approach shown to the user"}},"required":["title","description"],"additionalProperties":false}
    ,
};

pub const remember = ToolDefinition{
    .name = "remember",
    .description = "Save one durable note to memory so it survives this session: add a note, or replace or delete an exact existing one.",
    .parameters_json =
    \\{"type":"object","properties":{"text":{"type":"string","description":"Note to add, new note for replace, or exact existing note for delete"},"action":{"type":"string","enum":["add","replace","delete"],"description":"Default add; replace and delete require an exact existing note"},"old_text":{"type":"string","description":"Exact existing note to replace; required only for replace"}},"required":["text"]}
    ,
};

pub const plan = ToolDefinition{
    .name = "plan",
    .description = "Read or update the plan for the work in progress: with no arguments it returns the plan, with 'steps' it replaces the whole plan, and with 'index' plus 'status' or 'note' it updates one step. The plan belongs to the session — it is saved with it and restored when it is resumed — so it, not the message history, is the map of long work.",
    .parameters_json =
    \\{"type":"object","properties":{"steps":{"type":"array","description":"The complete ordered plan, replacing the current one: one short line per step that can be verified on its own. At most 50 steps.","maxItems":50,"items":{"type":"object","properties":{"title":{"type":"string","description":"One line: what this step accomplishes"},"status":{"type":"string","enum":["pending","active","done","blocked"],"description":"Defaults to pending; at most one step is active"},"note":{"type":"string","description":"Optional one-line reason kept under the step, for example why it is blocked"}},"required":["title"]}},"index":{"type":"integer","minimum":1,"description":"1-based step to update, when 'steps' is omitted"},"status":{"type":"string","enum":["pending","active","done","blocked"],"description":"New status for that step"},"note":{"type":"string","description":"New note for that step; an empty string removes the old one"}},"required":[]}
    ,
};

/// Ordered default set. Copy individual definitions into arrays or ArrayLists
/// to compose a different set without changing the definitions themselves.
pub const builtin = [_]ToolDefinition{
    memory_search, bash,          read, write, apply_patch, ls,
    rg,            fd,            grep, find,  http,        ask_user,
    remember,      announce_task, plan,
};

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
