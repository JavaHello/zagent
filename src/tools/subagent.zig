const std = @import("std");
const Agent = @import("../agent/mod.zig").Agent;
const prompt = @import("../agent/prompt.zig");
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "subagent",
    .description = "Hand one self-contained task to a sub-agent that works on its own and returns a short report. The sub-agent does not read this conversation, cannot ask the user and cannot change the plan, so the task must carry everything it needs. Give it a 'title' — a one-line summary of the task, fewer than 80 characters — because that is what the terminal shows while the run works. Use it for a step whose tool output would flood this conversation; verify its work yourself before marking a plan step done. The sub-agent has no limits of its own: you watch it instead. 'checkin_seconds' is how long it works before it is asked for a progress report, and the call returns with that report, the final report, or the end of the run. A run that reported is paused: call subagent again with its 'id' to let it carry on, or subagent_stop with its 'id' to stop it and take its final report.",
    .parameters_json =
    \\{"type":"object","properties":{"task":{"type":"string","description":"One self-contained task: what to do and how it is verified, in full, since the sub-agent does not read this conversation. Omit it to resume or to start a second sub-agent by 'id'."},"title":{"type":"string","maxLength":79,"description":"One-line summary of the task, fewer than 80 Unicode characters: the terminal shows it on the call's line and while the run works. Omit it and that line falls back to the task itself."},"context":{"type":"string","description":"Optional facts the sub-agent needs: file paths, decisions already made, the shape of the expected change. Keep it short."},"id":{"type":"string","description":"The id of a sub-agent that is paused at a progress report: the call lets it carry on and returns its next report or its final one. Omit it to start a new sub-agent with 'task'."},"checkin_seconds":{"type":"integer","minimum":0,"maximum":3600,"description":"How long the sub-agent works before it is asked for a progress report, default 300. It is not a limit on the work: at the check-in the run pauses with that report, and you decide whether to go on. 0 asks for the report at the next request boundary."}},"required":[]}
    ,
    .run = run,
    .summary = writeRunName,
    .progress = writeProgress,
    .delegated = true,
};

const openai = @import("../model/openai.zig");

fn writeRunName(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    const title = openai.extractStringArg(ctx.allocator, arguments, "title") catch null;
    defer if (title) |value| ctx.allocator.free(value);
    const named = if (title) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    if (named.len > 0) {
        try writeCallBrief(w, named);
        return true;
    }
    const id = openai.extractStringArg(ctx.allocator, arguments, "id") catch null;
    defer if (id) |value| ctx.allocator.free(value);
    if (id) |value| {
        const run_id = std.mem.trim(u8, value, " \t\r\n");
        if (run_id.len > 0) {
            if (ctx.agent) |agent| {
                if (agent.findRun(run_id)) |run_state| {
                    if (run_state.title.len > 0) {
                        try writeCallBrief(w, run_state.title);
                        return true;
                    }
                }
            }
            try writeCallBrief(w, run_id);
            return true;
        }
    }
    const task = openai.extractStringArg(ctx.allocator, arguments, "task") catch return false;
    defer ctx.allocator.free(task);
    const trimmed = std.mem.trim(u8, task, " \t\r\n");
    if (trimmed.len == 0) return false;
    try writeCallBrief(w, trimmed);
    return true;
}

fn writeProgress(ctx: tool.Context, buf: *std.Io.Writer.Allocating, arguments: []const u8) !?[]const u8 {
    try buf.writer.writeAll("subagent · ");
    if (try writeRunName(ctx, &buf.writer, arguments)) return buf.written();
    buf.clearRetainingCapacity();
    try buf.writer.writeAll("subagent…");
    return buf.written();
}

/// Flatten and truncate model-provided run names on a UTF-8 boundary.
pub fn writeCallBrief(w: *std.Io.Writer, raw: []const u8) !void {
    const limit: usize = 120;
    var used: usize = 0;
    while (used < raw.len and used < limit) : (used += 1) {
        if (raw[used] == '\n' or raw[used] == '\r') break;
    }
    while (used > 0 and used < raw.len and (raw[used] & 0xC0) == 0x80) used -= 1;
    try @import("../util/terminal/sanitize.zig").writeSanitized(w, raw[0..used]);
    if (used < raw.len) try w.writeAll("…");
}

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args);
}

pub fn execute(self: *Agent, arguments: []const u8) anyerror!tool.ToolResult {
    if (self.role == .subagent) return .{
        .content = try self.allocator.dupe(u8, "A sub-agent cannot start another sub-agent: do this task yourself and report back."),
        .is_error = true,
    };
    const Arguments = struct {
        task: ?[]const u8 = null,
        title: ?[]const u8 = null,
        context: ?[]const u8 = null,
        id: ?[]const u8 = null,
        checkin_seconds: ?u32 = null,
    };
    const parsed = std.json.parseFromSlice(Arguments, self.allocator, arguments, .{}) catch {
        return .{
            .content = try self.allocator.dupe(u8, "Error: subagent takes a 'task' string to start a run, or the 'id' of a paused run to let it carry on; it may also take 'title', 'context' and 'checkin_seconds' (0-3600)."),
            .is_error = true,
        };
    };
    defer parsed.deinit();
    const checkin = parsed.value.checkin_seconds orelse prompt.default_subagent_checkin_seconds;
    if (checkin > prompt.max_subagent_checkin_seconds) return .{
        .content = try std.fmt.allocPrint(self.allocator, "Error: checkin_seconds must be between 0 and {d}. It is how long the sub-agent works before it is asked for a progress report, not a limit on the work.", .{prompt.max_subagent_checkin_seconds}),
        .is_error = true,
    };
    if (parsed.value.id) |id| {
        const child = self.findRun(id) orelse (self.restoreRun(id, checkin) catch |err| return .{
            .content = if (err == error.FileNotFound)
                try std.fmt.allocPrint(self.allocator, "Error: no saved sub-agent has the id \"{s}\".", .{id})
            else
                try std.fmt.allocPrint(self.allocator, "Error: could not restore sub-agent \"{s}\": {s}.", .{ id, @errorName(err) }),
            .is_error = true,
        });
        child.supervisor.carryOn(checkin == 0);
        return self.waitRun(child, checkin);
    }
    const task = std.mem.trim(u8, parsed.value.task orelse "", " \t\r\n");
    if (task.len == 0 or task.len > prompt.max_subagent_task_bytes or !std.unicode.utf8ValidateSlice(task)) return .{
        .content = try std.fmt.allocPrint(self.allocator, "Error: the sub-agent's task must be non-empty UTF-8 of at most {d} bytes: say what to do, and leave documents in files it can read. Pass the 'id' of a paused run instead to let it carry on.", .{prompt.max_subagent_task_bytes}),
        .is_error = true,
    };
    const context: []const u8 = if (parsed.value.context) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    if (context.len > prompt.max_subagent_context_bytes) return .{
        .content = try std.fmt.allocPrint(self.allocator, "Error: the sub-agent's context must be at most {d} bytes; put longer material in a file and name the path.", .{prompt.max_subagent_context_bytes}),
        .is_error = true,
    };
    const title = std.mem.trim(u8, parsed.value.title orelse "", " \t\r\n");
    if (!validRunTitle(title)) return .{
        .content = try std.fmt.allocPrint(self.allocator, "Error: the title must be one line of at most {d} Unicode characters: it is the summary the terminal shows while the run works, and the task itself says the rest. Leave it out to fall back to the task.", .{prompt.max_subagent_title_chars}),
        .is_error = true,
    };
    const child = self.startRun(task, context, title, checkin) catch |err| return .{
        .content = try std.fmt.allocPrint(self.allocator, "The sub-agent could not start: {s}.", .{@errorName(err)}),
        .is_error = true,
    };
    return self.waitRun(child, checkin);
}

fn validRunTitle(title: []const u8) bool {
    if (title.len == 0) return true;
    if (!std.unicode.utf8ValidateSlice(title)) return false;
    for (title) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    const count = std.unicode.utf8CountCodepoints(title) catch return false;
    return count <= prompt.max_subagent_title_chars;
}
