const std = @import("std");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const search = @import("search.zig");
const summary = @import("summary.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const GrepArgs = search.GrepArgs;
const freeGrepArgv = search.freeGrepArgv;
const freeGrepFlags = search.freeGrepFlags;
const appendGrepLimits = search.appendGrepLimits;
const runContentSearch = search.runContentSearch;
const expectArgv = util.expectArgv;

/// The rg tool: search file contents with ripgrep.
pub const spec: tool.Tool = .{
    .name = "rg",
    .description = "Search file contents with a regular expression and return matching lines with file and line number. Skips binary files. Results are paged; narrow pattern, path or glob when more remain.",
    .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for"},"path":{"type":"string","description":"File, directory, or shell-style path glob to search (e.g. README* or src/*.zig); defaults to the current directory. Path globs expand before searching, unlike the recursive glob filter."},"glob":{"type":"string","description":"Only search files whose names match this glob, e.g. *.zig"},"ignore_case":{"type":"boolean","description":"Match case-insensitively"},"context_lines":{"type":"integer","minimum":0,"description":"Number of surrounding lines before and after each match; defaults to 0"},"max_matches":{"type":"integer","minimum":1,"description":"Stop after this many matching lines per file (not a global limit); defaults to unlimited."},"hidden":{"type":"boolean","description":"Include hidden files (default false)"},"no_ignore":{"type":"boolean","description":"Disable ignore files (default false)"}},"required":["pattern"]}
    ,
    .label = "rg…",
    .summary = writeSummary,
    .run = run,
};

/// The pattern first — it is what the call is about — then what it is searched
/// in and the flags that narrow it. A flag that is off is the default and stays
/// out of the line.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    return summary.writeFields(w, ctx.allocator, arguments, &.{
        "pattern", "path", "glob", "ignore_case", "context_lines", "max_matches", "hidden", "no_ignore",
    });
}

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    if (args_mod.hasField(ctx.allocator, arguments, "offset")) return ctx.refuseOffset("rg");
    const args = search.parseGrepArgs(ctx.allocator, arguments) catch |err| return ctx.refuseFmt(
        "Error: rg arguments are unusable ({s}); expected a non-empty pattern, optional path/glob strings, ignore_case boolean, context_lines integer >= 0, and max_matches integer >= 1",
        .{@errorName(err)},
    );
    defer args.deinit(ctx.allocator);
    return rg(ctx.io, ctx.allocator, args);
}

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
