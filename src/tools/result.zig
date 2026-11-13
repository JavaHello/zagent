const std = @import("std");
const sanitize = @import("../util/terminal/sanitize.zig");

/// The name `ccr` gives a cached entry: twelve hex characters, drawn at random
/// so two entries of one run cannot collide.
pub const ccr_id_len: usize = 12;
pub const CcrId = [ccr_id_len]u8;

pub const ToolStatus = struct {
    is_error: bool,
    exit_code: ?u8 = null,
    timed_out: bool = false,
};

/// Status stays visible even when CCR caches the body. A result that was
/// cached says so in its content, naming the entry `ccr_retrieve` reads back.
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
    /// The entry this content is a preview of, when it is one: `bash` names the
    /// entry it kept a long output in, and `ccr` names the one it just wrote.
    /// A result that already carries an id is never cached again — keeping a
    /// preview would store the stand-in instead of the text it names — and
    /// `ccr_retrieve` marks each page with the entry it came from for the same
    /// reason.
    ccr_id: ?CcrId = null,

    pub fn status(self: ToolResult) ToolStatus {
        return .{ .is_error = self.is_error, .exit_code = self.exit_code, .timed_out = self.timed_out };
    }

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

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
    };
}

/// Strip terminal control sequences and escape invalid text without clipping.
pub fn normalizeToolText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try sanitize.writeSanitized(&aw.writer, raw);
    if (aw.written().len == 0) try aw.writer.writeAll("(no output)");
    return aw.toOwnedSlice();
}

pub fn toolError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

test "finalization preserves complete oversized results and status" {
    const a = std.testing.allocator;
    // Larger than anything a reader or a cache would hand over in one piece:
    // finalizing text cleans it and never clips it.
    const oversized = 16 * 1024;
    const raw = try a.alloc(u8, oversized);
    defer a.free(raw);
    @memset(raw, 'x');
    const result = try finalizeResult(a, raw, .{ .is_error = false, .exit_code = 7, .timed_out = true });
    defer result.deinit(a);
    try std.testing.expectEqualStrings(raw, result.content);
    try std.testing.expect(!result.is_error and result.ccr_id == null and result.timed_out);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    const content = try finalizeToolContent(a, raw);
    defer a.free(content);
    try std.testing.expectEqualStrings(raw, content);
}

test "owned finalization transfers the full allocation and preserves status" {
    const a = std.testing.allocator;
    const normalized = try a.alloc(u8, 16 * 1024 + 1);
    @memset(normalized, 'x');
    const result = finalizeNormalizedResultOwned(normalized, .{ .is_error = false, .timed_out = true });
    defer result.deinit(a);
    try std.testing.expectEqual(normalized.ptr, result.content.ptr);
    try std.testing.expectEqual(normalized.len, result.content.len);
    try std.testing.expect(!result.is_error and result.timed_out and result.ccr_id == null);
}

test "normalization sanitizes without changing printed markers into status" {
    const a = std.testing.allocator;
    const normalized = try normalizeToolText(a, "\x1b[32mgreen\x1b[0m\xff");
    defer a.free(normalized);
    try std.testing.expectEqualStrings("green\\xFF", normalized);
    const printed = try finalizeResult(a, "... (truncated)", .{ .is_error = false });
    defer printed.deinit(a);
    try std.testing.expect(printed.ccr_id == null);
    const encoded = try formatToolOutput(a, .{ .is_error = true, .exit_code = 7, .timed_out = true }, "body");
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"exit_code\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"timed_out\":true") != null);
}
