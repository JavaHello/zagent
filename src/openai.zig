const std = @import("std");
const Config = @import("config.zig").Config;

// JSON schema for the tools exposed to the model.
pub const TOOLS_JSON =
    \\[
    \\  {"type":"function","function":{"name":"shell","description":"Execute a shell command and return its output. Use this to run programs, inspect the system, manage files, and more.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"}},"required":["command"]}}},
    \\  {"type":"function","function":{"name":"read_file","description":"Read the contents of a file","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"}},"required":["path"]}}},
    \\  {"type":"function","function":{"name":"write_file","description":"Write content to a file, creating or overwriting it","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}}},
    \\  {"type":"function","function":{"name":"list_dir","description":"List the contents of a directory","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Directory path"}},"required":["path"]}}}
    \\]
;

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
    tool_calls: ?[]ToolCallData,
    tool_call_id: ?[]const u8,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
        if (self.tool_call_id) |id| allocator.free(id);
    }
};

pub const ApiResponse = struct {
    content: ?[]const u8,
    tool_calls: ?[]ToolCallData,
    finish_reason: []const u8,

    pub fn deinit(self: ApiResponse, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
        allocator.free(self.finish_reason);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    max_tokens: u32,

    pub fn init(allocator: std.mem.Allocator, config: Config) Client {
        return .{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .api_key = config.api_key,
            .base_url = config.base_url,
            .model = config.model,
            .max_tokens = config.max_tokens,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    /// Send a chat/completions request and return the parsed response.
    pub fn chat(self: *Client, messages: []const Message) !ApiResponse {
        const req_json = try buildRequest(self.allocator, self.model, messages, self.max_tokens);
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
        var aw: std.io.Writer.Allocating = .init(self.allocator);
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
            const body = aw.written();
            if (tryParseApiErrorMessage(self.allocator, body)) |err_msg| {
                defer self.allocator.free(err_msg);
                std.debug.print("API error (HTTP {d}): {s}\n", .{ @intFromEnum(fetch_result.status), err_msg });
            } else {
                std.debug.print("HTTP error: {d}\n", .{@intFromEnum(fetch_result.status)});
            }
            return error.ApiError;
        }

        return parseResponse(self.allocator, aw.written());
    }

    fn resetHttpClient(self: *Client) void {
        self.http_client.deinit();
        self.http_client = .{ .allocator = self.allocator };
    }
};

/// Build the JSON body for a chat/completions POST request.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    max_tokens: u32,
) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.encodeJsonString(model, .{}, w);
    try w.print(",\"max_tokens\":{d}", .{max_tokens});
    try w.writeAll(",\"messages\":[");
    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try writeMessageJson(w, msg);
    }
    try w.writeAll("],\"tools\":");
    try w.writeAll(TOOLS_JSON);
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

fn writeMessageJson(w: *std.io.Writer, msg: Message) !void {
    try w.writeAll("{\"role\":");
    try std.json.Stringify.encodeJsonString(msg.role, .{}, w);
    if (msg.content) |content| {
        try w.writeAll(",\"content\":");
        try std.json.Stringify.encodeJsonString(content, .{}, w);
    } else {
        try w.writeAll(",\"content\":null");
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
        .{ .role = "user", .content = "hello", .tool_calls = null, .tool_call_id = null },
    };
    const json = try buildRequest(allocator, "gpt-4o-mini", &messages, 4096);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools\"") != null);
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

test "recoverable fetch errors are retried" {
    try std.testing.expect(isRecoverableFetchError(error.HttpConnectionClosing));
    try std.testing.expect(isRecoverableFetchError(error.ConnectionResetByPeer));
    try std.testing.expect(!isRecoverableFetchError(error.ApiError));
}
