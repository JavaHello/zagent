//! Durable notes the agent keeps between sessions.
//!
//! Memory is a plain markdown list in global directory-scoped state by
//! default, so the user can read, edit, or delete it with any editor. One
//! entry per `- ` line; comments and blank lines are ignored. A failed read
//! or write never takes the agent down: memory is an aid, not a dependency.
const std = @import("std");
const openai = @import("openai.zig");
const Message = openai.Message;

pub const max_entries: usize = 200;
pub const max_entry_bytes: usize = 500;
/// Most of the system prompt the saved notes may occupy.
pub const prompt_budget: usize = 4_000;
/// Notes one automatic extraction may add. Two or three are plenty for one
/// turn; more is usually the model repeating itself in different words.
pub const max_extracted: usize = 3;

/// What the agent is asked after a turn, to decide whether anything said or
/// done deserves to survive the session.
pub const EXTRACT_SYSTEM_PROMPT =
    \\You maintain the durable memory of zagent, a command-line AI coding
    \\agent. You are given the user's request and a transcript of the turn.
    \\
    \\Decide what, if anything, should be remembered for future sessions in
    \\this workspace. Save only durable information:
    \\- the user's preferences, conventions and constraints
    \\- project facts (language, build command, important paths, architecture)
    \\- decisions that were made and the reason for them
    \\- a recurring command or workaround the user will need again
    \\
    \\Do not save transient status, one-off task details, tool output, secrets,
    \\credentials, or anything the user asked you to forget. Do not repeat a
    \\note that is already among the known notes you are shown.
    \\
    \\Write each note in the user's own language, as one short, self-contained
    \\sentence. Reply with one JSON object and nothing else:
    \\{"remember":[{"text":"..."}]}
    \\Use at most three items, and {"remember":[]} when nothing qualifies.
;

pub const Memory = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]u8,
    enabled: bool,
    entries: std.ArrayList([]u8),

    /// Resolve the memory file and read what is already in it. `AI_MEMORY=0`
    /// switches the feature off; `AI_MEMORY_FILE` chooses another file.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Memory {
        if (env.get("AI_MEMORY")) |value| {
            if (value.len > 0 and !parseEnabled(value)) {
                return initWithPath(allocator, io, null);
            }
        }
        const path = try resolvePath(allocator, io, env);
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

    /// A system-prompt section with the newest notes first, or null when
    /// nothing is saved. The notes are bounded so a long memory cannot push
    /// the instructions out of a small model's context.
    pub fn promptSection(self: *const Memory, allocator: std.mem.Allocator, max_bytes: usize) !?[]u8 {
        if (!self.enabled or self.entries.items.len == 0) return null;

        const header =
            "## Remembered context\n" ++
            "Notes saved for this workspace in earlier sessions. Use them when relevant, " ++
            "and call remember to add a new durable note.\n";

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.writeAll(header);

        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries.items[index];
            const line_len = entry.len + 3; // "- " and "\n"
            if (aw.written().len + line_len > max_bytes) continue;
            try aw.writer.writeAll("- ");
            try aw.writer.writeAll(entry);
            try aw.writer.writeByte('\n');
        }
        if (aw.written().len == header.len) return null;
        const section = try aw.toOwnedSlice();
        return section;
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

/// `AI_MEMORY` accepts the same spellings as the other booleans. Anything
/// unrecognised leaves memory enabled, so a typo does not silently hide it.
fn parseEnabled(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \t");
    const falsy = [_][]const u8{ "0", "false", "no", "off", "n", "f" };
    for (falsy) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return false;
    }
    return true;
}

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

/// The request that asks for this turn's extractable notes.
pub fn buildExtractMessages(
    allocator: std.mem.Allocator,
    request: []const u8,
    transcript: []const u8,
    known_notes: ?[]const u8,
) ![]Message {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (known_notes) |notes| {
        try w.writeAll("Known notes (do not repeat):\n");
        try w.writeAll(notes);
        try w.writeAll("\n\n");
    }
    try w.writeAll("User request:\n");
    try w.writeAll(request);
    try w.writeAll("\n\nTurn transcript:\n");
    try w.writeAll(transcript);
    const prompt = try aw.toOwnedSlice();
    errdefer allocator.free(prompt);

    const messages = try allocator.alloc(Message, 2);
    errdefer allocator.free(messages);
    messages[0] = .{
        .role = "system",
        .content = try allocator.dupe(u8, EXTRACT_SYSTEM_PROMPT),
        .reasoning_content = null,
        .tool_calls = null,
        .tool_call_id = null,
    };
    errdefer allocator.free(messages[0].content.?);
    messages[1] = .{
        .role = "user",
        .content = prompt,
        .reasoning_content = null,
        .tool_calls = null,
        .tool_call_id = null,
    };
    return messages;
}

pub const Extracted = struct {
    allocator: std.mem.Allocator,
    notes: std.ArrayList([]u8),

    pub fn deinit(self: *Extracted) void {
        for (self.notes.items) |note| self.allocator.free(note);
        self.notes.deinit(self.allocator);
    }
};

pub fn freeExtractMessages(allocator: std.mem.Allocator, messages: []Message) void {
    for (messages) |message| message.deinit(allocator);
    allocator.free(messages);
}

/// Read the extractor's JSON reply. A malformed reply yields no notes, which
/// is the safe outcome: no memory is better than a garbled one.
pub fn parseExtraction(allocator: std.mem.Allocator, content: []const u8) Extracted {
    var result = Extracted{ .allocator = allocator, .notes = .empty };
    const json = extractJsonObject(content) orelse return result;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return result;
    defer parsed.deinit();
    if (parsed.value != .object) return result;
    const remember = parsed.value.object.get("remember") orelse return result;
    if (remember != .array) return result;

    for (remember.array.items) |item| {
        if (result.notes.items.len >= max_extracted) break;
        if (item != .object) continue;
        const text_value = item.object.get("text") orelse continue;
        if (text_value != .string or text_value.string.len == 0) continue;
        const note = normalize(allocator, text_value.string) catch continue;
        if (note.len == 0) {
            allocator.free(note);
            continue;
        }
        result.notes.append(allocator, note) catch {
            allocator.free(note);
            return result;
        };
    }
    return result;
}

/// The first balanced JSON object, dropping a code fence or a sentence the
/// model wrapped it in. Braces inside strings do not count.
fn extractJsonObject(text: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text[start..], start..) |byte, i| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
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

test "the prompt section lists the newest notes first and stays bounded" {
    const allocator = std.testing.allocator;
    var memory = try Memory.initWithPath(allocator, std.testing.io, "unused");
    defer memory.deinit();
    try std.testing.expect(try memory.add("old"));
    try std.testing.expect(try memory.add("new"));

    const section = (try memory.promptSection(allocator, 512)).?;
    defer allocator.free(section);
    const new_index = std.mem.indexOf(u8, section, "- new").?;
    const old_index = std.mem.indexOf(u8, section, "- old").?;
    try std.testing.expect(new_index < old_index);

    // A budget too small for any note still returns null rather than a header
    // promising notes that are not there.
    try std.testing.expectEqual(@as(?[]u8, null), try memory.promptSection(allocator, 10));
}

test "an extraction reply is read tolerantly" {
    const allocator = std.testing.allocator;
    var extracted = parseExtraction(
        allocator,
        "```json\n{\"remember\":[{\"text\":\"user prefers zig 0.17\"},{\"text\":\"\"}]}\n```",
    );
    defer extracted.deinit();
    try std.testing.expectEqual(@as(usize, 1), extracted.notes.items.len);
    try std.testing.expectEqualStrings("user prefers zig 0.17", extracted.notes.items[0]);

    var empty = parseExtraction(allocator, "not json at all");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.notes.items.len);
}
