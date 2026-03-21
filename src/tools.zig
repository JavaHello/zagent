const std = @import("std");

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub fn executeShell(allocator: std.mem.Allocator, command: []const u8) !ToolResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", command },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };

    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    if (result.stdout.len > 0) {
        const normalized = try normalizeToolText(allocator, result.stdout);
        defer allocator.free(normalized);
        try aw.writer.writeAll(normalized);
    }
    if (result.stderr.len > 0) {
        if (aw.written().len > 0) try aw.writer.writeAll("\n");
        try aw.writer.writeAll("stderr: ");
        const normalized = try normalizeToolText(allocator, result.stderr);
        defer allocator.free(normalized);
        try aw.writer.writeAll(normalized);
    }
    if (aw.written().len == 0) {
        try aw.writer.writeAll("(no output)");
    }

    const content = try finalizeToolContent(allocator, aw.written());
    aw.deinit();

    return .{
        .content = content,
        .is_error = exit_code != 0,
    };
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !ToolResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer file.close();

    const max_size = 1 * 1024 * 1024;
    const content = file.readToEndAlloc(allocator, max_size) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };

    const normalized = try finalizeToolContent(allocator, content);
    allocator.free(content);
    return .{ .content = normalized, .is_error = false };
}

pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !ToolResult {
    if (std.fs.path.dirname(path)) |dir_path| {
        std.fs.cwd().makePath(dir_path) catch {};
    }

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error creating '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer file.close();

    file.writeAll(content) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error writing '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };

    return .{
        .content = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to '{s}'", .{ content.len, path }),
        .is_error = false,
    };
}

pub fn listDir(allocator: std.mem.Allocator, path: []const u8) !ToolResult {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer dir.close();

    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const kind_char: u8 = switch (entry.kind) {
            .directory => 'd',
            .file => 'f',
            .sym_link => 'l',
            else => '?',
        };
        try aw.writer.print("{c} {s}\n", .{ kind_char, entry.name });
    }

    if (aw.written().len == 0) {
        try aw.writer.writeAll("(empty directory)");
    }

    return .{ .content = try aw.toOwnedSlice(), .is_error = false };
}

test "shell echo" {
    const result = try executeShell(std.testing.allocator, "echo hello");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "hello") != null);
}

test "shell exit code" {
    const result = try executeShell(std.testing.allocator, "exit 1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

test "read missing file" {
    const result = try readFile(std.testing.allocator, "/nonexistent/path/file.txt");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

fn finalizeToolContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const normalized = try normalizeToolText(allocator, raw);
    defer allocator.free(normalized);

    const max_len = 8192;
    const suffix = "\n... (truncated)";
    if (normalized.len <= max_len) return allocator.dupe(u8, normalized);

    var cut = max_len - suffix.len;
    while (cut > 0 and !std.unicode.utf8ValidateSlice(normalized[0..cut])) : (cut -= 1) {}
    if (cut == 0) cut = max_len - suffix.len;

    return std.fmt.allocPrint(allocator, "{s}{s}", .{ normalized[0..cut], suffix });
}

fn normalizeToolText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        const byte = raw[i];

        // Strip common ANSI escape sequences used by terminal-oriented tools.
        if (byte == 0x1b) {
            i = skipAnsiEscape(raw, i);
            continue;
        }

        if (byte < 0x80) {
            if (byte == '\n' or byte == '\r' or byte == '\t' or byte >= 0x20) {
                try out.append(allocator, byte);
            } else {
                try out.append(allocator, ' ');
            }
            i += 1;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.writer(allocator).print("\\x{X:0>2}", .{byte});
            i += 1;
            continue;
        };
        if (i + seq_len > raw.len or !std.unicode.utf8ValidateSlice(raw[i .. i + seq_len])) {
            try out.writer(allocator).print("\\x{X:0>2}", .{byte});
            i += 1;
            continue;
        }

        try out.appendSlice(allocator, raw[i .. i + seq_len]);
        i += seq_len;
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "(no output)");
    }

    return out.toOwnedSlice(allocator);
}

fn skipAnsiEscape(raw: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= raw.len) return i;

    switch (raw[i]) {
        '[' => {
            i += 1;
            while (i < raw.len) : (i += 1) {
                const ch = raw[i];
                if (ch >= 0x40 and ch <= 0x7e) return i + 1;
            }
            return i;
        },
        ']' => {
            i += 1;
            while (i < raw.len) : (i += 1) {
                if (raw[i] == 0x07) return i + 1;
                if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') return i + 2;
            }
            return i;
        },
        else => return @min(i + 1, raw.len),
    }
}

test "normalize tool text strips ansi sequences" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeToolText(allocator, "\x1b[32mgreen\x1b[0m");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("green", normalized);
}

test "normalize tool text escapes invalid utf8" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeToolText(allocator, &[_]u8{ 'o', 'k', 0xff });
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("ok\\xFF", normalized);
}

test "finalize tool content truncates on utf8 boundary" {
    const allocator = std.testing.allocator;
    var repeated: std.ArrayList(u8) = .empty;
    defer repeated.deinit(allocator);
    for (0..1500) |_| {
        try repeated.appendSlice(allocator, "你好");
    }

    const finalized = try finalizeToolContent(allocator, repeated.items);
    defer allocator.free(finalized);
    try std.testing.expect(std.mem.endsWith(u8, finalized, "\n... (truncated)"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(finalized));
}
