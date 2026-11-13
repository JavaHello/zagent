const std = @import("std");
const grep_mod = @import("grep.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const search = @import("search.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const FindArgs = search.FindArgs;
const runSearch = search.runSearch;
const grep = grep_mod.grep;
const expectArgv = util.expectArgv;
const fixturePath = util.fixturePath;

/// The find tool: find files and directories by name glob.
pub const spec: tool.Tool = .{
    .name = "find",
    .description = "Find files and directories by name glob using find. Prunes .git; includes hidden entries; does not read ignore files.",
    .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Name glob, e.g. *.zig or *test*"},"path":{"type":"string","description":"Directory to search; defaults to ."}},"required":["pattern"]}
    ,
    .label = "find…",
    .run = run,
};

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    if (args_mod.hasField(ctx.allocator, arguments, "offset")) return ctx.refuseOffset("find");
    const args = search.parseFindArgs(ctx.allocator, arguments) catch |err| return ctx.refuseFmt(
        "Error: find arguments are unusable ({s}); it needs a non-empty 'pattern' holding a glob, and a 'path' it can use",
        .{@errorName(err)},
    );
    defer args.deinit(ctx.allocator);
    return find(ctx.io, ctx.allocator, args);
}

pub fn findArgv(allocator: std.mem.Allocator, args: FindArgs) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    // find reads no ignore file of its own, so `.git` is pruned by hand —
    // without it, a search for a name would walk every object in the
    // repository. The `-print` on the second branch cannot be left out:
    // the `-o` alone would make find print nothing at all.
    try argv.appendSlice(allocator, &.{ "find", args.path, "-name", ".git", "-prune", "-o", "-name", args.pattern, "-print" });

    return argv.toOwnedSlice(allocator);
}

/// The find tool: find files and directories by name.
pub fn find(io: std.Io, allocator: std.mem.Allocator, args: FindArgs) !ToolResult {
    const argv = try findArgv(allocator, args);
    defer allocator.free(argv);
    return runSearch(io, allocator, argv, false);
}

test "find argv always executes find" {
    const allocator = std.testing.allocator;
    const args = FindArgs{ .pattern = "*.zig", .path = "src" };

    const argv = try findArgv(allocator, args);
    defer allocator.free(argv);

    // The `-print` is load-bearing: `-prune -o -name …` with nothing after it
    // would make find print nothing at all.
    try expectArgv(&.{ "find", "src", "-name", ".git", "-prune", "-o", "-name", "*.zig", "-print" }, argv);
}

test "a search that matched nothing is an answer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "first line\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // grep exits 1 when it matched nothing. Reading that as a failure would
    // send the model off to retry a search that has already answered.
    const searched = try grep(io, allocator, .{ .pattern = "nowhere", .path = dir, .glob = null, .ignore_case = false });
    defer searched.deinit(allocator);
    try std.testing.expect(!searched.is_error);
    try std.testing.expectEqualStrings("", searched.output);

    // find reports the same nothing with a zero exit and no output at all.
    const looked = try find(io, allocator, .{ .pattern = "*.nope", .path = dir });
    defer looked.deinit(allocator);
    try std.testing.expect(!looked.is_error);
    try std.testing.expectEqualStrings("", looked.output);
}

test "find returns the paths whose name matches" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "wanted.zig", .data = "pub fn main() void {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "not this one\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const result = try find(io, allocator, .{ .pattern = "*.zig", .path = dir });
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "wanted.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "other.txt") == null);
}

test "a search that failed is an error, not an empty answer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // A pattern the program cannot compile comes back on stderr with the code
    // that means failure — 2 for both greps, unlike the 1 for "no match".
    const result = try grep(io, allocator, .{ .pattern = "[", .path = ".", .glob = null, .ignore_case = false });
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "stderr:") != null);

    // A path that does not exist is a failure for find too, even though fd
    // reports it with the exit code the content searches use for "no match".
    const missing = try find(io, allocator, .{ .pattern = "*.zig", .path = "/nonexistent-path-for-zagent-tests" });
    defer missing.deinit(allocator);
    try std.testing.expect(missing.is_error);
}
