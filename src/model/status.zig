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

/// Show requested Codex settings, not a claim about the server's chosen tier.
pub fn formatCodexSettings(a: std.mem.Allocator, service_tier: ?[]const u8, reasoning_effort: ?[]const u8) ![]u8 {
    const tier = nonEmpty(service_tier) orelse "default";
    const effort = nonEmpty(reasoning_effort) orelse "default (server-selected)";
    return std.fmt.allocPrint(a, "Codex fast mode: {s} (service_tier: {s})\nreasoning_effort: {s}\n", .{
        if (std.mem.eql(u8, tier, "fast") or std.mem.eql(u8, tier, "priority")) @as([]const u8, "enabled") else "disabled",
        tier,
        effort,
    });
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    if (value) |text| {
        if (text.len > 0) return text;
    }
    return null;
}

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

test "Codex settings show fast mode and reasoning effort" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "fast", "priority" }) |tier| {
        const output = try formatCodexSettings(a, tier, "high");
        defer a.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "fast mode: enabled") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, tier) != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "reasoning_effort: high\n") != null);
    }
    for ([_]?[]const u8{ null, "", "default", "flex" }) |tier| {
        const output = try formatCodexSettings(a, tier, if (tier == null) null else "");
        defer a.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "fast mode: disabled") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "reasoning_effort: default (server-selected)\n") != null);
        if (tier) |value| {
            if (value.len > 0) try std.testing.expect(std.mem.indexOf(u8, output, value) != null);
        }
    }
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
