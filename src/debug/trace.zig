//! The record a `--debug` run keeps: every step, the bytes of each model
//! request and response, and each tool call and its result.
//!
//! The record is written while the run happens, one JSON object per line. A
//! crash, a kill or a timeout therefore leaves everything up to that point on
//! disk, which is exactly the run a report is wanted for. The HTML report is
//! rendered from that same file rather than from memory, so a trace can be
//! turned into a report later (`zagent --debug-report <trace.jsonl>`) and the
//! two can never disagree about what happened.
//!
//! A sub-agent writes into the same file as the agent that started it: the
//! events carry the agent they belong to, and the run is one story. The two
//! never run at once — the caller waits while the child runs — and the mutex
//! below is what keeps the file whole if that ever changes.
const std = @import("std");
const build_options = @import("build_options");
const workspace = @import("../state/workspace.zig");
const report = @import("report.zig");

/// Whether this build records anything at all. Chosen when zagent is built
/// rather than when it runs: a build without tracing has no recorder, no
/// report renderer and no `--debug`, because none of that code is compiled.
pub const enabled = build_options.trace;

/// The most bytes of one payload kept in the trace: a request body, a response
/// stream, a tool result. A long history or a large file would otherwise make
/// the record grow without bound, and it is the opening of a payload that says
/// which request went wrong.
pub const max_payload_bytes: usize = 128 * 1024;

/// Which agent is speaking and which request of the turn it is making. Set by
/// the agent before every model call and every tool it runs.
pub const Ctx = struct {
    agent: []const u8 = "main",
    iteration: usize = 0,
};

/// What a run is, recorded once, when the trace is opened.
pub const Run = struct {
    session: []const u8 = "",
    workspace: []const u8 = "",
    scratch: []const u8 = "",
    model: []const u8 = "",
    provider: []const u8 = "",
    base_url: []const u8 = "",
    max_tokens: u32 = 0,
    max_iterations: u32 = 0,
};

pub const Call = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// One reply, as the report reads it back.
pub const Reply = struct {
    status: u16 = 200,
    finish_reason: []const u8 = "",
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    tool_calls: []const Call = &.{},
    in_tokens: ?u64 = null,
    out_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    cached_tokens: ?u64 = null,
    reasoning_tokens: ?u64 = null,
    ms: i64 = 0,
    raw: []const u8 = "",
};

/// How a tool call ended, beyond the bytes it returned.
pub const Outcome = struct {
    is_error: bool = false,
    exit_code: ?u8 = null,
    timed_out: bool = false,
    truncated: bool = false,
    ms: i64 = 0,
};

pub const Turn = struct {
    completed: bool,
    tool_calls: usize,
    ms: i64,
};

pub const Trace = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: ?std.Io.File,
    jsonl_path: []u8,
    report_path: []u8,
    started: std.Io.Timestamp,
    seq: std.atomic.Value(usize) = .init(0),
    /// Set once something could not be written. A full disk stays full, and a
    /// debug run must not fail the work it is watching. Atomic because a
    /// sub-agent writes into the same trace as the agent that started it.
    broken: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,

    /// Open a trace in the workspace's debug folder, named after the session
    /// and the moment it started.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        session: ?[]const u8,
    ) !Trace {
        const stamp = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const stem = try std.fmt.allocPrint(allocator, "debug/{s}-{d}", .{ session orelse "run", stamp });
        defer allocator.free(stem);

        const jsonl_name = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{stem});
        defer allocator.free(jsonl_name);
        const jsonl_path = try workspace.filePath(allocator, io, env, jsonl_name);
        errdefer allocator.free(jsonl_path);

        const html_name = try std.fmt.allocPrint(allocator, "{s}.html", .{stem});
        defer allocator.free(html_name);
        const report_path = try workspace.filePath(allocator, io, env, html_name);
        errdefer allocator.free(report_path);

        if (std.fs.path.dirname(jsonl_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        const file = try std.Io.Dir.cwd().createFile(io, jsonl_path, .{ .permissions = .fromMode(0o600) });
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .jsonl_path = jsonl_path,
            .report_path = report_path,
            .started = std.Io.Timestamp.now(io, .awake),
        };
    }

    pub fn deinit(self: *Trace) void {
        self.close();
        self.allocator.free(self.jsonl_path);
        self.allocator.free(self.report_path);
    }

    fn close(self: *Trace) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    /// Close the record and render the report from it. Called once, when the
    /// run is over; the trace file stays where it is either way.
    pub fn finish(self: *Trace) !void {
        self.close();
        try report.writeFile(self.allocator, self.io, self.jsonl_path, self.report_path);
    }

    pub fn run(self: *Trace, info: Run) void {
        self.writeEvent(.{
            .event = "run",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .tool = "zagent",
            .version = "0.1.0",
            .session = info.session,
            .workspace = info.workspace,
            .scratch = info.scratch,
            .model = info.model,
            .provider = info.provider,
            .base_url = info.base_url,
            .max_tokens = info.max_tokens,
            .max_iterations = info.max_iterations,
        });
    }

    /// The task this turn answers, as the user asked it.
    pub fn query(self: *Trace, ctx: Ctx, text: []const u8) void {
        const slice = self.piece(text);
        defer self.freePiece(slice);
        self.writeEvent(.{
            .event = "query",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .agent = ctx.agent,
            .text = slice.text,
        });
    }

    pub fn request(self: *Trace, ctx: Ctx, url: []const u8, model: []const u8, body: []const u8, est_tokens: u64) void {
        const metadata = requestMetadata(self.allocator, body) catch RequestMetadata{};
        const slice = self.piece(body);
        defer self.freePiece(slice);
        self.writeEvent(.{
            .event = "request",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .agent = ctx.agent,
            .iter = ctx.iteration,
            .url = url,
            .model = model,
            .est_tokens = est_tokens,
            .tool_schema_bytes = metadata.tool_schema_bytes,
            .tool_set_sha256 = metadata.tool_set_sha256[0..],
            .input_bytes = metadata.input_bytes,
            .bytes = slice.bytes,
            .body_truncated = slice.truncated,
            .body = slice.text,
        });
    }

    /// What came back: the parsed reply, and the bytes it was parsed from. The
    /// raw stream is where a wrong answer usually is — a delta that never
    /// arrived, an event type the parser skipped, an error sent mid-stream.
    pub fn response(self: *Trace, ctx: Ctx, reply: Reply) void {
        const raw_slice = self.piece(reply.raw);
        defer self.freePiece(raw_slice);
        const content = self.optionalPiece(reply.content);
        defer self.freeOptionalPiece(content);
        const reasoning = self.optionalPiece(reply.reasoning);
        defer self.freeOptionalPiece(reasoning);

        var calls: std.ArrayList(Call) = .empty;
        defer {
            for (calls.items) |call| {
                self.allocator.free(call.id);
                self.allocator.free(call.name);
                self.allocator.free(call.arguments);
            }
            calls.deinit(self.allocator);
        }
        for (reply.tool_calls) |call| {
            const id = self.copyString(call.id) orelse break;
            const name = self.copyString(call.name) orelse {
                self.allocator.free(id);
                break;
            };
            const arguments = self.copyPiece(call.arguments) orelse {
                self.allocator.free(id);
                self.allocator.free(name);
                break;
            };
            calls.append(self.allocator, .{ .id = id, .name = name, .arguments = arguments }) catch {
                self.allocator.free(id);
                self.allocator.free(name);
                self.allocator.free(arguments);
                break;
            };
        }

        self.writeEvent(.{
            .event = "response",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .agent = ctx.agent,
            .iter = ctx.iteration,
            .status = reply.status,
            .finish = reply.finish_reason,
            .ms = reply.ms,
            .in_tokens = reply.in_tokens,
            .out_tokens = reply.out_tokens,
            .total_tokens = reply.total_tokens,
            .cached_tokens = reply.cached_tokens,
            .reasoning_tokens = reply.reasoning_tokens,
            .content = if (content) |slice| slice.text else null,
            .reasoning = if (reasoning) |slice| slice.text else null,
            .tool_calls = calls.items,
            .raw_bytes = raw_slice.bytes,
            .raw_truncated = raw_slice.truncated,
            .raw = raw_slice.text,
        });
    }

    /// A request that never produced a reply, or a reply that could not be
    /// used. What the server sent is kept when there was anything.
    pub fn failure(self: *Trace, ctx: Ctx, message: []const u8, raw: []const u8, ms: i64) void {
        const slice = self.piece(raw);
        defer self.freePiece(slice);
        self.writeEvent(.{
            .event = "failure",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .agent = ctx.agent,
            .iter = ctx.iteration,
            .message = message,
            .ms = ms,
            .raw_bytes = slice.bytes,
            .raw_truncated = slice.truncated,
            .raw = slice.text,
        });
    }

    pub fn toolCall(self: *Trace, ctx: Ctx, name: []const u8, call_id: []const u8, arguments: []const u8) void {
        const slice = self.piece(arguments);
        defer self.freePiece(slice);
        self.writeEvent(.{
            .event = "tool_call",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .agent = ctx.agent,
            .iter = ctx.iteration,
            .name = name,
            .call_id = call_id,
            .args = slice.text,
            .args_bytes = slice.bytes,
            .args_truncated = slice.truncated,
        });
    }

    pub fn toolResult(
        self: *Trace,
        ctx: Ctx,
        name: []const u8,
        call_id: []const u8,
        content: []const u8,
        outcome: Outcome,
    ) void {
        const slice = self.piece(content);
        defer self.freePiece(slice);
        self.writeEvent(.{
            .event = "tool_result",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .agent = ctx.agent,
            .iter = ctx.iteration,
            .name = name,
            .call_id = call_id,
            .ms = outcome.ms,
            .is_error = outcome.is_error,
            .exit_code = outcome.exit_code,
            .timed_out = outcome.timed_out,
            .truncated = outcome.truncated,
            .content = slice.text,
            .bytes = slice.bytes,
            .content_truncated = slice.truncated,
        });
    }

    /// Something the loop did that a request alone does not explain: a
    /// continuation, guidance added mid-turn, a stop, a budget running out.
    pub fn note(self: *Trace, ctx: Ctx, level: []const u8, text: []const u8) void {
        const slice = self.piece(text);
        defer self.freePiece(slice);
        self.writeEvent(.{
            .event = "note",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .agent = ctx.agent,
            .iter = ctx.iteration,
            .level = level,
            .text = slice.text,
        });
    }

    /// How one turn ended: what it cost and whether the model finished.
    pub fn turn(self: *Trace, ctx: Ctx, summary: Turn) void {
        self.writeEvent(.{
            .event = "turn",
            .seq = self.next(),
            .t = self.elapsed(),
            .at = self.wall(),
            .agent = ctx.agent,
            .iter = ctx.iteration,
            .completed = summary.completed,
            .tool_calls = summary.tool_calls,
            .ms = summary.ms,
        });
    }

    // --- writing -----------------------------------------------------------

    fn next(self: *Trace) usize {
        return self.seq.fetchAdd(1, .monotonic);
    }

    fn elapsed(self: *Trace) i64 {
        return self.started.untilNow(self.io, .awake).toMilliseconds();
    }

    fn wall(self: *Trace) i64 {
        return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    }

    fn writeEvent(self: *Trace, value: anytype) void {
        if (self.broken.load(.monotonic)) return;
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        std.json.Stringify.value(value, .{}, &aw.writer) catch {
            self.broken.store(true, .monotonic);
            return;
        };
        aw.writer.writeByte('\n') catch {
            self.broken.store(true, .monotonic);
            return;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const file = self.file orelse return;
        file.writeStreamingAll(self.io, aw.written()) catch {
            self.broken.store(true, .monotonic);
        };
    }

    // --- payloads ----------------------------------------------------------

    const Piece = struct {
        text: []const u8,
        bytes: usize,
        truncated: bool,
        owned: bool = false,
    };

    fn freePiece(self: *Trace, slice: Piece) void {
        if (slice.owned) self.allocator.free(slice.text);
    }

    fn freeOptionalPiece(self: *Trace, slice: ?Piece) void {
        if (slice) |p| self.freePiece(p);
    }

    fn optionalPiece(self: *Trace, text: ?[]const u8) ?Piece {
        const value = text orelse return null;
        return self.piece(value);
    }

    /// One payload, held to `max_payload_bytes` and made valid UTF-8 for the
    /// JSON line it goes into.
    fn piece(self: *Trace, text: []const u8) Piece {
        const cut = cutOnBoundary(text);
        const truncated = cut.len < text.len;
        const fixed = repaired(self.allocator, cut) catch {
            self.broken.store(true, .monotonic);
            return .{ .text = "", .bytes = text.len, .truncated = truncated };
        };
        return .{
            .text = fixed orelse cut,
            .bytes = text.len,
            .truncated = truncated,
            .owned = fixed != null,
        };
    }

    /// An owned copy with invalid UTF-8 repaired, or null when nothing could
    /// be allocated.
    fn copyString(self: *Trace, text: []const u8) ?[]u8 {
        return repaired(self.allocator, text) catch null orelse self.allocator.dupe(u8, text) catch null;
    }

    /// An owned copy of a payload, cut on a character boundary.
    fn copyPiece(self: *Trace, text: []const u8) ?[]u8 {
        const cut = cutOnBoundary(text);
        return repaired(self.allocator, cut) catch null orelse self.allocator.dupe(u8, cut) catch null;
    }
};

/// What a build without tracing compiles its way into. Every call site in the
/// agent and the client stays as it is, and every one of them does nothing: the
/// methods are empty and inline, so nothing of the recorder reaches the binary.
/// Adding a method to `Trace` means adding it here too.
const RequestMetadata = struct {
    tool_schema_bytes: usize = 0,
    tool_set_sha256: [64]u8 = @splat('0'),
    input_bytes: usize = 0,
};

// Only sizes and a digest are added to the existing trace; never schema text.
fn requestMetadata(allocator: std.mem.Allocator, body: []const u8) !RequestMetadata {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    var result: RequestMetadata = .{};
    if (parsed.value != .object) return result;
    const tools = try std.json.Stringify.valueAlloc(allocator, parsed.value.object.get("tools") orelse .null, .{});
    defer allocator.free(tools);
    result.tool_schema_bytes = tools.len;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(tools, &digest, .{});
    result.tool_set_sha256 = std.fmt.bytesToHex(digest, .lower);
    const input = try std.json.Stringify.valueAlloc(allocator, parsed.value.object.get("input") orelse .null, .{});
    defer allocator.free(input);
    result.input_bytes = input.len;
    return result;
}

const Noop = struct {
    /// Kept so the lines that name the files still type-check. A build without
    /// tracing never has a file to name, and never prints one.
    jsonl_path: []const u8 = "",
    report_path: []const u8 = "",

    pub inline fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        session: ?[]const u8,
    ) !Noop {
        _ = .{ allocator, io, env, session };
        return error.TracingDisabled;
    }

    pub inline fn deinit(self: *Noop) void {
        _ = self;
    }

    pub inline fn finish(self: *Noop) !void {
        _ = self;
    }

    pub inline fn run(self: *Noop, info: Run) void {
        _ = .{ self, info };
    }

    pub inline fn query(self: *Noop, ctx: Ctx, text: []const u8) void {
        _ = .{ self, ctx, text };
    }

    pub inline fn request(
        self: *Noop,
        ctx: Ctx,
        url: []const u8,
        model: []const u8,
        body: []const u8,
        est_tokens: u64,
    ) void {
        _ = .{ self, ctx, url, model, body, est_tokens };
    }

    pub inline fn response(self: *Noop, ctx: Ctx, reply: Reply) void {
        _ = .{ self, ctx, reply };
    }

    pub inline fn failure(self: *Noop, ctx: Ctx, message: []const u8, raw: []const u8, ms: i64) void {
        _ = .{ self, ctx, message, raw, ms };
    }

    pub inline fn toolCall(self: *Noop, ctx: Ctx, name: []const u8, call_id: []const u8, arguments: []const u8) void {
        _ = .{ self, ctx, name, call_id, arguments };
    }

    pub inline fn toolResult(
        self: *Noop,
        ctx: Ctx,
        name: []const u8,
        call_id: []const u8,
        content: []const u8,
        outcome: Outcome,
    ) void {
        _ = .{ self, ctx, name, call_id, content, outcome };
    }

    pub inline fn note(self: *Noop, ctx: Ctx, level: []const u8, text: []const u8) void {
        _ = .{ self, ctx, level, text };
    }

    pub inline fn turn(self: *Noop, ctx: Ctx, summary: Turn) void {
        _ = .{ self, ctx, summary };
    }
};

/// The recorder a run holds: the real one when this build keeps a trace, and a
/// shape that does nothing when it does not.
pub const Recorder = if (enabled) Trace else Noop;

/// The opening of a payload, cut where a character ends so the line stays
/// readable. The whole payload is too long to keep: see `max_payload_bytes`.
fn cutOnBoundary(text: []const u8) []const u8 {
    if (text.len <= max_payload_bytes) return text;
    var end = max_payload_bytes;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

/// A copy with every invalid UTF-8 byte replaced, or null when the text is
/// already valid. Tool output is arbitrary bytes — a file read or a command can
/// return anything — and one bad byte must not make the trace invalid JSON.
fn repaired(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]u8 {
    if (std.unicode.utf8ValidateSlice(text)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        if (length > 0 and i + length <= text.len and std.unicode.utf8ValidateSlice(text[i .. i + length])) {
            try out.appendSlice(allocator, text[i .. i + length]);
            i += length;
        } else {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "request metadata fingerprints tools independently of input" {
    const a = std.testing.allocator;
    const first = try requestMetadata(a, "{\"tools\":[{\"name\":\"read\"}],\"input\":\"private\"}");
    const second = try requestMetadata(a, "{\"tools\":[{\"name\":\"read\"}],\"input\":\"different private text\"}");
    const third = try requestMetadata(a, "{\"tools\":[],\"input\":\"private\"}");
    try std.testing.expectEqual(@as(usize, 17), first.tool_schema_bytes);
    try std.testing.expectEqual(@as(usize, 9), first.input_bytes);
    try std.testing.expectEqualSlices(u8, &first.tool_set_sha256, &second.tool_set_sha256);
    try std.testing.expect(!std.mem.eql(u8, &first.tool_set_sha256, &third.tool_set_sha256));
    try std.testing.expect(second.input_bytes > first.input_bytes);
}

test "a payload is cut on a character boundary" {
    const allocator = std.testing.allocator;
    try std.testing.expect(max_payload_bytes > 4);
    // Two bytes of a three-byte character sit right at the limit, so the cut
    // has to walk back over them instead of splitting the character.
    const text = try allocator.alloc(u8, max_payload_bytes + 2);
    defer allocator.free(text);
    @memset(text, 'a');
    text[max_payload_bytes - 2] = 0xe4;
    text[max_payload_bytes - 1] = 0xb8;
    text[max_payload_bytes] = 0xad;
    const cut = cutOnBoundary(text);
    try std.testing.expectEqual(max_payload_bytes - 2, cut.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "invalid UTF-8 is repaired rather than written raw" {
    const allocator = std.testing.allocator;
    const text = "ok \xff\xfe done";
    try std.testing.expect(!std.unicode.utf8ValidateSlice(text));
    const fixed = (try repaired(allocator, text)).?;
    defer allocator.free(fixed);
    try std.testing.expect(std.unicode.utf8ValidateSlice(fixed));
    try std.testing.expectEqualStrings("ok \u{FFFD}\u{FFFD} done", fixed);
    // Valid text is not copied at all.
    try std.testing.expectEqual(@as(?[]u8, null), try repaired(allocator, "already fine"));
}
