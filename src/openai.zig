const std = @import("std");
const Config = @import("config.zig").Config;

// JSON schema for the tools exposed to the model.
///
/// The built-in tools, one JSON function object per line, commas included:
/// this is the body of a request's `tools` array rather than a finished one,
/// so that the tools of the MCP servers connected at the moment can follow it.
const builtin_tools =
    \\{"type":"function","function":{"name":"shell","description":"Execute a shell command and return its output. Use this to run programs, inspect the system, manage files, and more.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"},"timeout_seconds":{"type":"integer","minimum":1,"maximum":3600,"description":"Command time limit in seconds, default 180. Increase for long builds or tests."}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"read_file","description":"Read the contents of a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write_file","description":"Write content to a file, creating or overwriting it","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit_file","description":"Edit an existing file by replacing one exact, unique text block. Prefer this for small edits or appending to a unique final block; no line counts are needed. Copy old_text exactly from the current file and include enough context to match once. Nothing changes if the text is absent or ambiguous.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["path","old_text","new_text"]}}},
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
    /// Exact Responses output items, including encrypted reasoning.
    response_items: ?[]const u8 = null,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.reasoning_content) |c| allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.response_items) |items| allocator.free(items);
    }
};

pub const ApiResponse = struct {
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    tool_calls: ?[]ToolCallData,
    finish_reason: []const u8,
    response_items: ?[]const u8 = null,

    pub fn deinit(self: ApiResponse, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.reasoning_content) |c| allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
        allocator.free(self.finish_reason);
        if (self.response_items) |items| allocator.free(items);
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
    retryable_http_error: bool = false,

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

    /// Send a Responses API request and return the parsed response.
    ///
    /// `extra_tools` are the tools that are not built in — one JSON function
    /// object each, from the MCP servers that are connected. They are offered
    /// beside the built-in ones, so the model can call either.
    pub fn respond(self: *Client, messages: []const Message, extra_tools: []const []const u8) !ApiResponse {
        return self.respondWith(messages, .included, extra_tools);
    }

    /// Send a request that advertises no tools, for the completion judge. It
    /// must not be able to answer with a tool call, MCP ones included.
    pub fn respondWithoutTools(self: *Client, messages: []const Message) !ApiResponse {
        return self.respondWith(messages, .omitted, &.{});
    }

    fn respondWith(
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

        const response_url = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{std.mem.trimEnd(u8, self.base_url, "/")});
        defer self.allocator.free(response_url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        return self.performResponseWithRetry(response_url, auth_header, req_json);
    }

    fn performResponseWithRetry(self: *Client, response_url: []const u8, auth_header: []const u8, req_json: []const u8) !ApiResponse {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            return self.performResponseFetch(response_url, auth_header, req_json) catch |err| {
                if (attempt >= 2 or (!isRecoverableFetchError(err) and !self.retryable_http_error)) return err;
                self.resetHttpClient();
                try self.io.sleep(.fromMilliseconds(1000 * (@as(i64, 1) << @intCast(attempt))), .awake);
                continue;
            };
        }
    }

    fn performResponseFetch(self: *Client, response_url: []const u8, auth_header: []const u8, req_json: []const u8) !ApiResponse {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        self.retryable_http_error = false;
        const fetch_result = self.http_client.fetch(.{
            .location = .{ .url = response_url },
            .method = .POST,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .payload = req_json,
            .response_writer = &aw.writer,
        }) catch |err| return err;

        if (fetch_result.status != .ok) {
            self.retryable_http_error = switch (@backingInt(fetch_result.status)) {
                408, 429, 500, 502, 503, 504 => true,
                else => false,
            };
            self.recordHttpError(fetch_result.status, aw.written());
            return error.ApiError;
        }

        if (self.http_error) |message| self.allocator.free(message);
        self.http_error = null;
        return parseResponse(self.allocator, aw.written()) catch |err| {
            if (err == error.ApiError) self.recordHttpError(fetch_result.status, aw.written());
            return err;
        };
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
                .{ @backingInt(status), message },
            ) catch null
        else
            std.fmt.allocPrint(
                self.allocator,
                "HTTP error: {d}",
                .{@backingInt(status)},
            ) catch null;
    }
};

/// Whether a request advertises the tools. The completion judge must not, or
/// the model can answer it with a tool call instead of a verdict.
pub const Tools = enum { included, omitted };

/// Build a stateless Responses API request, replaying typed output items.
pub fn buildRequest(allocator: std.mem.Allocator, model: []const u8, messages: []const Message, max_tokens: u32, tools: Tools) ![]u8 {
    return buildRequestWithTools(allocator, model, messages, max_tokens, tools, &.{});
}

pub fn buildRequestWithTools(allocator: std.mem.Allocator, model: []const u8, messages: []const Message, max_tokens: u32, tools: Tools, extra_tools: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"model\":");
    try std.json.Stringify.encodeJsonString(model, .{}, w);
    try w.print(",\"max_output_tokens\":{d},\"store\":false,\"include\":[\"reasoning.encrypted_content\"],\"input\":[", .{max_tokens});
    var first = true;
    for (messages) |message| {
        if (message.response_items) |items| {
            // Preserve every returned item, including encrypted reasoning and
            // message/function IDs. Reconstructing only the text loses state.
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, items, .{});
            defer parsed.deinit();
            if (parsed.value != .array) return error.InvalidResponseItems;
            for (parsed.value.array.items) |item| {
                if (item != .object) return error.InvalidResponseItems;
                try separator(w, &first);
                try std.json.Stringify.value(item, .{}, w);
            }
            continue;
        }
        if (std.mem.eql(u8, message.role, "tool")) {
            const call_id = message.tool_call_id orelse return error.MissingCallId;
            try separator(w, &first);
            try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try std.json.Stringify.encodeJsonString(call_id, .{}, w);
            try w.writeAll(",\"output\":");
            try std.json.Stringify.encodeJsonString(message.content orelse "", .{}, w);
            try w.writeByte('}');
            continue;
        }
        if (message.content) |content| {
            try separator(w, &first);
            try w.writeAll("{\"role\":");
            try std.json.Stringify.encodeJsonString(message.role, .{}, w);
            try w.writeAll(",\"content\":");
            try std.json.Stringify.encodeJsonString(content, .{}, w);
            try w.writeByte('}');
        }
        // Older session snapshots are converted to typed call/output pairs.
        // Their unstructured Chat Completions reasoning strings are not sent.
        if (message.tool_calls) |calls| for (calls) |call| {
            try separator(w, &first);
            try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
            try std.json.Stringify.encodeJsonString(call.id, .{}, w);
            try w.writeAll(",\"name\":");
            try std.json.Stringify.encodeJsonString(call.name, .{}, w);
            try w.writeAll(",\"arguments\":");
            try std.json.Stringify.encodeJsonString(call.arguments, .{}, w);
            try w.writeByte('}');
        };
    }
    try w.writeByte(']');
    if (tools == .included) {
        try w.writeAll(",\"tools\":[");
        first = true;
        const builtin = try std.json.parseFromSlice(std.json.Value, allocator, TOOLS_JSON, .{});
        defer builtin.deinit();
        for (builtin.value.array.items) |tool| {
            try separator(w, &first);
            try writeFunction(w, tool);
        }
        for (extra_tools) |entry| {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry, .{});
            defer parsed.deinit();
            try separator(w, &first);
            try writeFunction(w, parsed.value);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
    return aw.toOwnedSlice();
}

fn separator(w: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
}

fn stringField(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidResponse;
    const item = value.object.get(key) orelse return error.InvalidResponse;
    if (item != .string) return error.InvalidResponse;
    return item.string;
}

fn writeFunction(w: *std.Io.Writer, tool: std.json.Value) !void {
    if (tool != .object) return error.InvalidToolSchema;
    const function = tool.object.get("function") orelse tool;
    const name = try stringField(function, "name");
    const parameters = function.object.get("parameters") orelse return error.InvalidToolSchema;
    if (parameters != .object) return error.InvalidToolSchema;
    try w.writeAll("{\"type\":\"function\",\"strict\":false,\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, w);
    if (function.object.get("description")) |description| {
        if (description != .string) return error.InvalidToolSchema;
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(description, .{}, w);
    }
    try w.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, w);
    try w.writeByte('}');
}

/// Parse only terminal Responses objects. Incomplete tool calls never execute.
pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !ApiResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    if (root.object.get("error")) |api_error| if (api_error != .null) return error.ApiError;
    const status = try stringField(root, "status");
    if (std.mem.eql(u8, status, "incomplete")) return .{
        .content = null,
        .reasoning_content = null,
        .tool_calls = null,
        .finish_reason = try allocator.dupe(u8, "length"),
    };
    if (!std.mem.eql(u8, status, "completed")) return error.ResponseNotCompleted;
    const output = root.object.get("output") orelse return error.InvalidResponse;
    if (output != .array) return error.InvalidResponse;
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    var calls: std.ArrayList(ToolCallData) = .empty;
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }
    for (output.array.items) |item| {
        const kind = try stringField(item, "type");
        if (std.mem.eql(u8, kind, "function_call") or std.mem.eql(u8, kind, "message")) {
            if (item.object.get("status")) |item_status| {
                if (item_status != .string or !std.mem.eql(u8, item_status.string, "completed")) return error.ResponseNotCompleted;
            }
        }
        if (std.mem.eql(u8, kind, "function_call")) {
            const id = try stringField(item, "call_id");
            const name = try stringField(item, "name");
            const arguments = try stringField(item, "arguments");
            if (id.len == 0 or name.len == 0) return error.InvalidResponse;
            for (calls.items) |call| if (std.mem.eql(u8, call.id, id)) return error.DuplicateCallId;
            const owned_id = try allocator.dupe(u8, id);
            errdefer allocator.free(owned_id);
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            const owned_args = try allocator.dupe(u8, arguments);
            errdefer allocator.free(owned_args);
            try calls.append(allocator, .{ .id = owned_id, .name = owned_name, .arguments = owned_args });
        } else if (std.mem.eql(u8, kind, "message")) {
            if (!std.mem.eql(u8, try stringField(item, "role"), "assistant")) return error.InvalidResponse;
            const blocks = item.object.get("content") orelse return error.InvalidResponse;
            if (blocks != .array) return error.InvalidResponse;
            for (blocks.array.items) |block| {
                const block_type = try stringField(block, "type");
                if (std.mem.eql(u8, block_type, "output_text")) {
                    try content.writer.writeAll(try stringField(block, "text"));
                } else if (std.mem.eql(u8, block_type, "refusal")) {
                    try content.writer.writeAll(try stringField(block, "refusal"));
                } else return error.UnsupportedOutputItem;
            }
        } else if (!std.mem.eql(u8, kind, "reasoning")) return error.UnsupportedOutputItem;
    }
    if (calls.items.len == 0 and content.written().len == 0) return error.EmptyResponse;
    const text = if (content.written().len > 0) try allocator.dupe(u8, content.written()) else null;
    errdefer if (text) |value| allocator.free(value);
    const raw_items = try std.json.Stringify.valueAlloc(allocator, output, .{});
    errdefer allocator.free(raw_items);
    const reason = try allocator.dupe(u8, if (calls.items.len > 0) "tool_calls" else "stop");
    errdefer allocator.free(reason);
    return .{
        .content = text,
        .reasoning_content = null,
        .response_items = raw_items,
        .tool_calls = if (calls.items.len > 0) try calls.toOwnedSlice(allocator) else null,
        .finish_reason = reason,
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

test "extract string arg" {
    const allocator = std.testing.allocator;
    const result = try extractStringArg(allocator, "{\"command\":\"ls -la\"}", "command");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ls -la", result);
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

test "Responses request uses typed items and flat non-strict function schemas" {
    const a = std.testing.allocator;
    var calls = [_]ToolCallData{.{ .id = "call_1", .name = "shell", .arguments = "{}" }};
    const messages = [_]Message{
        .{ .role = "system", .content = "instructions", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "working", .reasoning_content = "legacy", .tool_calls = &calls, .tool_call_id = null },
        .{ .role = "tool", .content = "result", .reasoning_content = null, .tool_calls = null, .tool_call_id = "call_1" },
    };
    const borrowed = [_][]const u8{"{\"type\":\"function\",\"function\":{\"name\":\"mcp__test__search\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}"};
    const encoded = try buildRequestWithTools(a, "provider/model-name", &messages, 1234, .included, &borrowed);
    defer a.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("messages") == null and root.get("max_tokens") == null and root.get("thinking") == null);
    try std.testing.expectEqualStrings("provider/model-name", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 1234), root.get("max_output_tokens").?.integer);
    try std.testing.expect(!root.get("store").?.bool);
    const input = root.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), input.len);
    try std.testing.expectEqualStrings("function_call", input[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[3].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("function_call_output", input[3].object.get("type").?.string);
    try std.testing.expect(input[1].object.get("reasoning_content") == null);
    const tools = root.get("tools").?.array.items;
    for (tools) |tool| {
        try std.testing.expect(tool.object.get("function") == null);
        try std.testing.expect(tool.object.get("name").? == .string);
        try std.testing.expect(!tool.object.get("strict").?.bool);
    }
    try std.testing.expectEqualStrings("mcp__test__search", tools[tools.len - 1].object.get("name").?.string);
}

test "Responses parsing keeps call_id separate from item IDs and replays all output" {
    const a = std.testing.allocator;
    const body =
        \\{"status":"completed","error":null,"output":[
        \\ {"id":"rs_1","type":"reasoning","summary":[],"encrypted_content":"opaque-token"},
        \\ {"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"First "},{"type":"output_text","text":"second"}]},
        \\ {"id":"fc_1","type":"function_call","call_id":"call_1","name":"shell","arguments":"{}"},
        \\ {"id":"fc_2","type":"function_call","call_id":"call_2","name":"read_file","arguments":"{}"}]}
    ;
    const response = try parseResponse(a, body);
    defer response.deinit(a);
    try std.testing.expectEqualStrings("First second", response.content.?);
    try std.testing.expectEqualStrings("tool_calls", response.finish_reason);
    try std.testing.expectEqual(@as(usize, 2), response.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", response.tool_calls.?[0].id);
    const messages = [_]Message{.{ .role = "assistant", .content = response.content, .reasoning_content = null, .tool_calls = response.tool_calls, .tool_call_id = null, .response_items = response.response_items }};
    const request = try buildRequest(a, "model", &messages, 1000, .omitted);
    defer a.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, request, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("tools") == null);
    const replayed = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), replayed.len);
    try std.testing.expectEqualStrings("opaque-token", replayed[0].object.get("encrypted_content").?.string);
    try std.testing.expectEqualStrings("fc_1", replayed[2].object.get("id").?.string);
}

test "Responses refuses nonterminal, malformed and ambiguous outputs" {
    const a = std.testing.allocator;
    const incomplete = try parseResponse(a, "{\"status\":\"incomplete\",\"output\":[{\"type\":\"function_call\"}]}");
    defer incomplete.deinit(a);
    try std.testing.expectEqualStrings("length", incomplete.finish_reason);
    try std.testing.expect(incomplete.tool_calls == null);
    try std.testing.expectError(error.ApiError, parseResponse(a, "{\"status\":\"failed\",\"error\":{\"message\":\"failure\"}}"));
    try std.testing.expectError(error.ResponseNotCompleted, parseResponse(a, "{\"status\":\"in_progress\",\"output\":[]}"));
    try std.testing.expectError(error.EmptyResponse, parseResponse(a, "{\"status\":\"completed\",\"output\":[]}"));
    try std.testing.expectError(error.InvalidResponse, parseResponse(a, "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"wrong-id\",\"name\":\"shell\",\"arguments\":\"{}\"}]}"));
    try std.testing.expectError(error.DuplicateCallId, parseResponse(a, "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"shell\",\"arguments\":\"{}\"},{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"shell\",\"arguments\":\"{}\"}]}"));
    const refusal = try parseResponse(a, "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Cannot do that\"}]}]}");
    defer refusal.deinit(a);
    try std.testing.expectEqualStrings("Cannot do that", refusal.content.?);
}
