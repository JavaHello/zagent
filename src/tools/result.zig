const std = @import("std");
const text = @import("../util/text.zig");

pub const ToolStatus = struct {
    is_error: bool,
    exit_code: ?u8 = null,
    timed_out: bool = false,
    truncated: bool = false,
};

/// Status remains visible even when CCR caches or deduplicates the body.
pub fn formatToolOutput(allocator: std.mem.Allocator, status: ToolStatus, content: []const u8) ![]u8 {
    const encoded = try std.json.Stringify.valueAlloc(allocator, status, .{});
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "[tool_status {s}]\n{s}", .{ encoded, content });
}

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool,
    exit_code: ?u8 = null,
    timed_out: bool = false,
    truncated: bool = false,

    pub fn status(self: ToolResult) ToolStatus {
        return .{ .is_error = self.is_error, .exit_code = self.exit_code, .timed_out = self.timed_out, .truncated = self.truncated };
    }

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

/// CCR's cache threshold, not a tool-result size limit.
pub const max_output_bytes: usize = 40 * 1024;
/// CCR page and bash streaming-preview budgets. Producers must not clip their
/// complete results to these sizes before the CCR hook can cache them.
pub const default_output_bytes: usize = 12 * 1024;
pub const page_room_bytes: usize = default_output_bytes - 256;

pub fn finalizeToolContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return normalizeToolText(allocator, raw);
}

pub fn finalizeResult(allocator: std.mem.Allocator, raw: []const u8, status: ToolStatus) !ToolResult {
    return finalizeNormalizedResultOwned(try normalizeToolText(allocator, raw), status);
}

/// Consumes sanitized, owned text without discarding any content.
pub fn finalizeNormalizedResultOwned(normalized: []u8, status: ToolStatus) ToolResult {
    return .{
        .content = normalized,
        .is_error = status.is_error,
        .exit_code = status.exit_code,
        .timed_out = status.timed_out,
        .truncated = status.truncated,
    };
}

/// Compatibility wrappers; the old byte budget no longer clips tool output.
pub fn finalizeResultLimited(allocator: std.mem.Allocator, raw: []const u8, status: ToolStatus, _: usize) !ToolResult {
    return finalizeResult(allocator, raw, status);
}

pub fn finalizeNormalizedResultOwnedLimited(_: std.mem.Allocator, normalized: []u8, status: ToolStatus, _: usize) !ToolResult {
    return finalizeNormalizedResultOwned(normalized, status);
}

pub fn finalizeToolContentLimited(allocator: std.mem.Allocator, raw: []const u8, _: usize) ![]u8 {
    return normalizeToolText(allocator, raw);
}

/// Strip terminal control sequences and escape invalid text without clipping.
pub fn normalizeToolText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try text.writeSanitized(&aw.writer, raw);
    if (aw.written().len == 0) try aw.writer.writeAll("(no output)");
    return aw.toOwnedSlice();
}

pub fn toolError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

test "finalization preserves complete oversized results and status for CCR" {
    const a = std.testing.allocator;
    const raw = try a.alloc(u8, max_output_bytes + 512);
    defer a.free(raw);
    @memset(raw, 'x');
    const result = try finalizeResultLimited(a, raw, .{ .is_error = false, .exit_code = 7, .timed_out = true }, 32);
    defer result.deinit(a);
    try std.testing.expectEqualStrings(raw, result.content);
    try std.testing.expect(!result.is_error and !result.truncated and result.timed_out);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    const content = try finalizeToolContentLimited(a, raw, 1);
    defer a.free(content);
    try std.testing.expectEqualStrings(raw, content);
}

test "owned finalization transfers the full allocation and preserves explicit pagination status" {
    const a = std.testing.allocator;
    const normalized = try a.alloc(u8, max_output_bytes + 1);
    @memset(normalized, 'x');
    const result = try finalizeNormalizedResultOwnedLimited(a, normalized, .{ .is_error = false, .truncated = true }, 0);
    defer result.deinit(a);
    try std.testing.expectEqual(normalized.ptr, result.content.ptr);
    try std.testing.expectEqual(normalized.len, result.content.len);
    try std.testing.expect(!result.is_error and result.truncated);
}

test "normalization sanitizes without changing printed truncation into status" {
    const a = std.testing.allocator;
    const normalized = try normalizeToolText(a, "\x1b[32mgreen\x1b[0m\xff");
    defer a.free(normalized);
    try std.testing.expectEqualStrings("green\\xFF", normalized);
    const printed = try finalizeResult(a, "... (truncated)", .{ .is_error = false });
    defer printed.deinit(a);
    try std.testing.expect(!printed.truncated);
    const encoded = try formatToolOutput(a, .{ .is_error = true, .exit_code = 7, .timed_out = true }, "body");
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"exit_code\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"timed_out\":true") != null);
}
