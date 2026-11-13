const std = @import("std");
const args_mod = @import("args.zig");
const result_mod = @import("result.zig");
const util = @import("util.zig");
const host_exec = @import("../host/exec.zig");

const ToolResult = result_mod.ToolResult;
const ToolStatus = result_mod.ToolStatus;
const toolError = result_mod.toolError;
const ownedResult = result_mod.ownedResult;
const lessString = util.lessString;
const fixturePath = util.fixturePath;
const optionalUnsigned = args_mod.optionalUnsigned;
const optionalBool = args_mod.optionalBool;
const optionalString = args_mod.optionalString;
const searchPath = args_mod.searchPath;

/// Which search programs are installed. Decided once, in `Agent.init`, so a
/// search never has to ask the filesystem mid-answer — the same reasoning that
/// keeps `render_markdown` out of the answer path.
pub const SearchBackends = struct {
    /// Search file contents with ripgrep rather than grep.
    rg: bool = false,
    /// Look for files with fd rather than find.
    fd: bool = false,
};

/// Look for `rg` and `fd` on the PATH `env` carries.
///
/// Zig has no `which` to call: there is no `std.process.findExecutable`, and no
/// `std.posix.getenv` to hand one a path. The directories are walked here
/// instead, over the same PATH a spawned program will be resolved with.
pub fn detectSearchBackends(io: std.Io, env: *const std.process.Environ.Map) SearchBackends {
    const path = env.get("PATH") orelse return .{};
    return .{
        .rg = isOnPath(io, path, "rg"),
        .fd = isOnPath(io, path, "fd"),
    };
}

/// Whether an executable file named `name` sits in one of the `path` directories.
fn isOnPath(io: std.Io, path: []const u8, name: []const u8) bool {
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (dirs.next()) |dir| {
        // An empty entry means the working directory. It is skipped rather than
        // searched: picking up a search program from whatever directory the
        // agent happens to be sitting in is not something a `which` needs to do.
        if (dir.len == 0) continue;
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (isExecutableFile(io, candidate)) return true;
    }
    return false;
}

fn isExecutableFile(io: std.Io, path: []const u8) bool {
    // `statFile` follows symlinks, which is what makes a Homebrew install
    // (/opt/homebrew/bin/rg -> ../Cellar/ripgrep/.../rg) count as present.
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        if (stat.permissions.toMode() & 0o111 == 0) return false;
    }
    return true;
}

/// A grep tool call as the model described it. Owns its strings.
pub const GrepArgs = struct {
    /// A regular expression: ripgrep syntax for rg, extended syntax for grep.
    pattern: []const u8,
    /// The file or directory to search.
    path: []const u8,
    /// Only search files whose names match this glob.
    glob: ?[]const u8,
    ignore_case: bool,
    context_lines: ?usize = null,
    max_matches: ?usize = null,
    hidden: bool = false,
    no_ignore: bool = false,

    pub fn deinit(self: GrepArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        allocator.free(self.path);
        if (self.glob) |glob| allocator.free(glob);
    }
};

/// Parse a grep tool call's arguments.
pub fn parseGrepArgs(allocator: std.mem.Allocator, arguments_json: []const u8) !GrepArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const arguments = parsed.value.object;

    // A search with no pattern is not a wide search, it is a missing argument:
    // every line of every file is what an empty pattern would match, and that
    // answer is worth neither the wait nor the tool result.
    const pattern_value = arguments.get("pattern") orelse return error.MissingPattern;
    if (pattern_value != .string or pattern_value.string.len == 0) return error.MissingPattern;
    const pattern = try allocator.dupe(u8, pattern_value.string);
    errdefer allocator.free(pattern);

    const path = try searchPath(allocator, arguments.get("path"));
    errdefer allocator.free(path);
    const glob = try optionalString(allocator, arguments.get("glob"));
    errdefer if (glob) |value| allocator.free(value);

    return .{
        .pattern = pattern,
        .path = path,
        .glob = glob,
        .ignore_case = try optionalBool(arguments.get("ignore_case")),
        .context_lines = try optionalUnsigned(arguments.get("context_lines"), 0),
        .max_matches = try optionalUnsigned(arguments.get("max_matches"), 1),
        .hidden = try optionalBool(arguments.get("hidden")),
        .no_ignore = try optionalBool(arguments.get("no_ignore")),
    };
}

/// A find tool call as the model described it. Owns its strings.
pub const FindArgs = struct {
    /// A glob the name has to match, e.g. `*.zig`. Not a regular expression.
    pattern: []const u8,
    path: []const u8,
    hidden: bool = false,
    no_ignore: bool = false,

    pub fn deinit(self: FindArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        allocator.free(self.path);
    }
};

/// Parse a find tool call's arguments.
pub fn parseFindArgs(allocator: std.mem.Allocator, arguments_json: []const u8) !FindArgs {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const arguments = parsed.value.object;

    const pattern_value = arguments.get("pattern") orelse return error.MissingPattern;
    if (pattern_value != .string or pattern_value.string.len == 0) return error.MissingPattern;
    const pattern = try allocator.dupe(u8, pattern_value.string);
    errdefer allocator.free(pattern);

    const path = try searchPath(allocator, arguments.get("path"));
    errdefer allocator.free(path);

    return .{
        .pattern = pattern,
        .path = path,
        .hidden = try optionalBool(arguments.get("hidden")),
        .no_ignore = try optionalBool(arguments.get("no_ignore")),
    };
}

/// Build the argv for one grep call.
///
/// Borrows args and literals, but owns numeric flags. Free with freeGrepArgv.
pub fn freeGrepArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    freeGrepFlags(allocator, argv);
    allocator.free(argv);
}

pub fn freeGrepFlags(allocator: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;
    const start: usize = if (std.mem.eql(u8, argv[0], "rg")) 4 else 6;
    if (argv.len <= start) return;
    // Only the numeric flags immediately following the fixed backend flags
    // are owned. Glob and pattern strings may contain flag-looking text.
    for (argv[start..]) |arg| {
        if (!std.mem.startsWith(u8, arg, "--context=") and !std.mem.startsWith(u8, arg, "--max-count=")) break;
        allocator.free(arg);
    }
}

pub fn appendGrepLimits(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: GrepArgs) !void {
    if (args.context_lines) |number| {
        const flag = try std.fmt.allocPrint(allocator, "--context={d}", .{number});
        errdefer allocator.free(flag);
        try argv.append(allocator, flag);
    }
    if (args.max_matches) |number| {
        const flag = try std.fmt.allocPrint(allocator, "--max-count={d}", .{number});
        errdefer allocator.free(flag);
        try argv.append(allocator, flag);
    }
}

/// Longest search output read back before the search is given up on. Much
/// larger than the 8 KB a result is finally cut to, so that an ordinary search
/// over a large repository comes back truncated rather than refused.
const search_max_output: usize = 256 * 1024;

/// Longest error output read back from a search program.
const search_stderr_max: usize = 64 * 1024;

/// How long a search program may run. A search that has not answered in three
/// minutes is one the call has to narrow and try again.
pub const search_timeout_seconds: u32 = 180;

/// Collects a search program's output, refusing to hold more of it than a
/// result could use: a pattern that matches everything must not be able to fill
/// this process's memory before the page is shaped.
const Capture = struct {
    allocator: std.mem.Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,

    pub fn feed(self: *Capture, io: std.Io, stream: host_exec.Stream, data: []const u8) !void {
        _ = io;
        const list, const limit = switch (stream) {
            .stdout => .{ &self.stdout, search_max_output },
            .stderr => .{ &self.stderr, search_stderr_max },
        };
        if (list.items.len + data.len > limit) return error.StreamTooLong;
        try list.appendSlice(self.allocator, data);
    }

    fn deinit(self: *Capture) void {
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
    }
};

/// Run a search program and shape its output into a tool result.
///
/// `exit_one_is_no_match` is the one way the two search tools differ. grep and
/// rg report a search that matched nothing with exit code 1, which is an answer
/// and not a failure; fd and find report it with a zero exit and no output, and
/// keep every nonzero code for an error — fd also uses 1 for a path it could
/// not search. A program killed by a signal is never an answer, whichever tool
/// asked for it.
pub fn runSearch(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    exit_one_is_no_match: bool,
) !ToolResult {
    return runSearchTimed(io, allocator, argv, exit_one_is_no_match, search_timeout_seconds);
}

pub fn runSearchTimed(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    exit_one_is_no_match: bool,
    timeout_seconds: u32,
) !ToolResult {
    var captured: Capture = .{ .allocator = allocator };
    defer captured.deinit();
    const run = host_exec.run(io, allocator, .{
        .argv = argv,
        .timeout_seconds = timeout_seconds,
    }, &captured) catch |err| switch (err) {
        // The sink refuses the whole result once the limit is passed, so there
        // is nothing of it worth showing; the model is told what to do instead.
        error.StreamTooLong => return toolError(
            allocator,
            "Error: the search matched more output than the tool reads. Narrow it with a 'glob' or a more specific 'pattern'.",
            .{},
        ),
        // A program that could not be started at all is reported rather than
        // failing the turn over, so the model can fall back to the shell.
        else => return toolError(allocator, "Error: could not run '{s}': {s}", .{ argv[0], @errorName(err) }),
    };

    if (run.timed_out) return toolError(
        allocator,
        "Error: '{s}' ran for more than {d}s and was stopped. Narrow the 'path', 'glob' or 'pattern'.",
        .{ argv[0], timeout_seconds },
    );

    // A program that died from a signal is not an answer, whatever the code it
    // would have carried means: `null` marks it as a failure below.
    const exit_code = run.exitCode();
    const no_matches = exit_one_is_no_match and exit_code != null and exit_code.? == 1;
    const is_error = exit_code == null or (exit_code.? != 0 and !no_matches);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // What the search program printed is handed on as it printed it: a match
    // is quoted, copied or patched from, so a rewritten line would not be the
    // line it matched.
    if (captured.stdout.items.len > 0) try aw.writer.writeAll(captured.stdout.items);
    if (captured.stderr.items.len > 0) {
        if (aw.written().len > 0) try aw.writer.writeAll("\n");
        try aw.writer.writeAll("stderr: ");
        try aw.writer.writeAll(captured.stderr.items);
    }
    if (aw.written().len == 0) {
        // A search that matched nothing is the one thing this tool answers with
        // no output at all. Any other silent exit is a failure, and says that.
        try aw.writer.writeAll(if (is_error) "(no output)" else "(no matches)");
    }

    return searchPage(allocator, aw.written(), !exit_one_is_no_match, .{
        .is_error = is_error,
        .exit_code = exit_code,
    });
}

pub fn searchPage(allocator: std.mem.Allocator, output: []const u8, sort: bool, status: ToolStatus) !ToolResult {
    if (std.mem.eql(u8, output, "(no matches)"))
        return ownedResult(try allocator.dupe(u8, output), status);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, output, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    if (sort) std.mem.sort([]const u8, lines.items, {}, lessString);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var index: usize = 0;
    while (index < lines.items.len) : (index += 1) {
        try aw.writer.print("{s}\n", .{lines.items[index]});
    }
    return ownedResult(try aw.toOwnedSlice(), status);
}

pub fn runContentSearch(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, args: GrepArgs) !ToolResult {
    if (std.mem.indexOfAny(u8, args.path, "*?[") != null) {
        // Match the shell's pathname expansion, not rg's recursive --glob
        // filter: README* must only select entries in the current directory.
        // Pass all user input as positional arguments, never as shell source.
        // Empty IFS prevents splitting paths containing spaces; expansion does
        // not evaluate substitutions/operators contained in the path. An
        // unmatched glob stays literal, preserving the backend's error.
        var expanded: std.ArrayList([]const u8) = .empty;
        defer expanded.deinit(allocator);
        try expanded.appendSlice(allocator, &.{
            "sh", "-c", "path=$1; shift; IFS=; exec \"$@\" $path", "zagent-search", args.path,
        });
        try expanded.appendSlice(allocator, argv[0 .. argv.len - 1]);
        return runSearch(io, allocator, expanded.items, true);
    }
    return runSearch(io, allocator, argv, true);
}

test "search results sort names and preserve complete output and status" {
    const a = std.testing.allocator;
    const sorted = try searchPage(a, "z\na\nm\n", true, .{ .is_error = false, .exit_code = 0 });
    defer sorted.deinit(a);
    try std.testing.expectEqualStrings("a\nm\nz\n", sorted.content);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    const page_lines = @import("ccr.zig").page_room_bytes / "one matching line\n".len;
    while (buffer.items.len < (page_lines + 100) * "one matching line\n".len)
        try buffer.appendSlice(a, "one matching line\n");
    const data = buffer.items;
    const page = try searchPage(a, data, false, .{ .is_error = true, .exit_code = 2 });
    defer page.deinit(a);
    try std.testing.expect(page.is_error);
    try std.testing.expectEqual(@as(?u8, 2), page.exit_code);
    // The cut is reported and the call is narrowed; there is no cursor to resume.
    try std.testing.expect(std.mem.indexOf(u8, page.content, "offset=") == null);
    try std.testing.expectEqualStrings(data, page.content);
}

test "a search program is only found where one can be run" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // An executable `rg`, a plain file `fd`, and a directory named `grep`:
    // only the first is something the tool could run.
    var rg_file = try tmp.dir.createFile(io, "rg", .{ .permissions = std.Io.File.Permissions.fromMode(0o755) });
    rg_file.close(io);
    var fd_file = try tmp.dir.createFile(io, "fd", .{ .permissions = std.Io.File.Permissions.fromMode(0o644) });
    fd_file.close(io);
    try tmp.dir.createDir(io, "grep", std.Io.File.Permissions.default_dir);

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    try std.testing.expect(isOnPath(io, dir, "rg"));
    // A file that is not executable, and a directory that shares the name, are
    // both things a shell would refuse to run.
    try std.testing.expect(!isOnPath(io, dir, "fd"));
    try std.testing.expect(!isOnPath(io, dir, "grep"));
    try std.testing.expect(!isOnPath(io, dir, "definitely-not-here"));
    // An empty entry means the working directory, which is not searched.
    try std.testing.expect(!isOnPath(io, ":", "rg"));
}

test "parse grep args defaults to the current directory" {
    const allocator = std.testing.allocator;
    const args = try parseGrepArgs(allocator, "{\"pattern\":\"needle\"}");
    defer args.deinit(allocator);

    try std.testing.expectEqualStrings("needle", args.pattern);
    try std.testing.expectEqualStrings(".", args.path);
    try std.testing.expect(args.glob == null);
    try std.testing.expect(!args.ignore_case);
}

test "parse a search rejects the arguments it cannot use" {
    const allocator = std.testing.allocator;

    // An empty pattern matches every line of every file, which is a missing
    // argument rather than a wide search.
    try std.testing.expectError(error.MissingPattern, parseGrepArgs(allocator, "{}"));
    try std.testing.expectError(error.MissingPattern, parseGrepArgs(allocator, "{\"pattern\":\"\"}"));
    try std.testing.expectError(error.MissingPattern, parseGrepArgs(allocator, "{\"pattern\":7}"));
    try std.testing.expectError(error.MissingPattern, parseFindArgs(allocator, "{}"));
    try std.testing.expectError(error.InvalidArguments, parseGrepArgs(allocator, "[]"));
    try std.testing.expectError(error.InvalidArguments, parseFindArgs(allocator, "[]"));
    // A flag sent as a string is not a flag: the arguments are typed, and
    // guessing here would let the model write the command line after all.
    try std.testing.expectError(error.InvalidArguments, parseGrepArgs(allocator, "{\"pattern\":\"x\",\"ignore_case\":\"yes\"}"));
}

test "a search that outruns the limit is refused with advice" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // `yes` writes without end, which is the shape of output this tool cannot
    // read at all: std refuses the whole result once the cap is passed rather
    // than handing back the beginning of it.
    const result = try runSearch(io, allocator, &.{"yes"}, true);
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Narrow it") != null);
}
