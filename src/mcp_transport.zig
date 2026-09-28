//! The wire under the MCP client: JSON-RPC envelopes, and the two transports
//! that carry them — a server subprocess on stdio, and a Streamable HTTP
//! endpoint.
//!
//! Nothing here knows what an MCP method means. A method name and its
//! already-rendered params go in, and the message that answers them comes back.
//! The envelope is understood here all the same, because finding the answer
//! means finding the message whose `id` matches — and on stdio that is the same
//! parse that tells a notification from a response.

const std = @import("std");

/// Longest single message read from a server. A tool result can be large, but
/// a server that never sends a newline must not be able to grow this process
/// without bound.
pub const max_message_bytes = 4 * 1024 * 1024;

/// How many lines that are not JSON-RPC messages are stepped over before the
/// server is given up on. A banner on stdout — npm's, when it downloads a
/// package — is normal; a stream of them means this is not an MCP server.
const max_garbage_lines = 64;

/// How many messages that belong to somebody else — notifications, mostly —
/// one request steps over while it waits for its answer.
const max_skipped_messages = 4096;

/// How much of a refused response's body is kept for the caller: enough for the
/// JSON-RPC error a modern server returns with a `400 Bad Request`, and no more.
const max_error_body_bytes = 4 * 1024;

/// Bytes read from a subprocess pipe at a time.
const read_chunk_bytes = 8 * 1024;

/// The buffer a response body is read through. It is the reader's whole window,
/// so it is also the longest single SSE frame this client can survive.
const transfer_buffer_bytes = 64 * 1024;

/// What this layer raises on its own. Errors from the operating system and from
/// `std.http` are passed through as they are: the caller reports them by name.
pub const Error = error{
    /// The server did not answer within the time the request was given.
    McpTimeout,
    /// The server's side of the stream ended before it answered.
    McpClosed,
    /// The stream carried something this client cannot follow, and its framing
    /// can no longer be trusted.
    McpProtocol,
    /// A single message was longer than this client reads.
    McpMessageTooLong,
    /// The server's `url` is not a URL.
    McpBadEndpoint,
    /// A variable in a server's `env` cannot be written as one.
    McpInvalidEnvKey,
};

/// Build a JSON-RPC request. `params_json` is already-rendered JSON: this layer
/// does not know what any method means.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    id: i64,
    method: []const u8,
    params_json: ?[]const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try w.print("{d}", .{id});
    try w.writeAll(",\"method\":");
    try std.json.Stringify.encodeJsonString(method, .{}, w);
    if (params_json) |params| {
        try w.writeAll(",\"params\":");
        try w.writeAll(params);
    }
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

/// Build a JSON-RPC notification: a request with no id, which nothing answers.
pub fn buildNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: ?[]const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try std.json.Stringify.encodeJsonString(method, .{}, w);
    if (params_json) |params| {
        try w.writeAll(",\"params\":");
        try w.writeAll(params);
    }
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

/// Build an error response, which is how a request *from* a server is refused.
pub fn buildErrorResponse(
    allocator: std.mem.Allocator,
    id: i64,
    code: i64,
    message: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try w.print("{d}", .{id});
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.writeAll("}}");

    return aw.toOwnedSlice();
}

/// A JSON-RPC error a server sent back. Owns its strings.
pub const RpcError = struct {
    code: i64,
    message: []u8,
    /// The `data` member, when the error carried one: the protocol versions a
    /// server supports are named there.
    data_json: ?[]u8,

    pub fn deinit(self: RpcError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.data_json) |data| allocator.free(data);
    }
};

/// What one message from a server turned out to be, from the point of view of a
/// request carrying `want_id`. What this hands back is owned, because a caller
/// reports it after the raw line is gone.
pub const Verdict = union(enum) {
    /// The answer: the JSON text of its `result`.
    result: []u8,
    err: RpcError,
    /// A request *from* the server. The 2026 revision removed every one of them
    /// (a server that needs input returns an `input_required` result instead),
    /// but a legacy server may still send one, and a request that is never
    /// answered hangs it: the caller refuses it politely.
    server_request: struct { id: i64 },
    /// Somebody else's traffic: a notification, or an answer to a request that
    /// is no longer in flight.
    ignore,
    /// Not a JSON-RPC object at all — a banner line, half a message.
    garbage,

    pub fn deinit(self: Verdict, allocator: std.mem.Allocator) void {
        switch (self) {
            .result => |text| allocator.free(text),
            .err => |err| err.deinit(allocator),
            else => {},
        }
    }
};

/// Read one message and decide what it is.
pub fn interpret(allocator: std.mem.Allocator, raw: []const u8, want_id: i64) !Verdict {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return .garbage;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return .garbage,
    };

    // A message carrying a method is a request or a notification, whichever
    // side sent it. Servers are not supposed to initiate requests, but the id
    // is what tells the two apart, so it is read either way.
    if (object.get("method")) |method_value| {
        if (method_value != .string) return .garbage;
        const id_value = object.get("id") orelse return .ignore;
        if (id_value != .integer) return .garbage;
        return .{ .server_request = .{ .id = id_value.integer } };
    }

    // With no method this is a response, and only its id can say whose. An id
    // that is not an integer is not one this client ever sends.
    const id_value = object.get("id") orelse return .garbage;
    if (id_value != .integer or id_value.integer != want_id) return .ignore;

    if (object.get("error")) |error_value| {
        if (error_value != .object) return .garbage;
        const code: i64 = if (error_value.object.get("code")) |code_value|
            (if (code_value == .integer) code_value.integer else 0)
        else
            0;
        const message = if (error_value.object.get("message")) |message_value|
            (if (message_value == .string) message_value.string else "")
        else
            "";

        var data_json: ?[]u8 = null;
        errdefer if (data_json) |data| allocator.free(data);
        if (error_value.object.get("data")) |data_value| {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            try std.json.Stringify.value(data_value, .{}, &aw.writer);
            data_json = try aw.toOwnedSlice();
        }

        return .{ .err = .{
            .code = code,
            .message = try allocator.dupe(u8, message),
            .data_json = data_json,
        } };
    }

    const result_value = object.get("result") orelse return .garbage;

    // Re-rendered rather than cut out of the raw line: what the caller gets is
    // then JSON this process wrote, whatever the server sent.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(result_value, .{}, &aw.writer);
    return .{ .result = try aw.toOwnedSlice() };
}

/// What a server answered, or what the HTTP layer refused to pass on.
pub const Response = union(enum) {
    /// The JSON text of the result.
    result: []u8,
    err: RpcError,
    /// A refusal from the HTTP layer rather than from the protocol. Kept whole
    /// — status and body — because the era probe is the one caller that has to
    /// read it, and the status is what it reads.
    http_error: struct { status: u16, body: []u8 },
    /// `202 Accepted`: a notification was taken, and nothing is coming back.
    accepted,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        switch (self) {
            .result => |text| allocator.free(text),
            .err => |err| err.deinit(allocator),
            .http_error => |refusal| allocator.free(refusal.body),
            .accepted => {},
        }
    }
};

/// One request, as the transports need to see it.
pub const Call = struct {
    /// The whole JSON-RPC request: one line, with no newline of its own.
    message: []const u8,
    /// The id it carries. The answer is the message with this id.
    id: i64,
    /// Mirrored into `Mcp-Method` on Streamable HTTP. Empty for a notification,
    /// whose headers this revision does not define.
    method: []const u8,
    /// `params.name`, mirrored into `Mcp-Name` on Streamable HTTP.
    name: ?[]const u8 = null,
    /// The revision to declare. Null leaves the header off, which a legacy
    /// server's `initialize` wants: the header belongs to the versions after it.
    protocol_version: ?[]const u8 = null,
    /// How long to wait for the answer. A subprocess is read with a deadline;
    /// `std.http` offers no such thing, so this is a stdio setting.
    timeout_ms: i64,
};

pub const Transport = union(enum) {
    stdio: Stdio,
    http: Http,
    /// Answers from a script instead of a server. It is a transport rather than
    /// a test-only backdoor because the era negotiation is both the part of
    /// this file most worth testing and the part hardest to reach through a
    /// socket: a test needs a server that answers `-32601` to a modern request.
    scripted: Scripted,

    /// Send one request and return the message that answers it.
    pub fn request(self: *Transport, allocator: std.mem.Allocator, call: Call) !Response {
        return switch (self.*) {
            .stdio => |*stdio| stdio.request(allocator, call),
            .http => |*http| http.request(allocator, call),
            .scripted => |*scripted| scripted.request(allocator, call),
        };
    }

    /// Send a notification: a message nothing answers.
    pub fn notify(self: *Transport, allocator: std.mem.Allocator, call: Call) !void {
        switch (self.*) {
            .stdio => |*stdio| try stdio.notify(call.message),
            .http => |*http| try http.notify(allocator, call.message),
            .scripted => |*scripted| try scripted.notify(call.message),
        }
    }

    /// Shut the server down. Idempotent.
    pub fn close(self: *Transport) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.close(),
            .http => {},
            .scripted => {},
        }
    }

    pub fn deinit(self: *Transport) void {
        switch (self.*) {
            .stdio => |*stdio| stdio.deinit(),
            .http => |*http| http.deinit(),
            .scripted => |*scripted| scripted.deinit(),
        }
    }

    /// Whether the server is a subprocess, which is what the request timeout
    /// applies to.
    pub fn isStdio(self: *const Transport) bool {
        return switch (self.*) {
            .stdio => true,
            else => false,
        };
    }
};

/// Bytes read from a server, handed out a line at a time. A pipe delivers
/// whatever it has, so one read can carry three messages and half of a fourth;
/// what is left over waits here for the rest of it.
const LineBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Where the next unread line starts.
    start: usize = 0,

    fn deinit(self: *LineBuffer) void {
        self.bytes.deinit(self.allocator);
    }

    fn push(self: *LineBuffer, chunk: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, chunk);
    }

    /// The next complete line without its line ending, or null when the buffer
    /// holds no complete line yet. The slice is valid until the next read.
    fn next(self: *LineBuffer, max: usize) !?[]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.bytes.items, self.start, '\n') orelse {
            if (self.bytes.items.len - self.start >= max) return Error.McpMessageTooLong;
            return null;
        };
        var line: []const u8 = self.bytes.items[self.start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        self.start = end + 1;
        return line;
    }

    /// Drop the part of the buffer that has been handed out already.
    fn compact(self: *LineBuffer) void {
        if (self.start == 0) return;
        const remaining = self.bytes.items.len - self.start;
        std.mem.copyForwards(u8, self.bytes.items[0..remaining], self.bytes.items[self.start..]);
        self.bytes.shrinkRetainingCapacity(remaining);
        self.start = 0;
    }
};

/// How a server subprocess is launched. Its `argv[0]` is resolved on the PATH
/// of *this* process, so `npx` and `uvx` are found the way a shell finds them.
pub const StdioSpec = struct {
    argv: []const []const u8,
    /// Variables added on top of this process's own environment. A server
    /// inherits that environment, because it is where its credentials and its
    /// PATH live.
    env: []const [2][]const u8 = &.{},
};

/// A server spoken to over its standard streams: one JSON-RPC message per line,
/// which is the whole of the stdio binding.
pub const Stdio = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    child: std.process.Child,
    inbox: LineBuffer,
    /// Set once the framing can no longer be trusted — a timeout, a closed
    /// stream, noise nobody can parse past. What is left in the pipe is not
    /// necessarily the answer to the *next* request, so the connection is not
    /// used again: every later call says what went wrong, instead of pairing a
    /// stale response with a fresh request.
    poisoned: bool = false,
    /// Lines that were not JSON-RPC messages, counted over the whole
    /// connection.
    garbage: usize = 0,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        spec: StdioSpec,
        parent_env: *const std.process.Environ.Map,
    ) !Stdio {
        // The child's environment replaces its parent's rather than adding to
        // it, so a server configured with extra variables gets a full copy of
        // this process's environment with those written over it.
        var env: ?std.process.Environ.Map = null;
        defer if (env) |*map| map.deinit();

        if (spec.env.len > 0) {
            var map = try parent_env.clone(allocator);
            errdefer map.deinit();
            for (spec.env) |pair| {
                // `put` asserts on a key that cannot be written as one, and a
                // key comes from a file the user wrote: it is checked rather
                // than assumed, so a typo is a message and not a panic.
                if (!std.process.Environ.Map.validateKeyForPut(pair[0])) return Error.McpInvalidEnvKey;
                try map.put(pair[0], pair[1]);
            }
            env = map;
        }

        const child = try std.process.spawn(io, .{
            .argv = spec.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            // Inherited rather than piped: a server that logs is not talking to
            // us, and a pipe nobody drains fills up and hangs it. Its output
            // reaching the terminal is the price, and also the only way a
            // server that dies at startup gets to say why.
            .stderr = .inherit,
            .environ_map = if (env) |*map| map else null,
        });

        return .{
            .io = io,
            .allocator = allocator,
            .child = child,
            .inbox = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Stdio) void {
        self.inbox.deinit();
    }

    /// Close the server's input, then make sure it is gone.
    ///
    /// Closing stdin is what the binding calls for, and the only portable
    /// shutdown signal there is: a server that reads end-of-file exits by
    /// itself. The kill that follows is for one that does not — and it reaps
    /// the process either way, so a server never outlives the agent as a
    /// zombie.
    pub fn close(self: *Stdio) void {
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }
        if (self.child.id != null) self.child.kill(self.io);
    }

    fn notify(self: *Stdio, json: []const u8) !void {
        try self.write(json);
    }

    /// Write one message. Nothing is buffered in this process: a request sitting
    /// in a buffer is a request the server has not been given yet.
    fn write(self: *Stdio, message: []const u8) !void {
        const stdin = self.child.stdin orelse {
            self.poisoned = true;
            return Error.McpClosed;
        };
        stdin.writeStreamingAll(self.io, message) catch |err| {
            self.poisoned = true;
            return err;
        };
        stdin.writeStreamingAll(self.io, "\n") catch |err| {
            self.poisoned = true;
            return err;
        };
    }

    fn request(self: *Stdio, allocator: std.mem.Allocator, call: Call) !Response {
        if (self.poisoned) return Error.McpProtocol;
        try self.write(call.message);

        var skipped: usize = 0;
        while (true) {
            const line = try self.readLine(call.timeout_ms);
            var verdict = try interpret(allocator, line, call.id);
            switch (verdict) {
                .result => |text| {
                    verdict = .ignore; // Ownership goes to the caller.
                    return .{ .result = text };
                },
                .err => |err| {
                    verdict = .ignore;
                    return .{ .err = err };
                },
                .server_request => |from_server| {
                    verdict.deinit(allocator);
                    // Servers are not supposed to ask; refusing costs a line
                    // and keeps a legacy one from waiting forever on an answer.
                    const refusal = try buildErrorResponse(allocator, from_server.id, -32601, "Method not found");
                    defer allocator.free(refusal);
                    self.write(refusal) catch {};
                },
                .ignore => {
                    verdict.deinit(allocator);
                    skipped += 1;
                    if (skipped > max_skipped_messages) {
                        self.poisoned = true;
                        return Error.McpProtocol;
                    }
                },
                .garbage => {
                    verdict.deinit(allocator);
                    self.garbage += 1;
                    if (self.garbage > max_garbage_lines) {
                        self.poisoned = true;
                        return Error.McpProtocol;
                    }
                },
            }
        }
    }

    /// The next line of a message, waiting no longer than `timeout_ms` for it.
    fn readLine(self: *Stdio, timeout_ms: i64) ![]const u8 {
        while (true) {
            if (try self.inbox.next(max_message_bytes)) |line| return line;
            self.inbox.compact();
            try self.fill(timeout_ms);
        }
    }

    fn fill(self: *Stdio, timeout_ms: i64) !void {
        var chunk: [read_chunk_bytes]u8 = undefined;
        const stdout = self.child.stdout orelse {
            self.poisoned = true;
            return Error.McpClosed;
        };

        // A timed read rather than a plain one: a server that has gone quiet
        // must not be able to hang the agent, and a deadline is the only way to
        // tell "still thinking" from "gone". The descriptor is polled before it
        // is read, so a timeout leaves nothing half-done: whatever arrives
        // later is read by whoever asks next.
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(timeout_ms),
            .clock = .awake,
        } };
        const outcome = self.io.operateTimeout(.{ .file_read_streaming = .{
            .file = stdout,
            .data = &.{&chunk},
        } }, timeout) catch |err| switch (err) {
            // A timeout says nothing about the stream: the descriptor is polled
            // before it is read, so a line that was only half delivered is
            // still waiting in `inbox` and the rest of it arrives later. Only
            // the framing being lost — end of stream, noise nobody can parse
            // past, a write that fails — makes the connection unusable.
            error.Timeout => return Error.McpTimeout,
            else => |other| return other,
        };

        const read = outcome.file_read_streaming catch |err| switch (err) {
            error.EndOfStream => {
                self.poisoned = true;
                return Error.McpClosed;
            },
            else => |other| return other,
        };
        try self.inbox.push(chunk[0..read]);
    }
};

/// Where a Streamable HTTP server lives, and what to send it besides the
/// protocol's own headers.
pub const HttpSpec = struct {
    url: []const u8,
    /// Sent as they are. This is where a token goes.
    headers: []const [2][]const u8 = &.{},
};

/// A server spoken to over Streamable HTTP: one POST per message, answered by
/// either a single JSON object or a stream of events.
///
/// There are no protocol-level sessions in the revision this client speaks, and
/// no timeout on a read — `std.http` offers none — so a server that takes a
/// request and never answers holds the agent until it is interrupted.
pub const Http = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const [2][]const u8,
    /// The session a legacy server handed out at `initialize`, echoed back on
    /// every request after it. A modern server never sends one.
    session_id: ?[]u8 = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, spec: HttpSpec) Http {
        return .{
            .io = io,
            .allocator = allocator,
            .url = spec.url,
            .headers = spec.headers,
        };
    }

    pub fn deinit(self: *Http) void {
        if (self.session_id) |id| self.allocator.free(id);
        self.session_id = null;
    }

    /// Nothing is kept open between requests — every one is its own POST — so
    /// there is nothing to shut down.
    pub fn close(self: *Http) void {
        _ = self;
    }

    fn notify(self: *Http, allocator: std.mem.Allocator, json: []const u8) !void {
        var response = try self.post(allocator, .{
            .message = json,
            .id = 0,
            .method = "",
            .timeout_ms = 0,
        });
        defer response.deinit(allocator);
    }

    fn request(self: *Http, allocator: std.mem.Allocator, call: Call) !Response {
        return self.post(allocator, call);
    }

    fn post(self: *Http, allocator: std.mem.Allocator, call: Call) !Response {
        const uri = std.Uri.parse(self.url) catch return Error.McpBadEndpoint;

        var client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer client.deinit();

        // The headers a request carries have to outlive it, and the ones built
        // here are strings: an arena keeps the bookkeeping to one line.
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(allocator);
        // Either answer is acceptable, and a server picks per request.
        try headers.append(arena, .{ .name = "Accept", .value = "application/json, text/event-stream" });
        if (call.protocol_version) |version| {
            try headers.append(arena, .{ .name = "MCP-Protocol-Version", .value = version });
        }
        if (call.method.len > 0) {
            try appendRoutingHeaders(arena, &headers, call.method, call.name);
        }
        if (self.session_id) |id| {
            try headers.append(arena, .{ .name = "Mcp-Session-Id", .value = id });
        }
        for (self.headers) |header| {
            try headers.append(arena, .{ .name = header[0], .value = header[1] });
        }

        var req = client.request(.POST, uri, .{
            // A redirect would leave the body behind, and an MCP endpoint does
            // not redirect: what the server says is what the caller reads.
            .redirect_behavior = .unhandled,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = headers.items,
        }) catch |err| return err;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = call.message.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| return err;
        body_writer.writer.writeAll(call.message) catch |err| return err;
        body_writer.end() catch |err| return err;
        const connection = req.connection orelse return Error.McpProtocol;
        connection.flush() catch |err| return err;

        var head_buffer: [16 * 1024]u8 = undefined;
        var response = req.receiveHead(&head_buffer) catch |err| return err;

        // The head's strings point into `head_buffer` and are invalidated the
        // moment the body is read, so everything wanted from it is taken now.
        const status = response.head.status;
        var content_type: []const u8 = "";
        var session: ?[]const u8 = null;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) content_type = header.value;
            if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) session = header.value;
        }
        if (session) |id| {
            if (self.session_id) |previous| self.allocator.free(previous);
            self.session_id = try allocator.dupe(u8, id);
        }

        if (status == .accepted) {
            // Nothing will drain the body, and deinit's own drain would block
            // on a response whose framing never ends. The connection is not
            // reused, so closing it costs nothing.
            connection.closing = true;
            return .accepted;
        }

        if (status != .ok) {
            // The status is what a caller reads this for; the body is a bonus,
            // and a body that cannot be read is worth less than the status.
            const body = readBody(allocator, &response, max_error_body_bytes) catch
                try allocator.dupe(u8, "");
            return .{ .http_error = .{ .status = @intFromEnum(status), .body = body } };
        }

        if (std.mem.indexOf(u8, content_type, "text/event-stream") != null) {
            return readEvents(allocator, &response, call.id);
        }

        const body = try readBody(allocator, &response, max_message_bytes);
        defer allocator.free(body);

        // A server answering with a JSON body answers with one message.
        var verdict = try interpret(allocator, body, call.id);
        switch (verdict) {
            .result => |text| {
                verdict = .ignore; // Ownership goes to the caller.
                return .{ .result = text };
            },
            .err => |err| {
                verdict = .ignore;
                return .{ .err = err };
            },
            else => {
                verdict.deinit(allocator);
                return Error.McpProtocol;
            },
        }
    }
};

/// Read the events of a response stream until the message that answers this
/// request arrives. The stream ends with that answer, so there is nothing left
/// to drain.
fn readEvents(
    allocator: std.mem.Allocator,
    response: *std.http.Client.Response,
    want_id: i64,
) !Response {
    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var events: Sse = .init(allocator);
    defer events.deinit();

    var chunk: [read_chunk_bytes]u8 = undefined;
    var empty_reads: usize = 0;
    while (true) {
        var writer: std.Io.Writer = .fixed(&chunk);
        const read = reader.stream(&writer, .limited(chunk.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            // The writer offers exactly the room the stream was told it could
            // fill, so a write that does not fit is this client's bug rather
            // than the server's, and is reported as one.
            error.WriteFailed => return Error.McpProtocol,
            else => |other| return other,
        };
        if (read == 0) {
            // A short read is not the end of a stream, so a run of empty ones
            // is treated as a stream that has stopped moving.
            empty_reads += 1;
            if (empty_reads > 64) return Error.McpProtocol;
            continue;
        }
        empty_reads = 0;

        try events.push(writer.buffered());
        while (try events.next()) |payload| {
            // Notifications ride in front of the answer and are dropped here;
            // anything unparseable is stepped over rather than failing the
            // request, because a stream is the one place a server's own
            // chatter can appear.
            var verdict = try interpret(allocator, payload, want_id);
            switch (verdict) {
                .result => |text| {
                    verdict = .ignore; // Ownership goes to the caller.
                    return .{ .result = text };
                },
                .err => |err| {
                    verdict = .ignore;
                    return .{ .err = err };
                },
                else => verdict.deinit(allocator),
            }
        }
    }

    // The stream ended without an answer. Whatever was on its way is lost with
    // it, and re-issuing the request is the caller's to decide.
    return Error.McpClosed;
}

/// Server-Sent Events, as far as this client needs them: the `data` of each
/// event, assembled from as many `data:` lines as it took. Comments, event
/// names and ids are read and dropped — a JSON-RPC answer is all this is for.
const Sse = struct {
    allocator: std.mem.Allocator,
    lines: LineBuffer,
    data: std.ArrayList(u8) = .empty,
    /// Whether `data` is still the payload last handed out. It is cleared on
    /// the next ask, so a caller may read what it was given until then.
    delivered: bool = false,

    fn init(allocator: std.mem.Allocator) Sse {
        return .{ .allocator = allocator, .lines = .{ .allocator = allocator } };
    }

    fn deinit(self: *Sse) void {
        self.lines.deinit();
        self.data.deinit(self.allocator);
    }

    fn push(self: *Sse, bytes: []const u8) !void {
        try self.lines.push(bytes);
    }

    /// The next completed event's payload, or null when no event is complete
    /// yet. The slice is valid until the next call.
    fn next(self: *Sse) !?[]const u8 {
        if (self.delivered) {
            self.data.clearRetainingCapacity();
            self.delivered = false;
        }

        while (try self.lines.next(max_message_bytes)) |line| {
            if (line.len == 0) {
                // A blank line ends an event. One carrying no data at all is a
                // keep-alive, and is not an event.
                if (self.data.items.len == 0) continue;
                self.delivered = true;
                return self.data.items;
            }
            if (line[0] == ':') continue;
            if (!std.mem.startsWith(u8, line, "data:")) continue;

            var value: []const u8 = line["data:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (self.data.items.len > 0) try self.data.append(self.allocator, '\n');
            try self.data.appendSlice(self.allocator, value);
        }

        self.lines.compact();
        return null;
    }
};

/// A value as an `Mcp-*` header may carry it.
///
/// Printable ASCII goes through as it is. Everything else — a name with a space
/// or a non-ASCII character in it — is wrapped in the base64 sentinel the
/// specification defines, so a name can never be read as header syntax. A value
/// that already looks like the sentinel is encoded too, or it would be decoded
/// back into something it never was.
pub fn encodeHeaderValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (isPlainHeaderValue(value)) return allocator.dupe(u8, value);

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(value.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, value);

    return std.fmt.allocPrint(allocator, "=?base64?{s}?=", .{encoded});
}

const base64_prefix = "=?base64?";
const base64_suffix = "?=";

fn isPlainHeaderValue(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == ' ' or value[0] == '\t') return false;
    if (value[value.len - 1] == ' ' or value[value.len - 1] == '\t') return false;
    if (std.mem.startsWith(u8, value, base64_prefix) and std.mem.endsWith(u8, value, base64_suffix)) {
        return false;
    }
    for (value) |byte| {
        const printable = byte >= 0x21 and byte <= 0x7e;
        if (!printable and byte != ' ' and byte != '\t') return false;
    }
    return true;
}

/// The headers a Streamable HTTP request is routed on.
///
/// A gateway reads these instead of the body, and a server checks that the two
/// agree — a mismatch is refused with `-32020` — so they are built from the
/// same values the message carries. Values are owned by `allocator`; the names
/// are literals.
pub fn appendRoutingHeaders(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(std.http.Header),
    method: []const u8,
    name: ?[]const u8,
) !void {
    try out.append(allocator, .{ .name = "Mcp-Method", .value = method });
    if (name) |tool| {
        try out.append(allocator, .{ .name = "Mcp-Name", .value = try encodeHeaderValue(allocator, tool) });
    }
}

/// The buffer a decompressing reader needs. Empty for an uncompressed body,
/// which is the usual case.
fn allocDecompressBuffer(allocator: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => error.UnsupportedCompressionMethod,
    };
}

/// Read a response body into memory, stopping at `limit` rather than failing,
/// so an oversized body still shows its beginning.
fn readBody(
    allocator: std.mem.Allocator,
    response: *std.http.Client.Response,
    limit: usize,
) ![]u8 {
    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    while (aw.written().len < limit) {
        // A short read is not the end of the body: only EndOfStream or the
        // limit ends this loop. Stopping at the limit leaves the rest unread,
        // which closing the connection deals with rather than draining it.
        _ = reader.stream(&aw.writer, .limited(limit - aw.written().len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |other| return other,
        };
    }
    return aw.toOwnedSlice();
}

/// One scripted answer.
pub const Answer = union(enum) {
    /// The JSON text of a `result`.
    result: []const u8,
    err: struct {
        code: i64,
        message: []const u8,
        /// The JSON text of the error's `data`, where a server names the
        /// protocol versions it does support.
        data: ?[]const u8 = null,
    },
    /// Nothing at all: the request times out.
    silence,
};

/// A transport that answers from a script, for tests that need a server saying
/// something specific — a version it does not support, a method it does not
/// have, or nothing at all for a while.
pub const Scripted = struct {
    allocator: std.mem.Allocator,
    script: []const Answer,
    index: usize = 0,
    /// Every message this transport was handed, in order.
    sent: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, script: []const Answer) Scripted {
        return .{ .allocator = allocator, .script = script };
    }

    pub fn deinit(self: *Scripted) void {
        for (self.sent.items) |message| self.allocator.free(message);
        self.sent.deinit(self.allocator);
    }

    fn request(self: *Scripted, allocator: std.mem.Allocator, call: Call) !Response {
        try self.sent.append(self.allocator, try self.allocator.dupe(u8, call.message));

        if (self.index >= self.script.len) return Error.McpTimeout;
        const answer = self.script[self.index];
        self.index += 1;

        return switch (answer) {
            .silence => Error.McpTimeout,
            .err => |err| .{ .err = .{
                .code = err.code,
                .message = try allocator.dupe(u8, err.message),
                .data_json = if (err.data) |data| try allocator.dupe(u8, data) else null,
            } },
            .result => |result| try frameResult(allocator, call.id, result),
        };
    }

    fn notify(self: *Scripted, json: []const u8) !void {
        try self.sent.append(self.allocator, try self.allocator.dupe(u8, json));
    }
};

/// Wrap a scripted `result` in a response and read it back the way a real one
/// would be read, so a test exercises the same path a server's answer takes.
fn frameResult(allocator: std.mem.Allocator, id: i64, result: []const u8) !Response {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":", .{id});
    try aw.writer.writeAll(result);
    try aw.writer.writeByte('}');
    const raw = try aw.toOwnedSlice();
    defer allocator.free(raw);

    var verdict = try interpret(allocator, raw, id);
    switch (verdict) {
        .result => |text| {
            verdict = .ignore;
            return .{ .result = text };
        },
        else => {
            verdict.deinit(allocator);
            return Error.McpProtocol;
        },
    }
}

test "build request carries the id, the method and the params" {
    const allocator = std.testing.allocator;
    const message = try buildRequest(allocator, 7, "tools/call", "{\"name\":\"echo\"}");
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\"}}",
        message,
    );
    // The stdio binding is one message per line, so a message must not carry a
    // line ending of its own.
    try std.testing.expect(std.mem.indexOfScalar(u8, message, '\n') == null);
}

test "build notification has no id" {
    const allocator = std.testing.allocator;
    const message = try buildNotification(allocator, "notifications/initialized", null);
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        message,
    );
}

test "build error response names the code" {
    const allocator = std.testing.allocator;
    const message = try buildErrorResponse(allocator, 3, -32601, "Method not found");
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
        message,
    );
}

test "an answer is read by its id" {
    const allocator = std.testing.allocator;

    var verdict = try interpret(allocator, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"tools\":[]}}", 4);
    defer verdict.deinit(allocator);
    try std.testing.expectEqualStrings("{\"tools\":[]}", verdict.result);

    // An answer to somebody else's request is not ours to read.
    const other = try interpret(allocator, "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}", 4);
    defer other.deinit(allocator);
    try std.testing.expectEqual(Verdict.ignore, std.meta.activeTag(other));
}

test "an error answer keeps its code, message and data" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version",
        \\ "data":{"supported":["2026-07-28"]}}}
    ;

    const verdict = try interpret(allocator, raw, 1);
    defer verdict.deinit(allocator);

    try std.testing.expectEqual(@as(i64, -32022), verdict.err.code);
    try std.testing.expectEqualStrings("Unsupported protocol version", verdict.err.message);
    // The versions a server supports are named in `data`, which is why it comes
    // out whole rather than dropped.
    try std.testing.expectEqualStrings("{\"supported\":[\"2026-07-28\"]}", verdict.err.data_json.?);
}

test "notifications, server requests and noise are told apart" {
    const allocator = std.testing.allocator;

    const notification = try interpret(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}", 1);
    defer notification.deinit(allocator);
    try std.testing.expectEqual(Verdict.ignore, std.meta.activeTag(notification));

    const request = try interpret(allocator, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"roots/list\"}", 1);
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 9), request.server_request.id);

    // A string id is not one this client ever sends, so the message is not an
    // answer to anything it asked.
    const string_id = try interpret(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"result\":{}}", 1);
    defer string_id.deinit(allocator);
    try std.testing.expectEqual(Verdict.ignore, std.meta.activeTag(string_id));

    for ([_][]const u8{ "", "npm warn using --force", "[1,2]", "{\"id\":1}" }) |raw| {
        const verdict = try interpret(allocator, raw, 1);
        defer verdict.deinit(allocator);
        try std.testing.expectEqual(Verdict.garbage, std.meta.activeTag(verdict));
    }
}

test "header values are encoded only when they have to be" {
    const allocator = std.testing.allocator;

    const plain = try encodeHeaderValue(allocator, "search");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("search", plain);

    // A space between words is a header value like any other — this is the
    // example the specification gives — but a name that would arrive trimmed is
    // encoded, because the space at its edge means something.
    const inside = try encodeHeaderValue(allocator, "find all");
    defer allocator.free(inside);
    try std.testing.expectEqualStrings("find all", inside);

    const unicode = try encodeHeaderValue(allocator, "天气");
    defer allocator.free(unicode);

    const decoded = try allocator.alloc(u8, "天气".len);
    defer allocator.free(decoded);
    _ = try std.base64.standard.Decoder.decode(
        decoded,
        unicode[base64_prefix.len .. unicode.len - base64_suffix.len],
    );
    try std.testing.expectEqualStrings("天气", decoded);

    // A value that looks like the sentinel would be decoded back into something
    // else, so it is encoded as well — and with no leading space kept either.
    const sentinel = try encodeHeaderValue(allocator, "=?base64?literal?=");
    defer allocator.free(sentinel);
    try std.testing.expect(std.mem.startsWith(u8, sentinel, base64_prefix));
    try std.testing.expect(sentinel.len > "=?base64?literal?=".len);

    const padded = try encodeHeaderValue(allocator, " padded ");
    defer allocator.free(padded);
    try std.testing.expectEqualStrings("=?base64?IHBhZGRlZCA=?=", padded);
}

test "routing headers mirror the body" {
    const allocator = std.testing.allocator;

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);

    try appendRoutingHeaders(allocator, &headers, "tools/list", null);
    try std.testing.expectEqual(@as(usize, 1), headers.items.len);
    try std.testing.expectEqualStrings("Mcp-Method", headers.items[0].name);
    try std.testing.expectEqualStrings("tools/list", headers.items[0].value);

    try appendRoutingHeaders(allocator, &headers, "tools/call", "echo");
    try std.testing.expectEqual(@as(usize, 3), headers.items.len);
    try std.testing.expectEqualStrings("Mcp-Name", headers.items[2].name);
    try std.testing.expectEqualStrings("echo", headers.items[2].value);
    allocator.free(headers.items[2].value);
}

test "a line buffer hands out whole messages however they arrive" {
    const allocator = std.testing.allocator;
    var buffer: LineBuffer = .{ .allocator = allocator };
    defer buffer.deinit();

    // One read carrying a whole line and a fragment of the next.
    try buffer.push("first\nsec");
    try std.testing.expectEqualStrings("first", (try buffer.next(max_message_bytes)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try buffer.next(max_message_bytes));

    buffer.compact();
    try buffer.push("ond\n");
    try std.testing.expectEqualStrings("second", (try buffer.next(max_message_bytes)).?);

    // A carriage return before the newline belongs to the framing, not the line.
    buffer.compact();
    try buffer.push("third\r\n");
    try std.testing.expectEqualStrings("third", (try buffer.next(max_message_bytes)).?);

    // An unterminated line that runs past the cap is refused rather than held.
    buffer.compact();
    try buffer.push("x" ** 64);
    try std.testing.expectError(Error.McpMessageTooLong, buffer.next(64));
}

test "sse events are assembled from their data lines" {
    const allocator = std.testing.allocator;
    var events: Sse = .init(allocator);
    defer events.deinit();

    // A comment, then an event whose payload arrives in two data lines.
    try events.push(": keep-alive\nevent: message\ndata: {\"a\":\ndata: 1}\n\n");
    try std.testing.expectEqualStrings("{\"a\":\n1}", (try events.next()).?);
    // The payload stays readable until the next event is asked for.
    try std.testing.expectEqual(@as(?[]const u8, null), try events.next());

    try events.push("data: {\"id\":1}\n\n");
    try std.testing.expectEqualStrings("{\"id\":1}", (try events.next()).?);

    // A blank line carrying no data at all is not an event.
    try events.push("\n\n");
    try std.testing.expectEqual(@as(?[]const u8, null), try events.next());
}

test "a scripted transport answers in order and remembers what it was sent" {
    const allocator = std.testing.allocator;
    // The script lives in the union rather than beside it: a Scripted copied in
    // by value would keep the recorded messages where nobody frees them.
    var transport: Transport = .{ .scripted = .init(allocator, &.{
        .{ .err = .{ .code = -32601, .message = "Method not found" } },
        .{ .result = "{\"ok\":true}" },
        .silence,
    }) };
    defer transport.deinit();

    const call = struct {
        fn at(id: i64, method: []const u8) Call {
            return .{ .message = "{\"jsonrpc\":\"2.0\"}", .id = id, .method = method, .timeout_ms = 50 };
        }
    };

    {
        const refusal = try transport.request(allocator, call.at(1, "server/discover"));
        defer refusal.deinit(allocator);
        try std.testing.expectEqual(@as(i64, -32601), refusal.err.code);
    }
    {
        const answer = try transport.request(allocator, call.at(2, "initialize"));
        defer answer.deinit(allocator);
        try std.testing.expectEqualStrings("{\"ok\":true}", answer.result);
    }
    try std.testing.expectError(Error.McpTimeout, transport.request(allocator, call.at(3, "tools/list")));

    try std.testing.expectEqual(@as(usize, 3), transport.scripted.sent.items.len);
}
