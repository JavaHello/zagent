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

/// The edit tool: one exact, unique block replaced in an existing file.
pub const spec: tool.Tool = .{
    .name = "edit",
    .description = "Replace one exact, unique text block in an existing file. Missing or ambiguous matches change nothing. Use write to create or overwrite a whole file.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string","minLength":1,"description":"Exact non-empty text to replace"},"new_text":{"type":"string","description":"Replacement text; may be empty"}},"required":["path","old_text","new_text"],"additionalProperties":false}
    ,
    .label = "edit…",
    .summary = writeSummary,
    .summary_block = true,
    .run = run,
};

/// The call is drawn as the diff it makes.
///
/// Its two arguments are blocks of exact text, and neither the JSON they arrive
/// in nor a one-line preview of it says what the file loses and gains. The line
/// the old text starts at is the one thing the arguments cannot say, so it is
/// counted in the file — when the file can be read and still holds that text,
/// and silently left out when it cannot, because this is a preview: the edit
/// itself is what says why a call changed nothing.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    const parsed = std.json.parseFromSlice(Arguments, ctx.allocator, arguments, .{}) catch return false;
    defer parsed.deinit();
    const args = parsed.value;
    if (args.old_text.len == 0) return false;
    try diff.renderEdit(w, args.path, startLine(ctx.io, ctx.allocator, args.path, args.old_text), args.old_text, args.new_text);
    return true;
}

/// The 1-based line `text` starts on in the file at `path`, or null when the
/// file cannot be read or no longer holds that text.
fn startLine(io: std.Io, allocator: std.mem.Allocator, path: []const u8, text: []const u8) ?usize {
    const original = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch return null;
    defer allocator.free(original);
    const position = std.mem.indexOf(u8, original, text) orelse return null;
    return std.mem.count(u8, original[0..position], "\n") + 1;
}

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    // All three fields are required and no other field is read: a call carrying
    // `content` is a `write` call, and is told so rather than editing anything.
    const parsed = std.json.parseFromSlice(Arguments, ctx.allocator, arguments, .{}) catch
        return ctx.refuse("Error: edit requires 'path', 'old_text' and 'new_text' strings; do not pass 'content'");
    defer parsed.deinit();
    return editFile(ctx.io, ctx.allocator, parsed.value.path, parsed.value.old_text, parsed.value.new_text);
}

/// The arguments of one edit call, as the model sent them.
const Arguments = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

/// Replace one exact, unique text block without requiring hunk line counts.
pub fn editFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, old_text: []const u8, new_text: []const u8) !ToolResult {
    if (old_text.len == 0) return toolError(allocator, "Error: old_text must be non-empty; use write with content for a new file.", .{});
    const cwd = std.Io.Dir.cwd();
    const target = cwd.realPathFileAlloc(io, path, allocator) catch |err| return toolError(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) });
    defer allocator.free(target);
    const original = cwd.readFileAlloc(io, target, allocator, .limited(max_file_bytes)) catch |err| return toolError(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) });
    defer allocator.free(original);
    const position = std.mem.indexOf(u8, original, old_text) orelse return toolError(allocator, "Error: old_text was not found in '{s}'; read the current file and copy its exact text.", .{path});
    if (std.mem.indexOfPos(u8, original, position + 1, old_text) != null) return toolError(allocator, "Error: old_text occurs more than once in '{s}'; include more surrounding context.", .{path});
    const updated = try std.mem.concat(allocator, u8, &.{ original[0..position], new_text, original[position + old_text.len ..] });
    defer allocator.free(updated);
    const stat = try cwd.statFile(io, target, .{});
    var atomic = try cwd.createFileAtomic(io, target, .{ .replace = true, .permissions = stat.permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, updated);
    try atomic.file.setPermissions(io, stat.permissions);
    try atomic.replace(io);
    return .{ .output = try std.fmt.allocPrint(allocator, "Replaced one exact text block in '{s}' ({d} -> {d} bytes)", .{ path, original.len, updated.len }), .is_error = false };
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
    const rejected = try editFile(io, allocator, path, "alpha", "changed");
    defer rejected.deinit(allocator);
    try std.testing.expect(rejected.is_error);
    const unchanged = try tmp.dir.readFileAlloc(io, "script", allocator, .limited(1024));
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("alpha alpha\n", unchanged);
    const edited = try editFile(io, allocator, path, "alpha alpha", "beta");
    defer edited.deinit(allocator);
    try std.testing.expect(!edited.is_error);
    const content = try tmp.dir.readFileAlloc(io, "script", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("beta\n", content);
    const stat = try tmp.dir.statFile(io, "script", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o7777);
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
