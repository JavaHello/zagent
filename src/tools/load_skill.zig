const std = @import("std");
const args_mod = @import("args.zig");
const summary = @import("summary.zig");
const tool = @import("tool.zig");
const Skills = @import("../state/skills.zig").Skills;

pub const spec: tool.Tool = .{
    .name = "load_skill",
    .description = "Load a skill's full instructions by name before starting a task it covers. The system prompt lists every installed skill with what it is for; call this once when one matches, then follow the instructions and read the files they name with read_skill_resource.",
    .parameters_json =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Exact name of an installed skill, from the list in the system prompt"}},"required":["name"],"additionalProperties":false}
    ,
    .label = "loading skill…",
    .summary = writeSummary,
    .run = run,
};

/// The skill is what the call is about; it is the only thing on the line.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    return summary.writeFields(w, ctx.allocator, arguments, &.{"name"});
}

fn run(ctx: tool.Context, arguments: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    const name = args_mod.requiredString(ctx.allocator, arguments, "name") catch
        return ctx.refuse("Error: load_skill needs a non-empty 'name' string: the exact name of an installed skill.");
    defer ctx.allocator.free(name);

    const text = agent.skills.load(ctx.allocator, name) catch |err| switch (err) {
        error.UnknownSkill => return unknownSkill(ctx, agent.skills, name),
        error.SkillUnavailable => return ctx.refuseFmt(
            "Error: skill '{s}' is no longer readable: its SKILL.md was removed or cannot be opened.",
            .{name},
        ),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return ctx.refuseFmt(
            "Error: the instructions of skill '{s}' could not be assembled.",
            .{name},
        ),
    };
    return .{ .output = text, .is_error = false };
}

/// What a call that named no installed skill is told: the names there are, so
/// the model can correct itself instead of guessing a second time. Shared with
/// `read_skill_resource`, which refuses an unknown skill the same way.
pub fn unknownSkill(ctx: tool.Context, skills: *const Skills, name: []const u8) !tool.ToolResult {
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer aw.deinit();
    try aw.writer.print("Error: no skill is named '{s}'.", .{name});
    if (!skills.hasAny()) {
        try aw.writer.writeAll(" No skills are installed for this workspace.");
    } else {
        try aw.writer.writeAll(" Installed skills:\n");
        try skills.writeNames(&aw.writer);
    }
    return .{ .output = try aw.toOwnedSlice(), .is_error = true };
}
