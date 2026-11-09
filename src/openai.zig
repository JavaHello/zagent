const std = @import("std");
const search_tools = @import("tools.zig");
const codex_auth = @import("codex_auth.zig");
const Config = @import("config.zig").Config;

// JSON schema for the tools exposed to the model.
///
/// The built-in tools, one JSON function object per line, commas included:
/// this is the body of a request's `tools` array rather than a finished one,
/// so that the tools of the MCP servers connected at the moment can follow it.
const builtin_tools =
    \\{"type":"function","function":{"name":"bash","description":"Execute a Bash command and return its output. Use this to run programs, inspect the system, manage files, and more.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to execute"},"timeout_seconds":{"type":"integer","minimum":1,"maximum":3600,"description":"Command time limit in seconds, default 180. Increase for long builds or tests."}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"read","description":"Read a file or a line range. Output is limited to about 8192 bytes; use narrow line ranges to inspect large files and continue after truncation.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path to the file"},"start_line":{"type":"integer","minimum":1,"description":"First line to read, 1-based and inclusive; defaults to 1"},"end_line":{"type":"integer","minimum":1,"description":"Last line to read, inclusive and >= start_line; defaults to end of file"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write","description":"Create or overwrite a file with content, OR replace one exact, unique text block using old_text and new_text. Never combine these modes. Prefer exact replacement for partial edits: copy old_text from the current file with enough context to match once; nothing changes if absent or ambiguous. Use content only for new files or full replacements.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string","description":"Entire file contents for creation or full replacement"},"old_text":{"type":"string","description":"Exact non-empty text to replace"},"new_text":{"type":"string","description":"Replacement text"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"apply_patch","description":"Change existing files by applying a unified diff. This is how an edit is made instead of writing the whole file back. The patch is a standard unified diff: a header line '--- a/path' and a '+++ b/path' line, then one or more hunks. Each hunk starts with '@@ -<start>,<count> +<start>,<count> @@' giving the line numbers in the file before and after the change, followed by the hunk's lines, each prefixed with a single space (unchanged context), '-' (removed) or '+' (added). Copy the context lines from the file exactly as they are, indentation included: the patch is refused rather than guessed at if they do not match. Keep the counts in the '@@' line equal to the number of lines below it when possible; the tool recomputes mistaken counts from the hunk body, but still requires exact matching context. A zero-length old range inserts after its stated old line. Send a new file as '--- /dev/null' with a hunk that adds every line, and delete one with '+++ /dev/null' and a hunk that removes every line. Several files may be patched in one call by putting one '---'/'+++' pair after another.","parameters":{"type":"object","properties":{"patch":{"type":"string","description":"The unified diff to apply, with its newlines"}},"required":["patch"]}}},
    \\{"type":"function","function":{"name":"ls","description":"List the contents of a directory","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Directory path"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"grep","description":"Search file contents with a regular expression and return the matching lines with their file and line number. Use this search tool instead of shell commands. Binary files are skipped.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"path":{"type":"string","description":"File or directory to search, defaults to the current directory"},"glob":{"type":"string","description":"Only search files whose names match this glob, e.g. *.zig"},"ignore_case":{"type":"boolean","description":"Match case-insensitively"},"context_lines":{"type":"integer","minimum":0,"description":"Number of surrounding lines before and after each match; defaults to 0"},"max_matches":{"type":"integer","minimum":1,"description":"Stop after this many matching lines per file (not a global limit); defaults to unlimited. Output is still subject to the byte limit."}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"find","description":"Find files and directories whose name matches a glob and return their paths. Use this filename search tool instead of shell commands.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob the name must match, e.g. *.zig or *test*"},"path":{"type":"string","description":"Directory to search in, defaults to the current directory"}},"required":["pattern"]}}},
    \\{"type":"function","function":{"name":"http","description":"Make an HTTP request and return its status line, response headers, and body. Use this instead of curl for fetching URLs and calling APIs. Set Content-Type yourself when you send a body; use save_to to download the body to a file instead of returning it.","parameters":{"type":"object","properties":{"url":{"type":"string","description":"The full URL, including the scheme"},"method":{"type":"string","description":"HTTP method: GET, HEAD, POST, PUT, PATCH, DELETE, or OPTIONS. Defaults to GET"},"headers":{"type":"object","description":"Request headers as name/value pairs","additionalProperties":{"type":"string"}},"body":{"type":"string","description":"Request body, for a method that takes one"},"save_to":{"type":"string","description":"Write the response body to this file path instead of returning it"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"ask_user","description":"Ask the user to choose between concrete options when the request is ambiguous, or when a decision only the user can make blocks progress. Not for confirming routine steps.","parameters":{"type":"object","properties":{"question":{"type":"string","description":"The decision that is needed, in one sentence"},"options":{"type":"array","description":"Two to four concrete choices","items":{"type":"object","properties":{"label":{"type":"string","description":"Short name of the choice"},"description":{"type":"string","description":"One sentence on what this choice means"},"recommended":{"type":"boolean","description":"True for the option you would pick"}},"required":["label"]}}},"required":["question","options"]}}},
    \\{"type":"function","function":{"name":"remember","description":"Save one durable note to memory so it survives this session. Use it when the user states a lasting preference, convention or constraint, when a project fact or build command is learned, or when a decision is made that future work must respect. Do not save transient status, one-off task details, secrets, or anything the user asked to forget.","parameters":{"type":"object","properties":{"text":{"type":"string","description":"One short, self-contained sentence in the user's language"}},"required":["text"]}}}
;

/// Largest output budget a truncated response may be retried with. DeepSeek
/// rejects anything above 8192 output tokens for its chat models, so asking for
/// more would turn a recoverable truncation into a hard error.
const growth_cap: u32 = @import("config.zig").max_output_tokens_ceiling;

/// The built-in tools as a whole `tools` member, for the request that has
/// nothing of its own to add to them.
pub const TOOLS_JSON = "[" ++ builtin_tools ++ "]";

test "search registration follows installed backends and advertises renamed filesystem tools" {
    const allocator = std.testing.allocator;
    for ([_]search_tools.SearchBackends{ .{}, .{ .rg = true }, .{ .fd = true }, .{ .rg = true, .fd = true } }) |search| {
        const body = try buildRequestWithSearch(allocator, "test", &.{}, 100, .included, &.{}, false, search);
        defer allocator.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        var names: std.StringHashMap(void) = .init(allocator);
        defer names.deinit();
        for (parsed.value.object.get("tools").?.array.items) |tool| {
            try names.put(tool.object.get("name").?.string, {});
        }
        try std.testing.expect(!names.contains("http_request"));
        for ([_][]const u8{ "read", "write", "ls", "apply_patch", "http" }) |name| {
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

/// Token usage the server reported for one request. Optional because a failed
/// or cut-off request may not carry it.
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
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
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http_client: std.http.Client,
    api_key: []const u8,
    codex_auth_path: ?[]const u8 = null,
    credentials: ?codex_auth.Credentials = null,
    base_url: []const u8,
    model: []const u8,
    max_tokens: u32,
    /// The last HTTP-level failure, kept rather than printed when it happens.
    /// A request runs while the progress animation owns the terminal's line:
    /// a message written from in here would be glued onto a frame and then
    /// erased by the next one. Whoever stops the animation reports it instead.
    http_error: ?[]u8,
    retryable_http_error: bool = false,
    search: search_tools.SearchBackends = .{},
    /// Set only by tests; see `Transport`.
    transport: ?Transport = null,
    /// Live token accounting, read by the spinner while a request is in
    /// flight. These are totals for the current query, not per request.
    input_tokens: std.atomic.Value(u64) = .init(0),
    output_tokens: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .http_client = .{ .allocator = allocator, .io = io },
            .api_key = config.api_key,
            .codex_auth_path = config.codex_auth_path,
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
    }

    pub fn tokenCounts(self: *Client) struct { input: u64, output: u64 } {
        return .{
            .input = self.input_tokens.load(.monotonic),
            .output = self.output_tokens.load(.monotonic),
        };
    }

    fn addUsage(self: *Client, usage: ?Usage) void {
        const u = usage orelse return;
        _ = self.input_tokens.fetchAdd(u.input_tokens, .monotonic);
        _ = self.output_tokens.fetchAdd(u.output_tokens, .monotonic);
    }

    /// Replace the live estimates made for one streaming request with the real
    /// numbers the server reported once it finished. The estimates were added
    /// to the running totals as they were made; the difference is all that is
    /// left to apply.
    fn correctUsage(self: *Client, in_estimate: u64, out_estimate: u64, usage: ?Usage) void {
        const u = usage orelse return;
        if (u.input_tokens >= in_estimate) {
            _ = self.input_tokens.fetchAdd(u.input_tokens - in_estimate, .monotonic);
        } else {
            _ = self.input_tokens.fetchSub(in_estimate - u.input_tokens, .monotonic);
        }
        if (u.output_tokens >= out_estimate) {
            _ = self.output_tokens.fetchAdd(u.output_tokens - out_estimate, .monotonic);
        } else {
            _ = self.output_tokens.fetchSub(out_estimate - u.output_tokens, .monotonic);
        }
    }

    pub fn deinit(self: *Client) void {
        if (self.http_error) |message| self.allocator.free(message);
        if (self.credentials) |credentials| credentials.deinit(self.allocator);
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
        return self.respondWith(messages, .included, extra_tools, null);
    }

    /// Same as `respond`, but the request is streamed and every text delta is
    /// handed to `sink.onText` as it arrives, so the caller can paint the
    /// answer while the model is still writing it.
    pub fn respondStreaming(self: *Client, messages: []const Message, extra_tools: []const []const u8, sink: StreamSink) !ApiResponse {
        return self.respondWith(messages, .included, extra_tools, sink);
    }

    /// Send a request that advertises no tools, for the completion judge. It
    /// must not be able to answer with a tool call, MCP ones included.
    pub fn respondWithoutTools(self: *Client, messages: []const Message) !ApiResponse {
        return self.respondWith(messages, .omitted, &.{}, null);
    }

    fn respondWith(
        self: *Client,
        messages: []const Message,
        tools: Tools,
        extra_tools: []const []const u8,
        sink: ?StreamSink,
    ) !ApiResponse {
        const response_url = try std.fmt.allocPrint(self.allocator, "{s}/responses", .{std.mem.trimEnd(u8, self.base_url, "/")});
        defer self.allocator.free(response_url);

        try self.authenticate();
        const key = if (self.credentials) |c| c.parsed.value.access_token else self.api_key;
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
        defer self.allocator.free(auth_header);

        var max_tokens = self.max_tokens;
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const ordinary_json = try buildRequestWithSearch(
                self.allocator,
                self.model,
                messages,
                max_tokens,
                tools,
                extra_tools,
                sink != null or self.codex_auth_path != null,
                self.search,
            );
            defer self.allocator.free(ordinary_json);
            const req_json = if (self.codex_auth_path != null) try codexRequest(self.allocator, ordinary_json) else try self.allocator.dupe(u8, ordinary_json);
            defer self.allocator.free(req_json);

            const response = if (self.codex_auth_path != null)
                try self.performStreamWithRetry(response_url, auth_header, req_json, sink orelse .{ .context = self, .onText = discardText })
            else if (sink) |stream_sink|
                try self.performStreamWithRetry(response_url, auth_header, req_json, stream_sink)
            else
                try self.performResponseWithRetry(response_url, auth_header, req_json);
            if (!std.mem.eql(u8, response.finish_reason, "length")) return response;
            // Discard this attempt's partial output and retry the same input,
            // so completed tools are not repeated and incomplete calls are
            // never dispatched. Only the last attempt's partial text reaches
            // the caller, which continues it. Bound both the extra requests
            // and their token budget.
            if (attempt >= 3 or max_tokens >= growth_cap) return response;
            response.deinit(self.allocator);
            max_tokens = @min(growth_cap, @max(@as(u32, 1), max_tokens *| 2));
        }
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

    fn performStreamWithRetry(self: *Client, response_url: []const u8, auth_header: []const u8, req_json: []const u8, sink: StreamSink) !ApiResponse {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            return self.performResponseStream(response_url, auth_header, req_json, sink) catch |err| {
                if (attempt >= 2 or (!isRecoverableFetchError(err) and !self.retryable_http_error)) return err;
                self.resetHttpClient();
                try self.io.sleep(.fromMilliseconds(1000 * (@as(i64, 1) << @intCast(attempt))), .awake);
                continue;
            };
        }
    }

    fn performResponseFetch(self: *Client, response_url: []const u8, auth_header: []const u8, req_json: []const u8) !ApiResponse {
        if (self.transport) |transport| {
            const body = try transport.send(transport.context, self.allocator, req_json);
            defer self.allocator.free(body);
            if (self.http_error) |message| self.allocator.free(message);
            self.http_error = null;
            const parsed = try parseResponse(self.allocator, body);
            self.addUsage(parsed.usage);
            return parsed;
        }

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
        const parsed = parseResponse(self.allocator, aw.written()) catch |err| {
            if (err == error.ApiError) self.recordHttpError(fetch_result.status, aw.written());
            return err;
        };
        self.addUsage(parsed.usage);
        return parsed;
    }

    /// A streaming Responses request. The body is an SSE stream: every event
    /// is a `data:` line carrying one JSON object. Text deltas are forwarded
    /// to `sink` as they arrive, and the final event carries the complete
    /// response object, which is parsed exactly like a non-streaming reply.
    fn performResponseStream(self: *Client, response_url: []const u8, auth_header: []const u8, req_json: []const u8, sink: StreamSink) !ApiResponse {
        if (self.transport) |transport| {
            // Tests drive the buffered path; streaming is a network detail.
            const body = try transport.send(transport.context, self.allocator, req_json);
            defer self.allocator.free(body);
            if (self.http_error) |message| self.allocator.free(message);
            self.http_error = null;
            const parsed = try parseResponse(self.allocator, body);
            self.addUsage(parsed.usage);
            return parsed;
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

        self.retryable_http_error = false;
        if (response.head.status != .ok) {
            self.retryable_http_error = switch (@backingInt(response.head.status)) {
                408, 429, 500, 502, 503, 504 => true,
                else => false,
            };
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            _ = reader.streamRemaining(&aw.writer) catch {};
            self.recordHttpError(response.head.status, aw.written());
            return error.ApiError;
        }

        if (self.http_error) |message| self.allocator.free(message);
        self.http_error = null;

        // Estimate the request size so the spinner has an input-token count
        // before the server reports the real one. The real number replaces
        // this estimate once the final event arrives.
        const in_estimate = estimateTokens(req_json);
        _ = self.input_tokens.fetchAdd(in_estimate, .monotonic);

        var out_estimate: u64 = 0;
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
            var i: usize = 0;
            while (i < avail.len) : (i += 1) {
                const byte = avail[i];
                if (byte == '\n') {
                    try self.handleSseLine(line.items, &data, sink, &completed, &out_estimate);
                    line.clearRetainingCapacity();
                } else if (byte != '\r') {
                    try line.append(self.allocator, byte);
                }
            }
            reader.toss(avail.len);
        }
        if (line.items.len > 0) {
            try self.handleSseLine(line.items, &data, sink, &completed, &out_estimate);
        }

        const final_body = completed orelse return error.ResponseNotCompleted;
        const parsed = parseResponse(self.allocator, final_body) catch |err| {
            if (err == error.ApiError) self.recordHttpError(response.head.status, final_body);
            return err;
        };
        self.correctUsage(in_estimate, out_estimate, parsed.usage);
        return parsed;
    }

    fn handleSseLine(
        self: *Client,
        line: []const u8,
        data: *std.ArrayList(u8),
        sink: StreamSink,
        completed: *?[]u8,
        out_estimate: *u64,
    ) !void {
        if (line.len == 0) {
            // A blank line ends the event. Dispatch on the JSON object's own
            // `type` field rather than the SSE `event:` name, which the proxy
            // may not always set.
            if (data.items.len == 0) return;
            defer data.clearRetainingCapacity();
            try self.dispatchSse(data.items, sink, completed, out_estimate);
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
        out_estimate: *u64,
    ) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;

        if (root.object.get("type")) |kind| {
            if (kind == .string and (std.mem.eql(u8, kind.string, "response.output_text.delta") or
                std.mem.eql(u8, kind.string, "response.refusal.delta")))
            {
                const delta = root.object.get("delta") orelse return;
                if (delta != .string) return;
                sink.onText(sink.context, delta.string);
                const estimate = estimateTokens(delta.string);
                out_estimate.* += estimate;
                _ = self.output_tokens.fetchAdd(estimate, .monotonic);
                return;
            }
        }

        // The terminal events (completed, incomplete, failed) all carry the
        // full `response` object, which is exactly what the buffered parser
        // expects.
        const response_obj = root.object.get("response") orelse return;
        if (response_obj == .null) return;
        const encoded = std.json.Stringify.valueAlloc(self.allocator, response_obj, .{}) catch return;
        if (completed.*) |old| self.allocator.free(old);
        completed.* = encoded;
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
    return buildRequestWithTools(allocator, model, messages, max_tokens, tools, &.{}, false);
}

pub fn buildRequestWithTools(allocator: std.mem.Allocator, model: []const u8, messages: []const Message, max_tokens: u32, tools: Tools, extra_tools: []const []const u8, stream: bool) ![]u8 {
    return buildRequestWithSearch(allocator, model, messages, max_tokens, tools, extra_tools, stream, .{});
}

pub fn buildRequestWithSearch(allocator: std.mem.Allocator, model: []const u8, messages: []const Message, max_tokens: u32, tools: Tools, extra_tools: []const []const u8, stream: bool, search: search_tools.SearchBackends) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"model\":");
    try std.json.Stringify.encodeJsonString(model, .{}, w);
    try w.print(",\"max_output_tokens\":{d},\"store\":false,\"stream\":{},\"include\":[\"reasoning.encrypted_content\"],\"input\":[", .{ max_tokens, stream });
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
        // Older session snapshots carry unstructured Chat Completions
        // reasoning strings. Convert them to a typed reasoning item so the
        // chain-of-thought is passed back; thinking mode requires it when the
        // request carries tools.
        if (message.reasoning_content) |reasoning| {
            if (reasoning.len > 0) {
                try separator(w, &first);
                try w.writeAll("{\"type\":\"reasoning\",\"content\":[{\"type\":\"reasoning_text\",\"text\":");
                try std.json.Stringify.encodeJsonString(reasoning, .{}, w);
                try w.writeAll("}]}");
            }
        }
        if (message.content) |content| {
            try separator(w, &first);
            try w.writeAll("{\"role\":");
            try std.json.Stringify.encodeJsonString(message.role, .{}, w);
            try w.writeAll(",\"content\":");
            try std.json.Stringify.encodeJsonString(content, .{}, w);
            try w.writeByte('}');
        }
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
            var function = tool.object.get("function").?;
            const name = function.object.get("name").?.string;
            if (search.rg and std.mem.eql(u8, name, "grep")) {
                function.object.getPtr("name").?.* = .{ .string = "rg" };
            } else if (search.fd and std.mem.eql(u8, name, "find")) {
                function.object.getPtr("name").?.* = .{ .string = "fd" };
            }
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
    const text = if (content.written().len > 0) try allocator.dupe(u8, content.written()) else null;
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
    const usage: ?Usage = if (root.object.get("usage")) |usage_value| blk: {
        if (usage_value != .object) break :blk null;
        const input = usage_value.object.get("input_tokens");
        const out = usage_value.object.get("output_tokens");
        break :blk .{
            .input_tokens = if (input) |v| if (v == .integer) @intCast(v.integer) else 0 else 0,
            .output_tokens = if (out) |v| if (v == .integer) @intCast(v.integer) else 0 else 0,
        };
    } else null;
    return .{
        .content = text,
        .reasoning_content = reasoning,
        .response_items = raw_items,
        .tool_calls = if (calls.items.len > 0) try calls.toOwnedSlice(allocator) else null,
        .finish_reason = reason,
        .usage = usage,
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

/// Rough token count for the live status line, before the server reports the
/// real usage. It approximates OpenAI's tokenizer well enough to watch a reply
/// stream: ASCII text is about four bytes per token, and each non-ASCII
/// codepoint (CJK included) counts as one. The real numbers replace this at
/// the end of the request.
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
    const encoded = try buildRequestWithTools(a, "provider/model-name", &messages, 1234, .included, &borrowed, false);
    defer a.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("messages") == null and root.get("max_tokens") == null and root.get("thinking") == null);
    try std.testing.expectEqualStrings("provider/model-name", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 1234), root.get("max_output_tokens").?.integer);
    try std.testing.expect(!root.get("store").?.bool);
    const input = root.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), input.len);
    // The legacy Chat Completions reasoning string is replayed as a typed
    // reasoning item so thinking mode can receive it back.
    try std.testing.expectEqualStrings("reasoning", input[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("legacy", input[1].object.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("assistant", input[2].object.get("role").?.string);
    try std.testing.expect(input[2].object.get("reasoning_content") == null);
    try std.testing.expectEqualStrings("function_call", input[3].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[3].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("function_call_output", input[4].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[4].object.get("call_id").?.string);
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
    var out_estimate: u64 = 0;

    try client.dispatchSse("{\"type\":\"response.output_text.delta\",\"delta\":\"Hello \"}", sink, &completed, &out_estimate);
    try client.dispatchSse("{\"type\":\"response.output_text.delta\",\"delta\":\"world\"}", sink, &completed, &out_estimate);
    try client.dispatchSse("{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello world\"}]}],\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}}", sink, &completed, &out_estimate);

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

fn discardText(_: *anyopaque, _: []const u8) void {}

/// Codex accepts streaming requests and instructions, but no output token cap.
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
