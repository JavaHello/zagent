//! Linux tool boundary. Never falls back to unsandboxed execution.
const std = @import("std");
const tools = @import("tools.zig");

/// Returned argv borrows workspace, executable and command. Free the slice only.
pub fn argv(allocator: std.mem.Allocator, workspace: []const u8, executable: ?[]const u8, network: bool, command: []const []const u8) ![][]const u8 {
    if (!std.fs.path.isAbsolute(workspace) or std.mem.eql(u8, workspace, "/")) return error.UnsafeWorkspace;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{
        "/usr/bin/timeout",  "--signal=KILL", "180",           "/usr/bin/bwrap",
        "--die-with-parent", "--new-session", "--unshare-all",
    });
    if (network) try list.append(allocator, "--share-net");
    try list.appendSlice(allocator, &.{
        "--ro-bind",        "/usr",          "/usr",           "--symlink",      "usr/bin",       "/bin",
        "--symlink",        "usr/sbin",      "/sbin",          "--symlink",      "usr/lib",       "/lib",
        "--symlink",        "usr/lib64",     "/lib64",         "--proc",         "/proc",         "--dev",
        "/dev",             "--tmpfs",       "/tmp",           "--dir",          "/tmp/home",     "--dir",
        "/etc",             "--ro-bind-try", "/etc/ssl/certs", "/etc/ssl/certs", "--ro-bind-try", "/etc/resolv.conf",
        "/etc/resolv.conf", "--ro-bind-try", "/etc/hosts",     "/etc/hosts",     "--bind",        workspace,
        workspace,          "--chdir",       workspace,        "--clearenv",     "--setenv",      "PATH",
        "/usr/bin:/bin",    "--setenv",      "HOME",           "/tmp/home",      "--setenv",      "LANG",
        "C.UTF-8",
    });
    if (executable) |exe| try list.appendSlice(allocator, &.{ "--ro-bind", exe, "/zagent-worker" });
    try list.append(allocator, "--");
    try list.appendSlice(allocator, command);
    return list.toOwnedSlice(allocator);
}

pub fn execute(io: std.Io, allocator: std.mem.Allocator, network: bool, name: []const u8, arguments: []const u8) !tools.ToolResult {
    // Linux limits each argument to 128 KiB. Report it without running anything.
    if (arguments.len > 120 * 1024) return .{ .content = try allocator.dupe(u8, "Tool arguments exceed 120 KiB; split the operation into smaller patches."), .is_error = true };
    const workspace = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);
    // Linux appends this marker when an upgrade atomically replaces the running
    // image. Resolve the installed replacement rather than passing the marker.
    const deleted = " (deleted)";
    const worker_path = if (std.mem.endsWith(u8, exe, deleted)) exe[0 .. exe.len - deleted.len] else exe;
    const command = try argv(allocator, workspace, worker_path, network, &.{ "/zagent-worker", "--tool-worker", name, arguments });
    defer allocator.free(command);
    const timeout = shellTimeout(allocator, name, arguments) catch return .{
        .content = try allocator.dupe(u8, "Invalid timeout_seconds: use an integer from 1 to 3600."),
        .is_error = true,
    };
    const deadline = try std.fmt.allocPrint(allocator, "{d}", .{timeout});
    defer allocator.free(deadline);
    command[2] = deadline;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    const result = std.process.run(allocator, io, .{
        .argv = command,
        .environ_map = &env,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| return .{
        .content = try std.fmt.allocPrint(allocator, "Sandbox failed ({s}). Install bubblewrap and GNU timeout; no tool ran outside the sandbox.", .{@errorName(err)}),
        .is_error = true,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return .{
        .content = try std.fmt.allocPrint(allocator, "Sandbox failed or tool timed out: {s}", .{result.stderr}),
        .is_error = true,
    };
    const parsed = std.json.parseFromSlice(tools.ToolResult, allocator, result.stdout, .{ .allocate = .alloc_always }) catch return .{
        .content = try allocator.dupe(u8, "Sandbox worker returned an invalid result."),
        .is_error = true,
    };
    defer parsed.deinit();
    return .{ .content = try allocator.dupe(u8, parsed.value.content), .is_error = parsed.value.is_error };
}

test "sandbox argv requires a bounded workspace" {
    try std.testing.expectError(error.UnsafeWorkspace, argv(std.testing.allocator, "/", null, false, &.{"true"}));
    try std.testing.expectError(error.UnsafeWorkspace, argv(std.testing.allocator, ".", null, false, &.{"true"}));
    const args = try argv(std.testing.allocator, "/work", null, false, &.{"true"});
    defer std.testing.allocator.free(args);
    for (args) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--share-net"));
}

fn shellTimeout(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8) !u32 {
    if (!std.mem.eql(u8, name, "shell")) return 180;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const value = parsed.value.object.get("timeout_seconds") orelse return 180;
    if (value != .integer or value.integer < 1 or value.integer > 3600) return error.InvalidTimeout;
    return @intCast(value.integer);
}

test "shell timeout is bounded and applies only to commands" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 180), try shellTimeout(a, "shell", "{}"));
    try std.testing.expectEqual(@as(u32, 600), try shellTimeout(a, "shell", "{\"timeout_seconds\":600}"));
    try std.testing.expectEqual(@as(u32, 180), try shellTimeout(a, "read_file", "{\"timeout_seconds\":600}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "shell", "{\"timeout_seconds\":0}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "shell", "{\"timeout_seconds\":3601}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "shell", "{\"timeout_seconds\":\"600\"}"));
}
