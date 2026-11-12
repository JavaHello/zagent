const std = @import("std");
const plan_mod = @import("../state/plan.zig");
const Agent = @import("../agent/mod.zig").Agent;
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "plan",
    .description = "Read or update the plan for the work in progress: with no arguments it returns the complete plan, with 'steps' it replaces the whole plan (an empty array clears it), and with 'index' plus 'status' or 'note' it updates one step. Successful updates return only a brief change acknowledgement, not the checklist; call with no arguments to read it. The plan belongs to the session — it is saved with it and restored when it is resumed — so it, not the message history, is the map of long work.",
    .parameters_json =
    \\{"type":"object","properties":{"steps":{"type":"array","description":"The complete ordered plan, replacing the current one: one short line per step that can be verified on its own. At most 50 steps.","maxItems":50,"items":{"type":"object","properties":{"title":{"type":"string","description":"One line: what this step accomplishes"},"status":{"type":"string","enum":["pending","in_progress","completed","blocked"],"description":"Defaults to pending; at most one step is in_progress"},"note":{"type":"string","description":"Optional one-line reason kept under the step, for example why it is blocked"}},"required":["title"]}},"index":{"type":"integer","minimum":1,"description":"1-based step to update, when 'steps' is omitted"},"status":{"type":"string","enum":["pending","in_progress","completed","blocked"],"description":"New status for that step"},"note":{"type":"string","description":"New note for that step; an empty string removes the old one"}},"required":[]}
    ,
    .label = "plan…",
    .summary = writeSummary,
    .run = run,
};

pub const ArgumentStep = struct {
    title: []const u8,
    status: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const Arguments = struct {
    steps: ?[]const ArgumentStep = null,
    index: ?usize = null,
    status: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    return writeCallSummary(w, ctx.allocator, arguments);
}

pub fn writeCallSummary(w: *std.Io.Writer, allocator: std.mem.Allocator, arguments_json: []const u8) !bool {
    const parsed = std.json.parseFromSlice(Arguments, allocator, arguments_json, .{}) catch return false;
    defer parsed.deinit();
    const args = parsed.value;
    if (args.steps) |steps| {
        try w.print("{d} steps", .{steps.len});
        for (steps, 0..) |step, i| {
            if (i == 3) {
                try w.writeAll(", …");
                break;
            }
            try w.writeAll(if (i == 0) ": " else ", ");
            try writeOnOneLine(w, step.title);
        }
        return true;
    }
    if (args.index) |index| {
        try w.print("step {d}", .{index});
        if (args.status) |status| {
            try w.writeAll(" → ");
            try writeOnOneLine(w, status);
        }
        if (args.note) |note| {
            try w.writeAll(" · ");
            try writeOnOneLine(w, note);
        }
        return true;
    }
    try w.writeAll("read");
    return true;
}

fn writeOnOneLine(w: *std.Io.Writer, raw: []const u8) !void {
    var start: usize = 0;
    for (raw, 0..) |byte, i| {
        if (byte != '\n' and byte != '\r' and byte != '\t') continue;
        try @import("../util/text.zig").writeSanitized(w, raw[start..i]);
        try w.writeByte(' ');
        start = i + 1;
    }
    try @import("../util/text.zig").writeSanitized(w, raw[start..]);
}

pub fn describeChange(plan: *const plan_mod.Plan, allocator: std.mem.Allocator, index: ?usize, previous_status: ?plan_mod.Status, note_changed: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    if (index) |number| {
        if (number == 0 or number > plan.steps.items.len) return error.NoSuchStep;
        const status = plan.steps.items[number - 1].status;
        if (previous_status) |previous| {
            try aw.writer.print("Step {d}: {s} -> {s}", .{ number, @tagName(previous), @tagName(status) });
        } else {
            try aw.writer.print("Step {d}: {s}", .{ number, @tagName(status) });
        }
        if (note_changed) try aw.writer.writeAll("; note updated");
        try aw.writer.writeAll(".\n");
    } else if (plan.steps.items.len == 0) {
        try aw.writer.writeAll("Plan cleared.\n");
    } else {
        const progress = plan.tally();
        try aw.writer.print("Plan saved: {d} steps, {d} completed, {d} blocked.\n", .{ progress.total, progress.done, progress.blocked });
    }
    return aw.toOwnedSlice();
}

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args);
}

/// Changes are persisted by the agent's end-of-batch checkpoint, never here:
/// a mid-batch snapshot would contain tool calls without their results.
pub fn execute(self: *Agent, arguments: []const u8) !tool.ToolResult {
    const parsed = std.json.parseFromSlice(Arguments, self.allocator, arguments, .{}) catch {
        return .{
            .content = try self.allocator.dupe(u8, "Error: expected an object with an optional 'steps' array, or 'index' with 'status' or 'note'."),
            .is_error = true,
        };
    };
    defer parsed.deinit();
    const args = parsed.value;
    if (args.steps == null and args.index == null) {
        if (args.status != null or args.note != null) return .{
            .content = try self.allocator.dupe(u8, "Error: 'status' and 'note' change the step named by 'index'; add the index, or send 'steps' to replace the plan."),
            .is_error = true,
        };
        return .{ .content = try self.plan.describe(self.allocator), .is_error = false };
    }
    if (args.steps != null and args.index != null) return .{
        .content = try self.allocator.dupe(u8, "Error: send either 'steps' or 'index', not both."),
        .is_error = true,
    };
    var previous_status: ?plan_mod.Status = null;
    if (args.steps) |raw_steps| {
        var converted: std.ArrayList(plan_mod.NewStep) = .empty;
        defer converted.deinit(self.allocator);
        try converted.ensureTotalCapacity(self.allocator, raw_steps.len);
        for (raw_steps) |step| {
            const status = if (step.status) |label| plan_mod.Status.parse(label) orelse return .{
                .content = try std.fmt.allocPrint(self.allocator, "Error: step status '{s}' must be pending, in_progress, completed or blocked.", .{label}),
                .is_error = true,
            } else null;
            converted.appendAssumeCapacity(.{ .title = step.title, .status = status, .note = step.note });
        }
        self.plan.setSteps(converted.items) catch |err| return .{
            .content = try std.fmt.allocPrint(self.allocator, "The plan was not updated: {s}", .{@errorName(err)}),
            .is_error = true,
        };
    } else {
        const status = if (args.status) |label| plan_mod.Status.parse(label) orelse return .{
            .content = try std.fmt.allocPrint(self.allocator, "Error: status '{s}' must be pending, in_progress, completed or blocked.", .{label}),
            .is_error = true,
        } else null;
        if (status == null and args.note == null) return .{
            .content = try self.allocator.dupe(u8, "Error: 'index' needs a 'status' or a 'note' to change."),
            .is_error = true,
        };
        if (args.index.? > 0 and args.index.? <= self.plan.steps.items.len)
            previous_status = self.plan.steps.items[args.index.? - 1].status;
        self.plan.update(args.index.?, status, args.note) catch |err| switch (err) {
            error.NoSuchStep => return .{
                .content = try std.fmt.allocPrint(self.allocator, "Error: there is no step {d}; the plan has {d}.", .{ args.index.?, self.plan.steps.items.len }),
                .is_error = true,
            },
            else => return .{
                .content = try std.fmt.allocPrint(self.allocator, "The plan was not updated: {s}", .{@errorName(err)}),
                .is_error = true,
            },
        };
    }
    return .{ .content = try describeChange(&self.plan, self.allocator, args.index, previous_status, args.note != null), .is_error = false };
}
