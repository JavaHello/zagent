//! What machine this run is on.
//!
//! The operating system and its version, the kernel, the architecture, the CPUs
//! and the memory are read once, in `Agent.init`, for the same reason the search
//! programs are: they cannot change while the process runs, and what to run —
//! a package manager, a build system, a path, a version of a tool — is decided
//! from them. The system prompt names them, so the model starts out knowing
//! which machine it is working on instead of spending a tool call on `uname`.
const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// How much of a distribution name is worth keeping. A name longer than this is
/// a broken file, not a description of a system.
const max_name_bytes: usize = 200;

pub const Info = struct {
    /// The OS as its vendor names it: "Ubuntu 24.04.1 LTS" on Linux, "macOS
    /// 14.5" on a Mac, "Linux" when nothing named it better. Owned.
    os: []u8,
    /// Kernel and release, e.g. "Linux 6.8.0-45-generic". Owned.
    kernel: []u8,
    /// The architecture the binary was built for: "x86_64", "aarch64".
    arch: []const u8,
    /// The logical CPUs the process may use, or 0 when they cannot be counted.
    cpus: usize,
    /// Total memory, on the platforms that answer in one cheap call.
    memory_bytes: ?u64,

    /// Read the machine's facts. Every field but the OS name is best-effort: a
    /// platform that will not answer leaves its field empty, and the prompt
    /// says less rather than failing the startup over it.
    pub fn read(allocator: std.mem.Allocator, io: std.Io) !Info {
        var kernel_buf: [256]u8 = undefined;
        const uts = readUts(&kernel_buf);

        const kernel = try allocator.dupe(u8, uts.kernel);
        errdefer allocator.free(kernel);

        const os = try detectOsName(allocator, io, uts.sysname);
        errdefer allocator.free(os);

        return .{
            .os = os,
            .kernel = kernel,
            .arch = @tagName(builtin.cpu.arch),
            .cpus = std.Thread.getCpuCount() catch 0,
            .memory_bytes = readMemoryBytes(),
        };
    }

    /// A copy of the same facts, for an agent started on this machine: a
    /// sub-agent works where its parent works, so it inherits what the parent
    /// read instead of asking the kernel the same questions again.
    pub fn clone(self: Info, allocator: std.mem.Allocator) !Info {
        const os = try allocator.dupe(u8, self.os);
        errdefer allocator.free(os);
        const kernel = try allocator.dupe(u8, self.kernel);
        errdefer allocator.free(kernel);
        return .{
            .os = os,
            .kernel = kernel,
            .arch = self.arch,
            .cpus = self.cpus,
            .memory_bytes = self.memory_bytes,
        };
    }

    pub fn deinit(self: *Info, allocator: std.mem.Allocator) void {
        allocator.free(self.os);
        allocator.free(self.kernel);
    }

    /// The bullet the system prompt carries about the machine.
    ///
    /// Rendered from the captured fields rather than probing again, so main
    /// and sub-agent prompts describe the same machine they started on.
    pub fn writePromptNote(self: Info, w: *std.Io.Writer) !void {
        try w.print("\n- Host system: {s} ({s}, {s})", .{ self.os, self.kernel, self.arch });
        if (self.cpus > 0) try w.print(", {d} CPUs", .{self.cpus});
        if (self.memory_bytes) |bytes| {
            const tenths = memoryTenths(bytes);
            try w.print(", {d}.{d} GiB RAM", .{ tenths / 10, tenths % 10 });
        }
        try w.writeAll(
            ". Shell commands run with **bash** on this machine: use its package manager, paths and" ++
                " toolchain, and check which programs and versions it has instead of assuming what" ++
                " another system would have.\n",
        );
    }
};

/// The fields `uname` reports. A platform that does not have it — Windows —
/// names itself from the build instead.
const Uts = struct {
    /// The kernel and its release, e.g. "Linux 6.8.0-45-generic".
    kernel: []const u8,
    /// The kernel's own name for the system: "Linux", "Darwin".
    sysname: []const u8 = "",
};

/// `uname`, formatted into the caller's buffer: the slices in the result point
/// into it, so it has to outlive them.
fn readUts(kernel_buf: *[256]u8) Uts {
    if (comptime is_windows) {
        // Windows has no `uname`, and its version would cost a registry lookup.
        // The model is told less rather than told something it must verify.
        return .{ .kernel = "Windows", .sysname = "Windows" };
    }
    const uts = std.posix.uname();
    const sysname = std.mem.sliceTo(&uts.sysname, 0);
    const release = std.mem.sliceTo(&uts.release, 0);
    const kernel = std.fmt.bufPrint(kernel_buf, "{s} {s}", .{ sysname, release }) catch sysname;
    return .{ .kernel = kernel, .sysname = sysname };
}

/// The OS name a person would write: the distribution on Linux, the product
/// version on macOS, the kernel's own name anywhere else.
fn detectOsName(allocator: std.mem.Allocator, io: std.Io, sysname: []const u8) ![]u8 {
    switch (builtin.os.tag) {
        .linux => {
            if (try readOsReleaseName(allocator, io)) |name| return name;
            return allocator.dupe(u8, "Linux");
        },
        .macos => {
            if (try readMacOsProductVersion(allocator, io)) |version| {
                defer allocator.free(version);
                return std.fmt.allocPrint(allocator, "macOS {s}", .{version});
            }
            return allocator.dupe(u8, "macOS");
        },
        .windows => return allocator.dupe(u8, "Windows"),
        else => return allocator.dupe(u8, if (sysname.len > 0) sysname else @tagName(builtin.os.tag)),
    }
}

/// `PRETTY_NAME` from an os-release file, or null when none names anything.
///
/// Both paths are tried because the spec puts the file in `/usr/lib/os-release`
/// and `/etc/os-release` is the administrator's copy of it; either may be the
/// only one there. Failing to read it is not an error: the caller falls back to
/// the kernel's name for the OS.
fn readOsReleaseName(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    for ([_][]const u8{ "/etc/os-release", "/usr/lib/os-release" }) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(data);
        if (osReleaseName(data)) |name| return try allocator.dupe(u8, clampName(name));
    }
    return null;
}

/// The distribution an os-release file describes: `PRETTY_NAME` when it is
/// there, `NAME` otherwise. Quotes are removed because the value is allowed to
/// be either `Ubuntu 24.04 LTS` or `"Ubuntu 24.04 LTS"`.
fn osReleaseName(text: []const u8) ?[]const u8 {
    var name: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, "PRETTY_NAME")) return value;
        if (std.mem.eql(u8, key, "NAME")) name = value;
    }
    return name;
}

/// A name cut to the room the prompt has for it, on a character boundary so a
/// cut name is still valid UTF-8.
fn clampName(name: []const u8) []const u8 {
    if (name.len <= max_name_bytes) return name;
    var end = max_name_bytes;
    while (end > 0 and (name[end] & 0xc0) == 0x80) end -= 1;
    return name[0..end];
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const quote = value[0];
        if ((quote == '"' or quote == '\'') and value[value.len - 1] == quote) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

/// `ProductVersion` from the system version plist, e.g. "14.5". macOS is the
/// one platform whose `uname` release (`23.5.0`) is not the version a person
/// knows it by.
fn readMacOsProductVersion(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const path = "/System/Library/CoreServices/SystemVersion.plist";
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(data);
    const version = plistProductVersion(data) orelse return null;
    return try allocator.dupe(u8, clampName(version));
}

fn plistProductVersion(text: []const u8) ?[]const u8 {
    const key = "<key>ProductVersion</key>";
    const key_at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[key_at + key.len ..];
    const open_tag = "<string>";
    const open_at = std.mem.indexOf(u8, rest, open_tag) orelse return null;
    const value_start = open_at + open_tag.len;
    const close_at = std.mem.indexOf(u8, rest[value_start..], "</string>") orelse return null;
    const value = std.mem.trim(u8, rest[value_start .. value_start + close_at], " \t\r\n");
    if (value.len == 0) return null;
    return value;
}

/// Total memory, from the one place that has it cheaply.
///
/// `/proc/meminfo` looks like the obvious source, but procfs reports a size of
/// zero for every file in it, and a reader that trusts the stat finds nothing
/// there. One syscall answers the same question without a file, and a platform
/// whose answer costs more than that is left out: the prompt says less rather
/// than the startup paying for it.
fn readMemoryBytes() ?u64 {
    if (comptime builtin.os.tag != .linux) return null;
    var info: std.os.linux.Sysinfo = undefined;
    switch (std.posix.errno(std.os.linux.sysinfo(&info))) {
        .SUCCESS => {},
        else => return null,
    }
    // `totalram` counts in units of `mem_unit` bytes, which is the page size on
    // most kernels and 1 on some. The kernel reports the unit, so it is read
    // rather than assumed.
    return info.totalram * info.mem_unit;
}

/// Memory in tenths of a gibibyte, rounded: the prompt says "15.6 GiB", not the
/// byte count, which nobody reads and no decision depends on.
fn memoryTenths(bytes: u64) u64 {
    const gib: u64 = 1024 * 1024 * 1024;
    return (bytes * 10 + gib / 2) / gib;
}

test "os-release names are read as the distribution quotes them" {
    const ubuntu =
        \\PRETTY_NAME="Ubuntu 24.04.1 LTS"
        \\NAME="Ubuntu"
        \\VERSION_ID="24.04"
    ;
    try std.testing.expectEqualStrings("Ubuntu 24.04.1 LTS", osReleaseName(ubuntu).?);

    // Unquoted values and comments are both allowed, and NAME is the fallback
    // when no PRETTY_NAME is there.
    const fedora =
        \\# generated by the installer
        \\NAME="Fedora Linux"
        \\PRETTY_NAME='Fedora Linux 40 (Workstation Edition)'
    ;
    try std.testing.expectEqualStrings("Fedora Linux 40 (Workstation Edition)", osReleaseName(fedora).?);
    const plain =
        \\NAME=Alpine Linux
        \\ID=alpine
    ;
    try std.testing.expectEqualStrings("Alpine Linux", osReleaseName(plain).?);
    try std.testing.expect(osReleaseName("ID=linux\nVERSION_ID=1") == null);
}

test "a name too long for the prompt is cut between characters" {
    var exact: [max_name_bytes + 3]u8 = undefined;
    @memset(exact[0..max_name_bytes], 'x');
    @memcpy(exact[max_name_bytes..], "\u{4f60}");
    // The cut lands on a boundary here: the ASCII name is kept whole and the
    // character that would not fit is dropped whole.
    try std.testing.expectEqual(@as(usize, max_name_bytes), clampName(&exact).len);

    var split: [max_name_bytes + 2]u8 = undefined;
    @memset(split[0 .. max_name_bytes - 1], 'a');
    @memcpy(split[max_name_bytes - 1 ..][0..3], "\u{4f60}");
    // Here the cut would fall inside the character, so the character goes with
    // it rather than leaving half of it in the prompt.
    try std.testing.expectEqual(@as(usize, max_name_bytes - 1), clampName(&split).len);
}

test "macOS product version is read from the system version plist" {
    const plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0">
        \\<dict>
        \\    <key>ProductBuildVersion</key>
        \\    <string>23F79</string>
        \\    <key>ProductVersion</key>
        \\    <string>14.5</string>
        \\</dict>
        \\</plist>
    ;
    try std.testing.expectEqualStrings("14.5", plistProductVersion(plist).?);
    try std.testing.expect(plistProductVersion("<dict><key>Other</key></dict>") == null);
}

test "the prompt note names the machine and leaves out what is unknown" {
    var note: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer note.deinit();
    const info: Info = .{
        .os = try std.testing.allocator.dupe(u8, "Ubuntu 24.04.1 LTS"),
        .kernel = try std.testing.allocator.dupe(u8, "Linux 6.8.0-45-generic"),
        .arch = "x86_64",
        .cpus = 8,
        .memory_bytes = 16 * 1024 * 1024 * 1024,
    };
    var owned = info;
    defer owned.deinit(std.testing.allocator);
    try owned.writePromptNote(&note.writer);
    const line = note.written();
    try std.testing.expect(std.mem.startsWith(u8, line, "\n- Host system: Ubuntu 24.04.1 LTS (Linux 6.8.0-45-generic, x86_64), 8 CPUs, 16.0 GiB RAM. Shell commands run with **bash**"));
    try std.testing.expect(std.mem.indexOf(u8, line, "hostname") == null);
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));

    var minimal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer minimal.deinit();
    var bare: Info = .{
        .os = try std.testing.allocator.dupe(u8, "Linux"),
        .kernel = try std.testing.allocator.dupe(u8, "Linux 6.8.0"),
        .arch = "aarch64",
        .cpus = 0,
        .memory_bytes = null,
    };
    defer bare.deinit(std.testing.allocator);
    try bare.writePromptNote(&minimal.writer);
    try std.testing.expect(std.mem.startsWith(u8, minimal.written(), "\n- Host system: Linux (Linux 6.8.0, aarch64). Shell commands run with **bash**"));
    try std.testing.expect(std.mem.indexOf(u8, minimal.written(), "CPUs") == null);
    try std.testing.expect(std.mem.indexOf(u8, minimal.written(), "RAM") == null);
}

test "the machine this test runs on is read and cloned" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var info = try Info.read(allocator, io);
    defer info.deinit(allocator);
    try std.testing.expect(info.os.len > 0);
    try std.testing.expect(info.kernel.len > 0);
    try std.testing.expect(info.arch.len > 0);
    if (builtin.os.tag == .linux) try std.testing.expect((info.memory_bytes orelse 0) > 0);
    // The testing allocator fails the test on anything `read` failed to free.

    var copy = try info.clone(allocator);
    defer copy.deinit(allocator);
    try std.testing.expectEqualStrings(info.os, copy.os);
    try std.testing.expectEqualStrings(info.kernel, copy.kernel);
    try std.testing.expectEqual(info.cpus, copy.cpus);
    try std.testing.expectEqualStrings(info.arch, copy.arch);
}
