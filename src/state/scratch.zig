//! The one scratch directory a run owns. Nothing in it is meant to outlive the
//! process: the whole tree — files included — is removed at exit, and a new
//! session empties it so the next conversation starts from a clean path.
const std = @import("std");

pub const Scratch = struct {
    io: std.Io,
    path: []u8,

    /// Create the directory this run owns: a random name created exclusively
    /// under `$TMPDIR` (or `/tmp` when it is unset). Every agent started at the
    /// same time arrives at a different path, and a pre-existing directory is
    /// never adopted.
    pub fn init(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map) !Scratch {
        const base = env.get("TMPDIR") orelse "/tmp";
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, base, a);
        defer a.free(canonical);
        var bytes: [16]u8 = undefined;
        std.Io.random(io, &bytes);
        const path = try std.fmt.allocPrint(a, "{s}/zagent-{s}", .{ canonical, std.fmt.bytesToHex(bytes, .lower) });
        errdefer std.Io.Dir.cwd().deleteDir(io, path) catch {};
        errdefer a.free(path);
        try std.Io.Dir.createDirAbsolute(io, path, .fromMode(0o700));
        return .{ .io = io, .path = path };
    }

    /// Empty the directory without moving it, for `/new`: the files of the
    /// conversation being abandoned belong to that conversation, but the system
    /// prompt names one path for the life of the process, so the path stays.
    /// A run that already removed the directory itself gets an empty one back.
    pub fn reset(self: *Scratch) !void {
        try std.Io.Dir.cwd().deleteTree(self.io, self.path);
        std.Io.Dir.createDirAbsolute(self.io, self.path, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    /// Remove the whole tree, whatever the run left in it: the directory is
    /// temporary, and anything worth keeping was supposed to be copied out.
    /// Already gone — the model may have deleted it itself — is not an error.
    pub fn deinit(self: *Scratch, a: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        a.free(self.path);
        self.* = undefined;
    }
};

test "each run gets its own private scratch directory" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("TMPDIR", base);

    var first = try Scratch.init(io, a, &env);
    var second = try Scratch.init(io, a, &env);
    const first_path = try a.dupe(u8, first.path);
    defer a.free(first_path);
    const second_path = try a.dupe(u8, second.path);
    defer a.free(second_path);
    try std.testing.expect(!std.mem.eql(u8, first_path, second_path));

    for ([_][]const u8{ first_path, second_path }) |path| {
        try std.testing.expect(std.mem.startsWith(u8, path, base));
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    }

    // `reset` keeps the path and drops the contents, so a new session starts
    // from an empty directory the system prompt already names.
    var dir = try std.Io.Dir.openDirAbsolute(io, first_path, .{});
    try dir.writeFile(io, .{ .sub_path = "script.sh", .data = "printf scratch" });
    try dir.createDir(io, "build", .fromMode(0o755));
    try dir.writeFile(io, .{ .sub_path = "build/out.log", .data = "log" });
    dir.close(io);

    try first.reset();
    try std.testing.expectEqualStrings(first_path, first.path);
    var emptied = try std.Io.Dir.openDirAbsolute(io, first_path, .{});
    var it = emptied.iterate();
    try std.testing.expect((try it.next(io)) == null);
    emptied.close(io);

    // Nothing outlives the run: files are removed with the directory, and the
    // one this run owns is gone once the agent lets go of it.
    var kept = try std.Io.Dir.openDirAbsolute(io, second_path, .{});
    try kept.writeFile(io, .{ .sub_path = "kept.txt", .data = "kept" });
    kept.close(io);
    first.deinit(a);
    second.deinit(a);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, first_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, second_path, .{}));

    // The model may delete the directory itself; neither `reset` nor the exit
    // cleanup treats that as a failure.
    var third = try Scratch.init(io, a, &env);
    try std.Io.Dir.cwd().deleteTree(io, third.path);
    try third.reset();
    try std.testing.expect((try std.Io.Dir.cwd().statFile(io, third.path, .{})).kind == .directory);
    try std.Io.Dir.cwd().deleteTree(io, third.path);
    third.deinit(a);
}
