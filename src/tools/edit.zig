const std = @import("std");
const diff = @import("../diff/mod.zig");
const sgr = @import("../ui/style.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;

/// The most of a file one edit reads — to find the text it replaces, and to
/// count the line that text starts on for the diff the call is drawn as.
const max_file_bytes: usize = 1024 * 1024;

/// The edit tool: exact text replaced in an existing file — one unique block by
/// default, every occurrence of it when the call asks for that.
pub const spec: tool.Tool = .{
    .name = "edit",
    .description = "Replace exact text in an existing file. A missing match changes nothing, and a match that is not unique is refused unless 'replace_all' is true. Use write to create or overwrite a whole file.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string","minLength":1,"description":"Exact non-empty text to replace"},"new_text":{"type":"string","description":"Replacement text; may be empty"},"replace_all":{"type":"boolean","default":false,"description":"Default false; when true every occurrence of old_text is replaced instead of requiring a unique match"}},"required":["path","old_text","new_text"],"additionalProperties":false}
    ,
    .label = "edit…",
    .summary = writeSummary,
    .summary_block = true,
    .run = run,
};

/// The call is drawn as the diff it makes — one hunk per occurrence when it
/// replaces them all.
///
/// Its arguments are blocks of exact text, and neither the JSON they arrive in
/// nor a one-line preview of it says what the file loses and gains. The lines
/// those blocks start at are the one thing the arguments cannot say, so they
/// are counted in the file — when the file can be read and still holds the
/// text, and silently left out when it cannot, because this is a preview: the
/// edit itself is what says why a call changed nothing.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    const parsed = std.json.parseFromSlice(Arguments, ctx.allocator, arguments, .{}) catch return false;
    defer parsed.deinit();
    const args = parsed.value;
    if (args.old_text.len == 0) return false;
    const starts = startLines(ctx.io, ctx.allocator, args.path, args.old_text, args.replace_all) catch return false;
    defer ctx.allocator.free(starts);
    try diff.renderEdits(w, args.path, starts, args.old_text, args.new_text);
    return true;
}

/// The 1-based line each occurrence of `text` starts on in the file at `path`:
/// every occurrence for a call that replaces them all, and only the first for
/// one that needs a unique match. A file that cannot be read, or that no longer
/// holds the text, says nothing about where it is — and one such `null` is what
/// the call is still drawn from.
fn startLines(io: std.Io, allocator: std.mem.Allocator, path: []const u8, text: []const u8, replace_all: bool) ![]?usize {
    var starts: std.ArrayList(?usize) = .empty;
    errdefer starts.deinit(allocator);
    const original = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch {
        try starts.append(allocator, null);
        return starts.toOwnedSlice(allocator);
    };
    defer allocator.free(original);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, original, from, text)) |position| {
        try starts.append(allocator, std.mem.count(u8, original[0..position], "\n") + 1);
        if (!replace_all) break;
        // Replacements do not overlap: the text a call has just replaced is not
        // searched again, or new text holding the old would be replaced twice.
        from = position + text.len;
    }
    if (starts.items.len == 0) try starts.append(allocator, null);
    return starts.toOwnedSlice(allocator);
}

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    // All three strings are required and 'replace_all' is the only other field
    // read: a call carrying `content` is a `write` call, and is told so rather
    // than editing anything.
    const parsed = std.json.parseFromSlice(Arguments, ctx.allocator, arguments, .{}) catch
        return ctx.refuse("Error: edit requires 'path', 'old_text' and 'new_text' strings, and 'replace_all' as a boolean; do not pass 'content'");
    defer parsed.deinit();
    return editFile(ctx.io, ctx.allocator, parsed.value.path, parsed.value.old_text, parsed.value.new_text, parsed.value.replace_all);
}

/// The arguments of one edit call, as the model sent them.
const Arguments = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    /// Absent is false: an edit that does not say otherwise replaces one block.
    replace_all: bool = false,
};

/// Replace exact text without requiring hunk line counts: the one unique block
/// the call names, or every occurrence of it when `replace_all` says so.
pub fn editFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, old_text: []const u8, new_text: []const u8, replace_all: bool) !ToolResult {
    if (old_text.len == 0) return toolError(allocator, "Error: old_text must be non-empty; use write with content for a new file.", .{});
    const cwd = std.Io.Dir.cwd();
    const target = cwd.realPathFileAlloc(io, path, allocator) catch |err| return toolError(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) });
    defer allocator.free(target);
    const original = cwd.readFileAlloc(io, target, allocator, .limited(max_file_bytes)) catch |err| return toolError(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) });
    defer allocator.free(original);
    const first = std.mem.indexOf(u8, original, old_text) orelse return toolError(allocator, "Error: old_text was not found in '{s}'; read the current file and copy its exact text.", .{path});
    if (!replace_all and std.mem.indexOfPos(u8, original, first + 1, old_text) != null)
        return toolError(allocator, "Error: old_text occurs more than once in '{s}'; include more surrounding context, or set 'replace_all' to replace every occurrence.", .{path});

    // Every occurrence, from the first, whether the call wants one of them or
    // all: what a call replaces is never searched again, so text that arrives
    // holding the text it replaced is left alone.
    var updated: std.ArrayList(u8) = .empty;
    defer updated.deinit(allocator);
    var count: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, original, from, old_text)) |position| {
        try updated.appendSlice(allocator, original[from..position]);
        try updated.appendSlice(allocator, new_text);
        from = position + old_text.len;
        count += 1;
        if (!replace_all) break;
    }
    try updated.appendSlice(allocator, original[from..]);

    const stat = try cwd.statFile(io, target, .{});
    var atomic = try cwd.createFileAtomic(io, target, .{ .replace = true, .permissions = stat.permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, updated.items);
    try atomic.file.setPermissions(io, stat.permissions);
    try atomic.replace(io);
    if (count == 1)
        return .{ .output = try std.fmt.allocPrint(allocator, "Replaced one exact text block in '{s}' ({d} -> {d} bytes)", .{ path, original.len, updated.items.len }), .is_error = false };
    return .{ .output = try std.fmt.allocPrint(allocator, "Replaced {d} occurrences of an exact text block in '{s}' ({d} -> {d} bytes)", .{ count, path, original.len, updated.items.len }), .is_error = false };
}

test "exact edits reject ambiguous text and preserve permissions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "script", .{ .permissions = .fromMode(0o755) });
    try file.setPermissions(io, .fromMode(0o755));
    try file.writeStreamingAll(io, "alpha alpha\n");
    file.close(io);
    const path = try tmp.dir.realPathFileAlloc(io, "script", allocator);
    defer allocator.free(path);
    const rejected = try editFile(io, allocator, path, "alpha", "changed", false);
    defer rejected.deinit(allocator);
    try std.testing.expect(rejected.is_error);
    const unchanged = try tmp.dir.readFileAlloc(io, "script", allocator, .limited(1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("alpha alpha\n", unchanged);
    const edited = try editFile(io, allocator, path, "alpha alpha", "beta", false);
    defer edited.deinit(allocator);
    try std.testing.expect(!edited.is_error);
    const content = try tmp.dir.readFileAlloc(io, "script", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("beta\n", content);
    const stat = try tmp.dir.statFile(io, "script", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o7777);
}

test "replace_all replaces every occurrence, and only what was there" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "script", .data = "tick tock tick\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "script", allocator);
    defer allocator.free(path);

    // The same call without the flag is ambiguous, and says which way out of
    // that there is rather than leaving the file as it was.
    const rejected = try editFile(io, allocator, path, "tick", "TICK", false);
    defer rejected.deinit(allocator);
    try std.testing.expect(rejected.is_error);
    try std.testing.expect(std.mem.indexOf(u8, rejected.output, "replace_all") != null);

    // Every occurrence, including the last line's: the replacement text is not
    // searched again, or each `tick tick` would be replaced twice over.
    const edited = try editFile(io, allocator, path, "tick", "tick tick", true);
    defer edited.deinit(allocator);
    try std.testing.expect(!edited.is_error);
    try std.testing.expect(std.mem.indexOf(u8, edited.output, "Replaced 2 occurrences") != null);
    const content = try tmp.dir.readFileAlloc(io, "script", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("tick tick tock tick tick\n", content);

    // A text the file does not hold is still an error, flag or not.
    const absent = try editFile(io, allocator, path, "absent", "added", true);
    defer absent.deinit(allocator);
    try std.testing.expect(absent.is_error);
    try std.testing.expect(std.mem.indexOf(u8, absent.output, "not found") != null);
}

test "an edit call is drawn as the diff it makes, at the line it starts on" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\nthree\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "note.txt", allocator);
    defer allocator.free(path);

    const ctx: tool.Context = .{ .io = io, .allocator = allocator };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const call = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"old_text\":\"two\",\"new_text\":\"TWO\\nEXTRA\"}}", .{path});
    defer allocator.free(call);
    try std.testing.expect(try spec.summary.?(ctx, &out.writer, call));

    // The line is the file's own count, not the model's: the arguments name the
    // text, and only the file says where it is.
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "  " ++ sgr.DIM ++ "--- "));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), path) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "@@ -2,1 +2,2 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "-two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "+TWO") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "+EXTRA") != null);

    // A call that replaces every occurrence is drawn at each of them, under one
    // pair of file headers: two hunks, each at the line its own occurrence
    // starts on.
    try tmp.dir.writeFile(io, .{ .sub_path = "twice.txt", .data = "tick\ntock\ntick\n" });
    const twice = try tmp.dir.realPathFileAlloc(io, "twice.txt", allocator);
    defer allocator.free(twice);
    out.clearRetainingCapacity();
    const every = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"old_text\":\"tick\",\"new_text\":\"TOCK\",\"replace_all\":true}}", .{twice});
    defer allocator.free(every);
    try std.testing.expect(try spec.summary.?(ctx, &out.writer, every));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "--- "));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "@@ -1,1 +1,1 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "@@ -3,1 +3,1 @@") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "-tick"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "+TOCK"));

    // A text the file no longer holds is still drawn — that is the change the
    // call asks for — with no line claimed for it, and a call the tool would
    // refuse is left to the line that shows raw arguments.
    out.clearRetainingCapacity();
    const stale = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"old_text\":\"absent\",\"new_text\":\"added\"}}", .{path});
    defer allocator.free(stale);
    try std.testing.expect(try spec.summary.?(ctx, &out.writer, stale));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "@@") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "-absent") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "+added") != null);

    out.clearRetainingCapacity();
    try std.testing.expect(!try spec.summary.?(ctx, &out.writer, "{\"path\":\"unused\",\"old_text\":\"old\",\"new_text\":\"new\",\"content\":\"bad\"}"));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}
