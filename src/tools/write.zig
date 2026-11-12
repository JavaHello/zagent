const std = @import("std");
const result_mod = @import("result.zig");

const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;

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
        .content = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to '{s}'", .{ content.len, path }),
        .is_error = false,
    };
}
