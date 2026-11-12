const std = @import("std");
const result_mod = @import("result.zig");
const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;

/// Replace one exact, unique text block without requiring hunk line counts.
pub fn editFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, old_text: []const u8, new_text: []const u8) !ToolResult {
    if (old_text.len == 0) return toolError(allocator, "Error: old_text must be non-empty; use write with content for a new file.", .{});
    const cwd = std.Io.Dir.cwd();
    const target = cwd.realPathFileAlloc(io, path, allocator) catch |err| return toolError(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) });
    defer allocator.free(target);
    const original = cwd.readFileAlloc(io, target, allocator, .limited(1024 * 1024)) catch |err| return toolError(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) });
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
    return .{ .content = try std.fmt.allocPrint(allocator, "Replaced one exact text block in '{s}' ({d} -> {d} bytes)", .{ path, original.len, updated.len }), .is_error = false };
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
