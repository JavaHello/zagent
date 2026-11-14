const std = @import("std");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const search = @import("search.zig");
const summary = @import("summary.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const FindArgs = search.FindArgs;
const runSearch = search.runSearch;
const expectArgv = util.expectArgv;

/// The fd tool: find files and directories by name glob.
pub const spec: tool.Tool = .{
    .name = "fd",
    .description = "Find files and directories whose names match a glob and return their paths.",
    .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob the name must match, e.g. *.zig or *test*"},"path":{"type":"string","description":"Directory to search in, defaults to the current directory"},"hidden":{"type":"boolean","description":"Include hidden entries (default false)"},"no_ignore":{"type":"boolean","description":"Disable ignore files (default false)"}},"required":["pattern"]}
    ,
    .label = "fd…",
    .summary = writeSummary,
    .run = run,
};

/// The glob first, then the directory it is looked for in: a name pattern on
/// its own says where to look by leaving it to the default.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    return summary.writeFields(w, ctx.allocator, arguments, &.{ "pattern", "path", "hidden", "no_ignore" });
}

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    if (args_mod.hasField(ctx.allocator, arguments, "offset")) return ctx.refuseOffset("fd");
    const args = search.parseFindArgs(ctx.allocator, arguments) catch |err| return ctx.refuseFmt(
        "Error: fd arguments are unusable ({s}); it needs a non-empty 'pattern' holding a glob, and a 'path' it can use",
        .{@errorName(err)},
    );
    defer args.deinit(ctx.allocator);
    return fd(ctx.io, ctx.allocator, args);
}

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
