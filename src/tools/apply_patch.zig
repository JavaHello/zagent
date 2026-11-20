const std = @import("std");
const diff = @import("../diff/mod.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const fixturePath = util.fixturePath;

/// The patch the description carries, kept as its own constant so a test can
/// apply it to a real file: an example a model copies is worth having only if
/// copying it works.
const example =
    \\--- a/greet.txt
    \\+++ b/greet.txt
    \\@@ -1,3 +1,3 @@
    \\ alpha
    \\-beta
    \\+hello
    \\ gamma
    \\
;

/// The apply_patch tool: change files by applying a unified diff to them.
pub const spec: tool.Tool = .{
    .name = "apply_patch",
    .description = "Apply a Git unified diff patch: per file a '--- a/path' header, a '+++ b/path' header, then hunks headed '@@ -old_start,old_count +new_start,new_count @@' whose every line starts with ' ' (context, exactly as the file has it), '-' or '+'. A minimal patch, changing one line of an existing file:\n" ++
        example ++
        "\nA new file is '--- /dev/null' with '+++ b/path' and a hunk adding every line; a deletion is '+++ /dev/null' with a hunk removing them. The '*** Begin Patch' / '*** Update File: path' sentinel format is not a Git diff and is refused. For one exact block of text, edit is the shorter call: no line numbers and no counts.",
    .parameters_json =
    \\{"type":"object","properties":{"patch":{"type":"string","description":"The Git Unified Diff to apply, with its newlines: one or more file sections, each a header pair `--- a/old_path` and `+++ b/new_path` (`--- /dev/null` creates a file, `+++ /dev/null` deletes one), then hunks headed `@@ -old_start,old_count +new_start,new_count @@` whose lines start with a space for context, `-` for removed and `+` for added text"}},"required":["patch"]}
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
    // Another format is answered before the diff is read at all. The reader
    // would stop at the first line of it — "line 1 is not part of a diff" —
    // which names the symptom and not the format, and a model told that sends
    // the same shape again. What it needs is the change it meant, written the
    // way this tool reads it.
    if (try refuseForeign(allocator, patch_text)) |refusal| return refusal;

    const outcome = try diff.apply(allocator, io, normalizePatchEnvelope(patch_text));
    defer outcome.deinit(allocator);

    switch (outcome) {
        // The explanation is written by whoever gave up, so it is passed on
        // as it is: it names the file, the line and the text it wanted, which
        // is what the next patch has to be built from.
        .failed => |message| {
            // The message quotes lines of the patch, which the model wrote:
            // it is handed back as it is, so the two can be compared byte for
            // byte.
            return .{
                .output = try std.fmt.allocPrint(allocator, "Error: {s}", .{message}),
                .is_error = true,
            };
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
            return .{ .output = try aw.toOwnedSlice(), .is_error = false };
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

/// A patch written in a format that is not Git's, told apart by the line that
/// gives each one away.
const Foreign = enum {
    /// `*** Update File: path`: a block format of its own, not a typo in this
    /// one, and the marker most of the refused patches carry.
    update,
    add,
    delete,
    move,
    /// `*** End of File`, which that format writes where a Git diff has no
    /// line at all: the hunk's counts are what say the file ends.
    end_of_file,
    /// A context diff, as `diff -c` writes it, whose hunks are separated by a
    /// line of asterisks.
    context,
};

/// What the markers of the other format look like, and which one they mean.
/// `*** Begin Patch` and `*** End Patch` are not here: the envelope around a
/// patch may be there whatever the patch inside is, and a Git diff between
/// them applies as it comes.
const foreign_markers = [_]struct { prefix: []const u8, format: Foreign }{
    .{ .prefix = "*** Update File:", .format = .update },
    .{ .prefix = "*** Add File:", .format = .add },
    .{ .prefix = "*** Delete File:", .format = .delete },
    .{ .prefix = "*** Move to:", .format = .move },
    .{ .prefix = "*** End of File", .format = .end_of_file },
    .{ .prefix = "***************", .format = .context },
};

const Recognised = struct {
    format: Foreign,
    /// The 1-based line the format was recognised on.
    line: usize,
    /// What follows the marker on that line, trimmed: the path, for the
    /// markers that name one.
    rest: []const u8,
};

/// The format `patch` is written in, when it is not this tool's.
///
/// Only column zero is looked at: every line of a diff starts with the marker
/// that says what it is, so a line that begins with `***` names a format and
/// can never be the text of a change, which begins with a space, `-` or `+`.
fn foreign(patch: []const u8) ?Recognised {
    var start: usize = 0;
    var number: usize = 0;
    while (start < patch.len) {
        number += 1;
        const end = std.mem.indexOfScalarPos(u8, patch, start, '\n') orelse patch.len;
        const line = std.mem.trimEnd(u8, patch[start..end], "\r");
        for (foreign_markers) |marker| {
            if (!std.mem.startsWith(u8, line, marker.prefix)) continue;
            return .{
                .format = marker.format,
                .line = number,
                .rest = std.mem.trim(u8, line[marker.prefix.len..], " \t:"),
            };
        }
        start = end + 1;
    }
    return null;
}

/// What a format is called in the answer, in the words the model wrote it in.
fn shape(format: Foreign) []const u8 {
    return switch (format) {
        .update => "'*** Begin Patch' / '*** Update File: path' block",
        .add => "'*** Begin Patch' / '*** Add File: path' block",
        .delete => "'*** Begin Patch' / '*** Delete File: path' block",
        .move => "'*** Begin Patch' / '*** Move to: path' block",
        .end_of_file => "'*** Begin Patch' block, with '*** End of File' in it",
        .context => "context diff ('diff -c')",
    };
}

/// The answer a patch in another format gets: which format it is, and the same
/// change written in the one this tool reads — with the path it named, so the
/// next call is an edit of one line rather than a fresh attempt.
///
/// `null` when the patch is Git's, or when nothing at all says otherwise. The
/// diff module stays a reader of a single format, strict about every line it
/// does read: the habits of the models that write patches are known here, next
/// to the description that asks for the right one.
fn refuseForeign(allocator: std.mem.Allocator, patch: []const u8) !?ToolResult {
    const found = foreign(patch) orelse return null;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print(
        "Error: nothing was applied: this patch is written as a {s}, and apply_patch reads a Git unified diff only — line {d} is the marker that gives it away.",
        .{ shape(found.format), found.line },
    );
    try w.writeAll("\n\nThe same change, in the format this tool reads:\n\n");

    // A path the marker named is used as it is; without one, the template
    // leaves the word to be replaced rather than a header that cannot be sent.
    const path = if (found.rest.len == 0) "<path>" else found.rest;
    switch (found.format) {
        .add => try w.print(
            "--- /dev/null\n+++ b/{s}\n@@ -0,0 +1,2 @@\n+first line\n+second line\n",
            .{path},
        ),
        .delete => try w.print(
            "--- a/{s}\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-first line\n-second line\n",
            .{path},
        ),
        else => try w.print(
            "--- a/{s}\n+++ b/{s}\n@@ -1,3 +1,3 @@\n context line, exactly as the file has it\n-old line\n+new line\n",
            .{ path, path },
        ),
    }

    // A format that is not a form of this one is told what to send instead:
    // another flag on the command that wrote it, for a `diff -c`.
    if (found.format == .context) {
        try w.writeAll("\nA context diff is not read at all: 'diff -u old new', or 'git diff', writes the hunks this tool reads.");
    }

    try w.writeAll("\nEvery hunk line starts with ' ' (context, matching the file byte for byte), '-' or '+', and the '@@' header holds the first line and the line count of each side: nothing is matched loosely. For one exact block of text, edit(path, old_text, new_text) needs no line numbers and no counts, and is the shorter call.");

    return .{ .output = try aw.toOwnedSlice(), .is_error = true };
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Applied 1 file: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "note.txt (+1 -1)") != null);
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
    try std.testing.expectEqualStrings(expected, result.output);
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
    try std.testing.expect(std.mem.startsWith(u8, result.output, "Error: "));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "note.txt") != null);

    // And nothing was written: the file is exactly as it was.
    const content = try tmp.dir.readFileAlloc(io, "note.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("one\ntwo\n", content);
}

test "the example in the description is a patch that applies" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // The description asks the model to copy it, so it has to be a patch of a
    // file that exists, with the context it says it has. A wrong count or a
    // missing space would be copied as faithfully as a right one.
    try std.testing.expect(std.mem.indexOf(u8, spec.description, example) != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "greet.txt", .data = "alpha\nbeta\ngamma\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const from_a = try std.fmt.allocPrint(allocator, "a/{s}/greet.txt", .{dir});
    defer allocator.free(from_a);
    const from_b = try std.fmt.allocPrint(allocator, "b/{s}/greet.txt", .{dir});
    defer allocator.free(from_b);
    const named_a = try std.mem.replaceOwned(u8, allocator, example, "a/greet.txt", from_a);
    defer allocator.free(named_a);
    const patch = try std.mem.replaceOwned(u8, allocator, named_a, "b/greet.txt", from_b);
    defer allocator.free(patch);

    const result = try applyPatch(io, allocator, patch);
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "greet.txt (+1 -1)") != null);
    const content = try tmp.dir.readFileAlloc(io, "greet.txt", allocator, .limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("alpha\nhello\ngamma\n", content);
}

test "the sentinel patch format is answered with the git diff to send instead" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // The shapes of the format that was sent and refused: the envelope or
    // none, a file added, a file deleted, the end-of-file marker, and the same
    // patch with CRLF line endings. Each has to be told what it is, and given
    // the header pair for the path it named — a refusal a model cannot act on
    // costs the turn it was sent in.
    const cases = [_]struct {
        /// What was sent, with {dir} standing for the fixture directory.
        patch: []const u8,
        /// The line that gives the format away.
        marker: []const u8,
        /// The header pair the answer has to carry.
        headers: []const u8,
    }{
        .{
            .patch = "*** Begin Patch\n*** Update File: {dir}/note.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n*** End Patch\n",
            .marker = "*** Update File: ",
            .headers = "--- a/{dir}/note.txt\n+++ b/{dir}/note.txt",
        },
        .{
            .patch = "*** Update File: {dir}/note.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n",
            .marker = "*** Update File: ",
            .headers = "--- a/{dir}/note.txt\n+++ b/{dir}/note.txt",
        },
        .{
            .patch = "*** Begin Patch\n*** Add File: {dir}/new.txt\n+first\n+second\n*** End Patch\n",
            .marker = "*** Add File: ",
            .headers = "--- /dev/null\n+++ b/{dir}/new.txt",
        },
        .{
            .patch = "*** Begin Patch\n*** Delete File: {dir}/note.txt\n*** End Patch\n",
            .marker = "*** Delete File: ",
            .headers = "--- a/{dir}/note.txt\n+++ /dev/null",
        },
        // The end-of-file line of that format closes a block an update opened,
        // so the marker named is the one that opened it.
        .{
            .patch = "*** Begin Patch\n*** Update File: {dir}/note.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n*** End of File\n*** End Patch\n",
            .marker = "*** Update File: ",
            .headers = "--- a/{dir}/note.txt\n+++ b/{dir}/note.txt",
        },
        .{
            .patch = "*** Begin Patch\r\n*** Update File: {dir}/note.txt\r\n@@ -1,2 +1,2 @@\r\n one\r\n-two\r\n+TWO\r\n*** End Patch\r\n",
            .marker = "*** Update File: ",
            .headers = "--- a/{dir}/note.txt\n+++ b/{dir}/note.txt",
        },
    };

    for (cases) |case| {
        const patch = try std.mem.replaceOwned(u8, allocator, case.patch, "{dir}", dir);
        defer allocator.free(patch);
        const headers = try std.mem.replaceOwned(u8, allocator, case.headers, "{dir}", dir);
        defer allocator.free(headers);

        const result = try applyPatch(io, allocator, patch);
        defer result.deinit(allocator);

        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.startsWith(u8, result.output, "Error: nothing was applied"));
        // The format, by the name of the line that was sent.
        try std.testing.expect(std.mem.indexOf(u8, result.output, case.marker) != null);
        // And the change, with the path it named, as this tool reads it.
        try std.testing.expect(std.mem.indexOf(u8, result.output, headers) != null);
        // With the shorter way to say the same thing when only one block moves.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "edit(path, old_text, new_text)") != null);
        // And nothing applied: neither a rewrite of the file nor a new one.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "Applied") == null);
        const content = try tmp.dir.readFileAlloc(io, "note.txt", allocator, .limited(1024));
        defer allocator.free(content);
        try std.testing.expectEqualStrings("one\ntwo\n", content);
        try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "new.txt", allocator, .limited(1024)));
    }
}

test "a git diff inside the patch envelope still applies" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // The envelope is tolerated by design, and what it wraps here is a Git
    // diff rather than the sentinel format: recognising the format of a patch
    // must not turn that tolerance into a refusal.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try std.fmt.allocPrint(allocator,
        \\*** Begin Patch
        \\--- {s}/note.txt
        \\+++ {s}/note.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\+TWO
        \\*** End Patch
        \\
    , .{ dir, dir });
    defer allocator.free(patch);

    const result = try applyPatch(io, allocator, patch);
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "note.txt (+1 -1)") != null);
}

test "a context diff is told to be sent as a unified one" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // `diff -c` is a diff and not this tool's: its hunks are separated by a
    // line of asterisks and marked with '!' where a unified hunk has '-' and
    // '+'. Nothing here can read it, and the fix is another flag on the same
    // command rather than a rewrite by hand.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try std.fmt.allocPrint(allocator,
        \\*** {s}/note.txt 2024-01-01 00:00:00
        \\--- {s}/note.txt 2024-01-02 00:00:00
        \\***************
        \\*** 1,2 ****
        \\  one
        \\! two
        \\--- 1,2 ----
        \\  one
        \\! TWO
        \\
    , .{ dir, dir });
    defer allocator.free(patch);

    const result = try applyPatch(io, allocator, patch);
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "context diff") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "diff -u") != null);
    // The path is not on the line that gives the format away, so the template
    // leaves the word to replace rather than a header that cannot be sent.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "--- a/<path>") != null);
}

test "a format is recognised at column zero only" {
    // A diff's every line starts with the marker that says what it is, so the
    // text of a change — a context line, an added one — can hold these words
    // without being a patch in another format.
    try std.testing.expectEqual(Foreign.end_of_file, foreign("*** End of File\n").?.format);
    try std.testing.expectEqual(Foreign.move, foreign("*** Move to: src/b.zig\n").?.format);
    try std.testing.expectEqual(Foreign.context, foreign("***************\n").?.format);
    try std.testing.expectEqual(@as(usize, 2), foreign("*** Begin Patch\n*** Update File: src/a.zig\n").?.line);
    try std.testing.expectEqualStrings("src/a.zig", foreign("*** Update File:  src/a.zig \n").?.rest);

    try std.testing.expect(foreign(" *** Update File: src/a.zig\n") == null);
    try std.testing.expect(foreign("+*** Update File: src/a.zig\n") == null);
    try std.testing.expect(foreign("-***************\n") == null);
    // The envelope alone is not another format: a Git diff may sit inside it.
    try std.testing.expect(foreign(
        "*** Begin Patch\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n*** End Patch\n",
    ) == null);
}
