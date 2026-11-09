//! Tool boundary. Linux runs tools inside bubblewrap; macOS runs them inside
//! sandbox-exec with an SBPL profile. There is no unsandboxed fallback.
const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools.zig");

const native_os = builtin.os.tag;

/// Independent from network permission. Never falls back to host execution.
pub const Mode = enum { auto, required, off };

/// Probe the real isolation backend, not just whether its executable exists:
/// Linux can install bwrap while disabling unprivileged namespaces.
pub fn available(io: std.Io, allocator: std.mem.Allocator) bool {
    if (native_os != .linux and native_os != .macos) return false;
    const workspace = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch return false;
    defer allocator.free(workspace);
    var l = launch(io, allocator, workspace, null, false, &.{"/bin/true"}, &.{}, 5) catch return false;
    defer l.deinit();
    defer l.releaseTempDir();
    const result = std.process.run(allocator, io, .{
        .argv = l.argv,
        .environ_map = &l.env,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

pub fn initialize(io: std.Io, allocator: std.mem.Allocator, mode: Mode) !bool {
    if (mode == .off) return false;
    if (available(io, allocator)) return true;
    if (mode == .required) return error.SandboxUnavailable;
    try std.Io.File.stderr().writeStreamingAll(io, "Sandbox unavailable; skipping sandbox support. Operations requiring isolation will be refused.\n");
    return false;
}

/// A ready-to-spawn sandboxed command. Owns the argument list and the clean
/// environment. On macOS it also owns a private temp directory that must be
/// released with `releaseTempDir` once the child has exited.
pub const Launch = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: [][]const u8,
    env: std.process.Environ.Map,
    tmp_dir: ?[]u8 = null,
    /// Strings referenced by `argv` that are owned here and freed on deinit.
    owned: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Launch) void {
        self.env.deinit();
        self.allocator.free(self.argv);
        for (self.owned.items) |s| self.allocator.free(s);
        self.owned.deinit(self.allocator);
    }

    /// Remove the macOS private temp directory. Safe to call after the child
    /// has exited; no-op on Linux and idempotent.
    pub fn releaseTempDir(self: *Launch) void {
        if (self.tmp_dir) |d| {
            std.Io.Dir.cwd().deleteTree(self.io, d) catch {};
            self.allocator.free(d);
            self.tmp_dir = null;
        }
    }
};

fn validateWorkspace(workspace: []const u8) !void {
    if (!std.fs.path.isAbsolute(workspace) or std.mem.eql(u8, workspace, "/")) return error.UnsafeWorkspace;
}

/// Build the command line and environment that run `command` inside the
/// sandbox. `workspace` is the resolved absolute directory that is made
/// writable; `executable`, when non-null, is the worker binary exposed
/// read-only inside the sandbox. `extra_env` entries are appended to an
/// otherwise clean environment. `timeout_seconds` bounds the command on Linux
/// through `timeout(1)`; on macOS the caller applies the equivalent limit when
/// waiting on the child.
pub fn launch(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    executable: ?[]const u8,
    network: bool,
    command: []const []const u8,
    extra_env: []const [2][]const u8,
    timeout_seconds: ?u32,
) !Launch {
    try validateWorkspace(workspace);
    if (native_os == .linux) return linuxLaunch(io, allocator, workspace, executable, network, command, extra_env, timeout_seconds);
    if (native_os == .macos) return macosLaunch(io, allocator, workspace, executable, network, command, extra_env);
    return error.UnsupportedSandboxHost;
}

fn linuxLaunch(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    executable: ?[]const u8,
    network: bool,
    command: []const []const u8,
    extra_env: []const [2][]const u8,
    timeout_seconds: ?u32,
) !Launch {
    var owned: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    if (timeout_seconds) |t| {
        const deadline = try std.fmt.allocPrint(allocator, "{d}", .{t});
        try owned.append(allocator, deadline);
        try list.appendSlice(allocator, &.{ "/usr/bin/timeout", "--signal=KILL", deadline, "/usr/bin/bwrap" });
    } else {
        try list.append(allocator, "/usr/bin/bwrap");
    }
    try list.appendSlice(allocator, &.{
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
    for (extra_env) |pair| {
        if (!std.process.Environ.Map.validateKeyForPut(pair[0])) return error.InvalidEnvKey;
        try list.appendSlice(allocator, &.{ "--setenv", pair[0], pair[1] });
    }
    try list.append(allocator, "--");
    try list.appendSlice(allocator, command);

    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

    return .{
        .io = io,
        .allocator = allocator,
        .argv = try list.toOwnedSlice(allocator),
        .env = env,
        .owned = owned,
    };
}

const macos_profile =
    \\(version 1)
    \\(deny default)
    \\(import "system.sb")
    \\(allow process-fork)
    \\(allow process-exec)
    \\(allow process-info*)
    \\(allow signal (target self))
    \\(allow signal (target same-sandbox))
    \\(allow file-read-metadata)
    \\(allow file-read*
    \\  (subpath "/usr")
    \\  (subpath "/bin")
    \\  (subpath "/sbin")
    \\  (subpath "/System")
    \\  (subpath "/Library")
    \\  (subpath "/private/etc")
    \\  (subpath "/dev")
    \\  (subpath "/private/var/db/timezone")
    \\  (subpath "/opt/homebrew")
    \\  (subpath "/Applications/Xcode.app/Contents"))
    \\(allow file-map-executable
    \\  (subpath "/usr")
    \\  (subpath "/bin")
    \\  (subpath "/sbin")
    \\  (subpath "/System")
    \\  (subpath "/Library")
    \\  (subpath "/opt/homebrew")
    \\  (subpath "/Applications/Xcode.app/Contents"))
    \\(allow file-read* file-write* (subpath (param "WORKSPACE")))
    \\(allow file-map-executable (subpath (param "WORKSPACE")))
    \\(allow file-read* file-write* (subpath (param "TMPDIR")))
    \\(allow file-read* file-map-executable (literal (param "WORKER")))
    \\(if (equal? (param "NETWORK") "1") (allow network*))
;

fn macosLaunch(
    io: std.Io,
    allocator: std.mem.Allocator,
    workspace: []const u8,
    executable: ?[]const u8,
    network: bool,
    command: []const []const u8,
    extra_env: []const [2][]const u8,
) !Launch {
    var owned: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned.items) |s| allocator.free(s);
        owned.deinit(allocator);
    }

    // A private temp directory replaces the shared /tmp, mirroring the tmpfs
    // that bubblewrap creates on Linux. It is removed by `releaseTempDir`.
    var rand_bytes: [16]u8 = undefined;
    std.Io.random(io, &rand_bytes);
    const tmp_dir = try std.fmt.allocPrint(allocator, "/private/tmp/zagent-{s}", .{std.fmt.bytesToHex(rand_bytes, .lower)});
    errdefer allocator.free(tmp_dir);
    try std.Io.Dir.createDirAbsolute(io, tmp_dir, std.Io.Dir.Permissions.fromMode(0o700));

    const ws_param = try std.fmt.allocPrint(allocator, "WORKSPACE={s}", .{workspace});
    try owned.append(allocator, ws_param);
    const tmp_param = try std.fmt.allocPrint(allocator, "TMPDIR={s}", .{tmp_dir});
    try owned.append(allocator, tmp_param);
    const net_param = try std.fmt.allocPrint(allocator, "NETWORK={d}", .{@intFromBool(network)});
    try owned.append(allocator, net_param);
    const worker_param = try std.fmt.allocPrint(allocator, "WORKER={s}", .{executable orelse "/dev/null"});
    try owned.append(allocator, worker_param);

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{ "/usr/bin/sandbox-exec", "-p", macos_profile });
    try list.appendSlice(allocator, &.{ "-D", ws_param, "-D", tmp_param, "-D", net_param, "-D", worker_param });
    try list.appendSlice(allocator, command);

    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();
    try env.put("HOME", tmp_dir);
    try env.put("TMPDIR", tmp_dir);
    try env.put("PATH", "/opt/homebrew/bin:/usr/local/bin:/Library/Developer/CommandLineTools/usr/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin");
    for (extra_env) |pair| {
        if (!std.process.Environ.Map.validateKeyForPut(pair[0])) return error.InvalidEnvKey;
        try env.put(pair[0], pair[1]);
    }

    return .{
        .io = io,
        .allocator = allocator,
        .argv = try list.toOwnedSlice(allocator),
        .env = env,
        .tmp_dir = tmp_dir,
        .owned = owned,
    };
}

/// Run one built-in tool. On Linux the deadline is enforced by `timeout(1)`
/// wrapped around bubblewrap; on macOS it is enforced while draining the
/// child's output and by killing its whole process group.
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
    const timeout = shellTimeout(allocator, name, arguments) catch return .{
        .content = try allocator.dupe(u8, "Invalid timeout_seconds: use an integer from 1 to 3600."),
        .is_error = true,
    };
    if (native_os == .macos) {
        // Resolve the worker path so sandbox-exec's process-exec filter matches
        // the canonical path (the executable may be reached through a symlink).
        const worker = try std.Io.Dir.realPathFileAbsoluteAlloc(io, worker_path, allocator);
        defer allocator.free(worker);
        return executeMacos(io, allocator, network, name, arguments, workspace, worker, timeout);
    }
    if (native_os == .linux) return executeLinux(io, allocator, network, name, arguments, workspace, worker_path, timeout);
    return error.UnsupportedSandboxHost;
}

fn executeLinux(io: std.Io, allocator: std.mem.Allocator, network: bool, name: []const u8, arguments: []const u8, workspace: []const u8, worker_path: []const u8, timeout: u32) !tools.ToolResult {
    var l = try launch(io, allocator, workspace, worker_path, network, &.{ "/zagent-worker", "--tool-worker", name, arguments }, &.{}, timeout);
    defer l.deinit();
    const result = std.process.run(allocator, io, .{
        .argv = l.argv,
        .environ_map = &l.env,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| return .{
        .content = try std.fmt.allocPrint(allocator, "Sandbox failed ({s}). Install bubblewrap and GNU timeout; no tool ran outside the sandbox.", .{@errorName(err)}),
        .is_error = true,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return parseResult(allocator, result.stdout, result.stderr, result.term);
}

fn executeMacos(io: std.Io, allocator: std.mem.Allocator, network: bool, name: []const u8, arguments: []const u8, workspace: []const u8, worker: []const u8, timeout: u32) !tools.ToolResult {
    var l = try launch(io, allocator, workspace, worker, network, &.{ worker, "--tool-worker", name, arguments }, &.{}, timeout);
    defer l.deinit();
    defer l.releaseTempDir();

    return executeLaunch(io, allocator, &l, workspace, timeout);
}

/// Run an ordinary tool with the host environment and current working directory,
/// retaining the same timeout, output bounds and process-group cleanup.
pub fn executeDirect(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8, arguments: []const u8) !tools.ToolResult {
    if (arguments.len > 120 * 1024) return .{ .content = try allocator.dupe(u8, "Tool arguments exceed 120 KiB; split the operation into smaller patches."), .is_error = true };
    const timeout = shellTimeout(allocator, name, arguments) catch return .{
        .content = try allocator.dupe(u8, "Invalid timeout_seconds: use an integer from 1 to 3600."),
        .is_error = true,
    };
    const workspace = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(workspace);
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);
    const deleted = " (deleted)";
    const worker = if (std.mem.endsWith(u8, exe, deleted)) exe[0 .. exe.len - deleted.len] else exe;
    var l: Launch = blk: {
        const argv = try allocator.dupe([]const u8, &.{ worker, "--direct-tool-worker", name, arguments });
        errdefer allocator.free(argv);
        break :blk .{
            .io = io,
            .allocator = allocator,
            .argv = argv,
            .env = try env.clone(allocator),
        };
    };
    defer l.deinit();
    return executeLaunch(io, allocator, &l, workspace, timeout);
}

fn executeLaunch(io: std.Io, allocator: std.mem.Allocator, l: *Launch, workspace: []const u8, timeout: u32) !tools.ToolResult {
    var child = std.process.spawn(io, .{
        .argv = l.argv,
        .cwd = .{ .path = workspace },
        .environ_map = &l.env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // New process group: background processes the tool spawns are killed
        // with the worker, matching bubblewrap's --die-with-parent behaviour.
        .pgid = 0,
    }) catch |err| return .{
        .content = try std.fmt.allocPrint(allocator, "Sandbox failed ({s}). macOS sandbox-exec is required; no tool ran outside the sandbox.", .{@errorName(err)}),
        .is_error = true,
    };
    defer _ = killGroup(&child, io);

    var multi_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(allocator, io, multi_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    const stdout_reader = multi.reader(0);
    const stderr_reader = multi.reader(1);

    const run_timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromSeconds(@intCast(timeout)),
        .clock = .awake,
    } };

    while (multi.fill(64, run_timeout)) |_| {
        if (stdout_reader.buffered().len > 2 * 1024 * 1024) return .{
            .content = try allocator.dupe(u8, "Tool output exceeded the 2 MiB limit."),
            .is_error = true,
        };
        if (stderr_reader.buffered().len > 64 * 1024) return .{
            .content = try allocator.dupe(u8, "Tool error output exceeded the 64 KiB limit."),
            .is_error = true,
        };
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return .{
            .content = try std.fmt.allocPrint(allocator, "Tool timed out after {d}s.", .{timeout}),
            .is_error = true,
        },
        else => |e| return .{
            .content = try std.fmt.allocPrint(allocator, "Sandbox failed ({s}).", .{@errorName(e)}),
            .is_error = true,
        },
    }

    multi.checkAnyError() catch |err| return .{
        .content = try std.fmt.allocPrint(allocator, "Sandbox failed ({s}).", .{@errorName(err)}),
        .is_error = true,
    };
    // Kill the whole process group and reap the worker. This both collects the
    // exit status and removes any background processes the tool left running,
    // matching bubblewrap's --die-with-parent behaviour on Linux.
    const term = killGroup(&child, io) orelse std.process.Child.Term{ .unknown = 1 };
    const stdout = try multi.toOwnedSlice(0);
    defer allocator.free(stdout);
    const stderr = try multi.toOwnedSlice(1);
    defer allocator.free(stderr);
    return parseResult(allocator, stdout, stderr, term);
}

fn parseResult(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, term: std.process.Child.Term) !tools.ToolResult {
    if (!term.success()) return .{
        .content = try std.fmt.allocPrint(allocator, "Sandbox failed or tool timed out: {s}", .{stderr}),
        .is_error = true,
    };
    const parsed = std.json.parseFromSlice(tools.ToolResult, allocator, stdout, .{ .allocate = .alloc_always }) catch return .{
        .content = try allocator.dupe(u8, "Sandbox worker returned an invalid result."),
        .is_error = true,
    };
    defer parsed.deinit();
    return .{ .content = try allocator.dupe(u8, parsed.value.content), .is_error = parsed.value.is_error };
}

/// Kill the child and every process in its process group, then reap it and
/// return its termination status. The child is made a group leader on macOS, so
/// killing `-pid` also takes out any background processes the tool left behind.
/// Returns null if the child has already been reaped.
fn killGroup(child: *std.process.Child, io: std.Io) ?std.process.Child.Term {
    const pid = child.id orelse return null;
    std.posix.kill(-pid, .KILL) catch {};
    return child.wait(io) catch null;
}

/// Verify the worker is running under the macOS sandbox. `/Users` is outside
/// every path the sandbox grants, so being able to list it means the worker was
/// invoked directly on the host rather than through sandbox-exec.
pub fn verifyMacosSandbox(io: std.Io) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, "/Users", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    _ = it.next(io) catch return;
    return error.WorkerRequiresSandbox;
}

fn shellTimeout(allocator: std.mem.Allocator, name: []const u8, arguments: []const u8) !u32 {
    if (!std.mem.eql(u8, name, "bash")) return 180;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const value = parsed.value.object.get("timeout_seconds") orelse return 180;
    if (value != .integer or value.integer < 1 or value.integer > 3600) return error.InvalidTimeout;
    return @intCast(value.integer);
}

test "sandbox launch requires a bounded workspace" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsafeWorkspace, launch(std.testing.io, a, "/", null, false, &.{"true"}, &.{}, null));
    try std.testing.expectError(error.UnsafeWorkspace, launch(std.testing.io, a, ".", null, false, &.{"true"}, &.{}, null));
    if (native_os == .linux) {
        const l = try launch(std.testing.io, a, "/work", null, false, &.{"true"}, &.{}, 180);
        var ll = l;
        defer ll.deinit();
        for (ll.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--share-net"));
    }
}

test "shell timeout is bounded and applies only to commands" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 180), try shellTimeout(a, "bash", "{}"));
    try std.testing.expectEqual(@as(u32, 600), try shellTimeout(a, "bash", "{\"timeout_seconds\":600}"));
    try std.testing.expectEqual(@as(u32, 180), try shellTimeout(a, "read", "{\"timeout_seconds\":600}"));
    try std.testing.expectEqual(@as(u32, 180), try shellTimeout(a, "shell", "{\"timeout_seconds\":600}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "bash", "{\"timeout_seconds\":0}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "bash", "{\"timeout_seconds\":3601}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "bash", "{\"timeout_seconds\":\"600\"}"));
}
