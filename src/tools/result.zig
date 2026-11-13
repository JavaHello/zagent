//! The shape of a tool result: the text a tool hands the agent, how the call
//! ended, and the header the text is read under.
//!
//! Nothing is cleaned, clipped or cached here. A tool's text is the tool's own
//! answer — a file's bytes, a program's output, a server's reply — and a model
//! that quotes, copies or patches from it needs it as it was written. Where a
//! terminal must not see what the text holds, the guard is at the point the
//! terminal is written to.

const std = @import("std");

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

/// A result from text the caller already owns and hands over: the text becomes
/// the content unchanged, so only the status is added.
pub fn ownedResult(content: []u8, status: ToolStatus) ToolResult {
    return .{
        .content = content,
        .is_error = status.is_error,
        .exit_code = status.exit_code,
        .timed_out = status.timed_out,
    };
}

pub fn toolError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

test "a result hands on the text it was given, whole and unchanged" {
    const a = std.testing.allocator;
    // Larger than anything a terminal preview would show, and carrying bytes a
    // terminal acts on: neither is a reason to change what the model receives.
    const text = try a.alloc(u8, 16 * 1024);
    @memset(text, 'x');
    text[0] = 0x1b;
    text[1] = 0xff;
    // The result takes ownership of the text and frees it as its own.
    const result = ownedResult(text, .{ .is_error = false, .exit_code = 7, .timed_out = true });
    defer result.deinit(a);
    try std.testing.expectEqual(text.ptr, result.content.ptr);
    try std.testing.expectEqual(text.len, result.content.len);
    try std.testing.expect(!result.is_error and result.timed_out and result.ccr_id == null);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
}

test "the status header names every field and keeps markers out of it" {
    const a = std.testing.allocator;
    const printed = try toolError(a, "Error: {s}", .{"nope"});
    defer printed.deinit(a);
    try std.testing.expect(printed.is_error and printed.ccr_id == null);
    try std.testing.expectEqualStrings("Error: nope", printed.content);
    const encoded = try formatToolOutput(a, .{ .is_error = true, .exit_code = 7, .timed_out = true }, "body");
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"exit_code\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"timed_out\":true") != null);
    try std.testing.expect(std.mem.endsWith(u8, encoded, "\nbody"));
}
