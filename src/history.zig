const std = @import("std");
const Linenoise = @import("linenoise").Linenoise;

/// Prompts are remembered between runs, so ↑ recalls what was asked in an
/// earlier session and not just in this one. None of this is required for a
/// session to work: every failure here is swallowed, because a REPL that
/// cannot write its history file still has to be usable.

/// Resolve the file that remembers prompts between runs:
/// `$XDG_STATE_HOME/zagent/history`, or `~/.local/state/zagent/history` when
/// `XDG_STATE_HOME` is not set. Null when the environment names no home
/// directory, which leaves the REPL without a history on disk.
///
/// State rather than config: this is data the program produces, not something
/// the user writes, and it is not worth carrying between machines.
pub fn statePath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (nonEmpty(env, "XDG_STATE_HOME")) |state_home| {
        return try std.fmt.allocPrint(allocator, "{s}/zagent/history", .{state_home});
    }
    if (nonEmpty(env, "HOME")) |home| {
        return try std.fmt.allocPrint(allocator, "{s}/.local/state/zagent/history", .{home});
    }
    return null;
}

/// Recall the prompts stored at `path` into `ln`, creating the directory the
/// file lives in when it is not there yet. Reports whether the history can be
/// persisted, so that a session which cannot save turns saving off instead of
/// repeating the same failure on every line.
pub fn load(io: std.Io, ln: *Linenoise, path: []const u8) bool {
    ln.history.load(io, path) catch |err| switch (err) {
        // Nothing stored yet, and possibly nowhere to put it: the directory is
        // created now so that the first save has somewhere to land.
        error.FileNotFound => prepareDir(io, path) catch return false,
        // Reading failed for a reason a write is likely to share, so this
        // session runs with an empty history rather than a broken one.
        else => return false,
    };
    return true;
}

/// Replace the stored prompts with the ones `ln` holds. A failure is ignored:
/// the prompts stay in this session's history either way, and there is nothing
/// useful to tell the user about a file they did not ask for.
pub fn save(io: std.Io, ln: *Linenoise, path: []const u8) void {
    ln.history.save(io, path) catch {};
}

/// The value of an environment variable, treating an empty one as unset.
fn nonEmpty(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

fn prepareDir(io: std.Io, path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.BadPathName;
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
}

/// Build a hermetic environment map, so the developer's own shell cannot reach
/// these tests and no real history file is ever touched.
fn testEnv(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();
    for (pairs) |pair| try env.put(pair[0], pair[1]);
    return env;
}

test "the history file lives under the state directory" {
    const allocator = std.testing.allocator;

    {
        var env = try testEnv(allocator, &.{
            .{ "XDG_STATE_HOME", "/state" },
            .{ "HOME", "/home/user" },
        });
        defer env.deinit();

        const path = (try statePath(allocator, &env)).?;
        defer allocator.free(path);
        try std.testing.expectEqualStrings("/state/zagent/history", path);
    }

    {
        var env = try testEnv(allocator, &.{.{ "HOME", "/home/user" }});
        defer env.deinit();

        const path = (try statePath(allocator, &env)).?;
        defer allocator.free(path);
        try std.testing.expectEqualStrings("/home/user/.local/state/zagent/history", path);
    }

    {
        // An empty variable means "not set", as it does for the configuration.
        var env = try testEnv(allocator, &.{
            .{ "XDG_STATE_HOME", "" },
            .{ "HOME", "/home/user" },
        });
        defer env.deinit();

        const path = (try statePath(allocator, &env)).?;
        defer allocator.free(path);
        try std.testing.expectEqualStrings("/home/user/.local/state/zagent/history", path);
    }

    {
        var env = try testEnv(allocator, &.{});
        defer env.deinit();

        try std.testing.expectEqual(@as(?[]u8, null), try statePath(allocator, &env));
    }
}

/// A history file in a directory that does not exist until something creates
/// it: `load` does, or `ensureDir` for a test that writes the file itself.
const TestFile = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !TestFile {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir_path);
        const path = try std.fmt.allocPrint(allocator, "{s}/nested/history", .{dir_path});
        return .{ .tmp = tmp, .path = path, .allocator = allocator };
    }

    /// Create the directory the file lives in, for tests that write the file
    /// themselves instead of letting `load` do it.
    fn ensureDir(self: *TestFile) !void {
        try self.tmp.dir.createDirPath(std.testing.io, "nested");
    }

    fn deinit(self: *TestFile) void {
        self.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

/// A terminal attached to `env`, with `lines` in its history.
fn testTerminal(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, lines: []const []const u8) !Linenoise {
    var ln = Linenoise.init(allocator, std.testing.io, env);
    errdefer ln.deinit();
    for (lines) |line| try ln.history.add(line);
    return ln;
}

test "prompts are recalled by the next session" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env = try testEnv(allocator, &.{});
    defer env.deinit();

    var file = try TestFile.init(allocator);
    defer file.deinit();

    var first = try testTerminal(allocator, &env, &.{ "list the zig files", "now fix the build" });
    defer first.deinit();

    // The directory does not exist yet: loading reports that history can be
    // saved, having created it, rather than turning persistence off.
    try std.testing.expect(load(io, &first, file.path));
    save(io, &first, file.path);

    var second = try testTerminal(allocator, &env, &.{});
    defer second.deinit();

    try std.testing.expect(load(io, &second, file.path));
    try std.testing.expectEqual(@as(usize, 2), second.history.hist.items.len);
    try std.testing.expectEqualStrings("list the zig files", second.history.hist.items[0]);
    try std.testing.expectEqualStrings("now fix the build", second.history.hist.items[1]);
}

test "saving replaces what an earlier session stored" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env = try testEnv(allocator, &.{});
    defer env.deinit();

    var file = try TestFile.init(allocator);
    defer file.deinit();
    try file.ensureDir();

    var previous = try testTerminal(allocator, &env, &.{ "an earlier question", "and another" });
    defer previous.deinit();
    save(io, &previous, file.path);

    var current = try testTerminal(allocator, &env, &.{"a new question"});
    defer current.deinit();
    save(io, &current, file.path);

    var next = try testTerminal(allocator, &env, &.{});
    defer next.deinit();
    try std.testing.expect(load(io, &next, file.path));

    // The file is rewritten rather than appended to, so what an earlier
    // session stored cannot outlive a save that no longer holds it.
    try std.testing.expectEqual(@as(usize, 1), next.history.hist.items.len);
    try std.testing.expectEqualStrings("a new question", next.history.hist.items[0]);
}

test "an entry too long to store is left out of the file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env = try testEnv(allocator, &.{});
    defer env.deinit();

    var file = try TestFile.init(allocator);
    defer file.deinit();
    try file.ensureDir();

    const long = try allocator.alloc(u8, 8192);
    defer allocator.free(long);
    @memset(long, 'x');

    var ln = try testTerminal(allocator, &env, &.{ long, "a question worth keeping" });
    defer ln.deinit();
    save(io, &ln, file.path);

    // The long entry is still recalled in this session; it just cannot be read
    // back, so writing it would take the entry after it down on the next load.
    try std.testing.expectEqual(@as(usize, 2), ln.history.hist.items.len);

    var next = try testTerminal(allocator, &env, &.{});
    defer next.deinit();
    try std.testing.expect(load(io, &next, file.path));

    try std.testing.expectEqual(@as(usize, 1), next.history.hist.items.len);
    try std.testing.expectEqualStrings("a question worth keeping", next.history.hist.items[0]);
}

test "an over-long line does not cost the lines after it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env = try testEnv(allocator, &.{});
    defer env.deinit();

    var file = try TestFile.init(allocator);
    defer file.deinit();
    try file.ensureDir();

    // A file that this program would not have written: one unreadable line
    // between two good ones.
    const long = try allocator.alloc(u8, 9000);
    defer allocator.free(long);
    @memset(long, 'y');

    const contents = try std.fmt.allocPrint(allocator, "before\n{s}\nafter\n", .{long});
    defer allocator.free(contents);

    const handle = try std.Io.Dir.createFileAbsolute(io, file.path, .{});
    {
        defer handle.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = handle.writer(io, &write_buf);
        try writer.interface.writeAll(contents);
        try writer.interface.flush();
    }

    var ln = try testTerminal(allocator, &env, &.{});
    defer ln.deinit();
    try std.testing.expect(load(io, &ln, file.path));

    try std.testing.expectEqual(@as(usize, 2), ln.history.hist.items.len);
    try std.testing.expectEqualStrings("before", ln.history.hist.items[0]);
    try std.testing.expectEqualStrings("after", ln.history.hist.items[1]);
}

test "a history that cannot be read turns persistence off" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env = try testEnv(allocator, &.{});
    defer env.deinit();

    var ln = try testTerminal(allocator, &env, &.{});
    defer ln.deinit();

    // A directory where the file should be: reading fails with something other
    // than "not found", which a save would only repeat.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir_path);

    try std.testing.expect(!load(io, &ln, dir_path));
}
