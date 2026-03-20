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
        try aw.writer.writeAll(result.stdout);
    }
    if (result.stderr.len > 0) {
        if (aw.written().len > 0) try aw.writer.writeAll("\n");
        try aw.writer.writeAll("stderr: ");
        try aw.writer.writeAll(result.stderr);
    }
    if (aw.written().len == 0) {
        try aw.writer.writeAll("(no output)");
    }

    const max_len = 8192;
    if (aw.written().len > max_len) {
        aw.shrinkRetainingCapacity(max_len);
        try aw.writer.writeAll("\n... (truncated)");
    }

    return .{
        .content = try aw.toOwnedSlice(),
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

    return .{ .content = content, .is_error = false };
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
