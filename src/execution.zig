//! Host tool execution with bounded output, deadlines and process-group cleanup.
const std = @import("std");
const tools = @import("tools.zig");

pub fn execute(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8, arguments: []const u8) !tools.ToolResult {
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
    var child = std.process.spawn(io, .{
        .argv = &.{ worker, "--tool-worker", name, arguments },
        .cwd = .{ .path = workspace },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| return .{
        .content = try std.fmt.allocPrint(allocator, "Tool worker launch failed ({s}).", .{@errorName(err)}),
        .is_error = true,
    };
    defer _ = killGroup(&child, io);

    var multi_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(allocator, io, multi_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    const stdout_reader = multi.reader(0);
    const stderr_reader = multi.reader(1);
    const run_timeout = (std.Io.Timeout{ .duration = .{
        .raw = std.Io.Duration.fromSeconds(@intCast(timeout)),
        .clock = .awake,
    } }).toDeadline(io);
    while (multi.fill(64, run_timeout)) |_| {
        if (stdout_reader.buffered().len > 2 * 1024 * 1024) return .{
            .content = try allocator.dupe(u8, "Tool output exceeded the 2 MiB limit."),
            .is_error = true,
            .truncated = true,
        };
        if (stderr_reader.buffered().len > 64 * 1024) return .{
            .content = try allocator.dupe(u8, "Tool error output exceeded the 64 KiB limit."),
            .is_error = true,
            .truncated = true,
        };
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => return .{
            .content = try std.fmt.allocPrint(allocator, "Tool timed out after {d}s.", .{timeout}),
            .is_error = true,
            .timed_out = true,
        },
        else => |e| return .{
            .content = try std.fmt.allocPrint(allocator, "Tool worker failed ({s}).", .{@errorName(e)}),
            .is_error = true,
        },
    }
    multi.checkAnyError() catch |err| return .{
        .content = try std.fmt.allocPrint(allocator, "Tool worker failed ({s}).", .{@errorName(err)}),
        .is_error = true,
    };
    const term = killGroup(&child, io) orelse std.process.Child.Term{ .unknown = 1 };
    const stdout = try multi.toOwnedSlice(0);
    defer allocator.free(stdout);
    const stderr = try multi.toOwnedSlice(1);
    defer allocator.free(stderr);
    return parseResult(allocator, stdout, stderr, term);
}

fn parseResult(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, term: std.process.Child.Term) !tools.ToolResult {
    if (!term.success()) return .{
        .content = try std.fmt.allocPrint(allocator, "Tool worker failed: {s}", .{stderr}),
        .is_error = true,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => null,
        },
    };
    const WireResult = struct {
        content: []const u8,
        is_error: bool,
        exit_code: ?u8,
        timed_out: bool,
        truncated: bool,
    };
    const parsed = std.json.parseFromSlice(WireResult, allocator, stdout, .{ .allocate = .alloc_always }) catch return .{
        .content = try allocator.dupe(u8, "Tool worker returned an invalid result."),
        .is_error = true,
    };
    defer parsed.deinit();
    return .{
        .content = try allocator.dupe(u8, parsed.value.content),
        .is_error = parsed.value.is_error,
        .exit_code = parsed.value.exit_code,
        .timed_out = parsed.value.timed_out,
        .truncated = parsed.value.truncated,
    };
}

/// Kill and reap the worker and any background processes left in its group.
fn killGroup(child: *std.process.Child, io: std.Io) ?std.process.Child.Term {
    const pid = child.id orelse return null;
    std.posix.kill(-pid, .KILL) catch {};
    return child.wait(io) catch null;
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

test "worker JSON preserves status and rejects missing fields" {
    const a = std.testing.allocator;
    const result = try parseResult(a, "{\"content\":\"failed\",\"is_error\":true,\"exit_code\":7,\"timed_out\":true,\"truncated\":true}", "", .{ .exited = 0 });
    defer result.deinit(a);
    try std.testing.expect(result.is_error and result.timed_out and result.truncated);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    const invalid = try parseResult(a, "{\"content\":\"old\",\"is_error\":false}", "", .{ .exited = 0 });
    defer invalid.deinit(a);
    try std.testing.expect(invalid.is_error);
    try std.testing.expectEqualStrings("Tool worker returned an invalid result.", invalid.content);
    const failed = try parseResult(a, "", "worker crashed", .{ .exited = 137 });
    defer failed.deinit(a);
    try std.testing.expect(failed.is_error and !failed.timed_out);
    try std.testing.expectEqual(@as(?u8, 137), failed.exit_code);
}

test "shell timeout is bounded and applies only to commands" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 180), try shellTimeout(a, "bash", "{}"));
    try std.testing.expectEqual(@as(u32, 600), try shellTimeout(a, "bash", "{\"timeout_seconds\":600}"));
    try std.testing.expectEqual(@as(u32, 180), try shellTimeout(a, "read", "{\"timeout_seconds\":600}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "bash", "{\"timeout_seconds\":0}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "bash", "{\"timeout_seconds\":3601}"));
    try std.testing.expectError(error.InvalidTimeout, shellTimeout(a, "bash", "{\"timeout_seconds\":\"600\"}"));
}
