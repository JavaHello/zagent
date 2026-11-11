//! Formatting for the ChatGPT subscription usage endpoint. Unknown fields are
//! ignored so backend additions do not break the command.
const std = @import("std");
const Window = struct {
    used_percent: ?f64 = null,
    limit_window_seconds: ?u64 = null,
    reset_after_seconds: ?u64 = null,
};
const Limits = struct {
    allowed: ?bool = null,
    limit_reached: ?bool = null,
    primary_window: ?Window = null,
    secondary_window: ?Window = null,
};
const Quota = struct {
    plan_type: ?[]const u8 = null,
    rate_limit: ?Limits = null,
};

pub fn formatQuota(a: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Quota, a, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    try w.print("ChatGPT plan: {s}\n", .{parsed.value.plan_type orelse "unknown"});
    if (parsed.value.rate_limit) |limits| {
        if (limits.limit_reached == true or limits.allowed == false)
            try w.writeAll("Account quota: limit reached\n");
        if (limits.primary_window) |window| try writeWindow(w, "Primary", window);
        if (limits.secondary_window) |window| try writeWindow(w, "Secondary", window);
        if (limits.primary_window == null and limits.secondary_window == null)
            try w.writeAll("Account quota: usage windows unavailable\n");
    } else try w.writeAll("Account quota: unavailable in server response\n");
    return a.dupe(u8, out.written());
}

fn writeWindow(w: *std.Io.Writer, label: []const u8, window: Window) !void {
    try w.print("  {s}", .{label});
    if (window.limit_window_seconds) |seconds| try w.print(" ({d}s window)", .{seconds});
    if (window.used_percent) |used| {
        if (!std.math.isFinite(used) or used < 0 or used > 100) return error.InvalidQuotaResponse;
        try w.print(": {d:.1}% used, {d:.1}% remaining", .{ used, 100 - used });
    } else try w.writeAll(": usage unavailable");
    if (window.reset_after_seconds) |seconds|
        try w.print("; resets in {d}h {d}m {d}s", .{ seconds / 3600, seconds / 60 % 60, seconds % 60 });
    try w.writeByte('\n');
}

test "quota formats both windows and ignores new fields" {
    const a = std.testing.allocator;
    const output = try formatQuota(a,
        \\{"plan_type":"plus","extra":true,"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_after_seconds":3661},"secondary_window":{"used_percent":100}}}
    );
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "plus") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "25.0% used, 75.0% remaining") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1h 1m 1s") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "100.0% used, 0.0% remaining") != null);
}

test "missing quota is unavailable rather than zero usage" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"rate_limit\":{}}", "{\"rate_limit\":null}" }) |body| {
        const output = try formatQuota(a, body);
        defer a.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "unavailable") != null);
    }
    try std.testing.expectError(error.InvalidQuotaResponse, formatQuota(a, "{\"rate_limit\":{\"primary_window\":{\"used_percent\":101}}}"));
}
