const std = @import("std");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const summary = @import("summary.zig");

const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;

/// The write tool: whole-file writes only; exact replacements belong to edit.
pub const spec: tool.Tool = .{
    .name = "write",
    .description = "Create or overwrite an entire file with content. Use edit for exact text replacements.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string","description":"Entire file contents for creation or full replacement"}},"required":["path","content"],"additionalProperties":false}
    ,
    .label = "write…",
    .summary = writeSummary,
    .run = run,
};

/// The path, and how much is being written to it. The content is the file
/// itself, and printing it here would put a whole file on the call's line where
/// what the reader needs is to know which call wrote it and how much arrived.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    const parsed = std.json.parseFromSlice(Arguments, ctx.allocator, arguments, parse_options) catch return false;
    defer parsed.deinit();
    const path = parsed.value.path orelse return false;
    if (path.len == 0) return false;
    try summary.writeText(w, path);
    const content = parsed.value.content orelse return true;
    try w.print(" · {d} lines", .{lineCount(content)});
    return true;
}

/// The lines `content` holds. A trailing newline ends the last line rather than
/// starting one, and nothing at all is no lines.
fn lineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    return std.mem.count(u8, content, "\n") + @intFromBool(content[content.len - 1] != '\n');
}

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    // The arguments are read once, past the check that they are the ones this
    // tool takes. The content is the file itself, so every further reading
    // would copy the whole of it again.
    const parsed = std.json.parseFromSlice(Arguments, ctx.allocator, arguments, parse_options) catch
        return ctx.refuse("Error: write takes 'path' and 'content' strings");
    defer parsed.deinit();
    // A call that carries an edit's fields is an `edit` call that named the
    // wrong tool, so it is told which one to use rather than writing anything.
    if (parsed.value.old_text != null or parsed.value.new_text != null)
        return ctx.refuse("Error: write takes 'path' and 'content'; use edit for 'old_text' and 'new_text'");
    const path = parsed.value.path orelse return ctx.refuse("Error: missing 'path' argument");
    const content = parsed.value.content orelse return ctx.refuse("Error: missing 'content' argument");
    return writeFile(ctx.io, ctx.allocator, path, content);
}

/// The arguments of one write call, as the model sent them.
///
/// A field the call left out is not an error here: which argument is missing is
/// the tool's answer to give, in its own words.
const Arguments = struct {
    path: ?[]const u8 = null,
    content: ?[]const u8 = null,
    /// Presence only. These are never read; a call that carries one is an
    /// `edit` call that named the wrong tool.
    old_text: ?std.json.Value = null,
    new_text: ?std.json.Value = null,
};

/// A field this call does not read is not a reason to refuse it.
const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// Create or overwrite the entire file; exact replacements belong to edit.
pub fn writeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !ToolResult {
    const cwd = std.Io.Dir.cwd();
    const target = cwd.realPathFileAlloc(io, path, allocator) catch try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(target);
    if (std.Io.Dir.path.dirname(target)) |parent| try cwd.createDirPath(io, parent);
    const stat = cwd.statFile(io, target, .{}) catch null;
    const permissions: std.Io.File.Permissions = if (stat) |s| s.permissions else .default_file;
    var atomic = cwd.createFileAtomic(io, target, .{ .replace = true, .permissions = permissions }) catch |err|
        return toolError(allocator, "Error creating '{s}': {s}", .{ path, @errorName(err) });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, content);
    if (stat != null) try atomic.file.setPermissions(io, permissions);
    try atomic.replace(io);

    return .{
        .output = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to '{s}'", .{ content.len, path }),
        .is_error = false,
    };
}

test "a call this tool cannot use says which argument is wrong, and only reads it once" {
    const a = std.testing.allocator;
    const ctx: tool.Context = .{ .io = std.testing.io, .allocator = a };

    // An `edit` call that named the wrong tool is told which one it wanted.
    const wrong = try run(ctx, "{\"path\":\"a.txt\",\"content\":\"x\",\"old_text\":\"y\",\"new_text\":\"z\"}");
    defer wrong.deinit(a);
    try std.testing.expect(wrong.is_error);
    try std.testing.expectEqualStrings(
        "Error: write takes 'path' and 'content'; use edit for 'old_text' and 'new_text'",
        wrong.output,
    );

    // Which argument is missing is this tool's answer, not the parser's.
    const absent = try run(ctx, "{\"path\":\"a.txt\"}");
    defer absent.deinit(a);
    try std.testing.expectEqualStrings("Error: missing 'content' argument", absent.output);

    // Arguments that are not the strings this tool takes are refused as a whole.
    for ([_][]const u8{ "{\"path\":\"a.txt\",\"content\":5}", "{\"path\":\"a.txt\",\"content\":\"x\"} trailing", "[]" }) |arguments| {
        const refused = try run(ctx, arguments);
        defer refused.deinit(a);
        try std.testing.expect(refused.is_error);
        try std.testing.expectEqualStrings("Error: write takes 'path' and 'content' strings", refused.output);
    }

    // A member the call does not read is still ignored, as it was when the
    // arguments were read as a DOM: it is not what refuses the write.
    const extra = try std.json.parseFromSlice(Arguments, a, "{\"path\":\"a.txt\",\"content\":\"hi\",\"note\":1}", parse_options);
    defer extra.deinit();
    try std.testing.expectEqualStrings("a.txt", extra.value.path.?);
    try std.testing.expectEqualStrings("hi", extra.value.content.?);
}

test "the call's line names the path and how many lines arrive" {
    const a = std.testing.allocator;
    const ctx: tool.Context = .{ .io = std.testing.io, .allocator = a };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.testing.expect(try writeSummary(ctx, &aw.writer, "{\"path\":\"src/a.zig\",\"content\":\"one\\ntwo\\n\"}"));
    try std.testing.expectEqualStrings("src/a.zig · 2 lines", aw.written());

    // Nothing is written for a call whose arguments say nothing about a path.
    var none: std.Io.Writer.Allocating = .init(a);
    defer none.deinit();
    try std.testing.expect(!try writeSummary(ctx, &none.writer, "{\"content\":\"one\"}"));
    try std.testing.expectEqualStrings("", none.written());
}
