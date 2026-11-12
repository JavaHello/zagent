const std = @import("std");
const text = @import("../util/text.zig");
const util = @import("util.zig");

pub const ToolStatus = struct {
    is_error: bool,
    exit_code: ?u8 = null,
    timed_out: bool = false,
    truncated: bool = false,
};

/// Status is separate from the body in snapshots, but visible to the model
/// even when output is empty, deduplicated, or clipped.
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
        return .{
            .is_error = self.is_error,
            .exit_code = self.exit_code,
            .timed_out = self.timed_out,
            .truncated = self.truncated,
        };
    }

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

/// The one limit on a tool result. A tool that shapes its own output (`read`,
/// `ls`, the searches) keeps a page under it, and `clipOversized` holds the
/// line for whatever gets past them, an MCP server's answer among it.
///
/// No tool description quotes this number. The model is not asked to budget a
/// call against a size, and a result that still lands over the limit comes back
/// as an error naming it, so the next call can be narrowed rather than the
/// model reading a silently cut answer.
pub const max_output_bytes: usize = 40 * 1024;

/// Room one page of a tool that shapes its own output (`read`, `ls`, the
/// searches) may fill. A little under the default 12 KiB budget, so the line a page
/// appends — where the next one starts, that results were left out, or which
/// single row was too long — still fits under the limit the finished result is
/// held to.
pub const default_output_bytes: usize = 12 * 1024;
pub const page_room_bytes: usize = default_output_bytes - 256;

test "default pages leave notice room without changing the hard limit" {
    try std.testing.expectEqual(@as(usize, 12 * 1024 - 256), page_room_bytes);
    try std.testing.expectEqual(@as(usize, 40 * 1024), max_output_bytes);
}

/// Cut a result down to `max_output_bytes` when a tool let more through, and
/// report the cut as an error so the model narrows the call. Takes ownership of
/// `result.content`: consumed on success and failure (returned unchanged if it fits).
pub fn clipOversized(allocator: std.mem.Allocator, result: ToolResult) !ToolResult {
    if (result.content.len <= max_output_bytes) return result;
    defer allocator.free(result.content);
    const total = result.content.len;
    const notice = try std.fmt.allocPrint(
        allocator,
        "\n[Output truncated: {d} bytes came back, over the {d} KiB limit for one tool result. Narrow the request to see the rest.]",
        .{ total, max_output_bytes / 1024 },
    );
    defer allocator.free(notice);
    // The notice counts against the limit, and the text keeps whole characters.
    const kept = util.truncateUtf8(result.content, max_output_bytes - notice.len);
    const content = try std.fmt.allocPrint(allocator, "{s}{s}", .{ kept, notice });
    return .{
        .content = content,
        .is_error = true,
        .exit_code = result.exit_code,
        .timed_out = result.timed_out,
        .truncated = true,
    };
}

test "a result over the limit is cut there, kept whole and reported as an error" {
    const a = std.testing.allocator;

    const small = ToolResult{ .content = try a.dupe(u8, "kept"), .is_error = false };
    const untouched = try clipOversized(a, small);
    defer untouched.deinit(a);
    try std.testing.expect(!untouched.is_error and !untouched.truncated);
    try std.testing.expectEqualStrings("kept", untouched.content);

    // Enough three byte characters that the cut lands inside one of them.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(a);
    while (big.items.len <= max_output_bytes) try big.appendSlice(a, "你");
    const clipped = try clipOversized(a, .{ .content = try big.toOwnedSlice(a), .is_error = false, .exit_code = 3 });
    defer clipped.deinit(a);
    try std.testing.expect(clipped.is_error and clipped.truncated);
    try std.testing.expectEqual(@as(?u8, 3), clipped.exit_code);
    try std.testing.expect(clipped.content.len <= max_output_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped.content));
    try std.testing.expect(std.mem.indexOf(u8, clipped.content, "40 KiB limit") != null);
}

pub fn finalizeToolContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return finalizeToolContentLimited(allocator, raw, max_output_bytes);
}

/// Turn text that came from outside this program into what the model is shown:
/// Preserve truncation at the point it happens, rather than guessing from a
/// suffix which the external tool could itself have printed.
pub fn finalizeResultLimited(allocator: std.mem.Allocator, raw: []const u8, status: ToolStatus, max_len: usize) !ToolResult {
    const normalized = try normalizeToolText(allocator, raw);
    return finalizeNormalizedResultOwnedLimited(allocator, normalized, status, max_len);
}

/// Takes already sanitized, owned text. Consumes it on success and failure.
pub fn finalizeNormalizedResultOwnedLimited(allocator: std.mem.Allocator, normalized: []u8, status: ToolStatus, max_len: usize) !ToolResult {
    // A result held at the limit is an error even when the tool itself
    // succeeded: what the model has in hand is part of an answer, and it has to
    // narrow the call rather than read the rest as if it were all of it.
    const clipped = normalized.len > max_len;
    return .{
        .content = try clipNormalizedOwned(allocator, normalized, max_len),
        .is_error = status.is_error or clipped,
        .exit_code = status.exit_code,
        .timed_out = status.timed_out,
        .truncated = status.truncated or clipped,
    };
}

/// Turn text that came from outside this program into what the model is shown:
/// sanitized, then capped on a UTF-8 boundary. Shared with the MCP client,
/// whose results are as untrusted as a tool's output and are read the same way.
pub fn finalizeToolContentLimited(allocator: std.mem.Allocator, raw: []const u8, max_len: usize) ![]u8 {
    const normalized = try normalizeToolText(allocator, raw);
    return clipNormalizedOwned(allocator, normalized, max_len);
}

/// Consumes normalized on every path; fitting buffers transfer without a copy.
fn clipNormalizedOwned(allocator: std.mem.Allocator, normalized: []u8, max_len: usize) ![]u8 {
    const suffix = "\n... (truncated)";
    if (normalized.len <= max_len) return normalized;
    defer allocator.free(normalized);
    if (max_len < suffix.len) return allocator.dupe(u8, suffix[0..max_len]);

    const kept = util.truncateUtf8(normalized, max_len - suffix.len);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ kept, suffix });
}

/// Strip what a terminal would act on out of tool output, and escape the rest
/// of what is not text. The rule itself lives in `text.zig`, which is where the
/// renderer and the diff drawing get it from too.
pub fn normalizeToolText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try text.writeSanitized(&aw.writer, raw);

    if (aw.written().len == 0) {
        try aw.writer.writeAll("(no output)");
    }

    return aw.toOwnedSlice();
}

pub fn toolError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

test "tool status preserves failures and records actual truncation not printed suffixes" {
    const a = std.testing.allocator;
    const result = try finalizeResultLimited(a, "abcdefghijklmnopqrstuvwxyz0123456789", .{ .is_error = true, .exit_code = 7, .timed_out = true }, 32);
    defer a.free(result.content);
    try std.testing.expect(result.status().is_error);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    try std.testing.expect(result.timed_out and result.truncated);
    const printed = try finalizeResultLimited(a, "... (truncated)", .{ .is_error = false }, 32);
    defer a.free(printed.content);
    try std.testing.expect(!printed.truncated);
    const encoded = try formatToolOutput(a, result.status(), result.content);
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"exit_code\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"timed_out\":true") != null);
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

test "a response body is truncated at the result limit, not at its own" {
    const allocator = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    for (0..max_output_bytes + 512) |_| try raw.append(allocator, 'x');

    const finalized = try finalizeToolContentLimited(allocator, raw.items, max_output_bytes);
    defer allocator.free(finalized);

    try std.testing.expect(std.mem.endsWith(u8, finalized, "\n... (truncated)"));
    try std.testing.expect(finalized.len <= max_output_bytes);
}

test "finalize tool content truncates on utf8 boundary" {
    const allocator = std.testing.allocator;
    var repeated: std.ArrayList(u8) = .empty;
    defer repeated.deinit(allocator);
    while (repeated.items.len <= max_output_bytes) {
        try repeated.appendSlice(allocator, "你好");
    }

    const finalized = try finalizeToolContent(allocator, repeated.items);
    defer allocator.free(finalized);
    try std.testing.expect(std.mem.endsWith(u8, finalized, "\n... (truncated)"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(finalized));
}
