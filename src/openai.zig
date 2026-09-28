const std = @import("std");
const Config = @import("config.zig").Config;

// JSON schema for the tools exposed to the model.
///
/// The built-in tools, one JSON function object per line, commas included:
/// this is the body of a request's `tools` array rather than a finished one,
/// so that the tools of the MCP servers connected at the moment can follow it.
const builtin_tools =
    \\{"type":"function","function":{"name":"shell","description":"Execute a shell command and return its output. Use this to run programs, inspect the system, manage files, and more.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read the contents of a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write content to a file, creating or overwriting it","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"apply_patch","description":"Change existing files by applying a unified diff. This is how an edit is made instead of writing the whole file back. The patch is a standard unified diff: a header line '--- a/path' and a '+++ b/path' line, then one or more hunks. Each hunk starts with '@@ -<start>,<count> +<start>,<count> @@' giving the line numbers in the file before and after the change, followed by the hunk's lines, each prefixed with a single space (unchanged context), '-' (removed) or '+' (added). Copy the context lines from the file exactly as they are, indentation included: the patch is refused rather than guessed at if they do not match. Keep the counts in the '@@' line equal to the number of lines below it. Send a new file as '--- /dev/null' with a hunk that adds every line, and delete one with '+++ /dev/null' and a hunk that removes every line. Several files may be patched in one call by putting one '---'/'+++' pair after another.","parameters":{"type":"object","properties":{"patch":{"type":"string","description":"The unified diff to apply, with its newlines"}},"required":["patch"]}}},
    \\{"type":"function","function":{"name":"list_dir","description":"List the contents of a directory","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Directory path"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"grep","description":"Search file contents with a regular expression and return the matching lines with their file and line number. Prefer this over running grep or rg through the shell. Binary files are skipped.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"path":{"type":"string","description":"File or directory to search, defaults to the current directory"},"glob":{"type":"string","description":"Only search files whose names match this glob, e.g. *.zig"},"ignore_case":{"type":"boolean","description":"Match case-insensitively"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"find","description":"Find files and directories whose name matches a glob and return their paths. Prefer this over running find or fd through the shell.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob the name must match, e.g. *.zig or *test*"},"path":{"type":"string","description":"Directory to search in, defaults to the current directory"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"http_request","description":"Make an HTTP request and return its status line, response headers, and body. Use this instead of curl for fetching URLs and calling APIs. Set Content-Type yourself when you send a body; use save_to to download the body to a file instead of returning it.","parameters":{"type":"object","properties":{"url":{"type":"string","description":"The full URL, including the scheme"},"method":{"type":"string","description":"HTTP method: GET, HEAD, POST, PUT, PATCH, DELETE, or OPTIONS. Defaults to GET"},"headers":{"type":"object","description":"Request headers as name/value pairs","additionalProperties":{"type":"string"}},"body":{"type":"string","description":"Request body, for a method that takes one"},"save_to":{"type":"string","description":"Write the response body to this file path instead of returning it"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"ask_user","description":"Ask the user to choose between concrete options when the request is ambiguous, or when a decision only the user can make blocks progress. Not for confirming routine steps.","parameters":{"type":"object","properties":{"question":{"type":"string","description":"The decision that is needed, in one sentence"},"options":{"type":"array","description":"Two to four concrete choices","items":{"type":"object","properties":{"label":{"type":"string","description":"Short name of the choice"},"description":{"type":"string","description":"One sentence on what this choice means"},"recommended":{"type":"boolean","description":"True for the option you would pick"}},"required":["label"]}}},"required":["question","options"]}}}
;

/// The built-in tools as a whole `tools` member, for the request that has
/// nothing of its own to add to them.
pub const TOOLS_JSON = "[" ++ builtin_tools ++ "]";

pub const ToolCallData = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,

    pub fn deinit(self: ToolCallData, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
    }
};

pub const Message = struct {
    role: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    tool_calls: ?[]ToolCallData,
    tool_call_id: ?[]const u8,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.reasoning_content) |c| allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
        if (self.tool_call_id) |id| allocator.free(id);
    }
};

pub const ApiResponse = struct {
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    tool_calls: ?[]ToolCallData,
    finish_reason: []const u8,

    pub fn deinit(self: ApiResponse, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.reasoning_content) |c| allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
        allocator.free(self.finish_reason);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http_client: std.http.Client,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    max_tokens: u32,
    /// The last HTTP-level failure, kept rather than printed when it happens.
    /// A request runs while the progress animation owns the terminal's line:
    /// a message written from in here would be glued onto a frame and then
    /// erased by the next one. Whoever stops the animation reports it instead.
    http_error: ?[]u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = .{ .allocator = allocator, .io = io },
            .api_key = config.api_key,
            .base_url = config.base_url,
            .model = config.model,
            .max_tokens = config.max_tokens,
            .http_error = null,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.http_error) |message| self.allocator.free(message);
        self.http_client.deinit();
    }

    /// Take the failure recorded for the last request, if there was one, and
    /// with it the ownership of the message.
    pub fn takeHttpError(self: *Client) ?[]u8 {
        const message = self.http_error;
        self.http_error = null;
        return message;
    }

    /// Send a chat/completions request and return the parsed response.
    ///
    /// `extra_tools` are the tools that are not built in — one JSON function
    /// object each, from the MCP servers that are connected. They are offered
    /// beside the built-in ones, so the model can call either.
    pub fn chat(self: *Client, messages: []const Message, extra_tools: []const []const u8) !ApiResponse {
        return self.chatWith(messages, .included, extra_tools);
    }

    /// Send a request that advertises no tools, for the completion judge. It
    /// must not be able to answer with a tool call, MCP ones included.
    pub fn chatWithoutTools(self: *Client, messages: []const Message) !ApiResponse {
        return self.chatWith(messages, .omitted, &.{});
    }

    fn chatWith(
        self: *Client,
        messages: []const Message,
        tools: Tools,
        extra_tools: []const []const u8,
    ) !ApiResponse {
        const req_json = try buildRequestWithTools(
            self.allocator,
            self.model,
            messages,
            self.max_tokens,
            tools,
            extra_tools,
        );
        defer self.allocator.free(req_json);

        const chat_url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.base_url});
        defer self.allocator.free(chat_url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        return self.performChatWithRetry(chat_url, auth_header, req_json);
    }

    fn performChatWithRetry(self: *Client, chat_url: []const u8, auth_header: []const u8, req_json: []const u8) !ApiResponse {
        return self.performChatFetch(chat_url, auth_header, req_json) catch |err| {
            if (!isRecoverableFetchError(err)) return err;

            self.resetHttpClient();
            return self.performChatFetch(chat_url, auth_header, req_json);
        };
    }

    fn performChatFetch(self: *Client, chat_url: []const u8, auth_header: []const u8, req_json: []const u8) !ApiResponse {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = chat_url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .payload = req_json,
            .response_writer = &aw.writer,
        }) catch |err| return err;

        if (fetch_result.status != .ok) {
            self.recordHttpError(fetch_result.status, aw.written());
            return error.ApiError;
        }

        return parseResponse(self.allocator, aw.written());
    }

    fn resetHttpClient(self: *Client) void {
        self.http_client.deinit();
        self.http_client = .{ .allocator = self.allocator, .io = self.io };
    }

    /// Keep what the server said, for the caller to report once no animation is
    /// using the terminal's line. The message is the server's own text when
    /// there is one, since "HTTP error: 429" alone is less useful than
    /// "rate limit reached".
    fn recordHttpError(self: *Client, status: std.http.Status, body: []const u8) void {
        // A failure overwrites the one before it: only the newest request's
        // outcome is being reported.
        if (self.http_error) |previous| self.allocator.free(previous);
        self.http_error = null;

        const detail = tryParseApiErrorMessage(self.allocator, body);
        defer if (detail) |message| self.allocator.free(message);

        self.http_error = if (detail) |message|
            std.fmt.allocPrint(
                self.allocator,
                "API error (HTTP {d}): {s}",
                .{ @intFromEnum(status), message },
            ) catch null
        else
            std.fmt.allocPrint(
                self.allocator,
                "HTTP error: {d}",
                .{@intFromEnum(status)},
            ) catch null;
    }
};

/// Whether a request advertises the tools. The completion judge must not, or
/// the model can answer it with a tool call instead of a verdict.
pub const Tools = enum { included, omitted };

/// Build the JSON body for a chat/completions POST request.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    max_tokens: u32,
    tools: Tools,
) ![]u8 {
    return buildRequestWithTools(allocator, model, messages, max_tokens, tools, &.{});
}

/// As `buildRequest`, with tools from outside this program appended to the
/// built-in ones. Each entry of `extra_tools` is a whole JSON function object.
pub fn buildRequestWithTools(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    max_tokens: u32,
    tools: Tools,
    extra_tools: []const []const u8,
) ![]u8 {
    const request_options = resolveRequestOptions(model);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.encodeJsonString(request_options.model, .{}, w);
    try w.print(",\"max_tokens\":{d}", .{max_tokens});
    switch (request_options.thinking) {
        .omit => {},
        .enabled => try w.writeAll(",\"thinking\":{\"type\":\"enabled\"}"),
        .disabled => try w.writeAll(",\"thinking\":{\"type\":\"disabled\"}"),
    }
    try w.writeAll(",\"messages\":[");
    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try writeMessageJson(w, msg);
    }
    try w.writeByte(']');
    if (tools == .included) {
        try w.writeAll(",\"tools\":[");
        try w.writeAll(builtin_tools);
        for (extra_tools) |entry| {
            try w.writeByte(',');
            try w.writeAll(entry);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

/// Whether to send DeepSeek's `thinking` field, and with what value.
///
/// DeepSeek enables thinking by default, so "non-thinking" has to be asked for
/// explicitly: omitting the field leaves thinking on. The field is also
/// DeepSeek-specific, hence the `omit` case for every other model.
const ThinkingMode = enum { omit, enabled, disabled };

const RequestOptions = struct {
    model: []const u8,
    thinking: ThinkingMode,
};

const ModelRule = struct {
    /// Name accepted from AI_MODEL.
    name: []const u8,
    /// Name actually sent to the API.
    canonical: []const u8,
    thinking: ThinkingMode,
};

const MODEL_RULES = [_]ModelRule{
    // Current names. Thinking is the documented default, so state it rather
    // than relying on a server-side default we do not control.
    .{ .name = "deepseek-flash", .canonical = "deepseek-flash", .thinking = .enabled },
    .{ .name = "deepseek-v4-pro", .canonical = "deepseek-v4-pro", .thinking = .enabled },
    // Retired, but still accepted and routed to DeepSeek-V4.1-Flash. This name
    // has always meant "the cheap, non-thinking one", so keep that meaning.
    .{ .name = "deepseek-v4-flash", .canonical = "deepseek-flash", .thinking = .disabled },
    // Legacy aliases: the same model, non-thinking and thinking respectively.
    .{ .name = "deepseek-chat", .canonical = "deepseek-flash", .thinking = .disabled },
    .{ .name = "deepseek-reasoner", .canonical = "deepseek-flash", .thinking = .enabled },
};

fn resolveRequestOptions(model: []const u8) RequestOptions {
    for (MODEL_RULES) |rule| {
        if (std.mem.eql(u8, model, rule.name)) {
            return .{ .model = rule.canonical, .thinking = rule.thinking };
        }
    }

    // Unlisted models are passed through untouched with no thinking field, so
    // a future DeepSeek model still gets the server's own default.
    return .{ .model = model, .thinking = .omit };
}

fn writeMessageJson(w: *std.Io.Writer, msg: Message) !void {
    try w.writeAll("{\"role\":");
    try std.json.Stringify.encodeJsonString(msg.role, .{}, w);
    if (msg.content) |content| {
        try w.writeAll(",\"content\":");
        try std.json.Stringify.encodeJsonString(content, .{}, w);
    } else {
        try w.writeAll(",\"content\":null");
    }
    if (msg.reasoning_content) |reasoning_content| {
        try w.writeAll(",\"reasoning_content\":");
        try std.json.Stringify.encodeJsonString(reasoning_content, .{}, w);
    }
    if (msg.tool_calls) |calls| {
        try w.writeAll(",\"tool_calls\":[");
        for (calls, 0..) |call, j| {
            if (j > 0) try w.writeByte(',');
            try w.writeAll("{\"id\":");
            try std.json.Stringify.encodeJsonString(call.id, .{}, w);
            try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.encodeJsonString(call.name, .{}, w);
            try w.writeAll(",\"arguments\":");
            try std.json.Stringify.encodeJsonString(call.arguments, .{}, w);
            try w.writeAll("}}");
        }
        try w.writeByte(']');
    }
    if (msg.tool_call_id) |id| {
        try w.writeAll(",\"tool_call_id\":");
        try std.json.Stringify.encodeJsonString(id, .{}, w);
    }
    try w.writeByte('}');
}

/// Parse the API response JSON. Returns error.ApiError if the body contains
/// an API-level error object.
pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !ApiResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    if (root.object.get("error")) |_| return error.ApiError;

    const choices_val = root.object.get("choices") orelse return error.InvalidResponse;
    if (choices_val != .array) return error.InvalidResponse;
    if (choices_val.array.items.len == 0) return error.EmptyChoices;

    const choice = choices_val.array.items[0];
    if (choice != .object) return error.InvalidResponse;

    const finish_reason: []const u8 = if (choice.object.get("finish_reason")) |frv|
        switch (frv) {
            .string => |s| try allocator.dupe(u8, s),
            else => try allocator.dupe(u8, "stop"),
        }
    else
        try allocator.dupe(u8, "stop");
    errdefer allocator.free(finish_reason);

    const message_val = choice.object.get("message") orelse return error.InvalidResponse;
    if (message_val != .object) return error.InvalidResponse;

    const content: ?[]const u8 = blk: {
        if (message_val.object.get("content")) |cv| {
            if (cv == .string) break :blk try allocator.dupe(u8, cv.string);
        }
        break :blk null;
    };
    errdefer if (content) |c| allocator.free(c);

    const reasoning_content: ?[]const u8 = blk: {
        if (message_val.object.get("reasoning_content")) |rcv| {
            if (rcv == .string) break :blk try allocator.dupe(u8, rcv.string);
        }
        break :blk null;
    };
    errdefer if (reasoning_content) |c| allocator.free(c);

    const tool_calls: ?[]ToolCallData = blk: {
        const tc_val = message_val.object.get("tool_calls") orelse break :blk null;
        if (tc_val != .array) break :blk null;
        if (tc_val.array.items.len == 0) break :blk null;

        var calls: std.ArrayList(ToolCallData) = .empty;
        errdefer {
            for (calls.items) |c| c.deinit(allocator);
            calls.deinit(allocator);
        }
        for (tc_val.array.items) |tc| {
            if (tc != .object) continue;
            const id_val = tc.object.get("id") orelse continue;
            if (id_val != .string) continue;
            const func_val = tc.object.get("function") orelse continue;
            if (func_val != .object) continue;
            const name_val = func_val.object.get("name") orelse continue;
            if (name_val != .string) continue;
            const args_val = func_val.object.get("arguments") orelse continue;
            if (args_val != .string) continue;

            const id = try allocator.dupe(u8, id_val.string);
            errdefer allocator.free(id);
            const name = try allocator.dupe(u8, name_val.string);
            errdefer allocator.free(name);
            const arguments = try allocator.dupe(u8, args_val.string);
            errdefer allocator.free(arguments);

            try calls.append(allocator, .{ .id = id, .name = name, .arguments = arguments });
        }
        break :blk try calls.toOwnedSlice(allocator);
    };

    return .{
        .content = content,
        .reasoning_content = reasoning_content,
        .tool_calls = tool_calls,
        .finish_reason = finish_reason,
    };
}

/// Extract a string field from a JSON arguments object (e.g., tool call arguments).
pub fn extractStringArg(allocator: std.mem.Allocator, arguments_json: []const u8, key: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const val = parsed.value.object.get(key) orelse return error.MissingField;
    if (val != .string) return error.InvalidFieldType;
    return allocator.dupe(u8, val.string);
}

fn tryParseApiErrorMessage(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const err_val = parsed.value.object.get("error") orelse return null;
    if (err_val != .object) return null;
    const msg_val = err_val.object.get("message") orelse return null;
    if (msg_val != .string) return null;
    return allocator.dupe(u8, msg_val.string) catch null;
}

fn isRecoverableFetchError(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionClosing,
        error.ConnectionResetByPeer,
        => true,
        else => false,
    };
}

test "build request json" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "gpt-4o-mini", &messages, 4096, .included);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools\"") != null);
}

test "build request omits the tools when asked" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "gpt-4o-mini", &messages, 4096, .omitted);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages\"") != null);
}

test "the tools a request advertises parse, built in and borrowed alike" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const borrowed = [_][]const u8{
        \\{"type":"function","function":{"name":"mcp__filesystem__read","description":"server: read","parameters":{"type":"object"}}}
    };

    const json = try buildRequestWithTools(allocator, "gpt-4o-mini", &messages, 4096, .included, &borrowed);
    defer allocator.free(json);

    // The schema is hand-written JSON, so a typo in it would only surface as a
    // server-side error on the first request of every session.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const advertised = parsed.value.object.get("tools").?.array;
    const expected = [_][]const u8{ "shell", "read_file", "write_file", "apply_patch", "list_dir", "grep", "find", "http_request", "ask_user" };
    for (expected) |wanted| {
        var found = false;
        for (advertised.items) |entry| {
            const name = entry.object.get("function").?.object.get("name").?.string;
            if (std.mem.eql(u8, name, wanted)) found = true;
        }
        try std.testing.expect(found);
    }

    // And the borrowed tool came through as it was written, schema and all.
    const last = advertised.items[advertised.items.len - 1];
    try std.testing.expectEqualStrings(
        "mcp__filesystem__read",
        last.object.get("function").?.object.get("name").?.string,
    );
    const parameters = try std.json.Stringify.valueAlloc(
        allocator,
        last.object.get("function").?.object.get("parameters").?,
        .{},
    );
    defer allocator.free(parameters);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", parameters);
}

test "build request maps deepseek reasoner to the thinking mode of deepseek-flash" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "deepseek-reasoner", &messages, 4096, .included);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"deepseek-flash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"enabled\"}") != null);
}

test "build request maps deepseek chat to non-thinking deepseek-flash" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "deepseek-chat", &messages, 4096, .included);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"deepseek-flash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"disabled\"}") != null);
}

test "build request asks for thinking on deepseek flash explicitly" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "deepseek-flash", &messages, 4096, .included);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"deepseek-flash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"enabled\"}") != null);
}

test "build request omits the thinking field for other models" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "gpt-4o-mini", &messages, 4096, .included);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "thinking") == null);
}

test "build request enables thinking for deepseek v4 pro" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "deepseek-v4-pro", &messages, 4096, .included);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"deepseek-v4-pro\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"enabled\"}") != null);
}

test "build request keeps deepseek v4 flash in non-thinking mode" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "user", .content = "hello", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "deepseek-v4-flash", &messages, 4096, .included);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"deepseek-flash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"disabled\"}") != null);
}

test "extract string arg" {
    const allocator = std.testing.allocator;
    const result = try extractStringArg(allocator, "{\"command\":\"ls -la\"}", "command");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ls -la", result);
}

test "parse response stop" {
    const allocator = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}]}
    ;
    const resp = try parseResponse(allocator, body);
    defer resp.deinit(allocator);
    try std.testing.expectEqualStrings("stop", resp.finish_reason);
    try std.testing.expectEqualStrings("Hello!", resp.content.?);
}

test "build request includes reasoning content in assistant messages" {
    const allocator = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "assistant", .content = "Answer", .reasoning_content = "Chain of thought summary", .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "deepseek-v4-pro", &messages, 4096, .included);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning_content\":\"Chain of thought summary\"") != null);
}

test "parse response reads reasoning content" {
    const allocator = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"Hello!","reasoning_content":"Need to think first"},"finish_reason":"stop"}]}
    ;
    const resp = try parseResponse(allocator, body);
    defer resp.deinit(allocator);

    try std.testing.expectEqualStrings("Need to think first", resp.reasoning_content.?);
}

test "recoverable fetch errors are retried" {
    try std.testing.expect(isRecoverableFetchError(error.HttpConnectionClosing));
    try std.testing.expect(isRecoverableFetchError(error.ConnectionResetByPeer));
    try std.testing.expect(!isRecoverableFetchError(error.ApiError));
}

test "an http failure is kept until the caller asks for it" {
    const allocator = std.testing.allocator;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const config = try Config.load(allocator, std.testing.io, &env);
    defer config.deinit();

    var client = Client.init(allocator, std.testing.io, config);
    defer client.deinit();

    try std.testing.expectEqual(@as(?[]u8, null), client.takeHttpError());

    client.recordHttpError(.too_many_requests, "{\"error\":{\"message\":\"rate limit reached\"}}");
    // Recording a second failure drops the one before it rather than stacking:
    // only the newest request's outcome is worth reporting.
    client.recordHttpError(.internal_server_error, "{}");
    const reported = client.takeHttpError() orelse return error.TestUnexpectedResult;
    defer allocator.free(reported);
    try std.testing.expectEqualStrings("HTTP error: 500", reported);
    // Taking it clears it, so one failure is reported once.
    try std.testing.expectEqual(@as(?[]u8, null), client.takeHttpError());

    // The server's own words are what makes a failure actionable.
    client.recordHttpError(.too_many_requests, "{\"error\":{\"message\":\"rate limit reached\"}}");
    const message = client.takeHttpError() orelse return error.TestUnexpectedResult;
    defer allocator.free(message);
    try std.testing.expectEqualStrings("API error (HTTP 429): rate limit reached", message);
}
