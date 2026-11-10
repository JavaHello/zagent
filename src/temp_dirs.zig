//! Session-owned scratch directories. Files deliberately outlive the process.
const std = @import("std");

pub const State = struct {
    paths: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        for (self.paths.items) |path| a.free(path);
        self.paths.deinit(a);
        self.* = .{};
    }

    /// Restore only directories that still exist; never recreate deleted paths.
    pub fn restore(self: *State, io: std.Io, a: std.mem.Allocator, paths: []const []const u8) !void {
        for (paths) |path| {
            if (!std.fs.path.isAbsolute(path)) continue;
            var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.SymLinkLoop => continue,
                else => return err,
            };
            dir.close(io);
            const owned = try a.dupe(u8, path);
            errdefer a.free(owned);
            try self.paths.append(a, owned);
        }
    }

    pub fn create(self: *State, io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
        const base = env.get("TMPDIR") orelse "/tmp";
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, base, a);
        defer a.free(canonical);
        var bytes: [16]u8 = undefined;
        std.Io.random(io, &bytes);
        const path = try std.fmt.allocPrint(a, "{s}/zagent-{s}", .{ canonical, std.fmt.bytesToHex(bytes, .lower) });
        errdefer a.free(path);
        // Exclusive creation: never adopt a pre-existing directory.
        try std.Io.Dir.createDirAbsolute(io, path, .fromMode(0o700));
        errdefer std.Io.Dir.cwd().deleteDir(io, path) catch {};
        try self.paths.append(a, path);
        return path;
    }
};

test "scratch directories are unique, reusable, and not recreated after deletion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("TMPDIR", base);
    var state: State = .{};
    defer state.deinit(a);
    const first = try state.create(io, a, &env);
    const second = try state.create(io, a, &env);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    var dir = try std.Io.Dir.openDirAbsolute(io, first, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "script.sh", .data = "printf reused" });
    try std.Io.Dir.cwd().deleteDir(io, second);
    var restored: State = .{};
    defer restored.deinit(a);
    try restored.restore(io, a, state.paths.items);
    try std.testing.expectEqual(@as(usize, 1), restored.paths.items.len);
    try std.testing.expectEqualStrings(first, restored.paths.items[0]);
    const data = try dir.readFileAlloc(io, "script.sh", a, .limited(100));
    defer a.free(data);
    try std.testing.expectEqualStrings("printf reused", data);
}
