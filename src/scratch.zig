//! The one scratch directory a run owns. Files deliberately outlive the
//! process; an empty directory does not, so a run that discarded nothing leaves
//! `$TMPDIR` as it found it.
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

    /// Remove the directory when it is still empty, keeping whatever the run
    /// wrote: `deleteDir` refuses a directory that holds anything, which is
    /// exactly the line to draw between leftover state and a tidy `$TMPDIR`.
    pub fn deinit(self: *Scratch, a: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteDir(self.io, self.path) catch {};
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
    const first_path = try a.dupe(u8, first.path);
    defer a.free(first_path);
    var second = try Scratch.init(io, a, &env);
    defer second.deinit(a);
    try std.testing.expect(!std.mem.eql(u8, first_path, second.path));

    for ([_][]const u8{ first_path, second.path }) |path| {
        try std.testing.expect(std.mem.startsWith(u8, path, base));
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    }

    // An empty directory goes away with the run; files stay where they were
    // written, and a directory holding them is kept.
    var dir = try std.Io.Dir.openDirAbsolute(io, first_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "script.sh", .data = "printf scratch" });
    const data = try dir.readFileAlloc(io, "script.sh", a, .limited(100));
    defer a.free(data);
    first.deinit(a);
    try std.testing.expectEqualStrings("printf scratch", data);
    try std.testing.expect((try std.Io.Dir.cwd().statFile(io, first_path, .{})).kind == .directory);

    var empty = try Scratch.init(io, a, &env);
    const empty_path = try a.dupe(u8, empty.path);
    defer a.free(empty_path);
    empty.deinit(a);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, empty_path, .{}));
}
