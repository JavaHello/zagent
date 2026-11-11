const std = @import("std");
const result_mod = @import("result.zig");
const search = @import("search.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const FindArgs = search.FindArgs;
const runSearch = search.runSearch;
const expectArgv = util.expectArgv;

/// Build argv for one find call. Borrows args and literals; free only the slice.
pub fn fdArgv(allocator: std.mem.Allocator, args: FindArgs) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);

    // fd's defaults are the ones this tool wants: hidden files and anything
    // .gitignore leaves out are skipped, so the answer is the tree a
    // developer would have searched by hand.
    try argv.appendSlice(allocator, &.{ "fd", "--color=never", "--glob" });
    if (args.hidden) try argv.append(allocator, "--hidden");
    if (args.no_ignore) try argv.append(allocator, "--no-ignore");
    try argv.appendSlice(allocator, &.{ "--", args.pattern, args.path });
    return argv.toOwnedSlice(allocator);
}

/// The fd tool always runs fd, independent of startup detection.
pub fn fd(io: std.Io, allocator: std.mem.Allocator, args: FindArgs) !ToolResult {
    const argv = try fdArgv(allocator, args);
    defer allocator.free(argv);
    return runSearch(io, allocator, argv, false);
}

test "fd argv always executes fd" {
    const allocator = std.testing.allocator;
    const args = FindArgs{ .pattern = "*.zig", .path = "src" };

    const argv = try fdArgv(allocator, args);
    defer allocator.free(argv);

    try expectArgv(&.{ "fd", "--color=never", "--glob", "--", "*.zig", "src" }, argv);
}
