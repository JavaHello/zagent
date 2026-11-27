//! Durable conversations. API configuration and credentials are excluded.
const std = @import("std");
const openai = @import("../model/openai.zig");
const plan_mod = @import("plan.zig");
const signals = @import("../util/signals.zig");
const Message = openai.Message;
// Persist the current structure only; historical layouts are not supported.
const StoredMessage = struct {
    role: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
    tool_calls: ?[]openai.ToolCallData,
    tool_call_id: ?[]const u8,
    response_items: ?[]const u8,
    tool_result: ?@import("../tools/mod.zig").ToolResult,
};
/// The plan travels with the conversation: it is state of the session, not a
/// file of its own, so the snapshot carries it next to the messages.
const Snapshot = struct {
    version: u32,
    workspace: []const u8,
    messages: []StoredMessage,
    plan: []plan_mod.Stored,
    child: ?Child = null,
};

/// Child identity is scoped to the parent snapshot's path.
pub const Child = struct {
    parent: []const u8,
    id: []const u8,
    title: []const u8,
    status: enum { running, interrupted, completed, failed } = .running,
};
/// Only the current snapshot schema is accepted.
const schema_version: u32 = 4;

/// What a session holds: its messages and the plan of the work in progress.
pub const Loaded = struct {
    messages: std.ArrayList(Message),
    plan: plan_mod.Plan,
    child: ?Child = null,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| message.deinit(allocator);
        self.messages.deinit(allocator);
        self.plan.deinit();
        if (self.child) |child| {
            allocator.free(child.parent);
            allocator.free(child.id);
            allocator.free(child.title);
        }
        self.* = undefined;
    }
};

pub fn newId(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.Io.random(io, &bytes);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(bytes, .lower)});
}

pub fn validateId(id: []const u8) !void {
    if (id.len != 32) return error.InvalidSessionId;
    for (id) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.InvalidSessionId;
    }
}

test "child pending tools become unknown outcomes and running becomes interrupted" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "child.json" });
    defer a.free(path);
    var plan = plan_mod.Plan.init(a);
    defer plan.deinit();
    var calls = [_]openai.ToolCallData{.{ .id = "unknown", .name = "bash", .arguments = "{}" }};
    var messages = [_]Message{.{ .role = "assistant", .content = null, .reasoning_content = "thinking", .tool_calls = &calls, .tool_call_id = null }};
    try saveChild(io, a, path, &messages, &plan, .{ .parent = "parent", .id = "s7", .title = "child title" });
    var loaded = try load(io, a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqualStrings("parent", loaded.child.?.parent);
    try std.testing.expectEqualStrings("s7", loaded.child.?.id);
    try std.testing.expectEqualStrings("child title", loaded.child.?.title);
    try std.testing.expect(loaded.child.?.status == .interrupted);
    try std.testing.expectEqual(@as(usize, 2), loaded.messages.items.len);
    try std.testing.expectEqualStrings("unknown", loaded.messages.items[1].tool_call_id.?);
    try std.testing.expect(loaded.messages.items[1].tool_result.?.is_error);
    try std.testing.expect(std.mem.indexOf(u8, loaded.messages.items[1].tool_result.?.output, "NOT replayed") != null);
    try saveChild(io, a, path, loaded.messages.items, &plan, .{ .parent = "parent", .id = "s7", .title = "child title", .status = .completed });
    var again = try load(io, a, path);
    defer again.deinit(a);
    try std.testing.expect(again.child.?.status == .completed);
    try std.testing.expectEqual(@as(usize, 2), again.messages.items.len);
}

test "session IDs are unique and cannot escape the session directory" {
    const a = std.testing.allocator;
    const first = try newId(std.testing.io, a);
    defer a.free(first);
    const second = try newId(std.testing.io, a);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try validateId(first);
    try std.testing.expectError(error.InvalidSessionId, validateId("../session"));
    try std.testing.expectError(error.InvalidSessionId, validateId("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
}

pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, messages: []Message, plan: *const plan_mod.Plan) !void {
    return saveChild(io, allocator, path, messages, plan, null);
}

pub fn saveChild(io: std.Io, allocator: std.mem.Allocator, path: []const u8, messages: []Message, plan: *const plan_mod.Plan, child: ?Child) !void {
    const cwd = std.Io.Dir.cwd();
    const workspace = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    const steps = try plan.stored(allocator);
    defer allocator.free(steps);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    if (std.fs.path.dirname(path)) |parent| try cwd.createDirPath(io, parent);
    const file = try cwd.createFile(io, temporary, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer cwd.deleteFile(io, temporary) catch {};
    // Written straight to the file: a checkpoint is as large as the whole
    // conversation, and holding a serialized copy of it as well would double
    // that peak on every save.
    var buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    try std.json.Stringify.value(.{
        .version = schema_version,
        .workspace = workspace,
        .messages = messages,
        .plan = steps,
        .child = child,
    }, .{}, &file_writer.interface);
    try file_writer.interface.flush();
    try cwd.rename(temporary, cwd, path, io);
}

/// Returns owned messages with canonical static role strings, ready for Agent,
/// together with the plan the session carries.
/// A missing session is a new conversation. A corrupt/wrong-workspace one fails.
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Loaded {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .messages = .empty, .plan = plan_mod.Plan.init(allocator) },
        else => return err,
    };
    defer allocator.free(data);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, data, .{});
    defer parsed.deinit();
    if (parsed.value.version != schema_version) return error.UnsupportedSessionVersion;
    const workspace = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    if (!std.mem.eql(u8, workspace, parsed.value.workspace)) return error.SessionWorkspaceMismatch;
    var messages: std.ArrayList(Message) = .empty;
    errdefer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit(allocator);
    }
    // Only checkpoint complete tool batches: unmatched calls indicate corrupt input.
    var pending: ?[]openai.ToolCallData = null;
    var next_tool: usize = 0;
    for (parsed.value.messages) |source| {
        var message: Message = .{ .role = undefined, .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = null };
        errdefer message.deinit(allocator);
        if (source.tool_result) |result| {
            const output = try allocator.dupe(u8, result.output);
            message.tool_result = result;
            message.tool_result.?.output = output;
            message.tool_result.?.termination = if (result.termination) |written| signals.canonical(written) else null;
        }
        message.role = if (std.mem.eql(u8, source.role, "user")) "user" else if (std.mem.eql(u8, source.role, "assistant")) "assistant" else if (std.mem.eql(u8, source.role, "tool")) "tool" else return error.InvalidSessionRole;
        if (std.mem.eql(u8, message.role, "tool")) {
            if (source.content != null or source.tool_result == null) return error.InvalidSessionToolResult;
        } else if (source.tool_result != null) return error.InvalidSessionToolResult;
        if (pending) |calls| {
            if (!std.mem.eql(u8, message.role, "tool") or source.tool_call_id == null or !std.mem.eql(u8, calls[next_tool].id, source.tool_call_id.?)) return error.InvalidSessionToolSequence;
            next_tool += 1;
            if (next_tool == calls.len) pending = null;
        } else if (std.mem.eql(u8, message.role, "tool")) return error.InvalidSessionToolSequence;
        if (source.content) |v| message.content = try allocator.dupe(u8, v);
        if (source.reasoning_content) |v| message.reasoning_content = try allocator.dupe(u8, v);
        if (source.response_items) |v| message.response_items = try allocator.dupe(u8, v);
        if (source.tool_call_id) |v| message.tool_call_id = try allocator.dupe(u8, v);
        if (source.tool_calls) |calls| {
            if (!std.mem.eql(u8, message.role, "assistant") or calls.len == 0) return error.InvalidSessionToolSequence;
            const owned = try allocator.alloc(openai.ToolCallData, calls.len);
            var copied: usize = 0;
            errdefer {
                for (owned[0..copied]) |call| call.deinit(allocator);
                allocator.free(owned);
            }
            for (calls, 0..) |call, i| {
                const id = try allocator.dupe(u8, call.id);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, call.name);
                errdefer allocator.free(name);
                owned[i] = .{ .id = id, .name = name, .arguments = try allocator.dupe(u8, call.arguments) };
                copied += 1;
            }
            message.tool_calls = owned;
            pending = calls;
            next_tool = 0;
        }
        try messages.append(allocator, message);
    }
    if (pending) |calls| {
        if (parsed.value.child == null) return error.InvalidSessionToolSequence;
        // Never replay an unacknowledged side effect. Close the protocol with
        // an explicit unknown outcome; the model must inspect before retrying.
        for (calls[next_tool..]) |call| {
            const content = try allocator.dupe(u8, "Interrupted before confirmation. Outcome unknown; inspect state before retrying. This tool was NOT replayed.");
            errdefer allocator.free(content);
            const id = try allocator.dupe(u8, call.id);
            errdefer allocator.free(id);
            try messages.append(allocator, .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = id, .tool_result = .{ .output = content, .is_error = true } });
        }
    }
    const plan = restored: {
        var value = plan_mod.Plan.init(allocator);
        errdefer value.deinit();
        try value.restore(parsed.value.plan);
        break :restored value;
    };
    var child = parsed.value.child;
    if (child) |*value| {
        const parent = try allocator.dupe(u8, value.parent);
        errdefer allocator.free(parent);
        const id = try allocator.dupe(u8, value.id);
        errdefer allocator.free(id);
        value.title = try allocator.dupe(u8, value.title);
        value.parent = parent;
        value.id = id;
        if (value.status == .running) value.status = .interrupted;
    }
    return .{ .messages = messages, .plan = plan, .child = child };
}

/// The ID of a resumable snapshot, taken from its file name: exactly
/// `<32 lowercase hex>.json`. Child snapshots (`<id>.json.s1.json`) and the
/// temporary file a save renames into place are not sessions of their own.
pub fn idFromFileName(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, ".json")) return null;
    const id = name[0 .. name.len - ".json".len];
    validateId(id) catch return null;
    return id;
}

/// How much of a conversation's first question a title keeps. A menu that
/// scrolls through a paragraph per row is not a list a person reads.
pub const max_title_codepoints: usize = 60;

/// One saved conversation, as the session list shows it. `id` and `title` are
/// owned by whoever holds the summary.
pub const Summary = struct {
    id: []u8,
    /// When the snapshot was last written, in seconds since the epoch.
    modified: i64,
    messages: usize,
    /// The first thing the user asked, on one line; empty when no turn was
    /// completed before the session was left.
    title: []u8,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        self.* = undefined;
    }
};

/// The sessions of one workspace, newest first.
pub const Listing = struct {
    items: []Summary,
    /// Files among those read that are named like a session but could not be
    /// read as one of the current schema. They are not offered, because
    /// resuming them fails.
    skipped: usize,

    pub fn deinit(self: *Listing, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        if (self.items.len > 0) allocator.free(self.items);
        self.* = undefined;
    }
};

/// Read the snapshots in `directory` as a session list, newest first. A
/// missing directory is an empty listing: a workspace whose first session is
/// starting has nothing saved yet. `limit` bounds how many summaries are
/// parsed, not how many files are seen.
pub fn list(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, limit: usize) !Listing {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .items = &.{}, .skipped = 0 },
        else => return err,
    };
    defer dir.close(io);

    const Candidate = struct {
        name: []u8,
        /// Kept at full resolution: two sessions saved in the same second are
        /// still "newest last" to the person who saved them.
        modified: std.Io.Timestamp,
    };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |candidate| allocator.free(candidate.name);
        candidates.deinit(allocator);
    }
    var skipped: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        _ = idFromFileName(entry.name) orelse continue;
        const stat = dir.statFile(io, entry.name, .{}) catch {
            skipped += 1;
            continue;
        };
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try candidates.append(allocator, .{ .name = name, .modified = stat.mtime });
    }
    // Only the newest few are read: their stat is what the order is made of,
    // and parsing every conversation in the folder would be work nobody sees.
    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            if (a.modified.nanoseconds != b.modified.nanoseconds) return a.modified.nanoseconds > b.modified.nanoseconds;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    const keep = @min(limit, candidates.items.len);
    var items: std.ArrayList(Summary) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    try items.ensureTotalCapacity(allocator, keep);
    for (candidates.items[0..keep]) |candidate| {
        const data = dir.readFileAlloc(io, candidate.name, allocator, .limited(64 * 1024 * 1024)) catch {
            skipped += 1;
            continue;
        };
        defer allocator.free(data);
        const summary = summarize(allocator, candidate.name[0..32], candidate.modified.toSeconds(), data) catch {
            skipped += 1;
            continue;
        };
        items.appendAssumeCapacity(summary);
    }
    return .{ .items = try items.toOwnedSlice(allocator), .skipped = skipped };
}

/// The snapshot as a row of the list: the schema it was written with, how many
/// messages it holds, and the first thing the user asked.
///
/// Unknown fields are ignored, so the list reads what it shows without adopting
/// the whole schema, and the messages themselves are stepped over rather than
/// parsed. A snapshot is as large as its conversation, and the list shows a
/// title and a count; reading every message's text to find those is what made
/// opening a session list slow.
fn summarize(allocator: std.mem.Allocator, id: []const u8, modified: i64, data: []const u8) !Summary {
    // The strings the scan does read are kept in one arena and freed together,
    // whatever ends the scan: the file's own bytes stay borrowed from `data`.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const scan = arena_state.allocator();

    var scanner = std.json.Scanner.initCompleteInput(allocator, data);
    defer scanner.deinit();

    var version: ?u32 = null;
    var messages: ?usize = null;
    var asked: ?[]const u8 = null;

    try expectToken(&scanner, .object_begin);
    while (true) {
        const key = try fieldName(&scanner, scan);
        if (key == null) break;
        if (std.mem.eql(u8, key.?, "version")) {
            if (try scanner.peekNextTokenType() != .number) return error.UnsupportedSessionVersion;
            const written = switch (try scanner.next()) {
                .number => |text| text,
                else => return error.UnsupportedSessionVersion,
            };
            version = std.fmt.parseInt(u32, written, 10) catch return error.UnsupportedSessionVersion;
        } else if (std.mem.eql(u8, key.?, "messages")) {
            var count: usize = 0;
            try readMessages(&scanner, scan, &count, &asked);
            messages = count;
        } else try scanner.skipValue();
    }
    // Only the current schema can be resumed, so only it is offered.
    if (version == null or version.? != schema_version) return error.UnsupportedSessionVersion;
    if (messages == null) return error.InvalidSessionSnapshot;
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    return .{
        .id = owned_id,
        .modified = modified,
        .messages = messages.?,
        .title = try titleOf(allocator, asked),
    };
}

/// The next token, which must open the structure the caller expects.
fn expectToken(scanner: *std.json.Scanner, comptime wanted: std.json.TokenType) !void {
    if (try scanner.peekNextTokenType() != wanted) return error.InvalidSessionSnapshot;
    _ = try scanner.next();
}

/// The next key of an object, or null at its end. A key is only ever used for
/// the length of one field, so it is copied into `scan`, which outlives the
/// scan's own buffers.
fn fieldName(scanner: *std.json.Scanner, scan: std.mem.Allocator) !?[]const u8 {
    switch (try scanner.peekNextTokenType()) {
        .object_end => {
            _ = try scanner.next();
            return null;
        },
        .string => return try nextString(scanner, scan),
        else => return error.InvalidSessionSnapshot,
    }
}

/// The next string, owned by `scan`. A string with escapes in it is unescaped
/// into memory the caller keeps; one without is borrowed from the input.
fn nextString(scanner: *std.json.Scanner, scan: std.mem.Allocator) ![]const u8 {
    if (try scanner.peekNextTokenType() != .string) return error.InvalidSessionSnapshot;
    const token = try scanner.nextAlloc(scan, .alloc_if_needed);
    return switch (token) {
        .string => |text| text,
        .allocated_string => |text| text,
        else => error.InvalidSessionSnapshot,
    };
}

/// Count the messages and keep the first one the user asked, stepping over
/// every other value the conversation holds.
fn readMessages(scanner: *std.json.Scanner, scan: std.mem.Allocator, count: *usize, asked: *?[]const u8) !void {
    try expectToken(scanner, .array_begin);
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .array_end => {
                _ = try scanner.next();
                return;
            },
            // An element that is not an object is counted with the rest and
            // has nothing a list can show.
            else => {},
        }
        count.* += 1;
        if (try scanner.peekNextTokenType() != .object_begin) {
            try scanner.skipValue();
            continue;
        }
        _ = try scanner.next();
        var role: ?[]const u8 = null;
        var content: ?[]const u8 = null;
        // Once the question is found there is nothing else to read in any
        // message: the rest of the conversation is stepped over as bytes.
        const looking = asked.* == null;
        while (true) {
            const key = try fieldName(scanner, scan) orelse break;
            if (looking and std.mem.eql(u8, key, "role")) {
                role = if (try scanner.peekNextTokenType() == .string) try nextString(scanner, scan) else null;
                if (role == null) try scanner.skipValue();
            } else if (looking and std.mem.eql(u8, key, "content")) {
                content = if (try scanner.peekNextTokenType() == .string) try nextString(scanner, scan) else null;
                if (content == null) try scanner.skipValue();
            } else try scanner.skipValue();
        }
        // The first question is what a list of conversations can honestly say
        // about one. A question that says nothing — only blanks — is passed
        // over for the next one, the way a title that came out empty was.
        if (asked.* != null) continue;
        if (role == null or content == null) continue;
        if (!std.mem.eql(u8, role.?, "user")) continue;
        if (!hasWords(content.?)) continue;
        asked.* = content.?;
    }
}

/// Whether `text` holds anything a title could be made of: the blanks a line
/// drops, and no more, is what `oneLine` has nothing to say about.
fn hasWords(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        const scalar: u21 = std.unicode.utf8Decode(text[i..end]) catch 0xFFFD;
        i = end;
        const blank = scalar == ' ' or scalar == 0xa0 or scalar == 0x3000 or scalar < 0x20 or scalar == 0x7f;
        if (!blank) return true;
    }
    return false;
}

/// The first question the user asked, which is what a list of conversations can
/// honestly say about one. Owned by the caller.
fn titleOf(allocator: std.mem.Allocator, asked: ?[]const u8) ![]u8 {
    const content = asked orelse return allocator.alloc(u8, 0);
    return oneLine(allocator, content);
}

/// `text` on one line, sanitised, with runs of whitespace collapsed and cut to
/// `max_title_codepoints` so that it fits a menu row.
fn oneLine(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try @import("../util/terminal/sanitize.zig").writeOnOneLine(&aw.writer, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending_space = false;
    var points: usize = 0;
    var cut = false;
    const bytes = aw.written();
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        const end = @min(i + seq_len, bytes.len);
        const chunk = bytes[i..end];
        i = end;
        const scalar: u21 = std.unicode.utf8Decode(chunk) catch 0xFFFD;
        const blank = scalar == ' ' or scalar == 0xa0 or scalar == 0x3000 or scalar < 0x20 or scalar == 0x7f;
        if (blank) {
            pending_space = out.items.len > 0;
            continue;
        }
        if (pending_space) {
            if (points == max_title_codepoints) {
                cut = true;
                break;
            }
            try out.append(allocator, ' ');
            points += 1;
            pending_space = false;
        }
        if (points == max_title_codepoints) {
            cut = true;
            break;
        }
        try out.appendSlice(allocator, chunk);
        points += 1;
    }
    if (cut) try out.appendSlice(allocator, "…");
    return out.toOwnedSlice(allocator);
}

/// How long ago a snapshot was written, in the shortest words that say it.
/// Owned by the caller.
pub fn ageLabel(allocator: std.mem.Allocator, now: i64, stamp: i64) ![]u8 {
    const seconds = @max(now - stamp, 0);
    if (seconds < 60) return allocator.dupe(u8, "just now");
    if (seconds < 3600) return std.fmt.allocPrint(allocator, "{d}m ago", .{@divTrunc(seconds, 60)});
    if (seconds < 86400) return std.fmt.allocPrint(allocator, "{d}h ago", .{@divTrunc(seconds, 3600)});
    if (seconds < 30 * 86400) return std.fmt.allocPrint(allocator, "{d}d ago", .{@divTrunc(seconds, 86400)});
    if (seconds < 365 * 86400) return std.fmt.allocPrint(allocator, "{d}mo ago", .{@divTrunc(seconds, 30 * 86400)});
    return std.fmt.allocPrint(allocator, "{d}y ago", .{@divTrunc(seconds, 365 * 86400)});
}

test "session roundtrip retains tool calls, reasoning and the plan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "session.json" });
    defer allocator.free(path);
    var plan = plan_mod.Plan.init(allocator);
    defer plan.deinit();
    try plan.setSteps(&.{
        .{ .title = "read the code", .status = .completed },
        .{ .title = "write the module", .status = .in_progress, .note = "half way" },
    });
    var calls = [_]openai.ToolCallData{
        .{ .id = "1", .name = "shell", .arguments = "{}" },
        .{ .id = "2", .name = "bash", .arguments = "{}" },
    };
    var messages = [_]Message{
        .{ .role = "assistant", .content = null, .reasoning_content = "plan", .tool_calls = &calls, .tool_call_id = null, .response_items = "[{\"type\":\"reasoning\",\"id\":\"rs1\",\"summary\":[],\"encrypted_content\":\"opaque-token\"},{\"type\":\"function_call\",\"call_id\":\"1\",\"name\":\"shell\",\"arguments\":\"{}\"}]" },
        .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "1", .tool_result = .{ .output = "done", .is_error = true, .exit_code = 7, .timed_out = true, .ccr_id = "abcdef012345".* } },
        .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "2", .tool_result = .{ .output = "", .is_error = true, .termination = "SIGTERM" } },
    };
    try save(io, allocator, path, &messages, &plan);
    var loaded = try load(io, allocator, path);
    defer loaded.deinit(allocator);
    try std.testing.expect(loaded.messages.items[1].content == null);
    try std.testing.expectEqual(@as(usize, 3), loaded.messages.items.len);
    try std.testing.expectEqualStrings("plan", loaded.messages.items[0].reasoning_content.?);
    try std.testing.expectEqualStrings(messages[0].response_items.?, loaded.messages.items[0].response_items.?);
    try std.testing.expectEqualStrings("shell", loaded.messages.items[0].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("done", loaded.messages.items[1].tool_result.?.output);
    try std.testing.expectEqualDeep(messages[1].tool_result, loaded.messages.items[1].tool_result);
    // The signal that ended a call is part of the status, so a restored
    // conversation still shows how it ended.
    try std.testing.expectEqualDeep(messages[2].tool_result, loaded.messages.items[2].tool_result);
    try std.testing.expectEqual(@as(usize, 2), loaded.plan.steps.items.len);
    try std.testing.expectEqual(plan_mod.Status.in_progress, loaded.plan.steps.items[1].status);
    try std.testing.expectEqualStrings("half way", loaded.plan.steps.items[1].note.?);
    try save(io, allocator, path, messages[0..1], &plan);
    try std.testing.expectError(error.InvalidSessionToolSequence, load(io, allocator, path));
}

test "snapshots reject removed fields and require the current schema" {
    const a = std.testing.allocator;
    // A status no longer carries `truncated`: an old one is refused rather
    // than read as a status that never said where the rest of its result went.
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(
        @import("../tools/mod.zig").ToolResult,
        a,
        "{\"is_error\":false,\"exit_code\":null,\"timed_out\":false,\"truncated\":true}",
        .{},
    ));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(StoredMessage, a, "{\"role\":\"tool\",\"content\":\"old\",\"reasoning_content\":null,\"tool_calls\":null,\"tool_call_id\":\"1\"}", .{}));
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Snapshot, a, "{\"version\":3,\"workspace\":\"\",\"messages\":[],\"plan\":[],\"scratch_dirs\":[]}", .{}));
    // Replaced plan enum values are not migrated or silently discarded.
    inline for (.{ "active", "done" }) |status| {
        try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Snapshot, a, "{\"version\":3,\"workspace\":\"\",\"messages\":[],\"plan\":[{\"title\":\"old step\",\"status\":\"" ++ status ++ "\"}]}", .{}));
    }
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Snapshot, a, "{\"workspace\":\"\",\"messages\":[],\"plan\":[]}", .{}));
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Snapshot, a, "{\"version\":3,\"workspace\":\"\",\"messages\":[]}", .{}));
}

test "a missing session starts empty but malformed JSON is rejected" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "session.json" });
    defer a.free(path);
    var loaded = try load(io, a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), loaded.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.plan.steps.items.len);
    try tmp.dir.writeFile(io, .{ .sub_path = "session.json", .data = "{" });
    try std.testing.expectError(error.UnexpectedEndOfInput, load(io, a, path));
}

test "sessions reject incompatible versions and another workspace" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "session.json" });
    defer a.free(path);
    const cases = [_]struct { data: []const u8, expected: anyerror }{
        .{ .data = "{\"version\":2,\"workspace\":\"\",\"messages\":[],\"plan\":[]}", .expected = error.UnsupportedSessionVersion },
        // A snapshot from before the plan was part of the session is refused,
        // not resumed without the state it never had.
        .{ .data = "{\"version\":1,\"workspace\":\"\",\"messages\":[]}", .expected = error.MissingField },
        .{ .data = "{\"version\":4,\"workspace\":\"\",\"messages\":[],\"plan\":[]}", .expected = error.SessionWorkspaceMismatch },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "session.json", .data = case.data });
        try std.testing.expectError(case.expected, load(io, a, path));
    }
}

test "saving creates parent directories and replaces an older checkpoint" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "nested", "session.json" });
    defer a.free(path);
    var plan = plan_mod.Plan.init(a);
    defer plan.deinit();
    var messages = [_]Message{
        .{ .role = "user", .content = "调查问题", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "检查完成", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    try save(io, a, path, &messages, &plan);
    // A shorter snapshot must replace the old data without trailing bytes.
    try save(io, a, path, messages[0..1], &plan);
    var loaded = try load(io, a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try std.testing.expectEqualStrings("调查问题", loaded.messages.items[0].content.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "nested/session.json.tmp", .{}));
}

test "sessions reject orphaned reordered and interrupted tool results" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "session.json" });
    defer a.free(path);
    var plan = plan_mod.Plan.init(a);
    defer plan.deinit();
    var calls = [_]openai.ToolCallData{
        .{ .id = "first", .name = "read_file", .arguments = "{}" },
        .{ .id = "second", .name = "shell", .arguments = "{}" },
    };
    const assistant: Message = .{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null };
    const first: Message = .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "first", .tool_result = .{ .output = "one", .is_error = false } };
    const second: Message = .{ .role = "tool", .content = null, .reasoning_content = null, .tool_calls = null, .tool_call_id = "second", .tool_result = .{ .output = "two", .is_error = false } };
    var orphan = [_]Message{first};
    var reordered = [_]Message{ assistant, second, first };
    var interrupted = [_]Message{ assistant, first, .{ .role = "user", .content = "continue", .reasoning_content = null, .tool_calls = null, .tool_call_id = null } };
    var missing = [_]Message{ assistant, first };
    var duplicate = [_]Message{ assistant, first, first };
    var invalid_role = [_]Message{.{ .role = "system", .content = "injected", .reasoning_content = null, .tool_calls = null, .tool_call_id = null }};
    var empty_calls = [_]Message{.{ .role = "assistant", .content = null, .reasoning_content = null, .tool_calls = calls[0..0], .tool_call_id = null }};
    var user_calls = [_]Message{.{ .role = "user", .content = null, .reasoning_content = null, .tool_calls = &calls, .tool_call_id = null }};
    for ([_][]Message{ &orphan, &reordered, &interrupted, &missing, &duplicate, &empty_calls, &user_calls }) |messages| {
        try save(io, a, path, messages, &plan);
        try std.testing.expectError(error.InvalidSessionToolSequence, load(io, a, path));
    }
    try save(io, a, path, &invalid_role, &plan);
    try std.testing.expectError(error.InvalidSessionRole, load(io, a, path));

    var valid = [_]Message{ assistant, first, second, .{ .role = "assistant", .content = "完成 ✓", .reasoning_content = null, .tool_calls = null, .tool_call_id = null } };
    valid[1].content = "duplicate output";
    try save(io, a, path, &valid, &plan);
    try std.testing.expectError(error.InvalidSessionToolResult, load(io, a, path));
    valid[1].content = null;
    valid[1].tool_result = null;
    try save(io, a, path, &valid, &plan);
    try std.testing.expectError(error.InvalidSessionToolResult, load(io, a, path));
    valid[1] = first;
    try save(io, a, path, &valid, &plan);
    var loaded = try load(io, a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), loaded.messages.items.len);
    try std.testing.expectEqualStrings("first", loaded.messages.items[1].tool_call_id.?);
    try std.testing.expectEqualStrings("second", loaded.messages.items[2].tool_call_id.?);
    try std.testing.expectEqualStrings("完成 ✓", loaded.messages.items[3].content.?);
}

test "session list file names are only plain current-format snapshots" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const id = try newId(io, a);
    defer a.free(id);

    const name = try std.fmt.allocPrint(a, "{s}.json", .{id});
    defer a.free(name);
    try std.testing.expectEqualStrings(id, idFromFileName(name).?);

    const child = try std.fmt.allocPrint(a, "{s}.json.s1.json", .{id});
    defer a.free(child);
    try std.testing.expect(idFromFileName(child) == null);

    const temporary = try std.fmt.allocPrint(a, "{s}.json.tmp", .{id});
    defer a.free(temporary);
    try std.testing.expect(idFromFileName(temporary) == null);

    try std.testing.expect(idFromFileName("short.json") == null);
    try std.testing.expect(idFromFileName("notes.txt") == null);

    var upper_buf: [32]u8 = undefined;
    const upper = try std.fmt.allocPrint(a, "{s}.json", .{std.ascii.upperString(&upper_buf, id)});
    defer a.free(upper);
    try std.testing.expect(idFromFileName(upper) == null);
}

test "the session list reads newest first and skips what cannot be resumed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sessions");
    var sdir = try tmp.dir.openDir(io, "sessions", .{});
    defer sdir.close(io);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const sessions = try std.fs.path.join(a, &.{ root, "sessions" });
    defer a.free(sessions);

    var plan = plan_mod.Plan.init(a);
    defer plan.deinit();
    try plan.setSteps(&.{
        .{ .title = "read the code", .status = .completed },
        .{ .title = "write the module", .status = .pending },
    });

    const stamp: i64 = 1_700_000_000;
    const newest = try newId(io, a);
    defer a.free(newest);
    var newest_messages = [_]Message{.{ .role = "user", .content = "  Fix\n\tthe   build  ", .reasoning_content = null, .tool_calls = null, .tool_call_id = null }};
    const newest_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ sessions, newest });
    defer a.free(newest_path);
    try save(io, a, newest_path, &newest_messages, &plan);

    const middle = try newId(io, a);
    defer a.free(middle);
    var middle_messages = [_]Message{
        .{ .role = "user", .content = "second question", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        .{ .role = "assistant", .content = "answer", .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
    };
    const middle_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ sessions, middle });
    defer a.free(middle_path);
    try save(io, a, middle_path, &middle_messages, &plan);

    const empty = try newId(io, a);
    defer a.free(empty);
    const empty_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ sessions, empty });
    defer a.free(empty_path);
    try save(io, a, empty_path, &.{}, &plan);

    // Older schema, corrupt snapshot and a child snapshot: none of them is a
    // session this build can offer.
    const stale = try newId(io, a);
    defer a.free(stale);
    const stale_name = try std.fmt.allocPrint(a, "{s}.json", .{stale});
    defer a.free(stale_name);
    try sdir.writeFile(io, .{ .sub_path = stale_name, .data = "{\"version\":3,\"workspace\":\"/w\",\"messages\":[],\"plan\":[]}" });

    const broken = try newId(io, a);
    defer a.free(broken);
    const broken_name = try std.fmt.allocPrint(a, "{s}.json", .{broken});
    defer a.free(broken_name);
    try sdir.writeFile(io, .{ .sub_path = broken_name, .data = "{" });

    const child_name = try std.fmt.allocPrint(a, "{s}.json.s1.json", .{newest});
    defer a.free(child_name);
    try sdir.writeFile(io, .{ .sub_path = child_name, .data = "{\"version\":4,\"workspace\":\"/w\",\"messages\":[],\"plan\":[],\"child\":null}" });

    // Distinct write times, newest first.
    const newest_name = try std.fmt.allocPrint(a, "{s}.json", .{newest});
    defer a.free(newest_name);
    const middle_name = try std.fmt.allocPrint(a, "{s}.json", .{middle});
    defer a.free(middle_name);
    const empty_name = try std.fmt.allocPrint(a, "{s}.json", .{empty});
    defer a.free(empty_name);
    try sdir.setTimestamps(io, newest_name, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds((stamp + 3) * std.time.ns_per_s) } });
    try sdir.setTimestamps(io, middle_name, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds((stamp + 2) * std.time.ns_per_s) } });
    try sdir.setTimestamps(io, empty_name, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds((stamp + 1) * std.time.ns_per_s) } });
    // The unreadable files are older still, so a one-item listing reads the
    // newest session rather than one of them.
    try sdir.setTimestamps(io, stale_name, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds((stamp - 10) * std.time.ns_per_s) } });
    try sdir.setTimestamps(io, broken_name, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds((stamp - 20) * std.time.ns_per_s) } });

    var listing = try list(io, a, sessions, 10);
    defer listing.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), listing.skipped);
    try std.testing.expectEqual(@as(usize, 3), listing.items.len);
    try std.testing.expectEqualStrings(newest, listing.items[0].id);
    try std.testing.expectEqualStrings("Fix the build", listing.items[0].title);
    try std.testing.expectEqual(@as(usize, 1), listing.items[0].messages);
    try std.testing.expectEqual(stamp + 3, listing.items[0].modified);
    try std.testing.expectEqualStrings(middle, listing.items[1].id);
    try std.testing.expectEqualStrings("second question", listing.items[1].title);
    try std.testing.expectEqual(@as(usize, 2), listing.items[1].messages);
    try std.testing.expectEqualStrings(empty, listing.items[2].id);
    try std.testing.expectEqualStrings("", listing.items[2].title);

    // Only the newest file is read when the caller asks for one, so a broken
    // older snapshot is not counted among the skips.
    var limited = try list(io, a, sessions, 1);
    defer limited.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), limited.items.len);
    try std.testing.expectEqual(@as(usize, 0), limited.skipped);

    // A workspace with no saved session yet has an empty listing, not an error.
    const absent = try std.fs.path.join(a, &.{ root, "absent" });
    defer a.free(absent);
    var none = try list(io, a, absent, 10);
    defer none.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
    try std.testing.expectEqual(@as(usize, 0), none.skipped);
}

test "a listing counts the messages it does not read" {
    const a = std.testing.allocator;
    // A checkpoint holds calls, results and reasoning far larger than anything
    // a list shows; they are stepped over, and only the count and the first
    // question come out of it.
    const data =
        "{\"version\":4,\"workspace\":\"/w\",\"messages\":[" ++
        "{\"role\":\"user\",\"content\":null}," ++
        "{\"role\":\"user\",\"content\":\"line\\nnext\"}," ++
        "{\"role\":\"assistant\",\"content\":\"answer\",\"reasoning_content\":\"why\"," ++
        "\"tool_calls\":[{\"id\":\"1\",\"name\":\"bash\",\"arguments\":\"{}\"}]}," ++
        "{\"role\":\"tool\",\"tool_call_id\":\"1\"," ++
        "\"tool_result\":{\"output\":\"ok\",\"is_error\":false,\"exit_code\":0}}" ++
        "],\"plan\":[{\"title\":\"step\",\"status\":\"pending\"}],\"child\":null}";
    const summary = try summarize(a, "0123456789abcdef0123456789abcdef", 7, data);
    defer a.free(summary.id);
    defer a.free(summary.title);
    try std.testing.expectEqual(@as(usize, 4), summary.messages);
    try std.testing.expectEqualStrings("line next", summary.title);

    // A question that says nothing is passed over for the next one, and a
    // snapshot of another schema is not offered at all.
    const latter =
        "{\"version\":4,\"workspace\":\"/w\"," ++
        "\"messages\":[{\"role\":\"user\",\"content\":\"   \"},{\"role\":\"user\",\"content\":\"real one\"}]," ++
        "\"plan\":[]}";
    const found = try summarize(a, "0123456789abcdef0123456789abcdef", 7, latter);
    defer a.free(found.id);
    defer a.free(found.title);
    try std.testing.expectEqualStrings("real one", found.title);
    try std.testing.expectEqual(@as(usize, 2), found.messages);
    try std.testing.expectError(error.UnsupportedSessionVersion, summarize(
        a,
        "0123456789abcdef0123456789abcdef",
        7,
        "{\"version\":3,\"messages\":[]}",
    ));
    try std.testing.expectError(error.InvalidSessionSnapshot, summarize(
        a,
        "0123456789abcdef0123456789abcdef",
        7,
        "{\"version\":4}",
    ));
}

test "a session title is one short line of plain text" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sessions");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const sessions = try std.fs.path.join(a, &.{ root, "sessions" });
    defer a.free(sessions);

    const id = try newId(io, a);
    defer a.free(id);
    var filler: [100]u8 = undefined;
    @memset(&filler, 'x');
    const content = try std.mem.concat(a, u8, &.{ "hello\n\x1b[31mworld\x1b[0m ", &filler });
    defer a.free(content);
    var messages = [_]Message{.{ .role = "user", .content = content, .reasoning_content = null, .tool_calls = null, .tool_call_id = null }};
    var plan = plan_mod.Plan.init(a);
    defer plan.deinit();
    const path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ sessions, id });
    defer a.free(path);
    try save(io, a, path, &messages, &plan);

    var listing = try list(io, a, sessions, 10);
    defer listing.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), listing.items.len);
    const title = listing.items[0].title;
    try std.testing.expect(std.mem.startsWith(u8, title, "hello world x"));
    try std.testing.expect(std.mem.endsWith(u8, title, "…"));
    try std.testing.expect(std.mem.indexOfScalar(u8, title, 0x1b) == null);
    try std.testing.expectEqual(max_title_codepoints + 1, try std.unicode.utf8CountCodepoints(title));
}

test "ages read as the shortest span that says them" {
    const a = std.testing.allocator;
    const now: i64 = 1_700_000_000;
    const cases = [_]struct { ago: i64, expected: []const u8 }{
        .{ .ago = 0, .expected = "just now" },
        .{ .ago = 59, .expected = "just now" },
        .{ .ago = 60, .expected = "1m ago" },
        .{ .ago = 3599, .expected = "59m ago" },
        .{ .ago = 3600, .expected = "1h ago" },
        .{ .ago = 2 * 86400, .expected = "2d ago" },
        .{ .ago = 40 * 86400, .expected = "1mo ago" },
        .{ .ago = 400 * 86400, .expected = "1y ago" },
        // A clock that moved backwards still reads as something.
        .{ .ago = -120, .expected = "just now" },
    };
    for (cases) |case| {
        const label = try ageLabel(a, now, now - case.ago);
        defer a.free(label);
        try std.testing.expectEqualStrings(case.expected, label);
    }
}
