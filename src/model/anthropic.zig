//! The Anthropic Messages API: a second wire protocol behind the same client.
//!
//! The agent keeps one conversation model, and every protocol projects it onto
//! its own shape. `openai.zig` posts Responses requests; this file builds
//! Messages requests and reads the answers, buffered or streamed.
//!
//! Three differences drive the mapping:
//!
//! * the system prompt is a top-level `system` field, not a message;
//! * a tool result is a `user` block that names its `tool_use_id`, so the
//!   results of one assistant turn are merged into a single user message;
//! * content arrives as typed blocks (`text`, `thinking`, `tool_use`), and a
//!   thinking block carries a signature that has to be handed back unchanged
//!   when the conversation continues.
//!
//! `Message.response_items` therefore holds those blocks exactly as they
//! arrived, and a later turn is replayed as the model wrote it instead of being
//! rebuilt from the summary fields.
const std = @import("std");
const openai = @import("openai.zig");
const search_tools = @import("../tools/mod.zig");
const tool_schema = @import("../tools/schema.zig");

/// The API version every request declares. `x-api-key` and this header are what
/// the endpoint authenticates on, in place of a bearer token.
pub const version = "2023-06-01";

/// The output a request reserves for thinking, in tokens, given the reply
/// budget it may spend. The API requires at least a thousand tokens of budget
/// and strictly more `max_tokens` than budget, so half of the reply leaves room
/// for the answer itself; a request too small for that asks for no thinking at
/// all rather than for a budget the server would refuse.
pub fn thinkingBudget(max_tokens: u32) ?u32 {
    const budget = max_tokens / 2;
    if (budget < 1024) return null;
    return budget;
}

/// Everything a Messages request is built from. `tools` are the same
/// definitions the Responses builder sends; only the wire spelling differs.
pub const Options = struct {
    model: []const u8,
    max_tokens: u32,
    messages: []const openai.Message,
    tools: []const tool_schema.Function = &.{},
    stream: bool,
    /// Null asks for no thinking; the API's own default is off.
    thinking_budget: ?u32 = null,
};

/// One message of the request: a role and the blocks it carries.
const OutMessage = struct {
    role: []const u8,
    content: []const std.json.Value,
};

/// A tool as the Messages API defines it: `input_schema`, not `parameters`.
const OutTool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema: std.json.Value,
};

const OutThinking = struct {
    type: []const u8 = "enabled",
    budget_tokens: u32,
};

const Request = struct {
    model: []const u8,
    max_tokens: u32,
    stream: bool,
    system: ?[]const u8 = null,
    messages: []const OutMessage,
    tools: ?[]const OutTool = null,
    thinking: ?OutThinking = null,
};

/// Build a Messages request body. The whole body belongs to `allocator`.
pub fn buildRequest(allocator: std.mem.Allocator, options: Options) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const thinking = options.thinking_budget != null;
    var threads: std.ArrayList(OutMessage) = .empty;
    var system: std.ArrayList(u8) = .empty;
    for (options.messages) |message| {
        if (std.mem.eql(u8, message.role, "system")) {
            const content = message.content orelse continue;
            if (content.len == 0) continue;
            if (system.items.len > 0) try system.appendSlice(arena, "\n\n");
            try system.appendSlice(arena, content);
            continue;
        }
        const blocks = try blocksFor(arena, message, thinking);
        if (blocks.len == 0) continue;
        const role = if (std.mem.eql(u8, message.role, "assistant")) "assistant" else "user";
        try appendThread(arena, &threads, role, blocks);
    }

    const tools = try outTools(arena, options.tools);
    return std.json.Stringify.valueAlloc(allocator, Request{
        .model = options.model,
        .max_tokens = options.max_tokens,
        .stream = options.stream,
        .system = if (system.items.len > 0) system.items else null,
        .messages = threads.items,
        .tools = if (tools.len > 0) tools else null,
        .thinking = if (options.thinking_budget) |budget| .{ .budget_tokens = budget } else null,
    }, .{ .emit_null_optional_fields = false });
}

/// Add one message to the thread, merging it into the previous one when both
/// speak with the same role. The API wants strictly alternating turns: the
/// results of an assistant's parallel tool calls are one user message, not one
/// per call.
fn appendThread(arena: std.mem.Allocator, threads: *std.ArrayList(OutMessage), role: []const u8, blocks: []const std.json.Value) !void {
    if (threads.items.len > 0) {
        const last = &threads.items[threads.items.len - 1];
        if (std.mem.eql(u8, last.role, role)) {
            const merged = try arena.alloc(std.json.Value, last.content.len + blocks.len);
            @memcpy(merged[0..last.content.len], last.content);
            @memcpy(merged[last.content.len..], blocks);
            last.content = merged;
            return;
        }
    }
    try threads.append(arena, .{ .role = role, .content = blocks });
}

/// The blocks one stored message becomes.
fn blocksFor(arena: std.mem.Allocator, message: openai.Message, thinking: bool) ![]const std.json.Value {
    var blocks: std.ArrayList(std.json.Value) = .empty;

    if (std.mem.eql(u8, message.role, "tool")) {
        const id = message.tool_call_id orelse return blocks.items;
        const result = message.tool_result orelse return blocks.items;
        const output = try search_tools.formatToolOutput(arena, result);
        try blocks.append(arena, try toolResultBlock(arena, id, output, result.is_error));
        return blocks.items;
    }

    if (std.mem.eql(u8, message.role, "assistant")) {
        // The blocks as the model wrote them carry the text, the calls, and the
        // signed thinking that has to travel back with them.
        if (try replayBlocks(arena, message.response_items, thinking)) |replayed| {
            try blocks.appendSlice(arena, replayed);
            return blocks.items;
        }
    }

    if (message.content) |content| {
        if (content.len > 0) try blocks.append(arena, try textBlock(arena, content));
    }
    if (message.tool_calls) |calls| for (calls) |call| {
        try blocks.append(arena, try toolUseBlock(arena, call.id, call.name, call.arguments));
    };
    return blocks.items;
}

/// The assistant blocks recorded for an earlier turn, or null when the stored
/// items are not a Messages payload this client can send back.
///
/// Blocks from another protocol — a Responses item in a session that switched
/// providers — are dropped, and thinking is dropped unless this request asks
/// for it, because the API refuses a signed block it did not ask to receive.
fn replayBlocks(arena: std.mem.Allocator, items: ?[]const u8, thinking: bool) !?[]const std.json.Value {
    const recorded = items orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, recorded, .{}) catch return null;
    if (parsed != .array) return null;

    var blocks: std.ArrayList(std.json.Value) = .empty;
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const kind = stringValue(item.object.get("type")) orelse continue;
        if (std.mem.eql(u8, kind, "text")) {
            const text = item.object.get("text") orelse continue;
            if (text != .string or text.string.len == 0) continue;
            try blocks.append(arena, item);
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            if (item.object.get("id") == null or item.object.get("name") == null) continue;
            try blocks.append(arena, item);
        } else if (thinking and (std.mem.eql(u8, kind, "thinking") or std.mem.eql(u8, kind, "redacted_thinking"))) {
            try blocks.append(arena, item);
        }
    }
    if (blocks.items.len == 0) return null;
    return blocks.items;
}

fn textBlock(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(arena, "type", .{ .string = "text" });
    try object.put(arena, "text", .{ .string = text });
    return .{ .object = object };
}

fn toolUseBlock(arena: std.mem.Allocator, id: []const u8, name: []const u8, arguments_json: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(arena, "type", .{ .string = "tool_use" });
    try object.put(arena, "id", .{ .string = id });
    try object.put(arena, "name", .{ .string = name });
    try object.put(arena, "input", try argumentsObject(arena, arguments_json));
    return .{ .object = object };
}

fn toolResultBlock(arena: std.mem.Allocator, id: []const u8, output: []const u8, is_error: bool) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(arena, "type", .{ .string = "tool_result" });
    try object.put(arena, "tool_use_id", .{ .string = id });
    try object.put(arena, "content", .{ .string = output });
    // The flag is only spelled out when it is true: an omitted `is_error` is
    // the same as false, and the field stays out of the common case.
    if (is_error) try object.put(arena, "is_error", .{ .bool = true });
    return .{ .object = object };
}

/// A call's arguments as the JSON object the API expects. Arguments that are
/// not an object — empty, or cut off by the token limit — become an empty one.
fn argumentsObject(arena: std.mem.Allocator, arguments_json: []const u8) !std.json.Value {
    if (arguments_json.len == 0) return .{ .object = .{} };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch return .{ .object = .{} };
    if (parsed != .object) return .{ .object = .{} };
    return parsed;
}

fn outTools(arena: std.mem.Allocator, functions: []const tool_schema.Function) ![]const OutTool {
    var tools: std.ArrayList(OutTool) = .empty;
    for (functions) |function| {
        try tools.append(arena, .{
            .name = function.name,
            .description = function.description,
            .input_schema = try inputSchema(arena, function.parameters),
        });
    }
    return tools.items;
}

/// The schema as `input_schema`. The API validates it as a JSON schema object
/// and refuses one that does not name its type, which a hand-written MCP
/// definition may leave out.
fn inputSchema(arena: std.mem.Allocator, parameters: std.json.Value) !std.json.Value {
    if (parameters != .object) return .{ .object = .{} };
    var object = parameters.object;
    if (!object.contains("type")) try object.put(arena, "type", .{ .string = "object" });
    return .{ .object = object };
}

/// Token usage a Messages answer reports.
pub fn parseUsage(root: std.json.Value) ?openai.Usage {
    if (root != .object) return null;
    const usage = root.object.get("usage") orelse return null;
    if (usage != .object) return null;
    return composeUsage(
        counter(usage, "input_tokens"),
        counter(usage, "output_tokens"),
        counter(usage, "cache_read_input_tokens"),
        counter(usage, "cache_creation_input_tokens"),
    );
}

/// Project the API's four counters onto the two the terminal shows.
///
/// `input_tokens` is only the uncached part of the prompt; the tokens written
/// to and read from the cache are counted separately. The status line reads
/// input as the whole prompt with the cached part named inside it, so the parts
/// are added up here rather than being reported as three unrelated numbers.
fn composeUsage(input: ?u64, output: ?u64, cache_read: ?u64, cache_creation: ?u64) ?openai.Usage {
    if (input == null and output == null and cache_read == null and cache_creation == null) return null;
    const cached = (cache_read orelse 0) + (cache_creation orelse 0);
    const prompt = (input orelse 0) + cached;
    const reported = cache_read != null or cache_creation != null;
    const completion = output orelse 0;
    return .{
        .cache_usage_reported = reported,
        .input_tokens = prompt,
        .output_tokens = completion,
        .total_tokens = prompt + completion,
        .cached_tokens = cached,
        .reasoning_tokens = 0,
    };
}

fn counter(object: std.json.Value, name: []const u8) ?u64 {
    if (object != .object) return null;
    const value = object.object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    const held = value orelse return null;
    if (held != .string) return null;
    return held.string;
}

fn stringField(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidResponse;
    return stringValue(value.object.get(key)) orelse error.InvalidResponse;
}

/// Parse a complete Messages answer, whether the server sent it as JSON or the
/// streaming accumulator rebuilt it from the events.
///
/// A call the token limit cut off is not executed: its arguments are not a
/// finished JSON object, so the reply is kept as text and read as truncated.
pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !openai.ApiResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    if (root.object.get("error")) |api_error| {
        if (api_error != .null) return error.ApiError;
    }
    const blocks = root.object.get("content") orelse return error.InvalidResponse;
    if (blocks != .array) return error.InvalidResponse;

    // A cut-off reply is not a failure: its text is worth keeping so the agent
    // can continue it. Only the token limit is recoverable.
    const stop_reason = stringValue(root.object.get("stop_reason")) orelse "";
    const truncated = std.mem.eql(u8, stop_reason, "max_tokens");

    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    var reasoning: std.Io.Writer.Allocating = .init(allocator);
    defer reasoning.deinit();
    var calls: std.ArrayList(openai.ToolCallData) = .empty;
    errdefer {
        for (calls.items) |call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    for (blocks.array.items) |block| {
        if (block != .object) continue;
        const kind = stringValue(block.object.get("type")) orelse continue;
        if (std.mem.eql(u8, kind, "text")) {
            const text = block.object.get("text") orelse continue;
            if (text != .string) return error.InvalidResponse;
            try content.writer.writeAll(text.string);
        } else if (std.mem.eql(u8, kind, "thinking")) {
            const text = block.object.get("thinking") orelse continue;
            if (text != .string) continue;
            try reasoning.writer.writeAll(text.string);
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            if (truncated) continue;
            const id = try stringField(block, "id");
            const name = try stringField(block, "name");
            if (id.len == 0 or name.len == 0) return error.InvalidResponse;
            for (calls.items) |call| {
                if (std.mem.eql(u8, call.id, id)) return error.DuplicateCallId;
            }
            const input = block.object.get("input") orelse std.json.Value{ .object = .{} };
            const arguments = try std.json.Stringify.valueAlloc(allocator, input, .{});
            errdefer allocator.free(arguments);
            const owned_id = try allocator.dupe(u8, id);
            errdefer allocator.free(owned_id);
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            try calls.append(allocator, .{ .id = owned_id, .name = owned_name, .arguments = arguments });
        }
        // Server-side blocks (`web_search_tool_result` and the like) are not
        // used by this client and carry nothing the agent can act on.
    }
    if (!truncated and calls.items.len == 0 and content.written().len == 0) return error.EmptyResponse;

    const text = if (content.written().len > 0) try content.toOwnedSlice() else null;
    errdefer if (text) |value| allocator.free(value);
    const thoughts = if (reasoning.written().len > 0) try reasoning.toOwnedSlice() else null;
    errdefer if (thoughts) |value| allocator.free(value);
    // Incomplete blocks must not be replayed: a partial call would be sent back
    // to the model as if it had finished.
    //
    // Complete blocks are kept as they came, apart from a text block that says
    // nothing: the turn carries that block from now on, and an endpoint that
    // wrote it can still refuse to read it back (see
    // `openai.withoutEmptyText`).
    var kept_arena = std.heap.ArenaAllocator.init(allocator);
    defer kept_arena.deinit();
    const items = if (truncated) null else blk: {
        const kept = try openai.withoutEmptyText(kept_arena.allocator(), blocks);
        break :blk if (kept) |value| try std.json.Stringify.valueAlloc(allocator, value, .{}) else null;
    };
    errdefer if (items) |value| allocator.free(value);
    const reason = try allocator.dupe(u8, if (truncated) "length" else if (calls.items.len > 0) "tool_calls" else "stop");
    errdefer allocator.free(reason);
    return .{
        .content = text,
        .reasoning_content = thoughts,
        .tool_calls = if (calls.items.len > 0) try calls.toOwnedSlice(allocator) else null,
        .finish_reason = reason,
        .response_items = items,
        .usage = parseUsage(root),
    };
}

/// One content block while it is still arriving. Text and arguments are
/// accumulated from deltas; a block that arrives whole keeps its own JSON.
const Block = struct {
    index: u64 = 0,
    kind: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    start: ?std.json.Value = null,
    text: std.ArrayList(u8) = .empty,
    partial: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
};

const UsageOut = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_input_tokens: ?u64 = null,
    cache_creation_input_tokens: ?u64 = null,
};

const StreamedMessage = struct {
    type: []const u8 = "message",
    role: []const u8 = "assistant",
    content: []const std.json.Value,
    stop_reason: ?[]const u8 = null,
    usage: ?UsageOut = null,
};

/// What a stream has shown so far, and what it still owes the caller.
///
/// The events are the answer's own encoding: text and arguments arrive as
/// deltas, the stop reason and the output count at the end. Accumulating them
/// here lets a stream be parsed exactly like a buffered reply, without a second
/// reader for the same fields.
pub const Stream = struct {
    /// What the answer keeps: the text of each block, the tool call as it is
    /// assembled, and the one block that arrived whole. A block's own JSON stays
    /// valid for as long as the stream does.
    arena: std.heap.ArenaAllocator,
    /// What one event's parse needs, thrown away before the next event. An
    /// event's JSON is a document per delta, and a long answer sends thousands
    /// of them: keeping them here made the stream's memory grow to twice the
    /// answer it was reading.
    scratch: std.heap.ArenaAllocator,
    blocks: std.ArrayList(Block) = .empty,
    stop_reason: ?[]const u8 = null,
    started: bool = false,
    stopped: bool = false,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read: ?u64 = null,
    cache_creation: ?u64 = null,
    usage_ready: bool = false,
    usage_taken: bool = false,
    /// What the `error` event said, and whether another attempt can help.
    error_detail: ?[]const u8 = null,
    transient: bool = false,

    pub fn init(allocator: std.mem.Allocator) Stream {
        return .{ .arena = .init(allocator), .scratch = .init(allocator) };
    }

    pub fn deinit(self: *Stream) void {
        self.scratch.deinit();
        self.arena.deinit();
    }

    /// Feed one SSE event. Text and thinking are handed to `sink` as they
    /// arrive; an `error` event ends the exchange with `error.ApiError`.
    pub fn apply(self: *Stream, data: []const u8, sink: openai.StreamSink) !void {
        const arena = self.arena.allocator();
        // The event is parsed in a buffer that is emptied before the next one.
        // Everything that outlives the event is copied into `arena` below.
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();
        const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, data, .{}) catch return;
        if (root != .object) return;
        const kind = stringValue(root.object.get("type")) orelse return;

        if (std.mem.eql(u8, kind, "message_start")) {
            self.started = true;
            const message = root.object.get("message") orelse return;
            if (message == .object) self.absorbUsage(message.object.get("usage"));
            return;
        }
        if (std.mem.eql(u8, kind, "content_block_start")) {
            const index = integer(root.object.get("index")) orelse return;
            // The start of a block is kept whole — a `redacted_thinking` block
            // is handed back to the API as it arrived — so this one event is
            // parsed again, into the arena the answer lives in: what the first
            // parse borrowed is gone with the next event.
            const block = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return;
            if (block != .object) return;
            const kept = block.object.get("content_block") orelse return;
            if (kept != .object) return;
            const entry = try self.blockAt(index);
            entry.kind = stringValue(kept.object.get("type")) orelse return;
            entry.start = kept;
            entry.id = stringValue(kept.object.get("id")) orelse "";
            entry.name = stringValue(kept.object.get("name")) orelse "";
            return;
        }
        if (std.mem.eql(u8, kind, "content_block_delta")) {
            const index = integer(root.object.get("index")) orelse return;
            const delta = root.object.get("delta") orelse return;
            if (delta != .object) return;
            const delta_kind = stringValue(delta.object.get("type")) orelse return;
            const entry = try self.blockAt(index);
            // A stream that skipped the block's start event still says what the
            // delta updates; the type is taken from the delta rather than
            // losing the text.
            if (entry.kind.len == 0) {
                entry.kind = if (std.mem.eql(u8, delta_kind, "text_delta"))
                    "text"
                else if (std.mem.eql(u8, delta_kind, "thinking_delta"))
                    "thinking"
                else if (std.mem.eql(u8, delta_kind, "input_json_delta"))
                    "tool_use"
                else
                    "";
            }
            if (std.mem.eql(u8, delta_kind, "text_delta")) {
                const text = stringValue(delta.object.get("text")) orelse return;
                try entry.text.appendSlice(arena, text);
                sink.onText(sink.context, text);
            } else if (std.mem.eql(u8, delta_kind, "thinking_delta")) {
                // Thinking is narration, not the answer: it reaches the panel
                // the caller gave for it and nothing else.
                const text = stringValue(delta.object.get("thinking")) orelse return;
                try entry.text.appendSlice(arena, text);
                if (sink.onReasoning) |onReasoning| onReasoning(sink.context, text);
            } else if (std.mem.eql(u8, delta_kind, "input_json_delta")) {
                const partial = stringValue(delta.object.get("partial_json")) orelse return;
                try entry.partial.appendSlice(arena, partial);
            } else if (std.mem.eql(u8, delta_kind, "signature_delta")) {
                const signature = stringValue(delta.object.get("signature")) orelse return;
                try entry.signature.appendSlice(arena, signature);
            }
            return;
        }
        if (std.mem.eql(u8, kind, "message_delta")) {
            if (root.object.get("delta")) |delta| {
                if (delta == .object) {
                    // The reason outlives the event it arrived in.
                    if (stringValue(delta.object.get("stop_reason"))) |reason| self.stop_reason = try arena.dupe(u8, reason);
                }
            }
            self.absorbUsage(root.object.get("usage"));
            self.usage_ready = true;
            return;
        }
        if (std.mem.eql(u8, kind, "message_stop")) {
            self.stopped = true;
            self.usage_ready = true;
            return;
        }
        if (std.mem.eql(u8, kind, "error")) {
            return self.fail(arena, root);
        }
        // `ping`, `content_block_stop` and any event this client does not know
        // carry nothing the caller needs.
    }

    fn fail(self: *Stream, arena: std.mem.Allocator, root: std.json.Value) error{ApiError} {
        self.error_detail = "the stream reported an error without saying why";
        if (root.object.get("error")) |api_error| {
            if (api_error == .object) {
                // The message is read again by the retry that reports it, long
                // after the event's own buffer is gone.
                if (stringValue(api_error.object.get("message"))) |detail| self.error_detail = arena.dupe(u8, detail) catch return error.ApiError;
                const kind = stringValue(api_error.object.get("type")) orelse "";
                self.transient = isTransientError(kind);
            }
        }
        return error.ApiError;
    }

    fn absorbUsage(self: *Stream, usage: ?std.json.Value) void {
        const held = usage orelse return;
        if (held != .object) return;
        if (counter(held, "input_tokens")) |value| self.input_tokens = value;
        if (counter(held, "output_tokens")) |value| self.output_tokens = value;
        if (counter(held, "cache_read_input_tokens")) |value| self.cache_read = value;
        if (counter(held, "cache_creation_input_tokens")) |value| self.cache_creation = value;
    }

    /// The usage of this answer, once it is complete, and only once: the
    /// counters of a query must not double-count an event the reader saw twice.
    pub fn takeUsage(self: *Stream) ?openai.Usage {
        if (!self.usage_ready or self.usage_taken) return null;
        const usage = composeUsage(self.input_tokens, self.output_tokens, self.cache_read, self.cache_creation) orelse return null;
        self.usage_taken = true;
        return usage;
    }

    /// The message the events add up to, as the same JSON a buffered answer
    /// would have been, ready for `parseResponse`.
    pub fn finish(self: *Stream, allocator: std.mem.Allocator) ![]u8 {
        // A stream that stopped before the message did has no stop reason and
        // no complete answer; that is a failure, not a short reply.
        if (!self.stopped and self.stop_reason == null) return error.ResponseNotCompleted;
        const arena = self.arena.allocator();
        var content: std.ArrayList(std.json.Value) = .empty;
        for (self.blocks.items) |block| {
            // An index whose start never arrived has no type and nothing to
            // rebuild it from, so it is not part of the message.
            if (block.kind.len == 0) continue;
            try content.append(arena, try blockValue(arena, block));
        }
        const usage: ?UsageOut = if (self.input_tokens != null or self.output_tokens != null or self.cache_read != null or self.cache_creation != null)
            .{
                .input_tokens = self.input_tokens,
                .output_tokens = self.output_tokens,
                .cache_read_input_tokens = self.cache_read,
                .cache_creation_input_tokens = self.cache_creation,
            }
        else
            null;
        return std.json.Stringify.valueAlloc(allocator, StreamedMessage{
            .content = content.items,
            .stop_reason = self.stop_reason,
            .usage = usage,
        }, .{ .emit_null_optional_fields = false });
    }

    /// The block at `index`, created in index order when it is new. Indices are
    /// the block's place in the final content array, so they are kept sorted
    /// even if an event for a later block arrives first.
    fn blockAt(self: *Stream, index: u64) !*Block {
        const arena = self.arena.allocator();
        for (self.blocks.items, 0..) |*block, i| {
            if (block.index == index) return block;
            if (block.index > index) {
                try self.blocks.insert(arena, i, .{ .index = index });
                return &self.blocks.items[i];
            }
        }
        try self.blocks.append(arena, .{ .index = index });
        return &self.blocks.items[self.blocks.items.len - 1];
    }
};

fn blockValue(arena: std.mem.Allocator, block: Block) !std.json.Value {
    if (std.mem.eql(u8, block.kind, "text")) {
        var object: std.json.ObjectMap = .{};
        try object.put(arena, "type", .{ .string = "text" });
        try object.put(arena, "text", .{ .string = block.text.items });
        return .{ .object = object };
    }
    if (std.mem.eql(u8, block.kind, "thinking")) {
        var object: std.json.ObjectMap = .{};
        try object.put(arena, "type", .{ .string = "thinking" });
        try object.put(arena, "thinking", .{ .string = block.text.items });
        if (block.signature.items.len > 0) try object.put(arena, "signature", .{ .string = block.signature.items });
        return .{ .object = object };
    }
    if (std.mem.eql(u8, block.kind, "tool_use")) {
        var object: std.json.ObjectMap = .{};
        try object.put(arena, "type", .{ .string = "tool_use" });
        try object.put(arena, "id", .{ .string = block.id });
        try object.put(arena, "name", .{ .string = block.name });
        try object.put(arena, "input", try argumentsObject(arena, block.partial.items));
        return .{ .object = object };
    }
    // Anything else — `redacted_thinking`, a server tool's result — arrived
    // whole, and is kept verbatim so a later turn can hand it back untouched.
    return block.start orelse .{ .null = {} };
}

/// Whether an error event describes a server that was busy or briefly broken,
/// which is the same set of conditions the caller retries a request on.
pub fn isTransientError(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "overloaded_error") or
        std.mem.eql(u8, kind, "rate_limit_error") or
        std.mem.eql(u8, kind, "api_error");
}

fn integer(value: ?std.json.Value) ?u64 {
    const held = value orelse return null;
    if (held != .integer or held.integer < 0) return null;
    return @intCast(held.integer);
}

test "a request hoists the system prompt, merges tool results and maps the tools" {
    const a = std.testing.allocator;
    const messages = [_]openai.Message{
        .{ .role = "system", .content = "You are zagent.", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "user", .content = "list the files", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = @constCast(&[_]openai.ToolCallData{
            .{ .id = "toolu_1", .name = "ls", .arguments = "{\"path\":\".\"}" },
            .{ .id = "toolu_2", .name = "ls", .arguments = "{\"path\":\"src\"}" },
        }), .tool_call_id = null },
        .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "toolu_1", .tool_result = .{ .output = "one", .is_error = false } },
        .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "toolu_2", .tool_result = .{ .output = "two", .is_error = true } },
    };
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const functions = [_]tool_schema.Function{.{ .name = "ls", .description = "list", .parameters = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"properties\":{}}", .{}) }};
    const body = try buildRequest(a, .{
        .model = "claude-sonnet-4-5",
        .max_tokens = 4096,
        .messages = &messages,
        .tools = &functions,
        .stream = true,
    });
    defer a.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("claude-sonnet-4-5", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 4096), root.get("max_tokens").?.integer);
    try std.testing.expect(root.get("stream").?.bool);
    try std.testing.expectEqualStrings("You are zagent.", root.get("system").?.string);
    try std.testing.expect(root.get("thinking") == null);

    // user, assistant, user: the two results are one turn, not two.
    const messages_out = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), messages_out.len);
    try std.testing.expectEqualStrings("user", messages_out[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("assistant", messages_out[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", messages_out[2].object.get("role").?.string);

    const calls = messages_out[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), calls.len);
    try std.testing.expectEqualStrings("tool_use", calls[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_1", calls[0].object.get("id").?.string);
    try std.testing.expectEqualStrings(".", calls[0].object.get("input").?.object.get("path").?.string);

    const results = messages_out[2].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("tool_result", results[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_1", results[0].object.get("tool_use_id").?.string);
    try std.testing.expect(results[0].object.get("content") == null or results[0].object.get("content").? == .string);
    try std.testing.expect(results[0].object.get("is_error") == null);
    try std.testing.expect(results[1].object.get("is_error").?.bool);

    const tool = root.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("ls", tool.get("name").?.string);
    try std.testing.expectEqualStrings("list", tool.get("description").?.string);
    // A schema without a type is refused by the API, so one is supplied.
    try std.testing.expectEqualStrings("object", tool.get("input_schema").?.object.get("type").?.string);
    try std.testing.expect(tool.get("strict") == null);
}

test "recorded blocks are replayed with their signature, and thinking only when asked" {
    const a = std.testing.allocator;
    const recorded = "[{\"type\":\"thinking\",\"thinking\":\"weigh it\",\"signature\":\"sig-1\"}," ++
        "{\"type\":\"text\",\"text\":\"answer\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_9\",\"name\":\"read\",\"input\":{\"path\":\"a.zig\"}}," ++
        "{\"type\":\"message\",\"role\":\"assistant\"}]";
    const messages = [_]openai.Message{
        .{ .role = "user", .content = "go", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "answer", .reasoning_content = null, .tool_calls = null, .tool_call_id = null, .response_items = recorded },
    };
    for ([_]struct { thinking: ?u32, expected: usize }{ .{ .thinking = 4096, .expected = 3 }, .{ .thinking = null, .expected = 2 } }) |case| {
        const body = try buildRequest(a, .{
            .model = "claude-sonnet-4-5",
            .max_tokens = 8192,
            .messages = &messages,
            .stream = true,
            .thinking_budget = case.thinking,
        });
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        const blocks = parsed.value.object.get("messages").?.array.items[1].object.get("content").?.array.items;
        // The Responses item that shares the array is not sent, and the signed
        // thinking block only travels with a request that asked for thinking.
        try std.testing.expectEqual(case.expected, blocks.len);
        if (case.thinking) |budget| {
            const thinking = parsed.value.object.get("thinking").?.object;
            try std.testing.expectEqualStrings("enabled", thinking.get("type").?.string);
            try std.testing.expectEqual(@as(i64, budget), thinking.get("budget_tokens").?.integer);
            try std.testing.expectEqualStrings("sig-1", blocks[0].object.get("signature").?.string);
        } else try std.testing.expect(parsed.value.object.get("thinking") == null);
    }
}

test "a reply is recorded without a text block that says nothing" {
    const a = std.testing.allocator;
    // A Messages endpoint that writes a text block and then has no words for
    // it: the block carries nothing, and an endpoint that wrote it can still
    // refuse to read it back. The recorded turn keeps the thinking and the
    // call, and drops only the empty block.
    const body =
        \\{"type":"message","role":"assistant","stop_reason":"tool_use","content":[
        \\ {"type":"thinking","thinking":"look first","signature":"sig-1"},
        \\ {"type":"text","text":""},
        \\ {"type":"tool_use","id":"toolu_7","name":"read","input":{"path":"a.zig"}}]}
    ;
    const response = try parseResponse(a, body);
    defer response.deinit(a);
    try std.testing.expect(response.content == null);
    const items = response.response_items.?;
    try std.testing.expect(std.mem.indexOf(u8, items, "\"text\":\"\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, items, "sig-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, items, "toolu_7") != null);
    const kept = try std.json.parseFromSlice(std.json.Value, a, items, .{});
    defer kept.deinit();
    try std.testing.expectEqual(@as(usize, 2), kept.value.array.items.len);
}

test "a reply is read as text, calls, thinking and usage" {
    const a = std.testing.allocator;
    const body =
        "{\"type\":\"message\",\"role\":\"assistant\",\"stop_reason\":\"tool_use\"," ++
        "\"content\":[{\"type\":\"thinking\",\"thinking\":\"look first\",\"signature\":\"sig\"}," ++
        "{\"type\":\"text\",\"text\":\"Let me look.\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_7\",\"name\":\"read\",\"input\":{\"path\":\"a.zig\",\"limit\":2}}]," ++
        "\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"cache_read_input_tokens\":90,\"cache_creation_input_tokens\":6}}";
    const response = try parseResponse(a, body);
    defer response.deinit(a);
    try std.testing.expectEqualStrings("Let me look.", response.content.?);
    try std.testing.expectEqualStrings("look first", response.reasoning_content.?);
    try std.testing.expectEqualStrings("tool_calls", response.finish_reason);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.?.len);
    try std.testing.expectEqualStrings("toolu_7", response.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("read", response.tool_calls.?[0].name);
    const arguments = try std.json.parseFromSlice(std.json.Value, a, response.tool_calls.?[0].arguments, .{});
    defer arguments.deinit();
    try std.testing.expectEqual(@as(i64, 2), arguments.value.object.get("limit").?.integer);

    // The cached part of the prompt is counted inside the input, not beside it.
    const usage = response.usage.?;
    try std.testing.expectEqual(@as(u64, 106), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 96), usage.cached_tokens);
    try std.testing.expect(usage.cache_usage_reported);
    try std.testing.expectEqual(@as(u64, 4), usage.output_tokens);
    try std.testing.expectEqual(@as(u64, 110), usage.total_tokens);

    // The blocks are kept verbatim for the next turn.
    try std.testing.expect(response.response_items != null);
    const items = try std.json.parseFromSlice(std.json.Value, a, response.response_items.?, .{});
    defer items.deinit();
    try std.testing.expectEqual(@as(usize, 3), items.value.array.items.len);
}

test "a cut-off reply keeps its text and drops its unfinished calls" {
    const a = std.testing.allocator;
    const body =
        "{\"type\":\"message\",\"stop_reason\":\"max_tokens\",\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"half a sen\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\",\"input\":{}}]}";
    const response = try parseResponse(a, body);
    defer response.deinit(a);
    try std.testing.expectEqualStrings("length", response.finish_reason);
    try std.testing.expectEqualStrings("half a sen", response.content.?);
    try std.testing.expect(response.tool_calls == null);
    // Nothing incomplete is replayed, so the continuation starts from the text.
    try std.testing.expect(response.response_items == null);

    // A reply with neither text nor a usable call is a failure, not an answer.
    try std.testing.expectError(error.EmptyResponse, parseResponse(a, "{\"type\":\"message\",\"content\":[]}"));
    try std.testing.expectError(error.ApiError, parseResponse(a, "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}"));
    try std.testing.expectError(error.DuplicateCallId, parseResponse(a, "{\"type\":\"message\",\"content\":[" ++
        "{\"type\":\"tool_use\",\"id\":\"same\",\"name\":\"read\",\"input\":{}}," ++
        "{\"type\":\"tool_use\",\"id\":\"same\",\"name\":\"read\",\"input\":{}}]}"));
}

/// A sink that keeps what it was shown, so a streamed answer can be compared
/// with the buffered one it stands for.
const Recorder = struct {
    text: std.Io.Writer.Allocating,
    reasoning: std.Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .text = .init(allocator), .reasoning = .init(allocator) };
    }

    fn deinit(self: *Recorder) void {
        self.text.deinit();
        self.reasoning.deinit();
    }

    fn sink(self: *Recorder) openai.StreamSink {
        return .{ .context = self, .onText = onText, .onReasoning = onReasoning };
    }

    fn onText(context: *anyopaque, delta: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.text.writer.writeAll(delta) catch {};
    }

    fn onReasoning(context: *anyopaque, delta: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.reasoning.writer.writeAll(delta) catch {};
    }
};

test "a streamed answer is the same message as a buffered one" {
    const a = std.testing.allocator;
    var recorder = Recorder.init(a);
    defer recorder.deinit();
    var stream: Stream = .init(a);
    defer stream.deinit();

    const events = [_][]const u8{
        "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[],\"usage\":{\"input_tokens\":12,\"output_tokens\":1}}}",
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"weigh\"}}",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig-abc\"}}",
        "{\"type\":\"content_block_stop\",\"index\":0}",
        "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Lis\"}}",
        "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"ting.\"}}",
        "{\"type\":\"content_block_stop\",\"index\":1}",
        "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_3\",\"name\":\"ls\",\"input\":{}}}",
        "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}",
        "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\".\\\"}\"}}",
        "{\"type\":\"content_block_stop\",\"index\":2}",
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":31}}",
        "{\"type\":\"message_stop\"}",
        "{\"type\":\"ping\"}",
    };
    for (events) |event| try stream.apply(event, recorder.sink());

    try std.testing.expectEqualStrings("Listing.", recorder.text.written());
    try std.testing.expectEqualStrings("weigh", recorder.reasoning.written());
    const usage = stream.takeUsage().?;
    try std.testing.expectEqual(@as(u64, 12), usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 31), usage.output_tokens);
    try std.testing.expect(stream.takeUsage() == null);

    const body = try stream.finish(a);
    defer a.free(body);
    const response = try parseResponse(a, body);
    defer response.deinit(a);
    try std.testing.expectEqualStrings("Listing.", response.content.?);
    try std.testing.expectEqualStrings("weigh", response.reasoning_content.?);
    try std.testing.expectEqualStrings("tool_calls", response.finish_reason);
    try std.testing.expectEqualStrings("toolu_3", response.tool_calls.?[0].id);
    const arguments = try std.json.parseFromSlice(std.json.Value, a, response.tool_calls.?[0].arguments, .{});
    defer arguments.deinit();
    try std.testing.expectEqualStrings(".", arguments.value.object.get("path").?.string);
    // The signature the server appended returns with the block.
    try std.testing.expect(std.mem.indexOf(u8, response.response_items.?, "sig-abc") != null);
}

test "a long stream keeps only what the answer is, not the events it read" {
    const a = std.testing.allocator;
    var recorder = Recorder.init(a);
    defer recorder.deinit();
    var stream: Stream = .init(a);
    defer stream.deinit();

    // One event per word, the way a long answer arrives. Each event's own JSON
    // is read and dropped: what the stream holds afterwards is the answer, not
    // a document per delta.
    const event = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"word \"}}";
    var count: usize = 0;
    while (count < 500) : (count += 1) try stream.apply(event, recorder.sink());
    try std.testing.expectEqual(@as(usize, 500 * "word ".len), recorder.text.written().len);
    try std.testing.expect(stream.arena.queryCapacity() < 16 * 1024);

    try stream.apply("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}", recorder.sink());
    try stream.apply("{\"type\":\"message_stop\"}", recorder.sink());
    const body = try stream.finish(a);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "end_turn") != null);
    // The answer is the text of every delta, in the block it was sent for.
    try std.testing.expectEqual(@as(usize, 500), std.mem.count(u8, body, "word "));
}

test "a block announced only by its deltas is still read" {
    const a = std.testing.allocator;
    var recorder = Recorder.init(a);
    defer recorder.deinit();
    var stream: Stream = .init(a);
    defer stream.deinit();
    // A proxy that drops the start event still says which block it is updating.
    try stream.apply("{\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3}}}", recorder.sink());
    try stream.apply("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"still read\"}}", recorder.sink());
    try stream.apply("{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"orphan\"}}", recorder.sink());
    try stream.apply("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}", recorder.sink());
    try stream.apply("{\"type\":\"message_stop\"}", recorder.sink());
    try std.testing.expectEqualStrings("still read", recorder.text.written());

    const body = try stream.finish(a);
    defer a.free(body);
    const response = try parseResponse(a, body);
    defer response.deinit(a);
    try std.testing.expectEqualStrings("still read", response.content.?);
    // The index that never named a block type is not passed on.
    try std.testing.expect(std.mem.indexOf(u8, response.response_items.?, "orphan") == null);
}

test "an error event carries its message and whether a retry can help" {
    const a = std.testing.allocator;
    var recorder = Recorder.init(a);
    defer recorder.deinit();
    var stream: Stream = .init(a);
    defer stream.deinit();
    try std.testing.expectError(error.ApiError, stream.apply(
        "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}",
        recorder.sink(),
    ));
    try std.testing.expectEqualStrings("Overloaded", stream.error_detail.?);
    try std.testing.expect(stream.transient);

    // A stream cut off before its last event has nothing to hand over.
    try std.testing.expectError(error.ResponseNotCompleted, stream.finish(a));

    var refused: Stream = .init(a);
    defer refused.deinit();
    try std.testing.expectError(error.ApiError, refused.apply(
        "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad\"}}",
        recorder.sink(),
    ));
    try std.testing.expect(!refused.transient);
    try std.testing.expect(isTransientError("rate_limit_error"));
    try std.testing.expect(!isTransientError("authentication_error"));
}

test "the thinking budget leaves room for the answer and is never below the API floor" {
    try std.testing.expectEqual(@as(?u32, 4096), thinkingBudget(8192));
    try std.testing.expectEqual(@as(?u32, 1024), thinkingBudget(2048));
    // Too small a reply to reason inside: the request asks for no thinking.
    try std.testing.expectEqual(@as(?u32, null), thinkingBudget(2047));
    try std.testing.expectEqual(@as(?u32, null), thinkingBudget(0));
}
