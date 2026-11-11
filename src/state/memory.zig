//! Durable notes the agent keeps between sessions.
//!
//! Memory is a plain markdown list in global directory-scoped state by
//! default, so the user can read, edit, or delete it with any editor. One
//! entry per `- ` line; comments and blank lines are ignored. A failed read
//! or write never takes the agent down: memory is an aid, not a dependency.
const std = @import("std");
const tools = @import("../tools/mod.zig");

pub const max_entries: usize = 200;
pub const max_entry_bytes: usize = 500;
/// Maximum bytes returned by a memory lookup: the same limit one tool result is
/// held to, so a lookup the model asked for is not cut down after it is built.
pub const search_budget: usize = tools.max_output_bytes;

fn containsFolded(text: []const u8, term: []const u8) bool {
    if (term.len > text.len) return false;
    for (0..text.len - term.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(text[i..][0..term.len], term)) return true;
    }
    return false;
}

fn matchScore(entry: []const u8, token: []const u8) usize {
    if (containsFolded(entry, token)) return 1_000;
    // UTF-8 character bigrams permit unspaced Chinese phrases to match
    // shorter keywords without cutting through a character or matching
    // isolated common characters. ASCII terms remain whole substrings.
    var score: usize = 0;
    var i: usize = 0;
    while (i < token.len) {
        const n = std.unicode.utf8ByteSequenceLength(token[i]) catch return score;
        if (i + n > token.len) break;
        if (n > 1 and i + n < token.len) {
            const next = std.unicode.utf8ByteSequenceLength(token[i + n]) catch return score;
            if (next > 1 and i + n + next <= token.len and
                std.mem.indexOf(u8, entry, token[i..][0 .. n + next]) != null) score += 1;
        }
        i += n;
    }
    return score;
}

pub const Memory = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]u8,
    enabled: bool,
    entries: std.ArrayList([]u8),

    /// Resolve and load durable notes. `AI_MEMORY_FILE` chooses another file.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Memory {
        const path = resolvePath(allocator, io, env) catch |err| switch (err) {
            error.HomeNotSet => null,
            else => return err,
        };
        defer if (path) |value| allocator.free(value);
        return initWithPath(allocator, io, path);
    }

    pub fn initWithPath(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Memory {
        var memory = Memory{
            .allocator = allocator,
            .io = io,
            .path = if (path) |value| try allocator.dupe(u8, value) else null,
            .enabled = path != null,
            .entries = .empty,
        };
        errdefer memory.deinit();
        if (memory.path) |file| {
            load(allocator, io, file, &memory.entries) catch {};
        }
        return memory;
    }

    pub fn deinit(self: *Memory) void {
        for (self.entries.items) |entry| self.allocator.free(entry);
        self.entries.deinit(self.allocator);
        if (self.path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn count(self: *const Memory) usize {
        return self.entries.items.len;
    }

    /// Add a note. Returns false when the same note is already known, so a
    /// repeated tool call does not grow the file. The caller decides when to
    /// `save`; the tool and the commands save immediately.
    pub fn add(self: *Memory, raw: []const u8) !bool {
        if (!self.enabled) return error.MemoryDisabled;
        const note = try normalize(self.allocator, raw);
        errdefer self.allocator.free(note);
        if (note.len == 0) return error.EmptyMemory;

        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry, note)) {
                self.allocator.free(note);
                return false;
            }
        }
        try self.entries.append(self.allocator, note);
        while (self.entries.items.len > max_entries) {
            const oldest = self.entries.orderedRemove(0);
            self.allocator.free(oldest);
        }
        return true;
    }

    /// Add a note, or replace/delete an exact existing note.
    pub fn edit(self: *Memory, action: []const u8, text: []const u8, old_text: ?[]const u8) !bool {
        if (!self.enabled) return error.MemoryDisabled;
        if (std.mem.eql(u8, action, "add")) {
            if (old_text != null) return error.InvalidMemoryAction;
            return self.add(text);
        }
        const replacing = std.mem.eql(u8, action, "replace");
        if (!replacing and !std.mem.eql(u8, action, "delete")) return error.InvalidMemoryAction;
        if (!replacing and old_text != null) return error.InvalidMemoryAction;
        const target = if (replacing) old_text orelse return error.MissingOldText else text;
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry, target)) continue;
            if (!replacing) return self.remove(index);
            const note = try normalize(self.allocator, text);
            if (note.len == 0) {
                self.allocator.free(note);
                return error.EmptyMemory;
            }
            self.entries.items[index] = note;
            self.allocator.free(entry);
            return true;
        }
        return error.MemoryNotFound;
    }

    /// Remove the note at a zero-based index. Returns whether it existed.
    pub fn remove(self: *Memory, index: usize) bool {
        if (index >= self.entries.items.len) return false;
        const entry = self.entries.orderedRemove(index);
        self.allocator.free(entry);
        return true;
    }

    pub fn clear(self: *Memory) void {
        for (self.entries.items) |entry| self.allocator.free(entry);
        self.entries.clearRetainingCapacity();
    }

    pub fn save(self: *Memory) !void {
        const path = self.path orelse return;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |parent| try cwd.createDirPath(self.io, parent);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try aw.writer.writeAll("# zagent memory\n");
        for (self.entries.items) |entry| {
            try aw.writer.writeAll("- ");
            try aw.writer.writeAll(entry);
            try aw.writer.writeByte('\n');
        }

        const temporary = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(temporary);
        const file = try cwd.createFile(self.io, temporary, .{ .permissions = .fromMode(0o600) });
        defer file.close(self.io);
        errdefer cwd.deleteFile(self.io, temporary) catch {};
        try file.writeStreamingAll(self.io, aw.written());
        try cwd.rename(temporary, cwd, path, self.io);
    }

    /// Local lexical retrieval, ranked by relevance then recency. Never dumps
    /// unrelated notes; callers can retry with different keywords.
    pub fn search(self: *const Memory, allocator: std.mem.Allocator, query: []const u8, limit: usize, max_bytes: usize) ![]u8 {
        if (!self.enabled) return allocator.dupe(u8, "Memory is disabled.");
        var scores: [max_entries]usize = @splat(0);
        var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n,.;:!?，。；：！？/\\\"'()[]{}");
        var count_tokens: usize = 0;
        while (tokens.next()) |token| {
            if (count_tokens == 64) break;
            count_tokens += 1;
            for (self.entries.items, 0..) |entry, i| scores[i] += matchScore(entry, token);
        }
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        for (0..@min(limit, 10)) |_| {
            var best: ?usize = null;
            for (self.entries.items, 0..) |_, i| {
                if (scores[i] > 0 and (best == null or scores[i] >= scores[best.?])) best = i;
            }
            const index = best orelse break;
            scores[index] = 0;
            const entry = self.entries.items[index];
            if (aw.written().len + entry.len + 3 > max_bytes) continue;
            try aw.writer.print("- {s}\n", .{entry});
        }
        if (aw.written().len == 0) return allocator.dupe(u8, "No matching memories. Try different or shorter keywords.");
        return aw.toOwnedSlice();
    }

    /// Numbered list for `/memory`, or a short line when it is empty.
    pub fn writeList(self: *const Memory, w: *std.Io.Writer) !void {
        if (!self.enabled) {
            try w.writeAll("Memory is disabled.\n");
            return;
        }
        if (self.entries.items.len == 0) {
            try w.writeAll("No memories saved yet. Use /remember <text>, or let the agent call remember.\n");
            if (self.path) |path| try w.print("File: {s}\n", .{path});
            return;
        }
        if (self.path) |path| try w.print("Memory: {s}\n", .{path});
        for (self.entries.items, 0..) |entry, i| {
            try w.print("{d}. {s}\n", .{ i + 1, entry });
        }
    }
};

fn resolvePath(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("AI_MEMORY_FILE")) |path| {
        if (path.len > 0) {
            const chosen = try allocator.dupe(u8, path);
            return chosen;
        }
    }
    return try @import("workspace.zig").filePath(allocator, io, env, "memory.md");
}

fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8, entries: *std.ArrayList([]u8)) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const text = if (std.mem.startsWith(u8, line, "- ")) line[2..] else line;
        const note = normalize(allocator, text) catch continue;
        if (note.len == 0) {
            allocator.free(note);
            continue;
        }
        var duplicate = false;
        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry, note)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            allocator.free(note);
            continue;
        }
        entries.append(allocator, note) catch {
            allocator.free(note);
            return error.OutOfMemory;
        };
        while (entries.items.len > max_entries) {
            const oldest = entries.orderedRemove(0);
            allocator.free(oldest);
        }
    }
}

/// One line, trimmed, whitespace collapsed, and capped. A note with a newline
/// would become two entries in the file, so it is flattened here.
fn normalize(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var words = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (words.next()) |word| {
        if (aw.written().len > 0) try aw.writer.writeByte(' ');
        if (aw.written().len + word.len > max_entry_bytes) break;
        try aw.writer.writeAll(word);
    }
    return aw.toOwnedSlice();
}

test "memory edits replace and delete exact notes without losing failed edits" {
    var memory = try Memory.initWithPath(std.testing.allocator, std.testing.io, null);
    memory.enabled = true;
    defer memory.deinit();
    _ = try memory.edit("add", "old convention", null);
    try std.testing.expectError(error.MemoryNotFound, memory.edit("replace", "new", "old"));
    try std.testing.expectError(error.EmptyMemory, memory.edit("replace", "  ", "old convention"));
    try std.testing.expectEqualStrings("old convention", memory.entries.items[0]);
    try std.testing.expect(try memory.edit("replace", "new convention", "old convention"));
    try std.testing.expectEqualStrings("new convention", memory.entries.items[0]);
    try std.testing.expectError(error.InvalidMemoryAction, memory.edit("delete", "new convention", "unexpected"));
    try std.testing.expect(try memory.edit("delete", "new convention", null));
    try std.testing.expectEqual(@as(usize, 0), memory.count());
}

test "notes are normalised, deduplicated and bounded" {
    const allocator = std.testing.allocator;
    var memory = try Memory.initWithPath(allocator, std.testing.io, null);
    memory.enabled = true;
    defer memory.deinit();

    try std.testing.expect(try memory.add("  prefers   tabs\nand four spaces "));
    try std.testing.expectEqualStrings("prefers tabs and four spaces", memory.entries.items[0]);
    try std.testing.expect(!try memory.add("prefers tabs and four spaces"));
    try std.testing.expectEqual(@as(usize, 1), memory.count());
}

test "memory is saved, loaded back, and can be removed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const path = try std.fs.path.join(allocator, &.{ directory, "state", "memory.md" });
    defer allocator.free(path);

    var memory = try Memory.initWithPath(allocator, io, path);
    defer memory.deinit();
    try std.testing.expect(try memory.add("build with zig build test"));
    try std.testing.expect(try memory.add("the CLI lives in src/main.zig"));
    try memory.save();

    var loaded = try Memory.initWithPath(allocator, io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.count());
    try std.testing.expectEqualStrings("build with zig build test", loaded.entries.items[0]);

    try std.testing.expect(loaded.remove(0));
    try loaded.save();
    var again = try Memory.initWithPath(allocator, io, path);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 1), again.count());
    try std.testing.expectEqualStrings("the CLI lives in src/main.zig", again.entries.items[0]);
}

test "memory search ranks relevant notes, folds ASCII and breaks recency ties" {
    const allocator = std.testing.allocator;
    var memory = try Memory.initWithPath(allocator, std.testing.io, "unused");
    defer memory.deinit();
    _ = try memory.add("old tmux workaround");
    _ = try memory.add("new TMUX clipboard workaround");
    _ = try memory.add("unrelated build command");
    const result = try memory.search(allocator, "tmux clipboard", 5, search_budget);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("- new TMUX clipboard workaround\n- old tmux workaround\n", result);
    const tied = try memory.search(allocator, "tmux", 1, search_budget);
    defer allocator.free(tied);
    try std.testing.expectEqualStrings("- new TMUX clipboard workaround\n", tied);
}

test "memory search supports unspaced Chinese and bounds results" {
    const allocator = std.testing.allocator;
    var memory = try Memory.initWithPath(allocator, std.testing.io, "unused");
    defer memory.deinit();
    _ = try memory.add("用户偏好中文回答");
    _ = try memory.add("剪贴板通过 tmux 复制");
    const result = try memory.search(allocator, "请查询中文偏好", 5, search_budget);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("- 用户偏好中文回答\n", result);
    const bounded = try memory.search(allocator, "中文", 5, 4);
    defer allocator.free(bounded);
    try std.testing.expect(std.mem.startsWith(u8, bounded, "No matching memories"));
    const absent = try memory.search(allocator, "nonexistent", 5, search_budget);
    defer allocator.free(absent);
    try std.testing.expect(std.mem.startsWith(u8, absent, "No matching memories"));
    memory.enabled = false;
    const disabled = try memory.search(allocator, "中文", 5, search_budget);
    defer allocator.free(disabled);
    try std.testing.expectEqualStrings("Memory is disabled.", disabled);
}

test "memory lookup never returns a partial note or exceeds its byte budget" {
    const allocator = std.testing.allocator;
    var memory = try Memory.initWithPath(allocator, std.testing.io, "unused");
    defer memory.deinit();
    const bytes: [450]u8 = @splat('x');
    const padding: []const u8 = &bytes;
    for (0..20) |i| {
        const note = try std.fmt.allocPrint(allocator, "tmux {d} {s}", .{ i, padding });
        defer allocator.free(note);
        _ = try memory.add(note);
    }
    // A budget only some of these notes can fill proves both halves: no note
    // comes back in part, and the total stays inside what the caller allowed.
    const budget = search_budget / 10;
    const result = try memory.search(allocator, "tmux", 10, budget);
    defer allocator.free(result);
    try std.testing.expect(result.len <= budget);
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        count += 1;
        try std.testing.expect(std.mem.endsWith(u8, line, padding));
    }
    try std.testing.expectEqual(@as(usize, 8), count);
}
