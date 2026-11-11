const std = @import("std");
const result_mod = @import("result.zig");
const search = @import("search.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const GrepArgs = search.GrepArgs;
const freeGrepArgv = search.freeGrepArgv;
const freeGrepFlags = search.freeGrepFlags;
const appendGrepLimits = search.appendGrepLimits;
const runContentSearch = search.runContentSearch;
const expectArgv = util.expectArgv;

pub fn rgArgv(allocator: std.mem.Allocator, args: GrepArgs) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeGrepFlags(allocator, argv.items);
        argv.deinit(allocator);
    }

    // The flags are passed even though ripgrep prints this shape by itself
    // when it is not writing to a terminal: a RIPGREP_CONFIG_PATH file can
    // change the defaults, and the model should read the same output on
    // every machine. `--color=never` is for that same file: the result is
    // stripped of escapes before the model sees it, but that is no reason
    // to pay for them.
    try argv.appendSlice(allocator, &.{ "rg", "--line-number", "--no-heading", "--color=never" });
    try appendGrepLimits(allocator, &argv, args);
    try argv.appendSlice(allocator, &.{ "--no-config", "--sort=path" });
    if (args.hidden) try argv.append(allocator, "--hidden");
    if (args.no_ignore) try argv.append(allocator, "--no-ignore");
    if (args.glob) |glob| try argv.appendSlice(allocator, &.{ "--glob", glob });
    if (args.ignore_case) try argv.append(allocator, "--ignore-case");
    // `--` keeps a pattern that starts with a dash from being read as a flag.
    try argv.appendSlice(allocator, &.{ "--", args.pattern, args.path });
    return argv.toOwnedSlice(allocator);
}

/// The rg tool always runs ripgrep, independent of startup detection.
pub fn rg(io: std.Io, allocator: std.mem.Allocator, args: GrepArgs) !ToolResult {
    const argv = try rgArgv(allocator, args);
    defer freeGrepArgv(allocator, argv);
    return runContentSearch(io, allocator, argv, args);
}

test "rg argv always executes ripgrep" {
    const allocator = std.testing.allocator;
    const args = GrepArgs{ .pattern = "fn main", .path = "src", .glob = "*.zig", .ignore_case = true };

    const argv = try rgArgv(allocator, args);
    defer allocator.free(argv);

    try expectArgv(
        &.{ "rg", "--line-number", "--no-heading", "--color=never", "--no-config", "--sort=path", "--glob", "*.zig", "--ignore-case", "--", "fn main", "src" },
        argv,
    );
}
