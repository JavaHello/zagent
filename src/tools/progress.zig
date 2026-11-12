const std = @import("std");

/// A label for the animation shown while `name` runs, or null for a tool that
/// must not have one.
///
/// The names are written out rather than taken from the call: a tool name is
/// model output, and a name carrying escape sequences would be written straight
/// into the terminal (see `text.zig`). `ask_user` is deliberately absent — it
/// asks a question on the terminal and reads the answer from it, so it needs
/// the line to itself.
pub fn progressLabel(name: []const u8) ?[]const u8 {
    const labels = [_]struct { name: []const u8, label: []const u8 }{
        .{ .name = "bash", .label = "bash…" },
        .{ .name = "read", .label = "read…" },
        .{ .name = "write", .label = "write…" },
        .{ .name = "ls", .label = "ls…" },
        .{ .name = "rg", .label = "rg…" },
        .{ .name = "fd", .label = "fd…" },
        .{ .name = "apply_patch", .label = "apply_patch…" },
        .{ .name = "grep", .label = "grep…" },
        .{ .name = "find", .label = "find…" },
        .{ .name = "http", .label = "http…" },
        .{ .name = "memory_save", .label = "saving memory…" },
        .{ .name = "memory_search", .label = "searching memory…" },
        .{ .name = "plan", .label = "plan…" },
    };
    for (labels) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.label;
    }
    return null;
}

test "every tool that waits has a progress label, ask_user does not" {
    try std.testing.expect(progressLabel("shell") == null);
    try std.testing.expect(progressLabel("http_request") == null);
    const labelled = [_][]const u8{ "bash", "read", "write", "ls", "rg", "fd", "apply_patch", "grep", "find", "http" };
    for (labelled) |name| {
        const label = progressLabel(name) orelse return error.TestUnexpectedResult;
        // The label names the tool, so a user watching the line knows what is
        // taking the time.
        try std.testing.expect(std.mem.startsWith(u8, label, name));
    }

    // ask_user puts a question on the terminal and reads the answer from it:
    // an animation over that line would fight the prompt.
    try std.testing.expectEqual(@as(?[]const u8, null), progressLabel("ask_user"));
    // A name the model made up runs nothing and waits for nothing; it is not
    // written to the terminal either.
    try std.testing.expectEqual(@as(?[]const u8, null), progressLabel("rm -rf /"));
    try std.testing.expectEqual(@as(?[]const u8, null), progressLabel("shell\x1b[31m"));
}
