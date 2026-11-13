//! The shape of a tool result: the text a tool hands the agent, how the call
//! ended, and the JSON object the model receives.
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

/// A silent tool returns an empty output string; status carries its outcome.
pub const no_output = "";

/// Serialize the complete result, including the CCR identity, for the model.
pub fn formatToolOutput(allocator: std.mem.Allocator, result: ToolResult) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, result, .{});
}

pub const ToolResult = struct {
    output: []const u8 = "",
    is_error: bool,
    exit_code: ?u8 = null,
    timed_out: bool = false,
    /// The signal that ended the program, for a tool that ran one: a name from
    /// the table in `util/signals.zig`, never owned and never freed with the
    /// result. Null for a tool that ran nothing
    /// and for a program that chose its own exit status.
    termination: ?[]const u8 = null,
    /// The entry this content stands for, when it stands for one: `ccr` names
    /// the entry it just wrote, in place of a body too long to hand over. A
    /// result that already carries an id is never cached again — keeping a
    /// preview would store the stand-in instead of the text it names — and
    /// `ccr_retrieve` marks each page with the entry it came from for the same
    /// reason.
    ccr_id: ?CcrId = null,

    /// A tool response is a single JSON object, not a status header and body.
    pub fn jsonStringify(self: ToolResult, jw: anytype) !void {
        try jw.write(.{
            .output = self.output,
            .is_error = self.is_error,
            .exit_code = self.exit_code,
            .timed_out = self.timed_out,
            .termination = self.termination,
            .ccr_id = if (self.ccr_id) |*id| @as(?[]const u8, id) else null,
        });
    }

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

/// A result from text the caller already owns and hands over: the text becomes
/// the content unchanged, so only the status is added.
pub fn ownedResult(content: []u8, status: ToolResult) ToolResult {
    var result = status;
    result.output = content;
    return result;
}

pub fn toolError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .output = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
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
    try std.testing.expectEqual(text.ptr, result.output.ptr);
    try std.testing.expectEqual(text.len, result.output.len);
    try std.testing.expect(!result.is_error and result.timed_out and result.ccr_id == null);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
}

test "the JSON result names every field and keeps output separate" {
    const a = std.testing.allocator;
    const printed = try toolError(a, "Error: {s}", .{"nope"});
    defer printed.deinit(a);
    try std.testing.expect(printed.is_error and printed.ccr_id == null);
    try std.testing.expectEqualStrings("Error: nope", printed.output);
    const encoded = try formatToolOutput(a, .{ .output = "body", .is_error = true, .exit_code = 7, .timed_out = true });
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"exit_code\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"timed_out\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"output\":\"body\"") != null);
}

test "a killed program says so in the status, not in its output" {
    const a = std.testing.allocator;
    // The content is the program's own text — what it printed, or that it
    // printed nothing — and the signal that ended it travels beside it, where
    // every reader of the status can find it.
    const result = ownedResult(try a.dupe(u8, no_output), .{
        .is_error = true,
        .termination = "SIGTERM",
    });
    defer result.deinit(a);
    try std.testing.expectEqualStrings("", result.output);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqual(@as(?u8, null), result.exit_code);
    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqualStrings("SIGTERM", result.termination.?);
    try std.testing.expectEqual(@as(?CcrId, null), result.ccr_id);
    const encoded = try formatToolOutput(a, result);
    defer a.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"termination\":\"SIGTERM\"") != null);
    try std.testing.expectEqualStrings(
        "{\"output\":\"\",\"is_error\":true,\"exit_code\":null,\"timed_out\":false,\"termination\":\"SIGTERM\",\"ccr_id\":null}",
        encoded,
    );
}
