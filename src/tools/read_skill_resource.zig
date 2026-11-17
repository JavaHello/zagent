const std = @import("std");
const args_mod = @import("args.zig");
const load_skill = @import("load_skill.zig");
const summary = @import("summary.zig");
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "read_skill_resource",
    .description = "Read one file bundled with a skill: a script, a reference or an asset the skill's instructions name. The path is relative to the skill directory, which load_skill prints. Load the skill first and read only the files it names.",
    .parameters_json =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Exact name of an installed skill, from the list in the system prompt"},"path":{"type":"string","description":"Path of the file inside the skill directory, such as references/REFERENCE.md"}},"required":["name","path"],"additionalProperties":false}
    ,
    .label = "reading skill file…",
    .summary = writeSummary,
    .run = run,
};

/// The skill and the file inside it: two arguments that are one reference.
fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    return summary.writeFields(w, ctx.allocator, arguments, &.{ "name", "path" });
}

fn run(ctx: tool.Context, arguments: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    const name = args_mod.requiredString(ctx.allocator, arguments, "name") catch
        return ctx.refuse("Error: read_skill_resource needs a non-empty 'name' string: the exact name of an installed skill.");
    defer ctx.allocator.free(name);
    const path = args_mod.requiredString(ctx.allocator, arguments, "path") catch
        return ctx.refuse("Error: read_skill_resource needs a non-empty 'path' string: the file's path inside the skill directory.");

    defer ctx.allocator.free(path);
    const text = agent.skills.readResource(ctx.allocator, name, path) catch |err| switch (err) {
        error.UnknownSkill => return load_skill.unknownSkill(ctx, agent.skills, name),
        error.InvalidPath => return ctx.refuseFmt(
            "Error: '{s}' is not a path inside skill '{s}': give a path relative to the skill directory, with no '.' or '..' segment and no leading '/'.",
            .{ path, name },
        ),
        error.ResourceNotFound => return ctx.refuseFmt(
            "Error: skill '{s}' has no file '{s}'. Load the skill again to see the files it lists.",
            .{ name, path },
        ),
        error.NotText => {
            const skill = agent.skills.find(name) orelse return ctx.refuseFmt("Error: no skill is named '{s}'.", .{name});
            return ctx.refuseFmt(
                "Error: '{s}' in skill '{s}' is not UTF-8 text. Run it with bash, or read its bytes with read at {s}/{s}.",
                .{ path, name, skill.dir, path },
            );
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .output = text, .is_error = false };
}
