const std = @import("std");
const diff = @import("../diff/mod.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const finalizeResultLimited = result_mod.finalizeResultLimited;
const max_output_bytes = result_mod.max_output_bytes;
const fixturePath = util.fixturePath;

/// The apply_patch tool: change files by applying a unified diff to them.
pub const spec: tool.Tool = .{
    .name = "apply_patch",
    .description = "Apply a Git unified diff patch.",
    .parameters_json =
    \\{"type":"object","properties":{"patch":{"type":"string","description":"The Git Unified Diff to apply, with its newlines"}},"required":["patch"]}
    ,
    .label = "apply_patch…",
    .summary = writeSummary,
    .summary_block = true,
    .run = run,
};

fn writeSummary(ctx: tool.Context, w: *std.Io.Writer, arguments: []const u8) !bool {
    const patch = args_mod.requiredString(ctx.allocator, arguments, "patch") catch return false;
    defer ctx.allocator.free(patch);
    try diff.render(w, patch);
    return true;
}

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    const patch_text = args_mod.requiredString(ctx.allocator, arguments, "patch") catch
        return ctx.refuse("Error: missing 'patch' argument; it has to hold a unified diff");
    defer ctx.allocator.free(patch_text);
    return applyPatch(ctx.io, ctx.allocator, patch_text);
}

/// Apply a unified diff to the files it names.
///
/// The result is a summary rather than the patch back again: the model wrote
/// the patch, so what it does not already have is what became of it — which
/// files were written, and, when one could not be, why it did not fit.
pub fn applyPatch(io: std.Io, allocator: std.mem.Allocator, patch_text: []const u8) !ToolResult {
    const outcome = try diff.apply(allocator, io, normalizePatchEnvelope(patch_text));
    defer outcome.deinit(allocator);

    switch (outcome) {
        // The explanation is written by whoever gave up, so it is passed on
        // as it is: it names the file, the line and the text it wanted, which
        // is what the next patch has to be built from.
        .failed => |message| {
            const content = try std.fmt.allocPrint(allocator, "Error: {s}", .{message});
            defer allocator.free(content);
            // Sanitised like any other result: the message quotes lines of the
            // patch, which the model wrote.
            return finalizeResultLimited(allocator, content, .{ .is_error = true }, max_output_bytes);
        },
        .applied => |stats| {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try aw.writer.print("Applied {d} file{s}", .{ stats.len, if (stats.len == 1) @as([]const u8, "") else "s" });
            for (stats, 0..) |stat, i| {
                try aw.writer.writeAll(if (i == 0) ": " else ", ");
                try aw.writer.print("{s} (", .{stat.path});
                switch (stat.action) {
                    .modified => try aw.writer.print("+{d} -{d}", .{ stat.added, stat.removed }),
                    .created => try aw.writer.print("new, +{d}", .{stat.added}),
                    .deleted => try aw.writer.print("deleted, -{d}", .{stat.removed}),
                    .renamed => {
                        try aw.writer.print("renamed from {s}", .{stat.from orelse stat.path});
                        if (stat.added != 0 or stat.removed != 0) try aw.writer.print(", +{d} -{d}", .{ stat.added, stat.removed });
                    },
                    .mode_changed => try aw.writer.print("mode {o}", .{stat.mode.?}),
                }
                // A mode the patch set alongside the text is worth naming:
                // it is the one part of a change the diff itself cannot show.
                if (stat.action != .mode_changed) {
                    if (stat.mode) |mode| try aw.writer.print(", mode {o}", .{mode});
                }
                try aw.writer.writeByte(')');
            }
            return finalizeResultLimited(allocator, aw.written(), .{ .is_error = false }, max_output_bytes);
        },
    }
}

/// Models sometimes put their unified diff inside apply_patch sentinels.
/// Strip only those exact outer lines; keep hunk counts/context strict.
fn normalizePatchEnvelope(patch: []const u8) []const u8 {
    var value = std.mem.trim(u8, patch, "\r\n");
    if (std.mem.startsWith(u8, value, "*** Begin Patch\n")) value = value["*** Begin Patch\n".len..];
    if (std.mem.startsWith(u8, value, "*** Begin Patch\r\n")) value = value["*** Begin Patch\r\n".len..];
    if (std.mem.endsWith(u8, value, "\n*** End Patch")) value = value[0 .. value.len - "\n*** End Patch".len];
    return value;
}

test "patch envelopes do not change hunk content" {
    const patch = "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-before\n+after";
    try std.testing.expectEqualStrings(patch, normalizePatchEnvelope("*** Begin Patch\n" ++ patch ++ "\n*** End Patch\n"));
    try std.testing.expectEqualStrings(patch, normalizePatchEnvelope(patch));
    try std.testing.expectEqualStrings("+*** End Patch", normalizePatchEnvelope("+*** End Patch"));
}

test "apply patch changes the file and says what it changed" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try std.fmt.allocPrint(allocator,
        \\--- {s}/note.txt
        \\+++ {s}/note.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\+TWO
    , .{ dir, dir });
    defer allocator.free(patch);

    const result = try applyPatch(io, allocator, patch);
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Applied 1 file: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "note.txt (+1 -1)") != null);
}

test "a rename is reported as one, with the name the file came from" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\nthree\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try std.fmt.allocPrint(allocator,
        \\diff --git a/{0s}/note.txt b/{0s}/renamed.txt
        \\similarity index 66%
        \\rename from {0s}/note.txt
        \\rename to {0s}/renamed.txt
        \\--- {0s}/note.txt
        \\+++ {0s}/renamed.txt
        \\@@ -2 +2 @@
        \\-two
        \\+TWO
    , .{dir});
    defer allocator.free(patch);

    const result = try applyPatch(io, allocator, patch);
    defer result.deinit(allocator);

    const expected = try std.fmt.allocPrint(allocator, "Applied 1 file: {s}/renamed.txt (renamed from {s}/note.txt, +1 -1)", .{ dir, dir });
    defer allocator.free(expected);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings(expected, result.content);
}

test "a patch that does not fit is an error the model can act on" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // The context is from some other version of the file. The message has to
    // carry the file, the line and the text, or the next attempt is a guess.
    const patch = try std.fmt.allocPrint(allocator,
        \\--- {s}/note.txt
        \\+++ {s}/note.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-nowhere
        \\+anywhere
    , .{ dir, dir });
    defer allocator.free(patch);

    const result = try applyPatch(io, allocator, patch);
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.content, "Error: "));
    try std.testing.expect(std.mem.indexOf(u8, result.content, "note.txt") != null);

    // And nothing was written: the file is exactly as it was.
    const content = try tmp.dir.readFileAlloc(io, "note.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("one\ntwo\n", content);
}
