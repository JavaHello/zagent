const std = @import("std");
const memory_mod = @import("../state/memory.zig");
const openai = @import("../model/openai.zig");
const Agent = @import("../agent/mod.zig").Agent;
const tool = @import("tool.zig");

pub const spec: tool.Tool = .{
    .name = "memory_save",
    .description = "Save one durable note to memory so it survives this session: add a note, or replace or delete an exact existing one.",
    .parameters_json =
    \\{"type":"object","properties":{"text":{"type":"string","description":"Note to add, new note for replace, or exact existing note for delete"},"action":{"type":"string","enum":["add","replace","delete"],"description":"Default add; replace and delete require an exact existing note"},"old_text":{"type":"string","description":"Exact existing note to replace; required only for replace"}},"required":["text"]}
    ,
    .label = "saving memory…",
    .run = run,
};

fn run(ctx: tool.Context, args: []const u8) !tool.ToolResult {
    const agent = ctx.agent orelse return ctx.refuse("Error: this tool requires an agent context.");
    return execute(agent, args);
}

pub fn execute(self: *Agent, arguments: []const u8) !tool.ToolResult {
    if (!self.memory.enabled) {
        return .{
            .content = try self.allocator.dupe(u8, "Memory is unavailable: no storage path could be resolved."),
            .is_error = true,
        };
    }
    const note = openai.extractStringArg(self.allocator, arguments, "text") catch {
        return .{
            .content = try self.allocator.dupe(u8, "Error: memory_save needs a non-empty 'text' string"),
            .is_error = true,
        };
    };
    defer self.allocator.free(note);
    const parsed = try std.json.parseFromSlice(struct {
        text: []const u8,
        action: []const u8 = "add",
        old_text: ?[]const u8 = null,
    }, self.allocator, arguments, .{});
    defer parsed.deinit();
    // Stage edits so persistence failure cannot publish an unsaved note.
    var staged = try memory_mod.Memory.initWithPath(self.allocator, self.io, null);
    defer staged.deinit();
    staged.enabled = true;
    if (self.memory.path) |path| staged.path = try self.allocator.dupe(u8, path);
    for (self.memory.entries.items) |entry| _ = try staged.add(entry);
    const added = staged.edit(parsed.value.action, note, parsed.value.old_text) catch |err| switch (err) {
        error.EmptyMemory => return .{
            .content = try self.allocator.dupe(u8, "Error: memory_save needs a non-empty 'text' string"),
            .is_error = true,
        },
        else => return .{
            .content = try std.fmt.allocPrint(self.allocator, "Memory edit failed: {s}", .{@errorName(err)}),
            .is_error = true,
        },
    };
    if (!added) return .{
        .content = try std.fmt.allocPrint(self.allocator, "Already in memory: {s}", .{note}),
        .is_error = false,
    };
    staged.save() catch |err| {
        return .{ .content = try std.fmt.allocPrint(self.allocator, "Memory save failed: {s}", .{@errorName(err)}), .is_error = true };
    };
    std.mem.swap(memory_mod.Memory, &self.memory, &staged);
    return .{
        .content = try std.fmt.allocPrint(self.allocator, "Memory {s}: {s}", .{ parsed.value.action, note }),
        .is_error = false,
    };
}
