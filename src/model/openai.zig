const std = @import("std");
const search_tools = @import("../tools/mod.zig");
const codex_auth = @import("codex_auth.zig");
const trace_mod = @import("../debug/trace.zig");
const Config = @import("config.zig").Config;
const ThinkingMode = @import("config.zig").ThinkingMode;
pub const tool_schema = @import("../tools/schema.zig");
pub const ToolDefinition = tool_schema.ToolDefinition;

test "search registration follows installed backends and advertises renamed filesystem tools" {
    const allocator = std.testing.allocator;
    for ([_]search_tools.SearchBackends{ .{}, .{ .rg = true }, .{ .fd = true }, .{ .rg = true, .fd = true } }) |search| {
        const body = try buildRequestWithToolSelection(allocator, "test", &.{}, 100, .{}, false, search);
        defer allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        var names: std.StringHashMap(void) = .init(allocator);
        defer names.deinit();
        for (parsed.value.object.get("tools").?.array.items) |tool| {
            try names.put(tool.object.get("name").?.string, {});
            if (std.mem.eql(u8, tool.object.get("name").?.string, "ls")) {
                const params = tool.object.get("parameters").?.object;
                try std.testing.expectEqual(@as(usize, 0), params.get("required").?.array.items.len);
                const path = params.get("properties").?.object.get("path").?.object;
                try std.testing.expectEqualStrings(".", path.get("default").?.string);
            }
        }
        try std.testing.expect(!names.contains("http_request"));
        for ([_][]const u8{ "read", "write", "edit", "ls", "apply_patch", "http", "ccr_retrieve" }) |name| {
            try std.testing.expect(names.contains(name));
        }
        for ([_][]const u8{ "read_file", "write_file", "edit_file", "list_dir" }) |name| {
            try std.testing.expect(!names.contains(name));
        }
        try std.testing.expectEqual(search.rg, names.contains("rg"));
        try std.testing.expectEqual(!search.rg, names.contains("grep"));
        try std.testing.expectEqual(search.fd, names.contains("fd"));
        try std.testing.expectEqual(!search.fd, names.contains("find"));
    }
}

test "omitted names drop from the startup defaults and search selection still applies" {
    const allocator = std.testing.allocator;
    // The five tools a sub-agent must not hold, as agent/prompt.zig names them:
    // it cannot ask the user, announce on a terminal it does not own, move the
    // plan, write the shared memory, or start a run of its own.
    const omit = [_][]const u8{ "ask_user", "announce_task", "plan", "memory_save", "subagent" };
    for ([_]search_tools.SearchBackends{ .{}, .{ .rg = true }, .{ .fd = true }, .{ .rg = true, .fd = true } }) |search| {
        const body = try buildRequestWithToolSelection(allocator, "test", &.{}, 100, .{ .omit = &omit }, false, search);
        defer allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        var names: std.StringHashMap(void) = .init(allocator);
        defer names.deinit();
        for (parsed.value.object.get("tools").?.array.items) |tool| {
            try names.put(tool.object.get("name").?.string, {});
        }
        try std.testing.expectEqual(@as(usize, 12), names.count());
        for ([_][]const u8{ "memory_search", "bash", "read", "write", "edit", "apply_patch", "ls", "http", "report", "ccr_retrieve" }) |name| {
            try std.testing.expect(names.contains(name));
        }
        for (omit) |name| try std.testing.expect(!names.contains(name));
        try std.testing.expectEqual(search.rg, names.contains("rg"));
        try std.testing.expectEqual(!search.rg, names.contains("grep"));
        try std.testing.expectEqual(search.fd, names.contains("fd"));
        try std.testing.expectEqual(!search.fd, names.contains("find"));
    }
}

test "omitted names leave an explicit builtin slice unchanged" {
    const allocator = std.testing.allocator;
    const explicit = [_]ToolDefinition{ tool_schema.read, tool_schema.ask_user };
    const body = try buildRequestWithToolSelection(allocator, "test", &.{}, 100, .{
        .builtin = &explicit,
        .omit = &.{"ask_user"},
    }, false, .{ .rg = true, .fd = true });
    defer allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    for (tools, [_][]const u8{ "read", "ask_user" }) |tool, name| {
        try std.testing.expectEqualStrings(name, tool.object.get("name").?.string);
    }
}

test "tool selection composes runtime subsets and MCP schemas without mutating definitions" {
    const a = std.testing.allocator;
    var selected: std.ArrayList(ToolDefinition) = .empty;
    defer selected.deinit(a);
    try selected.appendSlice(a, &.{ tool_schema.read, tool_schema.grep });
    const extra = [_][]const u8{
        \\{"type":"function","function":{"name":"mcp__a","parameters":{"type":"object","properties":{}}}}
        ,
        \\{"type":"function","name":"mcp__flat","parameters":{"type":"object","properties":{}}}
        ,
    };
    const body = try buildRequestWithToolSelection(a, "test", &.{}, 100, .{ .builtin = selected.items, .extra = &extra }, false, .{ .rg = true, .fd = true });
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), tools.len);
    for (tools, [_][]const u8{ "read", "grep", "mcp__a", "mcp__flat" }) |tool, name| {
        try std.testing.expectEqualStrings(name, tool.object.get("name").?.string);
        try std.testing.expect(!tool.object.get("strict").?.bool);
        try std.testing.expect(tool.object.get("function") == null);
    }
    try std.testing.expectEqualStrings("grep", selected.items[1].name);
    try std.testing.expectEqualStrings("grep", tool_schema.grep.name);
}

test "explicit search definitions are independent of startup availability" {
    const a = std.testing.allocator;
    const definitions = [_]ToolDefinition{ tool_schema.rg, tool_schema.grep, tool_schema.fd, tool_schema.find };
    for ([_]search_tools.SearchBackends{ .{}, .{ .rg = true, .fd = true } }) |search| {
        const body = try buildRequestWithToolSelection(a, "test", &.{}, 100, .{ .builtin = &definitions }, false, search);
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        const registered = parsed.value.object.get("tools").?.array.items;
        try std.testing.expectEqual(definitions.len, registered.len);
        for (registered, definitions) |tool, definition| {
            try std.testing.expectEqualStrings(definition.name, tool.object.get("name").?.string);
            const parameters = try std.json.Stringify.valueAlloc(a, tool.object.get("parameters").?, .{});
            defer a.free(parameters);
            const expected = try std.json.parseFromSlice(std.json.Value, a, definition.parameters_json, .{});
            defer expected.deinit();
            const expected_parameters = try std.json.Stringify.valueAlloc(a, expected.value, .{});
            defer a.free(expected_parameters);
            try std.testing.expectEqualStrings(expected_parameters, parameters);
        }
    }
}

test "tool selection distinguishes omitted empty and MCP-only sets" {
    const a = std.testing.allocator;
    const omitted = try buildRequestWithToolSelection(a, "test", &.{}, 100, null, false, .{});
    defer a.free(omitted);
    const parsed_omitted = try std.json.parseFromSlice(std.json.Value, a, omitted, .{});
    defer parsed_omitted.deinit();
    try std.testing.expect(parsed_omitted.value.object.get("tools") == null);

    const extra = [_][]const u8{
        \\{"name":"mcp__only","parameters":{"type":"object","properties":{}}}
        ,
    };
    for ([_][]const []const u8{ &.{}, &extra }, 0..) |entries, expected_len| {
        const body = try buildRequestWithToolSelection(a, "test", &.{}, 100, .{ .builtin = &.{}, .extra = entries }, false, .{});
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(expected_len, parsed.value.object.get("tools").?.array.items.len);
    }
}

test "tool definitions escape names and descriptions when writing JSON" {
    const a = std.testing.allocator;
    const custom = ToolDefinition{ .name = "custom\"name", .description = "line\n中文", .parameters_json = "{\"type\":\"object\",\"properties\":{}}" };
    const body = try buildRequestWithToolSelection(a, "test", &.{}, 100, .{ .builtin = &.{custom} }, false, .{});
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const tool = parsed.value.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings(custom.name, tool.get("name").?.string);
    try std.testing.expectEqualStrings(custom.description, tool.get("description").?.string);
}

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
    /// Sole owner of tool output and execution metadata; content stays null.
    tool_result: ?search_tools.ToolResult = null,

    pub fn deinit(self: Message, allocator: std.mem.Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.tool_result) |result| result.deinit(allocator);
        if (self.reasoning_content) |c| allocator.free(c);
        if (self.tool_calls) |calls| {
            for (calls) |call| call.deinit(allocator);
            allocator.free(calls);
        }
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.response_items) |items| allocator.free(items);
    }
};

/// Token usage the server reported for one request. Optional because a failed
/// or cut-off request may not carry it.
pub const Usage = struct {
    cache_usage_reported: bool = false,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
};

pub const ApiResponse = struct {
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    tool_calls: ?[]ToolCallData,
    finish_reason: []const u8,
    response_items: ?[]const u8 = null,
    usage: ?Usage = null,

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

/// A replacement for the HTTP exchange, used to drive `respond` from tests
/// without a socket. Production clients leave it null and talk to the network.
pub const Transport = struct {
    context: *anyopaque,
    /// Handle one request and return the response body, which it owns.
    send: *const fn (context: *anyopaque, allocator: std.mem.Allocator, request: []const u8) anyerror![]u8,
};

/// Receives text as it streams from a Responses request. `delta` is borrowed
/// from the parser's buffer and must be consumed before returning.
pub const StreamSink = struct {
    context: *anyopaque,
    onText: *const fn (context: *anyopaque, delta: []const u8) void,
    /// The chain of thought, as the server narrates it. Optional: a sink that
    /// shows only the answer leaves it null, and the deltas are dropped.
    ///
    /// This is not the answer, so it does not count as text that has been
    /// shown: a request may still be sent again after reasoning arrived, and
    /// whatever showed it is expected to replace what it had.
    onReasoning: ?*const fn (context: *anyopaque, delta: []const u8) void = null,
};

/// Attempts a request is given: the first try and two retries.
const max_attempts: usize = 3;

/// How long the first retry waits for the network to settle; every later one
/// waits twice as long again.
const retry_delay_ms: i64 = 1000;

/// Forwards deltas to the caller's sink and remembers whether any of them got
/// through. The answer is painted as it arrives, so a retry is only safe while
/// this says nothing has been shown yet.
const Delivery = struct {
    target: StreamSink,
    shown: bool = false,

    fn sink(self: *Delivery) StreamSink {
        return .{ .context = self, .onText = onText, .onReasoning = onReasoning };
    }

    fn onText(context: *anyopaque, delta: []const u8) void {
        const self: *Delivery = @ptrCast(@alignCast(context));
        self.shown = true;
        self.target.onText(self.target.context, delta);
    }

    /// Reasoning is passed on but does not count as shown: it is narration, and
    /// a request that failed after some of it has no answer to duplicate yet.
    fn onReasoning(context: *anyopaque, delta: []const u8) void {
        const self: *Delivery = @ptrCast(@alignCast(context));
        const target = self.target.onReasoning orelse return;
        target(self.target.context, delta);
    }
};

/// Whether the attempt that just failed may be repeated: the failure has to be
/// one the network or the server can recover from on their own, no answer text
/// may have reached the screen, and an attempt has to be left.
fn shouldRetry(attempt: usize, shown: bool, transient: bool) bool {
    return transient and !shown and attempt + 1 < max_attempts;
}

/// Connection failures that say the transport failed, not the request: a pooled
/// connection the server had already closed, a reset, a timeout, a network that
/// went away. A URL that does not parse or a certificate that does not verify
/// would fail the same way however often it is sent, and is not here.
fn isTransientNetworkError(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionClosing, // the keep-alive connection was closed under us
        error.HttpRequestTruncated,
        error.HttpChunkTruncated,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.NetworkSubsystemFailed,
        => true,
        else => false,
    };
}

/// Statuses that say the server was busy or briefly broken rather than that the
/// request was wrong: sending the same request again can work.
fn isTransientStatus(status: std.http.Status) bool {
    return switch (@backingInt(status)) {
        408, 429, 500, 502, 503, 504 => true,
        else => false,
    };
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http_client: std.http.Client,
    api_key: []const u8,
    codex_auth_path: ?[]const u8 = null,
    /// Standard Responses reasoning effort, sent as the outer-level
    /// `reasoning.effort` for every provider, not only for Codex.
    reasoning_effort: ?[]const u8 = null,
    /// Whether the `reasoning` object asks for a narrated summary as well
    /// (`reasoning.summary: "auto"`). The OpenAI API and the Codex backend are
    /// the two that need the request to say so before they stream anything a
    /// reader can follow; DeepSeek narrates its own reasoning text unasked, and
    /// a generic compatible endpoint is not sent a member it may not define.
    reasoning_summary: bool = false,
    /// The Codex backend's fast mode. Only that backend understands its values,
    /// so every other provider omits the field.
    service_tier: ?[]const u8 = null,
    /// Whether the request asks the backend to think, sent as the outer-level
    /// `thinking` member. The presets decide the default; see `ThinkingMode`.
    thinking: ThinkingMode = .omit,
    /// Borrowed from Config, with the same lifetime as model and the fields above.
    prompt_cache_retention: ?[]const u8 = null,
    credentials: ?codex_auth.Credentials = null,
    base_url: []const u8,
    model: []const u8,
    max_tokens: u32,
    /// The last HTTP-level failure, kept rather than printed when it happens.
    /// A request runs while the progress animation owns the terminal's line:
    /// a message written from in here would be glued onto a frame and then
    /// erased by the next one. Whoever stops the animation reports it instead.
    http_error: ?[]u8,
    /// Whether the last response's status was one a retry may fix. Written by
    /// the exchange and read by the retry loop around it; nothing else uses it.
    retryable_status: bool = false,
    search: search_tools.SearchBackends = .{},
    /// Borrowed definitions; callers may replace this slice between requests.
    /// The slice and its strings must remain valid for each request's duration.
    builtin_tools: ?[]const ToolDefinition = null,
    /// Names dropped from the startup default set, for a role that must not
    /// have every tool. Ignored when `builtin_tools` is set, because an
    /// explicit slice is used unchanged.
    builtin_omit: []const []const u8 = &.{},
    /// Set only by tests; see `Transport`.
    transport: ?Transport = null,
    /// Where a debug run records what was sent and what came back. Null unless
    /// the run was started with `--debug`.
    trace: ?*trace_mod.Recorder = null,
    /// Which agent and which request of the turn the next exchange belongs to.
    /// The agent sets it before every call, so one trace can hold a whole tree.
    trace_ctx: trace_mod.Ctx = .{},
    /// Strict server-reported totals for the current query; never estimates.
    input_tokens: std.atomic.Value(u64) = .init(0),
    output_tokens: std.atomic.Value(u64) = .init(0),
    total_tokens: std.atomic.Value(u64) = .init(0),
    cached_tokens: std.atomic.Value(u64) = .init(0),
    cache_usage_reports: std.atomic.Value(u64) = .init(0),
    reasoning_tokens: std.atomic.Value(u64) = .init(0),
    requests: std.atomic.Value(u64) = .init(0),
    usage_reports: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = .{ .allocator = allocator, .io = io },
            .api_key = config.api_key,
            .codex_auth_path = config.codex_auth_path,
            .reasoning_effort = config.reasoning_effort,
            .reasoning_summary = switch (config.provider orelse .openai) {
                .openai, .codex => true,
                else => false,
            },
            .service_tier = config.service_tier,
            .thinking = config.thinking,
            .prompt_cache_retention = config.prompt_cache_retention,
            .base_url = config.base_url,
            .model = config.model,
            .max_tokens = config.max_tokens,
            .http_error = null,
        };
    }

    fn authenticate(self: *Client) !void {
        const path = self.codex_auth_path orelse return;
        const credentials = try codex_auth.load(self.allocator, self.io, path);
        if (self.credentials) |previous| previous.deinit(self.allocator);
        self.credentials = credentials;
    }

    pub fn listModels(self: *Client) ![]u8 {
        try self.authenticate();
        const key = if (self.credentials) |c| c.parsed.value.access_token else self.api_key;
        const bearer = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
        defer self.allocator.free(bearer);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/models{s}", .{ self.base_url, if (self.codex_auth_path != null) "?client_version=0.101.0" else "" });
        defer self.allocator.free(url);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const headers = [_]std.http.Header{
            .{ .name = "ChatGPT-Account-ID", .value = if (self.credentials) |c| c.account_id else "" },
            .{ .name = "originator", .value = "codex_cli_rs" },
        };
        const result = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .authorization = .{ .override = bearer } },
            .extra_headers = if (self.credentials != null) &headers else &.{},
            .redirect_behavior = .unhandled,
            .response_writer = &out.writer,
        });
        if (result.status != .ok) return error.ModelsRequestFailed;
        return self.allocator.dupe(u8, out.written());
    }

    /// Forget the token totals of the previous query. Called when a new query
    /// starts, so the counts the spinner shows belong to this query only.
    /// Query subscription limits without making a model request.
    pub fn quotaStatus(self: *Client) ![]u8 {
        if (self.codex_auth_path == null) return self.allocator.dupe(u8, "Account quota: unavailable for this provider; check its billing dashboard.\n");
        try self.authenticate();
        const credentials = self.credentials.?;
        const bearer = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{credentials.parsed.value.access_token});
        defer self.allocator.free(bearer);
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const result = try self.http_client.fetch(.{
            .location = .{ .url = "https://chatgpt.com/backend-api/wham/usage" },
            .headers = .{ .authorization = .{ .override = bearer } },
            .extra_headers = &.{.{ .name = "ChatGPT-Account-ID", .value = credentials.account_id }},
            .redirect_behavior = .unhandled,
            .response_writer = &out.writer,
        });
        if (result.status == .unauthorized) return error.CodexLoginRequired;
        if (result.status != .ok) return error.QuotaRequestFailed;
        return @import("status.zig").formatQuota(self.allocator, out.written());
    }

    pub fn resetTokenCounters(self: *Client) void {
        self.input_tokens.store(0, .monotonic);
        self.output_tokens.store(0, .monotonic);
        self.total_tokens.store(0, .monotonic);
        self.cached_tokens.store(0, .monotonic);
        self.cache_usage_reports.store(0, .monotonic);
        self.reasoning_tokens.store(0, .monotonic);
        self.requests.store(0, .monotonic);
        self.usage_reports.store(0, .monotonic);
    }

    pub fn tokenCounts(self: *const Client) struct { input: u64, output: u64, total: u64, cached: u64, reasoning: u64, requests: u64, usage_reports: u64, cache_usage_reports: u64 } {
        return .{
            .input = self.input_tokens.load(.monotonic),
            .output = self.output_tokens.load(.monotonic),
            .total = self.total_tokens.load(.monotonic),
            .cached = self.cached_tokens.load(.monotonic),
            .cache_usage_reports = self.cache_usage_reports.load(.monotonic),
            .reasoning = self.reasoning_tokens.load(.monotonic),
            .requests = self.requests.load(.monotonic),
            .usage_reports = self.usage_reports.load(.monotonic),
        };
    }

    /// Include all sub-agent requests, even those without a usage report.
    pub fn absorbUsage(self: *Client, other: *const Client) void {
        _ = self.input_tokens.fetchAdd(other.input_tokens.load(.monotonic), .monotonic);
        _ = self.output_tokens.fetchAdd(other.output_tokens.load(.monotonic), .monotonic);
        _ = self.total_tokens.fetchAdd(other.total_tokens.load(.monotonic), .monotonic);
        _ = self.cached_tokens.fetchAdd(other.cached_tokens.load(.monotonic), .monotonic);
        _ = self.cache_usage_reports.fetchAdd(other.cache_usage_reports.load(.monotonic), .monotonic);
        _ = self.reasoning_tokens.fetchAdd(other.reasoning_tokens.load(.monotonic), .monotonic);
        _ = self.requests.fetchAdd(other.requests.load(.monotonic), .monotonic);
        _ = self.usage_reports.fetchAdd(other.usage_reports.load(.monotonic), .monotonic);
    }

    fn addUsage(self: *Client, usage: ?Usage) void {
        const u = usage orelse return;
        _ = self.input_tokens.fetchAdd(u.input_tokens, .monotonic);
        _ = self.output_tokens.fetchAdd(u.output_tokens, .monotonic);
        _ = self.total_tokens.fetchAdd(u.total_tokens, .monotonic);
        _ = self.cached_tokens.fetchAdd(u.cached_tokens, .monotonic);
        if (u.cache_usage_reported) _ = self.cache_usage_reports.fetchAdd(1, .monotonic);
        _ = self.reasoning_tokens.fetchAdd(u.reasoning_tokens, .monotonic);
        _ = self.usage_reports.fetchAdd(1, .monotonic);
    }

    /// Account before parsing business output, which can fail independently.
    fn recordResponseUsage(self: *Client, body: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return;
        defer parsed.deinit();
        self.addUsage(parseUsage(parsed.value));
    }

    pub fn deinit(self: *Client) void {
        if (self.http_error) |message| self.allocator.free(message);
        if (self.credentials) |credentials| credentials.deinit(self.allocator);
        self.http_client.deinit();
    }

    /// Forget the failure recorded for the last request, without reporting it.
    /// Used when that request is sent again: what it said no longer describes
    /// the outcome the caller will see.
    fn discardHttpError(self: *Client) void {
        if (self.http_error) |message| self.allocator.free(message);
        self.http_error = null;
    }

    /// Drop every pooled connection, so the next attempt opens a new one. A
    /// request can fail because the keep-alive connection it reused had already
    /// been closed by the server, and sending it again on that same connection
    /// would fail the same way.
    fn resetHttpClient(self: *Client) void {
        self.http_client.deinit();
        self.http_client = .{ .allocator = self.allocator, .io = self.io };
    }

    /// Take the failure recorded for the last request, if there was one, and
    /// with it the ownership of the message.
    pub fn takeHttpError(self: *Client) ?[]u8 {
        const message = self.http_error;
        self.http_error = null;
        return message;
    }

    /// Shared projection for sending. With none of the optional outer-level
    /// fields set the original serialization is returned unchanged (including
    /// for Codex).
    fn buildWireRequest(self: *Client, messages: []const Message, extra_tools: []const []const u8) ![]u8 {
        const ordinary = try buildRequestWithToolSelection(self.allocator, self.model, messages, self.max_tokens, .{ .builtin = self.builtin_tools, .omit = self.builtin_omit, .extra = extra_tools }, true, self.search);
        const codex = self.codex_auth_path != null;
        const request = if (codex) adapted: {
            defer self.allocator.free(ordinary);
            break :adapted try codexRequest(self.allocator, ordinary);
        } else ordinary;
        const service_tier = if (codex) self.service_tier else null;
        if (self.reasoning_effort == null and self.thinking == .omit and service_tier == null and self.prompt_cache_retention == null) return request;
        defer self.allocator.free(request);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, request, .{});
        defer parsed.deinit();
        const arena = parsed.arena.allocator();
        // `reasoning.effort` is a Responses field of its own, so it is not tied
        // to the Codex adapter above; only `service_tier` is Codex's fast mode.
        if (nonEmpty(self.reasoning_effort)) |effort| {
            var reasoning: std.json.ObjectMap = .{};
            try reasoning.put(arena, "effort", .{ .string = effort });
            // Told to summarize, the backend narrates what it is thinking as
            // reasoning-summary deltas, which is what the live panel shows. It
            // is only asked for alongside an effort, so a model that does not
            // reason is never sent a member it would reject.
            if (self.reasoning_summary) try reasoning.put(arena, "summary", .{ .string = "auto" });
            try parsed.value.object.put(arena, "reasoning", .{ .object = reasoning });
        }
        if (self.thinking.wireValue()) |value| {
            var thinking: std.json.ObjectMap = .{};
            try thinking.put(arena, "type", .{ .string = value });
            try parsed.value.object.put(arena, "thinking", .{ .object = thinking });
        }
        if (nonEmpty(service_tier)) |tier| try parsed.value.object.put(arena, "service_tier", .{ .string = tier });
        if (self.prompt_cache_retention) |retention| try parsed.value.object.put(arena, "prompt_cache_retention", .{ .string = retention });
        return std.json.Stringify.valueAlloc(self.allocator, parsed.value, .{});
    }

    /// Stream a Responses request with built-in and MCP tools.
    pub fn respondStreaming(
        self: *Client,
        messages: []const Message,
        extra_tools: []const []const u8,
        sink: StreamSink,
    ) !ApiResponse {
        const response_url = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{std.mem.trimEnd(u8, self.base_url, "/")});
        defer self.allocator.free(response_url);

        try self.authenticate();
        const key = if (self.credentials) |c| c.parsed.value.access_token else self.api_key;
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
        defer self.allocator.free(auth_header);

        const req_json = try self.buildWireRequest(messages, extra_tools);
        defer self.allocator.free(req_json);

        return try self.performResponseStream(response_url, auth_header, req_json, sink);
    }

    /// The exchange, recorded when the run is being debugged.
    ///
    /// A build without tracing sends the request and keeps nothing of it: the
    /// recorder is not part of such a binary at all, so the branch that would
    /// wrap the exchange is not compiled.
    fn performResponseStream(
        self: *Client,
        response_url: []const u8,
        auth_header: []const u8,
        req_json: []const u8,
        sink: StreamSink,
    ) !ApiResponse {
        if (comptime trace_mod.enabled) {
            if (self.trace != null) return self.recordedResponseStream(response_url, auth_header, req_json, sink);
        }
        return self.exchangeStreaming(response_url, auth_header, req_json, sink, null);
    }

    /// The same exchange, with its bytes written into the trace the run holds.
    ///
    /// The recording wraps the whole exchange rather than sitting inside it: a
    /// request that fails part-way is exactly the one whose bytes are wanted,
    /// and the body has to be caught as it arrives, before the reader drops it.
    fn recordedResponseStream(
        self: *Client,
        response_url: []const u8,
        auth_header: []const u8,
        req_json: []const u8,
        sink: StreamSink,
    ) !ApiResponse {
        const trace = self.trace orelse
            return self.exchangeStreaming(response_url, auth_header, req_json, sink, null);

        trace.request(self.trace_ctx, response_url, self.model, req_json, estimateTokens(req_json));
        const started = std.Io.Timestamp.now(self.io, .awake);
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(self.allocator);

        const parsed = self.exchangeStreaming(response_url, auth_header, req_json, sink, &raw) catch |err| {
            // What the server said is more useful than the error's name, when
            // it said anything at all.
            const message = self.http_error orelse @errorName(err);
            trace.failure(self.trace_ctx, message, raw.items, started.untilNow(self.io, .awake).toMilliseconds());
            return err;
        };
        const calls = parsed.tool_calls orelse &.{};
        const recorded = self.allocator.alloc(trace_mod.Call, calls.len) catch null;
        defer if (recorded) |entries| self.allocator.free(entries);
        if (recorded) |entries| for (calls, entries) |call, *entry| {
            entry.* = .{ .id = call.id, .name = call.name, .arguments = call.arguments };
        };
        trace.response(self.trace_ctx, .{
            .finish_reason = parsed.finish_reason,
            .content = parsed.content,
            .reasoning = parsed.reasoning_content,
            .tool_calls = recorded orelse &.{},
            .in_tokens = if (parsed.usage) |usage| usage.input_tokens else null,
            .out_tokens = if (parsed.usage) |usage| usage.output_tokens else null,
            .total_tokens = if (parsed.usage) |usage| usage.total_tokens else null,
            .cached_tokens = if (parsed.usage) |usage| (if (usage.cache_usage_reported) usage.cached_tokens else null) else null,
            .reasoning_tokens = if (parsed.usage) |usage| usage.reasoning_tokens else null,
            .ms = started.untilNow(self.io, .awake).toMilliseconds(),
            .raw = raw.items,
        });
        return parsed;
    }

    /// A streaming Responses request. The body is an SSE stream: every event
    /// is a `data:` line carrying one JSON object. Text deltas are forwarded
    /// to `sink` as they arrive, and the final event carries the complete
    /// response object, which is parsed exactly like a non-streaming reply.
    ///
    /// The request is retried while the failure is one the network or the
    /// server can be expected to recover from: a connection the server had
    /// already closed, a reset, a timeout, or a status that says the server was
    /// busy (408, 429, 5xx).
    ///
    /// A retry is only sent while none of the answer has reached the caller.
    /// Deltas are painted as they arrive, so text shown once must never arrive
    /// a second time: a stream that fails after the reply started ends the turn
    /// instead of being sent again.
    fn exchangeStreaming(self: *Client, response_url: []const u8, auth_header: []const u8, req_json: []const u8, sink: StreamSink, raw: ?*std.ArrayList(u8)) !ApiResponse {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var delivery: Delivery = .{ .target = sink };
            const recorded = if (raw) |buffer| buffer.items.len else 0;
            if (self.exchangeOnce(response_url, auth_header, req_json, delivery.sink(), raw)) |response| {
                return response;
            } else |err| {
                if (!shouldRetry(attempt, delivery.shown, self.retryable_status or isTransientNetworkError(err))) return err;
                // The bytes and the message of this attempt belong to a request
                // that is being sent again: the trace keeps what counts, and
                // only the final failure is worth reporting.
                if (raw) |buffer| buffer.shrinkRetainingCapacity(recorded);
                self.discardHttpError();
                if (comptime trace_mod.enabled) {
                    if (self.trace) |trace| trace.note(self.trace_ctx, "warn", "the request failed before any answer text arrived; it was sent again on a new connection");
                }
                // The failure may have been the pooled connection the request
                // reused, so the retry has to reach the server on a fresh one.
                self.resetHttpClient();
                try self.io.sleep(.fromMilliseconds(retry_delay_ms * (@as(i64, 1) << @intCast(attempt))), .awake);
                continue;
            }
        }
    }

    /// One attempt at the exchange: the request, its response, and the stream
    /// that carries the answer to the sink.
    fn exchangeOnce(self: *Client, response_url: []const u8, auth_header: []const u8, req_json: []const u8, sink: StreamSink, raw: ?*std.ArrayList(u8)) !ApiResponse {
        _ = self.requests.fetchAdd(1, .monotonic);
        self.retryable_status = false;
        if (self.transport) |transport| {
            // Tests drive the buffered path; streaming is a network detail.
            const body = try transport.send(transport.context, self.allocator, req_json);
            defer self.allocator.free(body);
            if (raw) |buffer| buffer.appendSlice(self.allocator, body) catch {};
            self.discardHttpError();
            self.recordResponseUsage(body);
            return parseResponse(self.allocator, body);
        }

        const headers = [_]std.http.Header{
            .{ .name = "ChatGPT-Account-ID", .value = if (self.credentials) |c| c.account_id else "" },
            .{ .name = "originator", .value = "codex_cli_rs" },
        };
        const uri = try std.Uri.parse(response_url);
        var req = try self.http_client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
            },
            .extra_headers = if (self.credentials != null) &headers else &.{},
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = req_json.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(req_json);
        try body.end();
        try req.connection.?.flush();

        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Inspect headers before creating the body reader, which invalidates
        // the response head's borrowed storage.
        var json_response = false;
        var header_it = response.head.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-type") and
                std.mem.indexOf(u8, header.value, "application/json") != null)
            {
                json_response = true;
            }
        }
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);

        var transfer_buffer: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        if (response.head.status != .ok) {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            _ = reader.streamRemaining(&aw.writer) catch {};
            if (raw) |buffer| buffer.appendSlice(self.allocator, aw.written()) catch {};
            self.recordResponseUsage(aw.written());
            self.retryable_status = isTransientStatus(response.head.status);
            self.recordHttpError(response.head.status, aw.written());
            return error.ApiError;
        }

        self.discardHttpError();

        if (json_response) {
            var buffered: std.Io.Writer.Allocating = .init(self.allocator);
            defer buffered.deinit();
            _ = try reader.streamRemaining(&buffered.writer);
            if (raw) |buffer| buffer.appendSlice(self.allocator, buffered.written()) catch {};
            self.recordResponseUsage(buffered.written());
            return parseResponse(self.allocator, buffered.written());
        }

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.allocator);
        var completed: ?[]u8 = null;
        defer if (completed) |c| self.allocator.free(c);

        while (true) {
            const avail = reader.buffered();
            if (avail.len == 0) {
                reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return response.bodyErr() orelse err,
                };
                continue;
            }
            if (raw) |buffer| buffer.appendSlice(self.allocator, avail) catch {};
            var i: usize = 0;
            while (i < avail.len) : (i += 1) {
                const byte = avail[i];
                if (byte == '\n') {
                    try self.handleSseLine(line.items, &data, sink, &completed);
                    line.clearRetainingCapacity();
                } else if (byte != '\r') {
                    try line.append(self.allocator, byte);
                }
            }
            reader.toss(avail.len);
        }
        if (line.items.len > 0) {
            try self.handleSseLine(line.items, &data, sink, &completed);
        }

        if (data.items.len > 0) try self.dispatchSse(data.items, sink, &completed);

        const final_body = completed orelse return error.ResponseNotCompleted;
        const parsed = parseResponse(self.allocator, final_body) catch |err| {
            if (err == error.ApiError) self.recordHttpError(response.head.status, final_body);
            return err;
        };
        return parsed;
    }

    fn handleSseLine(
        self: *Client,
        line: []const u8,
        data: *std.ArrayList(u8),
        sink: StreamSink,
        completed: *?[]u8,
    ) !void {
        if (line.len == 0) {
            // A blank line ends the event. Dispatch on the JSON object's own
            // `type` field rather than the SSE `event:` name, which the proxy
            // may not always set.
            if (data.items.len == 0) return;
            defer data.clearRetainingCapacity();
            try self.dispatchSse(data.items, sink, completed);
            return;
        }
        if (line[0] == ':') return;
        if (std.mem.startsWith(u8, line, "data:")) {
            var value = line["data:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (data.items.len > 0) try data.append(self.allocator, '\n');
            try data.appendSlice(self.allocator, value);
        }
        // `event:` and `id:` lines carry nothing the caller needs.
    }

    fn dispatchSse(
        self: *Client,
        data: []const u8,
        sink: StreamSink,
        completed: *?[]u8,
    ) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object or completed.* != null) return;

        if (root.object.get("type")) |kind| {
            if (kind == .string and (std.mem.eql(u8, kind.string, "response.output_text.delta") or
                std.mem.eql(u8, kind.string, "response.refusal.delta")))
            {
                const delta = root.object.get("delta") orelse return;
                if (delta != .string) return;
                sink.onText(sink.context, delta.string);
                return;
            }
            // The chain of thought, in either of the shapes the Responses
            // protocol narrates it in: the model's own text, or the summary a
            // reasoning request asks for instead. Both read as thinking, so a
            // sink that shows one shows the other the same way.
            if (kind == .string and (std.mem.eql(u8, kind.string, "response.reasoning_text.delta") or
                std.mem.eql(u8, kind.string, "response.reasoning_summary_text.delta")))
            {
                const delta = root.object.get("delta") orelse return;
                if (delta != .string) return;
                if (sink.onReasoning) |onReasoning| onReasoning(sink.context, delta.string);
                return;
            }
        }

        // The terminal events (completed, incomplete, failed) all carry the
        // full `response` object, which is exactly what the buffered parser
        // expects.
        const kind = root.object.get("type") orelse return;
        if (kind != .string or !(std.mem.eql(u8, kind.string, "response.completed") or
            std.mem.eql(u8, kind.string, "response.incomplete") or
            std.mem.eql(u8, kind.string, "response.failed"))) return;
        const response_obj = root.object.get("response") orelse return;
        if (response_obj != .object) return;
        const encoded = std.json.Stringify.valueAlloc(self.allocator, response_obj, .{}) catch return;
        // Persist usage at the terminal event, even if the connection later fails.
        self.addUsage(parseUsage(response_obj));
        completed.* = encoded;
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

/// The single source of truth for Responses history replay and size estimates.
pub fn writeInput(allocator: std.mem.Allocator, w: *std.Io.Writer, messages: []const Message) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.json.Stringify.value(try buildInput(arena.allocator(), messages), .{}, w);
}

/// Heterogeneous Responses items serialize as their payload, not a union tag.
const InputItem = union(enum) {
    replay: std.json.Value,
    output: struct { type: []const u8 = "function_call_output", call_id: []const u8, output: []const u8 },
    message: struct { role: []const u8, content: []const u8 },
    call: struct { type: []const u8 = "function_call", call_id: []const u8, name: []const u8, arguments: []const u8 },

    pub fn jsonStringify(self: InputItem, json: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (self) {
            inline else => |item| try json.write(item),
        }
    }
};

/// All allocations belong to the caller's request-scoped arena.
fn buildInput(arena: std.mem.Allocator, messages: []const Message) ![]const InputItem {
    var input: std.ArrayList(InputItem) = .empty;
    for (messages) |message| {
        if (message.response_items) |items| {
            // Replay opaque items intact, including encrypted reasoning and IDs.
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, items, .{});
            if (parsed != .array) return error.InvalidResponseItems;
            for (parsed.array.items) |item| {
                if (item != .object) return error.InvalidResponseItems;
                try input.append(arena, .{ .replay = item });
            }
            continue;
        }
        if (std.mem.eql(u8, message.role, "tool")) {
            const call_id = message.tool_call_id orelse return error.MissingCallId;
            const result = message.tool_result orelse return error.MissingToolResult;
            const output = try search_tools.formatToolOutput(arena, result);
            try input.append(arena, .{ .output = .{ .call_id = call_id, .output = output } });
            continue;
        }
        if (message.content) |content| {
            try input.append(arena, .{ .message = .{ .role = message.role, .content = content } });
        }
        if (message.tool_calls) |calls| for (calls) |call| {
            try input.append(arena, .{ .call = .{ .call_id = call.id, .name = call.name, .arguments = call.arguments } });
        };
    }
    return input.items;
}

const Request = struct {
    model: []const u8,
    max_output_tokens: u32,
    store: bool = false,
    stream: bool,
    include: [1][]const u8 = .{"reasoning.encrypted_content"},
    input: []const InputItem,
    tools: ?[]const tool_schema.Function,
};

/// Built-in definitions can be any slice (including a runtime ArrayList's
/// items). Extra entries retain the existing MCP JSON schema interface.
pub const ToolSelection = struct {
    /// null selects startup defaults; an explicit slice is used unchanged.
    builtin: ?[]const ToolDefinition = null,
    /// Tool names dropped from the startup defaults. A role that must not have
    /// every tool is then described by the few names it lacks, rather than by
    /// every combination of the startup search programs. Applies to the
    /// default set only: an explicit `builtin` is still used unchanged.
    omit: []const []const u8 = &.{},
    extra: []const []const u8 = &.{},
};

/// null omits the tools member; an empty selection emits an empty array.
/// Startup preferences select independent search definitions, never MCP entries.
pub fn buildRequestWithToolSelection(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const Message,
    max_tokens: u32,
    selection: ?ToolSelection,
    stream: bool,
    search: search_tools.SearchBackends,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const input = try buildInput(arena, messages);
    var functions: std.ArrayList(tool_schema.Function) = .empty;
    if (selection) |selected| {
        for (selected.builtin orelse &tool_schema.builtin) |tool| {
            if (selected.builtin == null) {
                if (std.mem.eql(u8, tool.name, "rg") and !search.rg) continue;
                if (std.mem.eql(u8, tool.name, "grep") and search.rg) continue;
                if (std.mem.eql(u8, tool.name, "fd") and !search.fd) continue;
                if (std.mem.eql(u8, tool.name, "find") and search.fd) continue;
                if (isOmitted(selected.omit, tool.name)) continue;
            }
            try functions.append(arena, try tool.function(arena));
        }
        const builtin_count = functions.items.len;
        for (selected.extra) |entry| {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, entry, .{});
            try functions.append(arena, try readFunction(parsed));
        }
        std.mem.sort(tool_schema.Function, functions.items[builtin_count..], {}, struct {
            fn lessThan(_: void, a: tool_schema.Function, b: tool_schema.Function) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        for (functions.items, 0..) |function, i| {
            for (functions.items[0..i]) |previous| {
                if (std.mem.eql(u8, previous.name, function.name)) return error.DuplicateToolName;
            }
        }
    }
    return std.json.Stringify.valueAlloc(allocator, Request{
        .model = model,
        .max_output_tokens = max_tokens,
        .stream = stream,
        .input = input,
        .tools = if (selection != null) functions.items else null,
    }, .{ .emit_null_optional_fields = false });
}

/// Whether `name` is one of the tool names `omit` lists.
fn isOmitted(omit: []const []const u8, name: []const u8) bool {
    for (omit) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

fn stringField(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidResponse;
    const item = value.object.get(key) orelse return error.InvalidResponse;
    if (item != .string) return error.InvalidResponse;
    return item.string;
}

fn readFunction(tool: std.json.Value) !tool_schema.Function {
    if (tool != .object) return error.InvalidToolSchema;
    const function = tool.object.get("function") orelse tool;
    if (function != .object) return error.InvalidToolSchema;
    const name = try stringField(function, "name");
    const parameters = function.object.get("parameters") orelse return error.InvalidToolSchema;
    if (parameters != .object) return error.InvalidToolSchema;
    const description: ?[]const u8 = if (function.object.get("description")) |value| switch (value) {
        .string => |text| text,
        else => return error.InvalidToolSchema,
    } else null;
    return .{ .name = name, .description = description, .parameters = parameters };
}

/// The plain chain-of-thought text from a response's completed reasoning
/// items, or null when there is none. DeepSeek's thinking mode requires the
/// reasoning to be passed back on later tool-carrying turns, even when the
/// reply that followed it was cut off by the token limit.
fn reasoningText(allocator: std.mem.Allocator, output: std.json.Value) !?[]u8 {
    if (output != .array) return null;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    var first = true;
    for (output.array.items) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "reasoning")) continue;
        if (item.object.get("status")) |status| {
            if (status != .string or !std.mem.eql(u8, status.string, "completed")) continue;
        }
        const blocks = item.object.get("content") orelse continue;
        if (blocks != .array) continue;
        for (blocks.array.items) |block| {
            if (block != .object) continue;
            const block_type = block.object.get("type") orelse continue;
            if (block_type != .string or !std.mem.eql(u8, block_type.string, "reasoning_text")) continue;
            const text = block.object.get("text") orelse continue;
            if (text != .string) continue;
            if (!first) try w.writeByte('\n');
            first = false;
            try w.writeAll(text.string);
        }
    }
    if (first) {
        aw.deinit();
        return null;
    }
    return try aw.toOwnedSlice();
}

/// Missing or malformed counters are zero, not estimates. A report needs at
/// least one explicit nonnegative integer counter; an empty object is not one.
fn usageCounter(object: std.json.Value, name: []const u8) ?u64 {
    if (object != .object) return null;
    const value = object.object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn parseUsage(root: std.json.Value) ?Usage {
    if (root != .object) return null;
    const usage = root.object.get("usage") orelse return null;
    if (usage != .object) return null;
    const input = usageCounter(usage, "input_tokens");
    const output = usageCounter(usage, "output_tokens");
    const total = usageCounter(usage, "total_tokens");
    const cached = usageCounter(usage.object.get("input_tokens_details") orelse .null, "cached_tokens");
    const reasoning = usageCounter(usage.object.get("output_tokens_details") orelse .null, "reasoning_tokens");
    if (input == null and output == null and total == null and cached == null and reasoning == null) return null;
    return .{
        .input_tokens = input orelse 0,
        .output_tokens = output orelse 0,
        .total_tokens = total orelse 0,
        .cached_tokens = cached orelse 0,
        .cache_usage_reported = cached != null,
        .reasoning_tokens = reasoning orelse 0,
    };
}

/// Parse only terminal Responses objects. Incomplete tool calls never execute.
pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !ApiResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    if (root.object.get("error")) |api_error| if (api_error != .null) return error.ApiError;
    const status = try stringField(root, "status");
    // A cut-off reply is not a failure: its text is worth keeping so the agent
    // can continue it. Only the token limit is recoverable, and a partial tool
    // call in it is never dispatched or replayed.
    const truncated = std.mem.eql(u8, status, "incomplete");
    if (truncated) {
        const details = root.object.get("incomplete_details") orelse return error.ResponseNotCompleted;
        if (details != .object) return error.ResponseNotCompleted;
        const reason = try stringField(details, "reason");
        if (!std.mem.eql(u8, reason, "max_output_tokens")) return error.ResponseNotCompleted;
    } else if (!std.mem.eql(u8, status, "completed")) return error.ResponseNotCompleted;
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
        const is_message = std.mem.eql(u8, kind, "message");
        if (!truncated and (std.mem.eql(u8, kind, "function_call") or is_message)) {
            if (item.object.get("status")) |item_status| {
                if (item_status != .string or !std.mem.eql(u8, item_status.string, "completed")) return error.ResponseNotCompleted;
            }
        }
        if (std.mem.eql(u8, kind, "function_call")) {
            // The arguments of a call cut off by the token limit are not valid
            // JSON, so the call is dropped instead of executed or replayed.
            if (truncated) continue;
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
        } else if (is_message) {
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
        } else if (!truncated and !std.mem.eql(u8, kind, "reasoning")) return error.UnsupportedOutputItem;
    }
    if (!truncated and calls.items.len == 0 and content.written().len == 0) return error.EmptyResponse;
    const text = if (content.written().len > 0) try content.toOwnedSlice() else null;
    errdefer if (text) |value| allocator.free(value);
    // Incomplete output items must not be replayed: a partial call or message
    // would be sent back to the model as if it had been completed.
    const raw_items = if (truncated) null else try std.json.Stringify.valueAlloc(allocator, output, .{});
    errdefer if (raw_items) |items| allocator.free(items);
    // Keep the chain-of-thought as plain text. Incomplete output items are not
    // replayed, but the reasoning is complete and thinking mode requires it to
    // be passed back when the next request carries tools.
    const reasoning = try reasoningText(allocator, output);
    errdefer if (reasoning) |value| allocator.free(value);
    const reason = try allocator.dupe(u8, if (truncated) "length" else if (calls.items.len > 0) "tool_calls" else "stop");
    errdefer allocator.free(reason);
    return .{
        .content = text,
        .reasoning_content = reasoning,
        .response_items = raw_items,
        .tool_calls = if (calls.items.len > 0) try calls.toOwnedSlice(allocator) else null,
        .finish_reason = reason,
        .usage = parseUsage(root),
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

/// Rough token estimate, independent of server-reported accounting.
/// Used only for preflight sizing and trace request metadata:
/// ASCII text is about four bytes per token, and each non-ASCII codepoint
/// (CJK included) counts as one. Never contributes to usage counters.
pub fn estimateTokens(bytes: []const u8) u64 {
    var tokens: u64 = 0;
    var ascii_run: u64 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const byte = bytes[i];
        if (byte < 0x80) {
            ascii_run += 1;
            i += 1;
            continue;
        }
        tokens += (ascii_run + 3) / 4;
        ascii_run = 0;
        const len = std.unicode.utf8ByteSequenceLength(byte) catch {
            tokens += 1;
            i += 1;
            continue;
        };
        if (i + len > bytes.len) {
            tokens += 1;
            i += 1;
            continue;
        }
        tokens += 1;
        i += len;
    }
    tokens += (ascii_run + 3) / 4;
    return @max(tokens, 1);
}

test "extra tool order is stable and every duplicate name is rejected" {
    const a = std.testing.allocator;
    const x = "{\"name\":\"x\",\"parameters\":{}}";
    const y = "{\"name\":\"y\",\"parameters\":{}}";
    const different_x = "{\"name\":\"x\",\"parameters\":{\"type\":\"object\"}}";
    const first = try buildRequestWithToolSelection(a, "m", &.{}, 10, .{ .extra = &.{ x, y } }, false, .{});
    defer a.free(first);
    const second = try buildRequestWithToolSelection(a, "m", &.{}, 10, .{ .extra = &.{ y, x } }, false, .{});
    defer a.free(second);
    try std.testing.expectEqualStrings(first, second);
    for ([_][]const u8{ x, different_x }) |duplicate| {
        try std.testing.expectError(error.DuplicateToolName, buildRequestWithToolSelection(a, "m", &.{}, 10, .{ .extra = &.{ x, duplicate } }, false, .{}));
    }
    try std.testing.expectError(error.DuplicateToolName, buildRequestWithToolSelection(a, "m", &.{}, 10, .{ .extra = &.{"{\"name\":\"read\",\"parameters\":{}}"} }, false, .{}));
    try std.testing.expectError(error.DuplicateToolName, buildRequestWithToolSelection(a, "m", &.{}, 10, .{ .builtin = &.{ tool_schema.read, tool_schema.read } }, false, .{}));
}

test "cache usage distinguishes absent from explicit zero" {
    const a = std.testing.allocator;
    const absent = try std.json.parseFromSlice(std.json.Value, a, "{\"usage\":{\"input_tokens\":1}}", .{});
    defer absent.deinit();
    const zero = try std.json.parseFromSlice(std.json.Value, a, "{\"usage\":{\"input_tokens_details\":{\"cached_tokens\":0}}}", .{});
    defer zero.deinit();
    try std.testing.expect(!parseUsage(absent.value).?.cache_usage_reported);
    try std.testing.expect(parseUsage(zero.value).?.cache_usage_reported);
}

test "cache retention is borrowed and projected identically for ordinary and Codex requests" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    var config = try Config.load(a, std.testing.io, &env);
    defer config.deinit();
    // Restore the borrowed test values before Config frees its owned strings.
    const original_retention = config.prompt_cache_retention;
    defer config.prompt_cache_retention = original_retention;
    const retentions = [_]?[]const u8{ null, "", "in_memory", "24h" };
    for ([_]bool{ false, true }) |codex| {
        for (retentions) |retention| {
            config.prompt_cache_retention = retention;
            var client = Client.init(a, std.testing.io, config);
            defer client.deinit();
            if (retention) |value| {
                try std.testing.expect(client.prompt_cache_retention.?.ptr == value.ptr);
            } else try std.testing.expect(client.prompt_cache_retention == null);
            client.codex_auth_path = if (codex) "unused" else null;
            const request = try client.buildWireRequest(&.{}, &.{});
            defer a.free(request);
            var parsed = try std.json.parseFromSlice(std.json.Value, a, request, .{});
            defer parsed.deinit();
            if (retention) |value| {
                try std.testing.expectEqualStrings(value, parsed.value.object.get("prompt_cache_retention").?.string);
            } else try std.testing.expect(!parsed.value.object.contains("prompt_cache_retention"));
            if (retention == null) {
                const ordinary = try buildRequestWithToolSelection(a, client.model, &.{}, client.max_tokens, .{}, true, client.search);
                defer a.free(ordinary);
                const baseline = if (codex) try codexRequest(a, ordinary) else try a.dupe(u8, ordinary);
                defer a.free(baseline);
                try std.testing.expectEqualStrings(baseline, request);
            }
        }
    }
}

test "extract string arg" {
    const allocator = std.testing.allocator;
    const result = try extractStringArg(allocator, "{\"command\":\"ls -la\"}", "command");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ls -la", result);
}

test "a failed request is sent again only when that can work" {
    // A connection the server closed under a pooled request, and the statuses
    // that say the server was busy, are worth another attempt.
    try std.testing.expect(isTransientNetworkError(error.HttpConnectionClosing));
    try std.testing.expect(isTransientNetworkError(error.ConnectionResetByPeer));
    try std.testing.expect(isTransientNetworkError(error.BrokenPipe));
    try std.testing.expect(isTransientNetworkError(error.ConnectionTimedOut));
    try std.testing.expect(isTransientStatus(.too_many_requests));
    try std.testing.expect(isTransientStatus(.service_unavailable));
    try std.testing.expect(isTransientStatus(.gateway_timeout));
    // A request the server refused, and a status that says it was wrong, are
    // not: they fail the same way however often they are sent.
    try std.testing.expect(!isTransientNetworkError(error.ApiError));
    try std.testing.expect(!isTransientNetworkError(error.ConnectionRefused));
    try std.testing.expect(!isTransientStatus(.bad_request));
    try std.testing.expect(!isTransientStatus(.unauthorized));

    try std.testing.expect(shouldRetry(0, false, true));
    try std.testing.expect(shouldRetry(1, false, true));
    // The third attempt is the last one.
    try std.testing.expect(!shouldRetry(2, false, true));
    // Text that already reached the screen must never arrive twice.
    try std.testing.expect(!shouldRetry(0, true, true));
    // A failure a retry cannot fix is reported as it is.
    try std.testing.expect(!shouldRetry(0, false, false));
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
        .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "call_1", .tool_result = .{ .output = "result", .is_error = false } },
    };
    const borrowed = [_][]const u8{"{\"type\":\"function\",\"function\":{\"name\":\"mcp__test__search\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}"};
    const encoded = try buildRequestWithToolSelection(a, "provider/model-name", &messages, 1234, .{ .extra = &borrowed }, false, .{});
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
    // Reasoning is replayed only through exact Responses output items.
    try std.testing.expectEqualStrings("assistant", input[1].object.get("role").?.string);
    try std.testing.expect(input[1].object.get("reasoning_content") == null);
    try std.testing.expectEqualStrings("function_call", input[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[2].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("function_call_output", input[3].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[3].object.get("call_id").?.string);
    const tools = root.get("tools").?.array.items;
    for (tools) |tool| {
        try std.testing.expect(tool.object.get("function") == null);
        try std.testing.expect(tool.object.get("name").? == .string);
        try std.testing.expect(!tool.object.get("strict").?.bool);
    }
    try std.testing.expectEqualStrings("mcp__test__search", tools[tools.len - 1].object.get("name").?.string);
}

test "Responses request escapes strings and rejects malformed replay" {
    const a = std.testing.allocator;
    const tricky = "quote\" backslash\\ newline\n测试";
    var calls = [_]ToolCallData{.{ .id = tricky, .name = tricky, .arguments = "{\"path\":\"a\\\"b\"}" }};
    const messages = [_]Message{
        .{ .role = "user", .content = tricky, .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = tricky, .reasoning_content = tricky, .tool_calls = &calls, .tool_call_id = null },
        .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = tricky, .tool_result = .{ .output = tricky, .is_error = true, .exit_code = 7, .timed_out = true, .ccr_id = "abcdef012345".* } },
    };
    const encoded = try buildRequestWithToolSelection(a, tricky, &messages, 32, null, false, .{});
    defer a.free(encoded);
    const parsed = try std.json.parseFromSlice(struct {
        model: []const u8,
        max_output_tokens: u32,
        store: bool,
        stream: bool,
        include: []const []const u8,
        input: []const struct {
            type: ?[]const u8 = null,
            role: ?[]const u8 = null,
            content: ?std.json.Value = null,
            call_id: ?[]const u8 = null,
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
            output: ?[]const u8 = null,
        },
    }, a, encoded, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(tricky, parsed.value.model);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.include.len);
    const items = parsed.value.input;
    try std.testing.expectEqualStrings(tricky, items[0].content.?.string);
    try std.testing.expectEqualStrings(tricky, items[1].content.?.string);
    try std.testing.expectEqualStrings(tricky, items[2].call_id.?);
    try std.testing.expectEqualStrings(tricky, items[2].name.?);
    const tool_output = try std.json.parseFromSlice(std.json.Value, a, items[3].output.?, .{});
    defer tool_output.deinit();
    try std.testing.expectEqualStrings(tricky, tool_output.value.object.get("output").?.string);
    try std.testing.expectEqualStrings("abcdef012345", tool_output.value.object.get("ccr_id").?.string);
    try std.testing.expect(tool_output.value.object.get("is_error").?.bool);
    try std.testing.expectEqual(@as(i64, 7), tool_output.value.object.get("exit_code").?.integer);
    try std.testing.expect(tool_output.value.object.get("timed_out").?.bool);
    try std.testing.expect(tool_output.value.object.get("termination").? == .null);
    try std.testing.expect(tool_output.value.object.get("content") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, encoded, '\n') == null);

    // Replayed items must be a JSON array of objects, never a splice point.
    const broken = [_]Message{.{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = null, .response_items = "{\"type\":\"message\"}" }};
    try std.testing.expectError(error.InvalidResponseItems, buildRequestWithToolSelection(a, "m", &broken, 8, null, false, .{}));
    const garbage = [_]Message{.{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = null, .response_items = "[] , \"injected\":true" }};
    try std.testing.expectError(error.SyntaxError, buildRequestWithToolSelection(a, "m", &garbage, 8, null, false, .{}));
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
    const request = try buildRequestWithToolSelection(a, "model", &messages, 1000, null, false, .{});
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
    const incomplete = try parseResponse(a, "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[{\"type\":\"function_call\"}]}");
    defer incomplete.deinit(a);
    try std.testing.expectEqualStrings("length", incomplete.finish_reason);
    try std.testing.expect(incomplete.tool_calls == null);
    try std.testing.expect(incomplete.content == null);
    try std.testing.expect(incomplete.response_items == null);
    // The text a truncated reply did produce is kept, while its incomplete
    // message is never replayed as if it had been completed.
    const partial = try parseResponse(a, "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"incomplete\",\"content\":[{\"type\":\"output_text\",\"text\":\"half an ans\"}]}]}");
    defer partial.deinit(a);
    try std.testing.expectEqualStrings("length", partial.finish_reason);
    try std.testing.expectEqualStrings("half an ans", partial.content.?);
    try std.testing.expect(partial.response_items == null);
    try std.testing.expect(partial.tool_calls == null);
    try std.testing.expectError(error.ResponseNotCompleted, parseResponse(a, "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"},\"output\":[]}"));
    try std.testing.expectError(error.ResponseNotCompleted, parseResponse(a, "{\"status\":\"incomplete\",\"output\":[]}"));
    try std.testing.expectError(error.ApiError, parseResponse(a, "{\"status\":\"failed\",\"error\":{\"message\":\"failure\"}}"));
    try std.testing.expectError(error.ResponseNotCompleted, parseResponse(a, "{\"status\":\"in_progress\",\"output\":[]}"));
    try std.testing.expectError(error.EmptyResponse, parseResponse(a, "{\"status\":\"completed\",\"output\":[]}"));
    try std.testing.expectError(error.InvalidResponse, parseResponse(a, "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"wrong-id\",\"name\":\"shell\",\"arguments\":\"{}\"}]}"));
    try std.testing.expectError(error.DuplicateCallId, parseResponse(a, "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"shell\",\"arguments\":\"{}\"},{\"type\":\"function_call\",\"call_id\":\"same\",\"name\":\"shell\",\"arguments\":\"{}\"}]}"));
    const refusal = try parseResponse(a, "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Cannot do that\"}]}]}");
    defer refusal.deinit(a);
    try std.testing.expectEqualStrings("Cannot do that", refusal.content.?);
}

test "sse reasoning deltas reach the sink without counting as answer text" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const config = try Config.load(allocator, std.testing.io, &env);
    defer config.deinit();
    var client = Client.init(allocator, std.testing.io, config);
    defer client.deinit();

    const Capture = struct {
        allocator: std.mem.Allocator,
        text: std.ArrayList(u8) = .empty,
        reasoning: std.ArrayList(u8) = .empty,
        fn onText(context: *anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.text.appendSlice(self.allocator, delta) catch {};
        }
        fn onReasoning(context: *anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.reasoning.appendSlice(self.allocator, delta) catch {};
        }
    };
    var capture = Capture{ .allocator = allocator };
    defer capture.text.deinit(allocator);
    defer capture.reasoning.deinit(allocator);
    const sink = StreamSink{ .context = &capture, .onText = Capture.onText, .onReasoning = Capture.onReasoning };

    var completed: ?[]u8 = null;
    defer if (completed) |c| allocator.free(c);

    // Both shapes the protocol narrates thinking in: the model's own text and
    // the summary a reasoning request asks for.
    try client.dispatchSse("{\"type\":\"response.reasoning_text.delta\",\"delta\":\"weigh \",\"item_id\":\"rs_1\",\"output_index\":0}", sink, &completed);
    try client.dispatchSse("{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"the options\",\"item_id\":\"rs_1\",\"output_index\":0}", sink, &completed);
    try client.dispatchSse("{\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}", sink, &completed);

    try std.testing.expectEqualStrings("weigh the options", capture.reasoning.items);
    try std.testing.expectEqualStrings("answer", capture.text.items);

    // A sink that shows only the answer simply gets none of it.
    const Anonymous = struct {
        fn onText(_: *anyopaque, _: []const u8) void {}
    };
    var nothing: u8 = 0;
    const plain = StreamSink{ .context = &nothing, .onText = Anonymous.onText };
    try client.dispatchSse("{\"type\":\"response.reasoning_text.delta\",\"delta\":\"ignored\"}", plain, &completed);
    try std.testing.expectEqualStrings("weigh the options", capture.reasoning.items);
}

test "a reasoning summary is requested only where the backend needs asking" {
    const a = std.testing.allocator;
    const cases = [_]struct { effort: ?[]const u8, summary: bool, expected: bool }{
        .{ .effort = "high", .summary = true, .expected = true },
        // Without an effort no reasoning object is sent at all, so a model that
        // does not reason is never handed a member it would reject.
        .{ .effort = null, .summary = true, .expected = false },
        // A backend that narrates its own reasoning is not asked for a summary.
        .{ .effort = "high", .summary = false, .expected = false },
    };
    for (cases) |case| {
        var client: Client = .{
            .allocator = a,
            .io = std.testing.io,
            .http_client = .{ .allocator = a, .io = std.testing.io },
            .api_key = "unused",
            .base_url = "https://example.invalid",
            .model = "test",
            .max_tokens = 512,
            .http_error = null,
            .reasoning_effort = case.effort,
            .reasoning_summary = case.summary,
        };
        defer client.deinit();
        const request = try client.buildWireRequest(&.{}, &.{});
        defer a.free(request);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, request, .{});
        defer parsed.deinit();
        const reasoning = parsed.value.object.get("reasoning");
        if (case.expected) {
            try std.testing.expectEqualStrings("auto", reasoning.?.object.get("summary").?.string);
        } else if (reasoning) |object| {
            try std.testing.expect(object.object.get("summary") == null);
        }
    }
}

test "sse deltas stream to the sink and the final event is captured" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const config = try Config.load(allocator, std.testing.io, &env);
    defer config.deinit();
    var client = Client.init(allocator, std.testing.io, config);
    defer client.deinit();

    const Capture = struct {
        allocator: std.mem.Allocator,
        seen: std.ArrayList(u8),
        fn onText(context: *anyopaque, delta: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.seen.appendSlice(self.allocator, delta) catch {};
        }
    };
    var capture = Capture{ .allocator = allocator, .seen = .empty };
    defer capture.seen.deinit(allocator);
    const sink = StreamSink{ .context = &capture, .onText = Capture.onText };

    var completed: ?[]u8 = null;
    defer if (completed) |c| allocator.free(c);

    try client.dispatchSse("{\"type\":\"response.output_text.delta\",\"delta\":\"Hello \"}", sink, &completed);
    try client.dispatchSse("{\"type\":\"response.output_text.delta\",\"delta\":\"world\"}", sink, &completed);
    try client.dispatchSse("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello world\"}]}],\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}}", sink, &completed);

    try std.testing.expectEqualStrings("Hello world", capture.seen.items);
    try std.testing.expect(completed != null);
    const parsed = try parseResponse(allocator, completed.?);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("Hello world", parsed.content.?);
    try std.testing.expectEqual(@as(u64, 12), parsed.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 3), parsed.usage.?.output_tokens);
}

test "token estimates count cjk and ascii sensibly" {
    try std.testing.expectEqual(@as(u64, 1), estimateTokens(""));
    try std.testing.expectEqual(@as(u64, 1), estimateTokens("abcd"));
    try std.testing.expectEqual(@as(u64, 2), estimateTokens("abcde"));
    // Each CJK codepoint is one token, not the three bytes it encodes as.
    try std.testing.expectEqual(@as(u64, 2), estimateTokens("你好"));
}

test "reasoning effort is an outer field for every provider and service tier stays Codex-only" {
    const a = std.testing.allocator;
    const efforts = [_]?[]const u8{ null, "", "high" };
    const tiers = [_]?[]const u8{ null, "", "fast" };
    for ([_]bool{ false, true }) |codex| {
        for (efforts) |effort| {
            for (tiers) |tier| {
                var client: Client = .{
                    .allocator = a,
                    .io = std.testing.io,
                    .http_client = .{ .allocator = a, .io = std.testing.io },
                    .api_key = "unused",
                    .base_url = "https://example.invalid",
                    .model = "test",
                    .max_tokens = 512,
                    .http_error = null,
                    .codex_auth_path = if (codex) "unused" else null,
                    .reasoning_effort = effort,
                    .service_tier = tier,
                };
                defer client.deinit();
                const request = try client.buildWireRequest(&.{}, &.{});
                defer a.free(request);
                var parsed = try std.json.parseFromSlice(std.json.Value, a, request, .{});
                defer parsed.deinit();
                const reasoning = parsed.value.object.get("reasoning");
                // A blank setting omits the field rather than sending "".
                if (nonEmpty(effort)) |value| {
                    try std.testing.expectEqualStrings(value, reasoning.?.object.get("effort").?.string);
                } else try std.testing.expect(reasoning == null);
                const sent_tier = parsed.value.object.get("service_tier");
                if (codex) {
                    if (nonEmpty(tier)) |value| {
                        try std.testing.expectEqualStrings(value, sent_tier.?.string);
                    } else try std.testing.expect(sent_tier == null);
                } else try std.testing.expect(sent_tier == null);
            }
        }
    }
}

test "thinking is a member of its own, sent only when the request asks for it" {
    const a = std.testing.allocator;
    const cases = [_]struct { mode: ThinkingMode, value: ?[]const u8 }{
        .{ .mode = .omit, .value = null },
        .{ .mode = .enabled, .value = "enabled" },
        .{ .mode = .disabled, .value = "disabled" },
    };
    for ([_]bool{ false, true }) |codex| {
        for (cases) |case| {
            var client: Client = .{
                .allocator = a,
                .io = std.testing.io,
                .http_client = .{ .allocator = a, .io = std.testing.io },
                .api_key = "unused",
                .base_url = "https://example.invalid",
                .model = "test",
                .max_tokens = 512,
                .http_error = null,
                .codex_auth_path = if (codex) "unused" else null,
                .thinking = case.mode,
            };
            defer client.deinit();
            const request = try client.buildWireRequest(&.{}, &.{});
            defer a.free(request);
            var parsed = try std.json.parseFromSlice(std.json.Value, a, request, .{});
            defer parsed.deinit();
            const thinking = parsed.value.object.get("thinking");
            if (case.value) |value| {
                try std.testing.expectEqualStrings(value, thinking.?.object.get("type").?.string);
                // The member is the outer object DeepSeek documents, nothing else.
                try std.testing.expectEqual(@as(usize, 1), thinking.?.object.count());
            } else try std.testing.expect(thinking == null);
        }
    }
}

test "the Codex projection keeps its structural changes" {
    const a = std.testing.allocator;
    const messages = [_]Message{
        .{ .role = "system", .content = "be brief", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "user", .content = "hi", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const ordinary = try buildRequestWithToolSelection(a, "test", &messages, 100, null, true, .{});
    defer a.free(ordinary);
    const adapted = try codexRequest(a, ordinary);
    defer a.free(adapted);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, adapted, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("be brief\n", parsed.value.object.get("instructions").?.string);
    try std.testing.expect(!parsed.value.object.contains("max_output_tokens"));
    try std.testing.expect(!parsed.value.object.contains("reasoning"));
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("input").?.array.items.len);
}

/// The value when it is set and not blank: an empty setting means "leave the
/// field out" rather than sending an empty string the backend has to reject.
fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    if (value) |text| {
        if (text.len > 0) return text;
    }
    return null;
}

/// The structural half of the Codex projection: streaming instructions move to
/// `instructions` and the unsupported `max_output_tokens` is dropped. Optional
/// outer-level fields are added afterwards, in `buildWireRequest`, because they
/// are not specific to this backend.
fn codexRequest(a: std.mem.Allocator, ordinary: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, ordinary, .{});
    defer parsed.deinit();
    _ = parsed.value.object.swapRemove("max_output_tokens");
    const input = parsed.value.object.getPtr("input") orelse return error.InvalidRequest;
    var instructions: std.Io.Writer.Allocating = .init(a);
    defer instructions.deinit();
    var i: usize = 0;
    while (i < input.array.items.len) {
        const item = input.array.items[i];
        const role = if (item == .object) item.object.get("role") else null;
        if (role != null and role.? == .string and (std.mem.eql(u8, role.?.string, "system") or std.mem.eql(u8, role.?.string, "developer"))) {
            if (item.object.get("content")) |content| {
                if (content == .string) try instructions.writer.writeAll(content.string);
                if (content == .array) for (content.array.items) |block| {
                    if (block == .object) if (block.object.get("text")) |v| {
                        if (v == .string) try instructions.writer.writeAll(v.string);
                    };
                };
                try instructions.writer.writeByte('\n');
            }
            _ = input.array.orderedRemove(i);
        } else i += 1;
    }
    try parsed.value.object.put(parsed.arena.allocator(), "instructions", .{ .string = instructions.written() });
    return std.json.Stringify.valueAlloc(a, parsed.value, .{});
}

test "usage parsing is strict safe and never synthesizes total" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "{}",                                                                              "{\"usage\":null}",                                    "{\"usage\":false}", "{\"usage\":{}}",
        "{\"usage\":{\"input_tokens\":-1,\"output_tokens\":\"20\",\"total_tokens\":1.5}}", "{\"usage\":{\"input_tokens\":18446744073709551616}}",
    };
    for (cases) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(?Usage, null), parseUsage(parsed.value));
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"usage":{"input_tokens":12,"output_tokens":4,"input_tokens_details":{"cached_tokens":7},"output_tokens_details":{"reasoning_tokens":2}}}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Usage{ .input_tokens = 12, .output_tokens = 4, .cached_tokens = 7, .cache_usage_reported = true, .reasoning_tokens = 2 }, parseUsage(parsed.value).?);
    const malformed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"usage":{"input_tokens":-2,"output_tokens":0,"total_tokens":99,"input_tokens_details":3,"output_tokens_details":{"reasoning_tokens":-4}}}
    , .{});
    defer malformed.deinit();
    try std.testing.expectEqual(Usage{ .total_tokens = 99 }, parseUsage(malformed.value).?);
}

const UsageTestTransport = struct {
    body: []const u8 = "",
    fail: bool = false,
    fn send(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.fail) return error.TestDisconnect;
        return allocator.dupe(u8, self.body);
    }
    fn onText(_: *anyopaque, _: []const u8) void {}
};

test "buffered exchanges account usage before business errors and count every attempt" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const config = try Config.load(a, std.testing.io, &env);
    defer config.deinit();
    var client = Client.init(a, std.testing.io, config);
    defer client.deinit();
    var transport = UsageTestTransport{};
    client.transport = .{ .context = &transport, .send = UsageTestTransport.send };
    const sink = StreamSink{ .context = &transport, .onText = UsageTestTransport.onText };
    const cases = [_]struct { body: []const u8, err: anyerror }{
        .{ .body = "{\"status\":\"failed\",\"error\":{},\"usage\":{\"input_tokens\":9,\"output_tokens\":3,\"total_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":4},\"output_tokens_details\":{\"reasoning_tokens\":2}}}", .err = error.ApiError },
        .{ .body = "{\"status\":\"incomplete\",\"usage\":{\"input_tokens\":1}}", .err = error.ResponseNotCompleted },
        .{ .body = "{\"status\":\"completed\",\"output\":[],\"usage\":{\"output_tokens\":2}}", .err = error.EmptyResponse },
        .{ .body = "{\"status\":\"failed\",\"error\":{}}", .err = error.ApiError },
    };
    for (cases) |case| {
        transport.body = case.body;
        try std.testing.expectError(case.err, client.exchangeStreaming("", "", "{}", sink, null));
    }
    transport.fail = true;
    try std.testing.expectError(error.TestDisconnect, client.exchangeStreaming("", "", "{}", sink, null));
    const counts = client.tokenCounts();
    try std.testing.expectEqual(@as(u64, 10), counts.input);
    try std.testing.expectEqual(@as(u64, 5), counts.output);
    try std.testing.expectEqual(@as(u64, 12), counts.total);
    try std.testing.expectEqual(@as(u64, 4), counts.cached);
    try std.testing.expectEqual(@as(u64, 1), counts.cache_usage_reports);
    try std.testing.expectEqual(@as(u64, 2), counts.reasoning);
    try std.testing.expectEqual(@as(u64, 5), counts.requests);
    try std.testing.expectEqual(@as(u64, 3), counts.usage_reports);
    var parent = Client.init(a, std.testing.io, config);
    defer parent.deinit();
    parent.absorbUsage(&client);
    try std.testing.expectEqualDeep(counts, parent.tokenCounts());
    client.resetTokenCounters();
    const zero = client.tokenCounts();
    inline for (.{ "input", "output", "total", "cached", "reasoning", "requests", "usage_reports", "cache_usage_reports" }) |field| {
        try std.testing.expectEqual(@as(u64, 0), @field(zero, field));
    }
}

test "SSE counts only first terminal usage immediately even when output is invalid" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const config = try Config.load(a, std.testing.io, &env);
    defer config.deinit();
    var client = Client.init(a, std.testing.io, config);
    defer client.deinit();
    var context: u8 = 0;
    const sink = StreamSink{ .context = &context, .onText = UsageTestTransport.onText };
    for ([_][]const u8{ "response.completed", "response.incomplete", "response.failed" }) |kind| {
        client.resetTokenCounters();
        var completed: ?[]u8 = null;
        defer if (completed) |body| a.free(body);
        try client.dispatchSse("{\"type\":\"response.created\",\"response\":{\"usage\":{\"input_tokens\":900}}}", sink, &completed);
        try client.dispatchSse("{\"type\":\"response.in_progress\",\"response\":{\"usage\":{\"input_tokens\":900}}}", sink, &completed);
        try client.dispatchSse("{\"type\":\"response.output_text.delta\",\"delta\":\"long text not estimated\"}", sink, &completed);
        try std.testing.expect(completed == null);
        try std.testing.expectEqual(@as(u64, 0), client.tokenCounts().input);
        try std.testing.expectEqual(@as(u64, 0), client.tokenCounts().output);
        const event = try std.fmt.allocPrint(a, "{{\"type\":\"{s}\",\"response\":{{\"usage\":{{\"input_tokens\":5,\"total_tokens\":8}}}}}}", .{kind});
        defer a.free(event);
        try client.dispatchSse(event, sink, &completed);
        // Accounting has already happened; no final parse or clean EOF needed.
        try std.testing.expectEqual(@as(u64, 5), client.tokenCounts().input);
        try std.testing.expectEqual(@as(u64, 8), client.tokenCounts().total);
        try std.testing.expectEqual(@as(u64, 1), client.tokenCounts().usage_reports);
        try client.dispatchSse(event, sink, &completed);
        try std.testing.expectEqual(@as(u64, 1), client.tokenCounts().usage_reports);
        try std.testing.expectError(error.InvalidResponse, parseResponse(a, completed.?));
    }
}

test "public streaming buffered response preserves full usage and missing usage stays unknown" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const config = try Config.load(a, std.testing.io, &env);
    defer config.deinit();
    var client = Client.init(a, std.testing.io, config);
    defer client.deinit();
    var transport = UsageTestTransport{ .body =
        \\{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15,"input_tokens_details":{"cached_tokens":6},"output_tokens_details":{"reasoning_tokens":3}}}
    };
    client.transport = .{ .context = &transport, .send = UsageTestTransport.send };
    const sink = StreamSink{ .context = &transport, .onText = UsageTestTransport.onText };
    const response = try client.respondStreaming(&.{}, &.{}, sink);
    defer response.deinit(a);
    try std.testing.expectEqual(Usage{ .input_tokens = 10, .output_tokens = 5, .total_tokens = 15, .cached_tokens = 6, .cache_usage_reported = true, .reasoning_tokens = 3 }, response.usage.?);
    const before = client.tokenCounts();
    transport.body =
        \\{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"not estimated"}]}]}
    ;
    const unknown = try client.respondStreaming(&.{}, &.{}, sink);
    defer unknown.deinit(a);
    try std.testing.expect(unknown.usage == null);
    const after = client.tokenCounts();
    try std.testing.expectEqual(before.input, after.input);
    try std.testing.expectEqual(before.output, after.output);
    try std.testing.expectEqual(@as(u64, 2), after.requests);
    try std.testing.expectEqual(@as(u64, 1), after.usage_reports);
}
