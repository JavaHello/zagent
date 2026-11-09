//! Default-host execution policy. Detection is deliberately conservative, not
//! a security boundary: scripts and dynamically constructed commands can hide effects.
const std = @import("std");
const sandbox = @import("sandbox.zig");
const tools = @import("tools.zig");

pub fn requiresSandbox(io: std.Io, allocator: std.mem.Allocator, name: []const u8, arguments: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const obj = parsed.value.object;
    if (std.mem.eql(u8, name, "bash")) {
        const value = obj.get("command") orelse return error.InvalidArguments;
        if (value != .string) return error.InvalidArguments;
        return dangerousCommand(value.string);
    }
    // Resolve symlinks and relative paths before checking file-writing tools.
    const key: []const u8 = if (std.mem.eql(u8, name, "http")) "save_to" else "path";
    if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "http")) {
        if (obj.get(key)) |value| {
            if (value != .string) return error.InvalidArguments;
            const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
            defer allocator.free(cwd);
            const absolute = try std.fs.path.resolve(allocator, &.{ cwd, value.string });
            defer allocator.free(absolute);
            if (systemPath(absolute)) return true;
            // Resolve existing parents too, so new files through symlinked
            // directories receive the same policy as existing files.
            var parent: []const u8 = absolute;
            while (true) {
                const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator) catch {
                    parent = std.fs.path.dirname(parent) orelse break;
                    continue;
                };
                defer allocator.free(resolved);
                return systemPath(resolved);
            }
            return false;
        }
    }
    if (std.mem.eql(u8, name, "apply_patch")) {
        if (obj.get("patch")) |value| {
            if (value != .string) return error.InvalidArguments;
            return dangerousCommand(value.string);
        }
    }
    return false;
}

fn systemPath(path: []const u8) bool {
    for ([_][]const u8{ "/etc", "/private/etc", "/usr", "/boot", "/sys", "/proc", "/dev", "/System", "/Library", "/var", "/private/var", "/sbin", "/bin" }) |root| {
        if (std.mem.eql(u8, path, root) or (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/')) return true;
    }
    return false;
}

fn dangerousCommand(command: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n;|&()<>\"'`=\\");
    while (tokens.next()) |token| {
        if (systemPath(token)) return true;
        const base = std.fs.path.basename(token);
        for ([_][]const u8{
            "sudo",    "su",           "doas",      "systemctl", "service",  "launchctl",
            "sysctl",  "iptables",     "ip6tables", "nft",       "ip",       "ifconfig",
            "route",   "networksetup", "nmcli",     "netplan",   "ufw",      "firewall-cmd",
            "reboot",  "shutdown",     "poweroff",  "halt",      "mount",    "umount",
            "mkfs",    "fdisk",        "parted",    "dd",        "diskutil", "chroot",
            "passwd",  "useradd",      "usermod",   "userdel",   "groupadd", "apt",
            "apt-get", "dnf",          "yum",       "pacman",    "rpm",      "dpkg",
        }) |dangerous| {
            if (std.mem.eql(u8, base, dangerous) or std.mem.startsWith(u8, base, "mkfs.")) return true;
        }
    }
    return false;
}

pub fn execute(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, network: bool, sandbox_available: bool, name: []const u8, arguments: []const u8) !tools.ToolResult {
    const isolated = requiresSandbox(io, allocator, name, arguments) catch return .{
        .content = try allocator.dupe(u8, "Invalid tool arguments; execution was not attempted."),
        .is_error = true,
    };
    if (isolated) {
        if (!sandbox_available) return .{
            .content = try allocator.dupe(u8, "Sandbox is disabled or unavailable; this operation requires isolation and was not executed."),
            .is_error = true,
        };
        return sandbox.execute(io, allocator, network, name, arguments);
    }
    return sandbox.executeDirect(io, allocator, env, name, arguments);
}

test "unavailable sandbox rejects dangerous bash calls" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    for ([_][]const u8{"bash"}) |name| {
        const result = try execute(std.testing.io, a, &env, false, false, name, "{\"command\":\"sudo true\"}");
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.content, "was not executed") != null);
    }
}

test "ordinary development commands run directly; system changes require sandbox" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "zig build test", "git status", "npm install", "python3 script.py", "echo hello > local.txt" }) |command| {
        try std.testing.expect(!dangerousCommand(command));
    }
    for ([_][]const u8{ "sudo true", "echo x > /etc/hosts", "ip route add default", "sh -c 'systemctl restart ssh'", "true && /sbin/reboot", "mkfs.ext4 /dev/sda" }) |command| {
        try std.testing.expect(dangerousCommand(command));
    }
    try std.testing.expect(try requiresSandbox(std.testing.io, a, "write", "{\"path\":\"/etc/hosts\"}"));
    try std.testing.expect(!try requiresSandbox(std.testing.io, a, "write", "{\"path\":\"src/main.zig\"}"));
    try std.testing.expect(!try requiresSandbox(std.testing.io, a, "http", "{\"url\":\"https://example.com\"}"));
    try std.testing.expect(try requiresSandbox(std.testing.io, a, "http", "{\"url\":\"https://example.com\",\"save_to\":\"/etc/hosts\"}"));
    try std.testing.expect(!try requiresSandbox(std.testing.io, a, "http", "{\"url\":\"https://example.com\",\"save_to\":\"download.txt\"}"));
    try std.testing.expectError(error.InvalidArguments, requiresSandbox(std.testing.io, a, "bash", "{}"));
}
