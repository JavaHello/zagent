const std = @import("std");
const Agent = @import("../agent/mod.zig").Agent;
const prompt = @import("../agent/prompt.zig");
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "report",
    .description = "Send the agent that called you a short progress report and wait for its decision. It is how a check-in is answered: the caller reads the report, then either tells you to continue or stops the task and asks for your final report. Keep it to a status line — what is done, what you ran, what is left — not the final answer.",
    .parameters_json =
    \\{"type":"object","properties":{"summary":{"type":"string","description":"Short progress report: what you have done and changed, what you ran and what it printed, what is verified, and what is left"}},"required":["summary"]}
    ,
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args);
}

pub fn execute(self: *Agent, arguments: []const u8) !tool.ToolResult {
    const supervisor = self.supervisor orelse return .{
        .content = try self.allocator.dupe(u8, "The report tool belongs to a sub-agent. On the terminal, answer the user instead."),
        .is_error = true,
    };
    const parsed = std.json.parseFromSlice(struct { summary: []const u8 }, self.allocator, arguments, .{}) catch {
        return .{
            .content = try self.allocator.dupe(u8, "Error: report takes a 'summary' string: what is done, what you ran, what is left."),
            .is_error = true,
        };
    };
    defer parsed.deinit();
    const summary = std.mem.trim(u8, parsed.value.summary, " \t\r\n");
    if (summary.len == 0 or !std.unicode.utf8ValidateSlice(summary)) return .{
        .content = try self.allocator.dupe(u8, "Error: the report's summary must be non-empty UTF-8: say what is done, what you ran, and what is left."),
        .is_error = true,
    };
    const report = if (summary.len > prompt.max_subagent_report_bytes)
        try std.fmt.allocPrint(self.allocator, "{s}…", .{cutUtf8(summary, prompt.max_subagent_report_bytes)})
    else
        try self.allocator.dupe(u8, summary);
    const verdict = supervisor.handOver(report) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
    };
    return .{
        .content = try self.allocator.dupe(u8, switch (verdict) {
            .continue_task => prompt.continue_verdict,
            .stop => prompt.stop_verdict,
        }),
        .is_error = false,
    };
}

/// Clip model text without splitting its final Unicode character.
pub fn cutUtf8(bytes: []const u8, max: usize) []const u8 {
    if (bytes.len <= max) return bytes;
    var end = max;
    while (end > 0 and (bytes[end] & 0xc0) == 0x80) end -= 1;
    return bytes[0..end];
}
