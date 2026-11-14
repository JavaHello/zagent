const std = @import("std");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const search = @import("search.zig");
const summary = @import("summary.zig");
const rg_mod = @import("rg.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const GrepArgs = search.GrepArgs;
const freeGrepArgv = search.freeGrepArgv;
const freeGrepFlags = search.freeGrepFlags;
const appendGrepLimits = search.appendGrepLimits;
const runContentSearch = search.runContentSearch;
const parseGrepArgs = search.parseGrepArgs;
const rgArgv = rg_mod.rgArgv;
const rg = rg_mod.rg;
const expectArgv = util.expectArgv;
const fixturePath = util.fixturePath;

/// The grep tool: search file contents with grep.
pub const spec: tool.Tool = .{
    .name = "grep",
    .description = "Search file contents with grep extended regular expressions and return matching lines with file and line numbers. Skips binary files and .git; includes hidden files; does not read ignore files.",
    .parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Extended regular expression to search for"},"path":{"type":"string","description":"File, directory, or shell-style path glob (e.g. README*); defaults to ."},"glob":{"type":"string","description":"Only search files whose names match this glob"},"ignore_case":{"type":"boolean"},"context_lines":{"type":"integer","minimum":0},"max_matches":{"type":"integer","minimum":1}},"required":["pattern"]}
    ,
    .label = "grep…",
    .summary = writeSummary,
    .run = run,
};

/// As for `rg`: the pattern, then what it is searched in and the flags that
/// narrow it.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    return summary.writeFields(w, ctx.allocator, arguments, &.{
        "pattern", "path", "glob", "ignore_case", "context_lines", "max_matches",
    });
}

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    if (args_mod.hasField(ctx.allocator, arguments, "offset")) return ctx.refuseOffset("grep");
    const args = parseGrepArgs(ctx.allocator, arguments) catch |err| return ctx.refuseFmt(
        "Error: grep arguments are unusable ({s}); expected a non-empty pattern, optional path/glob strings, ignore_case boolean, context_lines integer >= 0, and max_matches integer >= 1",
        .{@errorName(err)},
    );
    defer args.deinit(ctx.allocator);
    return grep(ctx.io, ctx.allocator, args);
}

pub fn grepArgv(allocator: std.mem.Allocator, args: GrepArgs) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeGrepFlags(allocator, argv.items);
        argv.deinit(allocator);
    }
    // `-E` selects extended regular expressions.
    // Everything else is short options plus `--include` and `--exclude-dir`,
    // which the grep macOS ships also accepts.
    // `-I` drops binary files, as ripgrep does by default, and `.git` is
    // skipped by hand because this grep does not read .gitignore and would
    // otherwise work through every object the repository has ever stored.
    try argv.appendSlice(allocator, &.{ "grep", "-r", "-n", "-I", "-E", "--exclude-dir=.git" });
    try appendGrepLimits(allocator, &argv, args);
    if (args.glob) |glob| try argv.appendSlice(allocator, &.{ "--include", glob });
    if (args.ignore_case) try argv.append(allocator, "-i");
    // `-e` rather than a bare pattern, for the same reason as `--` above.
    try argv.appendSlice(allocator, &.{ "-e", args.pattern, "--", args.path });

    return argv.toOwnedSlice(allocator);
}

/// The grep tool: search file contents with a regular expression.
pub fn grep(io: std.Io, allocator: std.mem.Allocator, args: GrepArgs) !ToolResult {
    const argv = try grepArgv(allocator, args);
    defer freeGrepArgv(allocator, argv);
    return runContentSearch(io, allocator, argv, args);
}

test "grep includes context and stops matching per file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "before\nneedle\nafter\ngap\nneedle later\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "note.txt", a);
    defer a.free(path);
    const result = try grep(io, a, .{
        .pattern = "needle",
        .path = path,
        .glob = null,
        .ignore_case = false,
        .context_lines = 1,
        .max_matches = 1,
    });
    defer result.deinit(a);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "needle later") == null);
}

test "search limits parse and reach both backends" {
    const a = std.testing.allocator;
    const args = try parseGrepArgs(a, "{\"pattern\":\"needle\",\"context_lines\":2,\"max_matches\":1}");
    defer args.deinit(a);
    try std.testing.expectEqual(@as(?usize, 2), args.context_lines);
    try std.testing.expectEqual(@as(?usize, 1), args.max_matches);
    for ([_]bool{ false, true }) |use_rg| {
        const argv = try (if (use_rg) &rgArgv else &grepArgv)(a, args);
        defer freeGrepArgv(a, argv);
        const start: usize = if (use_rg) 4 else 6;
        try std.testing.expectEqualStrings("--context=2", argv[start]);
        try std.testing.expectEqualStrings("--max-count=1", argv[start + 1]);
    }
    for ([_][]const u8{
        "{\"pattern\":\"x\",\"context_lines\":-1}",
        "{\"pattern\":\"x\",\"context_lines\":true}",
        "{\"pattern\":\"x\",\"max_matches\":0}",
        "{\"pattern\":\"x\",\"max_matches\":1.5}",
        "{\"pattern\":\"x\",\"max_matches\":\"2\"}",
    }) |json| try std.testing.expectError(error.InvalidArguments, parseGrepArgs(a, json));
}

test "grep argv always executes grep" {
    const allocator = std.testing.allocator;
    const args = GrepArgs{ .pattern = "fn main", .path = "src", .glob = "*.zig", .ignore_case = true };

    const argv = try grepArgv(allocator, args);
    defer allocator.free(argv);

    // `-E` enables extended regular expressions; without it `|`, `+` and
    // `()` would be literals.
    try expectArgv(
        &.{ "grep", "-r", "-n", "-I", "-E", "--exclude-dir=.git", "--include", "*.zig", "-i", "-e", "fn main", "--", "src" },
        argv,
    );

    const plain = try grepArgv(allocator, .{ .pattern = "needle", .path = ".", .glob = null, .ignore_case = false });
    defer allocator.free(plain);
    try expectArgv(&.{ "grep", "-r", "-n", "-I", "-E", "--exclude-dir=.git", "-e", "needle", "--", "." }, plain);
}

test "grep finds a line and the file it is in" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "first line\nthe needle is here\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // The fallback backend is asked for by name: whether the machine running
    // the tests has ripgrep installed must not change what they assert.
    const result = try grep(io, allocator, .{ .pattern = "needle", .path = dir, .glob = null, .ignore_case = false });
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "note.txt:2:the needle is here") != null);
}

test "grep expands path globs without interpreting user input as shell source" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "docs space", .default_dir);
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "docs space/README.md", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs space/README zh.md", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs space/README $(printf INJECTED).md", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/README.md", .data = "needle\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.md", .data = "needle\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // Always exercise grep; also exercise rg when available on the test host.
    const probe = std.process.run(allocator, io, .{ .argv = &.{ "rg", "--version" } }) catch null;
    defer if (probe) |result| {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    };
    const have_rg = if (probe) |result| switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    } else false;
    for ([_]bool{ false, true }) |use_rg| {
        if (use_rg and !have_rg) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/docs */README*", .{dir});
        defer allocator.free(path);
        const result = try (if (use_rg) &rg else &grep)(io, allocator, .{
            .pattern = "needle",
            .path = path,
            .glob = null,
            .ignore_case = false,
        });
        defer result.deinit(allocator);
        try std.testing.expect(!result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "README.md:1:needle") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "README zh.md:1:needle") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "README $(printf INJECTED).md:1:needle") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "nested/") == null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "other.md") == null);

        const missing_path = try std.fmt.allocPrint(allocator, "{s}/missing*", .{dir});
        defer allocator.free(missing_path);
        const missing = try (if (use_rg) &rg else &grep)(io, allocator, .{
            .pattern = "needle",
            .path = missing_path,
            .glob = null,
            .ignore_case = false,
        });
        defer missing.deinit(allocator);
        try std.testing.expect(missing.is_error);
    }
}
