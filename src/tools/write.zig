const std = @import("std");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");

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
    .run = run,
};

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    // A call that carries an edit's fields is an `edit` call that named the
    // wrong tool, so it is told which one to use rather than writing anything.
    if (args_mod.hasField(ctx.allocator, arguments, "old_text") or args_mod.hasField(ctx.allocator, arguments, "new_text"))
        return ctx.refuse("Error: write takes 'path' and 'content'; use edit for 'old_text' and 'new_text'");
    const path = args_mod.requiredString(ctx.allocator, arguments, "path") catch
        return ctx.refuse("Error: missing 'path' argument");
    defer ctx.allocator.free(path);
    const content = args_mod.requiredString(ctx.allocator, arguments, "content") catch
        return ctx.refuse("Error: missing 'content' argument");
    defer ctx.allocator.free(content);
    return writeFile(ctx.io, ctx.allocator, path, content);
}

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
