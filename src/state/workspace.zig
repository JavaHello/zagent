//! Global, canonical-directory-scoped state and explicit workspace trust.
const std = @import("std");

pub fn rootForPath(a: std.mem.Allocator, env: *const std.process.Environ.Map, canonical: []const u8) ![]u8 {
    const history = (try @import("../cli/history.zig").statePath(a, env)) orelse return error.HomeNotSet;
    defer a.free(history);
    const base = std.fs.path.dirname(history).?;
    if (!std.fs.path.isAbsolute(base)) return error.StateDirectoryMustBeAbsolute;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    return std.fmt.allocPrint(a, "{s}/workspaces/{s}", .{ base, std.fmt.bytesToHex(digest, .lower) });
}

pub fn root(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]u8 {
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(canonical);
    return rootForPath(a, env, canonical);
}

pub fn filePath(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, name: []const u8) ![]u8 {
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(canonical);
    return filePathFor(a, env, canonical, name);
}

/// The state file for a directory whose canonical form is already known.
fn filePathFor(a: std.mem.Allocator, env: *const std.process.Environ.Map, canonical: []const u8, name: []const u8) ![]u8 {
    const base = try rootForPath(a, env, canonical);
    defer a.free(base);
    return std.fs.path.join(a, &.{ base, name });
}

pub fn isTrusted(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !bool {
    // The canonical directory is resolved once and used for both the state
    // path and the comparison it is stored against.
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(canonical);
    const path = try filePathFor(a, env, canonical, "trusted");
    defer a.free(path);
    const saved = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer a.free(saved);
    return std.mem.eql(u8, saved, canonical);
}

pub fn trust(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(canonical);
    const path = try filePathFor(a, env, canonical, "trusted");
    defer a.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, canonical);
}

test "global workspace keys are stable and directory specific" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", "/state");
    const first = try rootForPath(a, &env, "/project/a");
    defer a.free(first);
    const again = try rootForPath(a, &env, "/project/a");
    defer a.free(again);
    const other = try rootForPath(a, &env, "/project/b");
    defer a.free(other);
    try std.testing.expectEqualStrings(first, again);
    try std.testing.expect(!std.mem.eql(u8, first, other));
    try std.testing.expect(std.mem.startsWith(u8, first, "/state/zagent/workspaces/"));
    try std.testing.expectEqual(@as(usize, 64), std.fs.path.basename(first).len);
}
