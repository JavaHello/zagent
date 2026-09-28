//! Unified diffs: reading one, applying one, and drawing one.
//!
//! The agent edits files by writing these, so the parser is lenient about
//! everything that does not change what a patch means — git's metadata headers,
//! a count left out of a hunk header, the blank line a model writes where a
//! blank *context* line should be, the fence a patch arrives wrapped in — and
//! strict about the one thing that does: the text a hunk says it replaces has
//! to be the text the file holds. A hunk that does not match is reported, never
//! guessed at, because a patch landing in the wrong place is worse than a patch
//! that did not land at all.
//!
//! Nothing is written until every file of the patch has been rebuilt in memory,
//! so a patch whose last hunk fails leaves the tree exactly as it was.
//!
//! What is deliberately not supported: renames (a patch whose two headers name
//! different files is refused rather than quietly deleting one of them), binary
//! hunks, and the line shifting that lets `patch(1)` apply a hunk to text it
//! does not quite match.

const std = @import("std");
const sgr = @import("style.zig");
const text = @import("text.zig");

/// Longest file this will patch. The whole file is read into memory and rebuilt
/// there, so this cap is what keeps a mistyped path from taking the process out.
const max_file_bytes: usize = 8 * 1024 * 1024;
/// Longest patch text a single tool call may carry.
const max_patch_bytes: usize = 2 * 1024 * 1024;
/// Most files one patch may touch.
const max_files: usize = 256;
/// Patch lines drawn before the rest are left out. A runaway patch should not
/// push the conversation out of the terminal's scrollback.
const render_max_lines: usize = 400;
/// Longest patch line drawn, for the same reason.
const render_max_line_bytes: usize = 2000;

pub const Action = enum { modified, created, deleted };

/// One file the patch changed, as it was changed. Owns `path`.
pub const FileStat = struct {
    path: []const u8,
    action: Action,
    added: usize,
    removed: usize,
};

/// What applying a patch came to.
pub const Outcome = union(enum) {
    /// The files that were written, in the order the patch named them.
    applied: []const FileStat,
    /// Nothing was written, and this says why. Owns its text.
    failed: []const u8,

    pub fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .applied => |stats| {
                for (stats) |stat| allocator.free(stat.path);
                allocator.free(stats);
            },
            .failed => |message| allocator.free(message),
        }
    }
};

/// Parse `patch_text` and apply it to the files it names, relative to the
/// working directory.
///
/// A patch that cannot be applied is an outcome rather than an error: the
/// caller's job is to show the model why, and an error would carry a name
/// instead of a reason. Errors out of here are the ones with nothing to say —
/// running out of memory.
pub fn apply(allocator: std.mem.Allocator, io: std.Io, patch_text: []const u8) !Outcome {
    if (patch_text.len > max_patch_bytes) {
        return fail(allocator, "the patch is {d} bytes; this tool reads at most {d}", .{ patch_text.len, max_patch_bytes });
    }

    var diag: Diagnostic = .init(allocator);
    defer diag.deinit();

    var patch = parse(allocator, patch_text, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPatch => return failedWith(allocator, &diag),
    };
    defer patch.deinit(allocator);

    // Every file is rebuilt before any of them is written.
    var plans: std.ArrayList(Plan) = .empty;
    defer {
        for (plans.items) |plan| plan.deinit(allocator);
        plans.deinit(allocator);
    }

    for (patch.files) |file| {
        const plan = planFile(allocator, io, file, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadPatch => return failedWith(allocator, &diag),
        };
        plans.append(allocator, plan) catch |err| {
            plan.deinit(allocator);
            return err;
        };
    }

    const stats = try allocator.alloc(FileStat, plans.items.len);
    var filled: usize = 0;
    errdefer {
        // Only the entries that were built: the rest of the allocation is
        // uninitialised, and freeing a pointer read out of it is not a thing
        // that can be undone.
        for (stats[0..filled]) |stat| allocator.free(stat.path);
        allocator.free(stats);
    }
    for (plans.items, 0..) |plan, i| {
        stats[i] = .{
            .path = try allocator.dupe(u8, plan.path),
            .action = plan.action,
            .added = plan.added,
            .removed = plan.removed,
        };
        filled = i + 1;
    }

    for (plans.items, 0..) |plan, i| {
        writePlan(io, plan) catch |err| {
            // Reported as it happened rather than softened: the files before
            // this one are already written, and the model has to know which.
            const message = if (i == 0)
                try std.fmt.allocPrint(allocator, "could not write '{s}': {s}", .{ plan.path, @errorName(err) })
            else
                try std.fmt.allocPrint(
                    allocator,
                    "wrote {d} file(s), then could not write '{s}': {s}. The tree is part-patched; check those files",
                    .{ i, plan.path, @errorName(err) },
                );
            for (stats) |stat| allocator.free(stat.path);
            allocator.free(stats);
            return .{ .failed = message };
        };
    }

    return .{ .applied = stats };
}

/// Write one planned file, or remove it for a deletion.
fn writePlan(io: std.Io, plan: Plan) !void {
    const content = plan.content orelse {
        try std.Io.Dir.cwd().deleteFile(io, plan.path);
        return;
    };

    if (std.Io.Dir.path.dirname(plan.path)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }
    const file = try std.Io.Dir.cwd().createFile(io, plan.path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

/// What one file of a patch came to, once every hunk of it has been matched.
const Plan = struct {
    path: []const u8,
    action: Action,
    /// The file's new contents, or null for a deletion. Owned.
    content: ?[]u8,
    added: usize,
    removed: usize,

    fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.content) |content| allocator.free(content);
    }
};

/// Rebuild one file in memory, or explain why it cannot be rebuilt.
///
/// Nothing is written from here: the caller writes once every file of the patch
/// has come through this function, which is what makes a failed patch a no-op.
fn planFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: FilePatch,
    diag: *Diagnostic,
) (error{ OutOfMemory, BadPatch })!Plan {
    const action: Action = if (file.old_path == null)
        .created
    else if (file.new_path == null)
        .deleted
    else
        .modified;
    const path = file.new_path orelse file.old_path.?;

    // Two names that are not the same name are a rename, and a rename applied
    // by halves is how a mistyped header turns into a lost file. The agent can
    // delete and create instead, in two patches whose results it can check.
    if (file.old_path) |old| {
        if (file.new_path) |new| {
            if (!std.mem.eql(u8, old, new)) {
                diag.say("the patch names two different files, '{s}' and '{s}': renames are not supported, so patch the new file and delete the old one in two steps", .{ old, new });
                return error.BadPatch;
            }
        }
    }

    if (action == .created and pathExists(io, path)) {
        diag.say("'{s}' already exists, so it cannot be created: send it as a patch against the file it is now", .{path});
        return error.BadPatch;
    }

    const original: []u8 = if (action == .created)
        try allocator.dupe(u8, "")
    else
        std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch |err| {
            if (err == error.StreamTooLong) {
                diag.say("'{s}' is larger than the {d} MB this tool reads", .{ path, max_file_bytes / (1024 * 1024) });
                return error.BadPatch;
            }
            diag.say("'{s}' could not be read ({s}): it has to exist before it can be patched, and a new file is sent with '--- /dev/null'", .{ path, @errorName(err) });
            return error.BadPatch;
        };
    defer allocator.free(original);

    var source = try readLines(allocator, original);
    defer source.deinit(allocator);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(allocator);

    // How far the hunks have read into the original, and what the rebuilt file
    // ends with — which is what decides whether it ends with a newline.
    var consumed: usize = 0;
    var ending: Ending = .original;
    var added: usize = 0;
    var removed: usize = 0;

    for (file.hunks) |hunk| {
        const stated = if (hunk.header.old_start > 0) hunk.header.old_start - 1 else 0;
        // `locate` has more than one way to find nothing, and each explains
        // itself; `describeMiss` is for the one that has nothing to say yet.
        const already_said = diag.written().len;
        const at = locate(diag, path, source.lines.items, consumed, hunk, stated) orelse {
            if (diag.written().len == already_said) describeMiss(diag, path, source.lines.items, hunk, stated);
            return error.BadPatch;
        };

        try out.appendSlice(allocator, source.lines.items[consumed..at]);
        if (at > consumed) ending = .original;

        for (hunk.lines) |line| switch (line.kind) {
            .context => {
                try out.append(allocator, line.text);
                ending = if (line.no_newline) .patched_without_newline else .patched_with_newline;
            },
            .remove => removed += 1,
            .add => {
                added += 1;
                try out.append(allocator, line.text);
                ending = if (line.no_newline) .patched_without_newline else .patched_with_newline;
            },
        };

        consumed = at + oldSideLen(hunk);
    }

    if (consumed < source.lines.items.len) {
        try out.appendSlice(allocator, source.lines.items[consumed..]);
        ending = .original;
    }

    if (action == .deleted and out.items.len != 0) {
        diag.say("the patch deletes '{s}' without removing all of it: a deletion has to account for every line", .{path});
        return error.BadPatch;
    }

    // A deletion writes nothing, so its contents are not built at all.
    var content: ?[]u8 = null;
    if (action != .deleted) {
        var joined: std.Io.Writer.Allocating = .init(allocator);
        errdefer joined.deinit();

        const newline: []const u8 = if (source.crlf) "\r\n" else "\n";
        for (out.items, 0..) |line, i| {
            if (i > 0) try writeOrFail(&joined.writer, newline);
            try writeOrFail(&joined.writer, line);
        }
        if (out.items.len > 0 and switch (ending) {
            .original => source.trailing_newline,
            .patched_with_newline => true,
            .patched_without_newline => false,
        }) {
            try writeOrFail(&joined.writer, newline);
        }

        content = try joined.toOwnedSlice();
    }

    return .{
        .path = try allocator.dupe(u8, path),
        .action = action,
        .content = content,
        .added = added,
        .removed = removed,
    };
}

/// What the rebuilt file ends with, which its trailing newline follows from: a
/// file whose last line was copied keeps the ending it had, and a file whose
/// last came from the patch takes that line's `\ No newline at end of file`.
const Ending = enum { original, patched_with_newline, patched_without_newline };

/// A file split into lines, borrowing the bytes it was read into.
const TextFile = struct {
    lines: std.ArrayList([]const u8),
    /// Whether the last line is terminated.
    trailing_newline: bool,
    /// Whether the lines are separated by CRLF. The file is written back the
    /// way it came in: a patch that touches one line of a CRLF file must not
    /// turn every other line into a change as well.
    crlf: bool,

    fn deinit(self: *TextFile, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
    }
};

/// Split a file into lines. Line endings are not part of a line: they are the
/// two facts reported alongside, so that a line of a patch is compared as its
/// text whatever kind of file it came from.
fn readLines(allocator: std.mem.Allocator, content: []const u8) !TextFile {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);

    var crlf = false;
    var start: usize = 0;
    while (start < content.len) {
        const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        var line = content[start..end];
        if (std.mem.endsWith(u8, line, "\r")) {
            line = line[0 .. line.len - 1];
            crlf = true;
        }
        try lines.append(allocator, line);
        start = end + 1;
    }

    return .{
        .lines = lines,
        .trailing_newline = content.len > 0 and std.mem.endsWith(u8, content, "\n"),
        .crlf = crlf,
    };
}

/// How many lines of the original a hunk's old side covers.
fn oldSideLen(hunk: Hunk) usize {
    var count: usize = 0;
    for (hunk.lines) |line| {
        if (line.kind != .add) count += 1;
    }
    return count;
}

/// Whether a hunk's old side is the text of the file at `at`.
fn matchesAt(lines: []const []const u8, at: usize, hunk: Hunk) bool {
    const need = oldSideLen(hunk);
    // Written as a subtraction because `at` comes from a number the patch
    // chose, and `at + need` on a number that large wraps.
    if (at > lines.len or need > lines.len - at) return false;

    var j = at;
    for (hunk.lines) |line| {
        if (line.kind == .add) continue;
        if (!std.mem.eql(u8, lines[j], line.text)) return false;
        j += 1;
    }
    return true;
}

/// Where a hunk's old side sits in the file, at or after `consumed`.
///
/// The line the hunk states is tried first, and that is the only position that
/// cannot be wrong: a patch written against this file goes exactly where it
/// says. The text decides after that, because a model that counted the lines of
/// a file it had not re-read is off by a little far more often than it is wrong
/// about the text.
///
/// A hunk whose stated line does not match is placed only where its text fits
/// in exactly one place. Two fits are two different places — nearly always two
/// different functions — and taking the nearer one is a coin flip that produces
/// a file that compiles and does the wrong thing, with nothing in the output to
/// say so. Being told to add a line of context costs one round trip.
fn locate(diag: *Diagnostic, path: []const u8, lines: []const []const u8, consumed: usize, hunk: Hunk, stated: usize) ?usize {
    const need = oldSideLen(hunk);
    // A hunk that only adds lines has nothing to match against; it goes where
    // it says it goes, which is how the first lines of a new file are placed.
    if (need == 0) return @min(@max(stated, consumed), lines.len);

    const from = @max(stated, consumed);
    if (matchesAt(lines, from, hunk)) return from;

    var first: ?usize = null;
    var second: ?usize = null;
    var at = consumed;
    while (at <= lines.len) : (at += 1) {
        if (!matchesAt(lines, at, hunk)) continue;
        if (first == null) {
            first = at;
        } else {
            second = at;
            break;
        }
    }

    if (first) |only| {
        if (second) |other| {
            diag.say(
                "the hunk at patch line {d} fits '{s}' at two places, line {d} and line {d}, and its stated line {d} is neither. Add a line of context that is unique to the one you mean",
                .{ hunk.patch_line, path, only + 1, other + 1, stated + 1 },
            );
            return null;
        }
        return only;
    }
    return null;
}

/// Explain a hunk that matched nothing, naming the line it was looking for and
/// what the file has there instead: the two facts it takes to fix the patch.
fn describeMiss(
    diag: *Diagnostic,
    path: []const u8,
    lines: []const []const u8,
    hunk: Hunk,
    stated: usize,
) void {
    var wanted: ?[]const u8 = null;
    var j = stated;
    for (hunk.lines) |line| {
        if (line.kind == .add) continue;
        if (j >= lines.len or !std.mem.eql(u8, lines[j], line.text)) {
            wanted = line.text;
            break;
        }
        j += 1;
    }

    const expected = wanted orelse {
        diag.say("the hunk at patch line {d} does not fit '{s}': the {d} line(s) it expects from line {d} are not in the file", .{ hunk.patch_line, path, oldSideLen(hunk), stated + 1 });
        return;
    };

    if (j < lines.len) {
        diag.say("the hunk at patch line {d} does not fit '{s}': it expects \"{s}\" at line {d}, where the file has \"{s}\"", .{ hunk.patch_line, path, expected, j + 1, lines[j] });
    } else {
        diag.say("the hunk at patch line {d} does not fit '{s}': it expects \"{s}\" after line {d}, which is where the file ends", .{ hunk.patch_line, path, expected, j });
    }
}

/// Write into an in-memory buffer, whose only way to fail is the allocation
/// behind it. Keeping that as `OutOfMemory` is what lets every other failure
/// this module reports stay one a patch can be blamed for.
fn writeOrFail(w: *std.Io.Writer, bytes: []const u8) error{OutOfMemory}!void {
    w.writeAll(bytes) catch return error.OutOfMemory;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn failedWith(allocator: std.mem.Allocator, diag: *Diagnostic) !Outcome {
    const written = diag.written();
    const message = if (written.len > 0) written else "the patch could not be read";
    return .{ .failed = try allocator.dupe(u8, message) };
}

fn fail(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .failed = try std.fmt.allocPrint(allocator, fmt, args) };
}

/// The explanation of a patch that failed, written by whichever part of the
/// parse or the apply gave up. It is assembled as it goes rather than derived
/// from an error name, because what a model needs to fix an edit is the file,
/// the line and the text, and an error name carries none of them.
const Diagnostic = struct {
    aw: std.Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator) Diagnostic {
        return .{ .aw = .init(allocator) };
    }

    fn deinit(self: *Diagnostic) void {
        self.aw.deinit();
    }

    fn say(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        // Failing to write the failure is not worth a second failure: the
        // message comes out short or empty, and the caller reports that.
        self.aw.writer.print(fmt, args) catch {};
    }

    fn written(self: *Diagnostic) []const u8 {
        return self.aw.written();
    }
};

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

const Kind = enum { context, remove, add };

const Line = struct {
    kind: Kind,
    /// The line without its ` `, `-` or `+` marker, borrowing the patch text.
    text: []const u8,
    /// Whether the patch followed this line with `\ No newline at end of file`.
    no_newline: bool = false,
};

/// A hunk's `@@` header. The new-side numbers are read to make sure this is a
/// header at all, and are not used afterwards: the old side is what has to
/// match the file, and the result is built from the lines.
const HunkHeader = struct {
    old_start: usize,
    old_count: usize,
    new_count: usize,
};

const Hunk = struct {
    header: HunkHeader,
    lines: []Line,
    /// The line of the patch the `@@` is on, so a failure can point at it.
    patch_line: usize,

    fn deinit(self: Hunk, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
    }
};

const FilePatch = struct {
    /// Null when the header was `/dev/null`, i.e. the file is being created.
    old_path: ?[]const u8,
    /// Null when the header was `/dev/null`, i.e. the file is being deleted.
    new_path: ?[]const u8,
    hunks: []Hunk,

    fn deinit(self: FilePatch, allocator: std.mem.Allocator) void {
        if (self.old_path) |path| allocator.free(path);
        if (self.new_path) |path| allocator.free(path);
        for (self.hunks) |hunk| hunk.deinit(allocator);
        allocator.free(self.hunks);
    }
};

const Patch = struct {
    files: []FilePatch,

    fn deinit(self: Patch, allocator: std.mem.Allocator) void {
        for (self.files) |file| file.deinit(allocator);
        allocator.free(self.files);
    }
};

/// The lines of a patch, and how far through them the parse has read.
///
/// A cursor rather than an iterator because a diff needs to look at the line
/// after the one it is reading — the line after `---` decides what that header
/// even is — and to leave a line for whoever reads next when it turns out to
/// belong to them.
const Cursor = struct {
    lines: []const []const u8,
    i: usize = 0,

    fn peek(self: Cursor) ?[]const u8 {
        return if (self.i < self.lines.len) self.lines[self.i] else null;
    }

    fn take(self: *Cursor) ?[]const u8 {
        const line = self.peek() orelse return null;
        self.i += 1;
        return line;
    }

    /// The 1-based number of the line `peek` would return.
    fn number(self: Cursor) usize {
        return self.i + 1;
    }
};

/// Read a unified diff. Paths and line text borrow `patch_text`, so the parse
/// lives exactly as long as the bytes it was given.
fn parse(allocator: std.mem.Allocator, patch_text: []const u8, diag: *Diagnostic) (error{ OutOfMemory, BadPatch })!Patch {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(allocator);
    {
        var start: usize = 0;
        while (start < patch_text.len) {
            const end = std.mem.indexOfScalarPos(u8, patch_text, start, '\n') orelse patch_text.len;
            const raw = patch_text[start..end];
            try all.append(allocator, if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw);
            start = end + 1;
        }
    }

    var files: std.ArrayList(FilePatch) = .empty;
    errdefer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    var cursor: Cursor = .{ .lines = all.items };
    while (cursor.take()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t");
        if (isDecoration(line)) continue;

        if (std.mem.startsWith(u8, line, "--- ")) {
            if (files.items.len >= max_files) {
                diag.say("the patch changes more than {d} files", .{max_files});
                return error.BadPatch;
            }
            try files.append(allocator, try parseFile(allocator, &cursor, line, diag));
            continue;
        }

        diag.say("line {d} is not part of a diff: \"{s}\". A patch reads '--- a/path', '+++ b/path', then '@@ -1,2 +1,2 @@' hunks whose lines each start with a space, '-' or '+'", .{ cursor.i, line });
        return error.BadPatch;
    }

    if (files.items.len == 0) {
        diag.say("no file headers found: a patch starts with '--- a/path' followed by '+++ b/path'", .{});
        return error.BadPatch;
    }

    return .{ .files = try files.toOwnedSlice(allocator) };
}

/// Read one file of a patch: its `+++` header and every hunk up to the next
/// file, or the end.
fn parseFile(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    old_line: []const u8,
    diag: *Diagnostic,
) (error{ OutOfMemory, BadPatch })!FilePatch {
    const header_number = cursor.i;
    var file: FilePatch = .{
        .old_path = try headerPath(allocator, old_line[4..]),
        .new_path = null,
        .hunks = &.{},
    };
    errdefer {
        if (file.old_path) |path| allocator.free(path);
        if (file.new_path) |path| allocator.free(path);
        for (file.hunks) |hunk| hunk.deinit(allocator);
        allocator.free(file.hunks);
    }

    const plus_line = cursor.take() orelse {
        diag.say("the patch ends on the '---' on line {d}: a file header needs the '+++ b/path' line that follows it", .{header_number});
        return error.BadPatch;
    };
    const plus = std.mem.trimEnd(u8, plus_line, " \t");
    if (!std.mem.startsWith(u8, plus, "+++ ")) {
        diag.say("line {d} should be the '+++ b/path' matching the '---' on line {d}, and is \"{s}\"", .{ cursor.i, header_number, plus });
        return error.BadPatch;
    }
    file.new_path = try headerPath(allocator, plus[4..]);

    if (file.old_path == null and file.new_path == null) {
        diag.say("the header on line {d} is '/dev/null' on both sides, which names no file", .{header_number});
        return error.BadPatch;
    }

    // The list is emptied by `toOwnedSlice` below, so by the time this runs on
    // the way out there is only something in it if the parse gave up part way —
    // which is exactly when the hunks read so far would otherwise be lost.
    var hunks: std.ArrayList(Hunk) = .empty;
    defer {
        for (hunks.items) |hunk| hunk.deinit(allocator);
        hunks.deinit(allocator);
    }

    while (cursor.peek()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t");
        if (isDecoration(line)) {
            _ = cursor.take();
            continue;
        }
        // The next file's header, which the caller's loop reads.
        if (std.mem.startsWith(u8, line, "--- ")) break;
        if (!std.mem.startsWith(u8, line, "@@")) {
            diag.say("line {d} is not part of the hunk before it: \"{s}\" starts with none of the space, '-' or '+' a hunk line starts with", .{ cursor.number(), line });
            return error.BadPatch;
        }

        const at = cursor.number();
        const header = parseHunkHeader(line) orelse {
            diag.say("line {d} is not a hunk header: \"{s}\". It should read '@@ -<line>,<count> +<line>,<count> @@', or '@@ -<line> +<line> @@' where one line is meant", .{ at, line });
            return error.BadPatch;
        };
        _ = cursor.take();

        var body: std.ArrayList(Line) = .empty;
        errdefer body.deinit(allocator);
        try readHunkBody(allocator, cursor, header, &body, diag);

        const actual_old = countKind(body.items, .context) + countKind(body.items, .remove);
        const actual_new = countKind(body.items, .context) + countKind(body.items, .add);
        if (actual_old != header.old_count or actual_new != header.new_count) {
            diag.say(
                "the hunk header on line {d} accounts for {d} old and {d} new lines, and the hunk carries {d} and {d}. Check the '@@' line against what follows it: a hunk that was cut off looks the same",
                .{ at, header.old_count, header.new_count, actual_old, actual_new },
            );
            return error.BadPatch;
        }

        try hunks.append(allocator, .{
            .header = header,
            .lines = try body.toOwnedSlice(allocator),
            .patch_line = at,
        });
    }

    if (hunks.items.len == 0) {
        diag.say("the file header on line {d} has no hunks after it: a patch that changes nothing is not a patch", .{header_number});
        return error.BadPatch;
    }

    file.hunks = try hunks.toOwnedSlice(allocator);
    return file;
}

/// Read the lines of one hunk.
///
/// How many lines to read is decided by the counts in the header, which is what
/// those counts are for: a hunk's last line is followed by the next hunk's
/// `@@`, or by the next file's `--- a/path`, and only the count says which
/// lines belong to this hunk and which to the file after it.
fn readHunkBody(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    header: HunkHeader,
    body: *std.ArrayList(Line),
    diag: *Diagnostic,
) (error{ OutOfMemory, BadPatch })!void {
    var old_seen: usize = 0;
    var new_seen: usize = 0;

    while (cursor.peek()) |raw| {
        const line = raw;

        // The marker belongs to the line before it, and can come after the last
        // line the counts account for, so it is read whether or not the hunk is
        // full.
        if (line.len > 0 and line[0] == '\\') {
            if (body.items.len == 0) {
                diag.say("line {d} marks the end of a file with no newline, but no hunk line comes before it", .{cursor.number()});
                return error.BadPatch;
            }
            body.items[body.items.len - 1].no_newline = true;
            _ = cursor.take();
            continue;
        }

        if (old_seen >= header.old_count and new_seen >= header.new_count) break;

        if (line.len == 0) {
            // An empty line where the hunk still needs lines is a context line
            // whose marking space went missing, which is how a model writes a
            // blank line of context far more often than it means anything else.
            try body.append(allocator, .{ .kind = .context, .text = "" });
            old_seen += 1;
            new_seen += 1;
            _ = cursor.take();
            continue;
        }

        switch (line[0]) {
            ' ' => {
                try body.append(allocator, .{ .kind = .context, .text = line[1..] });
                old_seen += 1;
                new_seen += 1;
            },
            '-' => {
                try body.append(allocator, .{ .kind = .remove, .text = line[1..] });
                old_seen += 1;
            },
            '+' => {
                try body.append(allocator, .{ .kind = .add, .text = line[1..] });
                new_seen += 1;
            },
            else => break,
        }
        _ = cursor.take();
    }
}

fn countKind(lines: []const Line, kind: Kind) usize {
    var count: usize = 0;
    for (lines) |line| {
        if (line.kind == kind) count += 1;
    }
    return count;
}

/// Lines that carry nothing about what to change: the blank line between two
/// files, the fence a patch arrived wrapped in, and git's own headers — which
/// git writes before every `---` it emits, and a model copies out with them.
fn isDecoration(line: []const u8) bool {
    if (line.len == 0) return true;
    if (std.mem.startsWith(u8, line, "```")) return true;

    const prefixes = [_][]const u8{
        "diff --git ",
        "index ",
        "old mode ",
        "new mode ",
        "deleted file mode ",
        "new file mode ",
        "similarity index ",
        "dissimilarity index ",
        "rename from ",
        "rename to ",
        "copy from ",
        "copy to ",
        "Binary files ",
        "GIT binary patch",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

/// The path out of a `---` or `+++` header, or null for `/dev/null`.
///
/// A git patch writes `a/path` and `b/path`, and `-p1` is what strips those two
/// off. Doing it here rather than asking the model to is what lets the output of
/// `git diff` be pasted in as it comes.
fn headerPath(allocator: std.mem.Allocator, rest: []const u8) !?[]const u8 {
    // A timestamp may follow the path, separated by a tab.
    const path = if (std.mem.indexOfScalar(u8, rest, '\t')) |tab| rest[0..tab] else rest;
    const trimmed = std.mem.trim(u8, path, " ");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "/dev/null")) return null;

    const stripped = if (std.mem.startsWith(u8, trimmed, "a/") or std.mem.startsWith(u8, trimmed, "b/"))
        trimmed[2..]
    else
        trimmed;
    if (stripped.len == 0) return null;
    return try allocator.dupe(u8, stripped);
}

/// Parse `@@ -old_start,old_count +new_start,new_count @@`, with both counts
/// optional and each defaulting to a single line.
fn parseHunkHeader(line: []const u8) ?HunkHeader {
    var i: usize = 2; // past the opening "@@"
    if (i >= line.len or line[i] != ' ') return null;
    i += 1;

    const old = parseRange(line, &i) orelse return null;
    const new = parseRange(line, &i) orelse return null;

    if (i + 2 > line.len or line[i] != '@' or line[i + 1] != '@') return null;
    // A section heading may follow the closing "@@"; nothing in it is used.

    return .{
        .old_start = old.start,
        .old_count = old.count,
        .new_count = new.count,
    };
}

const Range = struct { start: usize, count: usize };

/// Read one `-start,count` or `+start,count` out of a hunk header, and the
/// space that follows it.
fn parseRange(line: []const u8, i: *usize) ?Range {
    if (i.* >= line.len) return null;
    if (line[i.*] != '-' and line[i.*] != '+') return null;
    i.* += 1;

    const start_at = i.*;
    while (i.* < line.len and std.ascii.isDigit(line[i.*])) i.* += 1;
    if (i.* == start_at) return null;
    const start = std.fmt.parseInt(usize, line[start_at..i.*], 10) catch return null;

    var count: usize = 1;
    if (i.* < line.len and line[i.*] == ',') {
        i.* += 1;
        const count_at = i.*;
        while (i.* < line.len and std.ascii.isDigit(line[i.*])) i.* += 1;
        if (i.* == count_at) return null;
        count = std.fmt.parseInt(usize, line[count_at..i.*], 10) catch return null;
    }

    if (i.* >= line.len or line[i.*] != ' ') return null;
    i.* += 1;
    return .{ .start = start, .count = count };
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

/// Draw a patch for a terminal: file headers bold, hunk headers cyan, added
/// lines the terminal's green, and removed lines its red held back to a faint
/// shade — so what was added is what reads first, and what it replaced is there
/// to be found rather than to be looked at. Context lines are left plain.
///
/// A patch is model output, so every line goes through the same sanitising as
/// anything else printed: an escape sequence inside a "source line" is text
/// here, not a command, and it cannot end the colour early either.
pub fn render(w: *std.Io.Writer, patch_text: []const u8) !void {
    // Counted first so that a patch cut short for the terminal says how much of
    // it was left out, rather than trailing off as though that were all of it.
    // One line per newline, plus the last line when the text does not end in
    // one — which is the same walk the loop below makes.
    const total = std.mem.count(u8, patch_text, "\n") +
        @intFromBool(patch_text.len > 0 and !std.mem.endsWith(u8, patch_text, "\n"));

    var it = std.mem.splitScalar(u8, patch_text, '\n');
    var drawn: usize = 0;

    while (it.next()) |raw| {
        if (raw.len == 0 and it.peek() == null) break; // the text's own last newline
        if (drawn == render_max_lines) {
            try w.print("{s}  … {d} more line(s) of the diff are not shown{s}\n", .{ sgr.DIM, total - drawn, sgr.RESET });
            break;
        }
        drawn += 1;

        // One trailing carriage return, and only one: a CRLF patch would
        // otherwise leave each line's `\r` to return the cursor to the start
        // of the line as it is printed.
        const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        const style = lineStyle(line);

        try w.writeAll("  ");
        if (style.len != 0) try w.writeAll(style);

        // Cut on a codepoint boundary: half of a UTF-8 sequence would be
        // printed as an escape, which is noise rather than a shorter line.
        var cut = @min(line.len, render_max_line_bytes);
        while (cut > 0 and cut < line.len and !std.unicode.utf8ValidateSlice(line[0..cut])) cut -= 1;
        try text.writeSanitized(w, line[0..cut]);
        if (cut < line.len) try w.writeAll("…");

        if (style.len != 0) try w.writeAll(sgr.RESET);
        try w.writeByte('\n');
    }
}

/// The colour one line of a patch is drawn in, or an empty slice for plain.
///
/// Classification is by prefix alone, which the parser cannot afford and this
/// can: the one line it gets wrong is a removed line whose own text starts with
/// two dashes — drawn as a header rather than as a removal — and reading hunk
/// counts here to tell the difference would mean refusing to draw exactly the
/// malformed patches a user most needs to see.
fn lineStyle(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, "--- ")) return sgr.BOLD;
    if (std.mem.startsWith(u8, line, "+++ ")) return sgr.BOLD;
    if (std.mem.startsWith(u8, line, "@@")) return sgr.CYAN;
    if (line.len == 0) return "";
    return switch (line[0]) {
        '+' => sgr.GREEN,
        // Faint as well as red: a line on its way out is context for the one
        // arriving, and full-strength red on every line of a large deletion
        // turns a diff into a wall the eye stops reading.
        '-' => sgr.DIM ++ sgr.RED,
        '\\' => sgr.DIM,
        else => if (isDecoration(line)) sgr.DIM else "",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fixturePath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(testing.io, buf)];
}

/// A patch whose `{0}` is the fixture directory. Real paths are absolute, so a
/// test writes the patch it means and the applier still gets files it can open.
fn patchFor(allocator: std.mem.Allocator, dir: []const u8, comptime body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, body, .{dir});
}

fn readFixture(allocator: std.mem.Allocator, tmp: *testing.TmpDir, sub_path: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(testing.io, sub_path, allocator, .limited(1024 * 1024));
}

/// Apply a patch that is expected to apply, failing the test with the reason if
/// it does not. The caller owns what comes back.
fn applyOk(allocator: std.mem.Allocator, patch_text: []const u8) !Outcome {
    const outcome = try apply(allocator, testing.io, patch_text);
    switch (outcome) {
        .applied => {},
        .failed => |message| {
            std.debug.print("the patch did not apply: {s}\n", .{message});
            outcome.deinit(allocator);
            return error.TestUnexpectedResult;
        },
    }
    return outcome;
}

/// Apply a patch that is expected to be refused, and hand back the reason for
/// the test to read. The caller frees it.
fn applyRefused(allocator: std.mem.Allocator, patch_text: []const u8) ![]const u8 {
    const outcome = try apply(allocator, testing.io, patch_text);
    switch (outcome) {
        .applied => |stats| {
            std.debug.print("the patch applied to {d} file(s) instead of being refused\n", .{stats.len});
            outcome.deinit(allocator);
            return error.TestUnexpectedResult;
        },
        .failed => |message| return message,
    }
}

fn expectFileContent(allocator: std.mem.Allocator, tmp: *testing.TmpDir, sub_path: []const u8, expected: []const u8) !void {
    const content = try readFixture(allocator, tmp, sub_path);
    defer allocator.free(content);
    try testing.expectEqualStrings(expected, content);
}

test "a patch changes the lines it names" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "first\nsecond\nthird\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -1,3 +1,3 @@
        \\ first
        \\-second
        \\+SECOND
        \\ third
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    const stats = outcome.applied;

    try testing.expectEqual(@as(usize, 1), stats.len);
    try testing.expectEqual(Action.modified, stats[0].action);
    try testing.expectEqual(@as(usize, 1), stats[0].added);
    try testing.expectEqual(@as(usize, 1), stats[0].removed);
    try expectFileContent(allocator, &tmp, "note.txt", "first\nSECOND\nthird\n");
}

test "a patch creates a file and the directory above it" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try patchFor(allocator, dir,
        \\--- /dev/null
        \\+++ {0s}/deep/new.txt
        \\@@ -0,0 +1,2 @@
        \\+one
        \\+two
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);

    try testing.expectEqual(Action.created, outcome.applied[0].action);
    try expectFileContent(allocator, &tmp, "deep/new.txt", "one\ntwo\n");
}

test "a patch deletes a file" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "gone.txt", .data = "only\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try patchFor(allocator, dir,
        \\--- {0s}/gone.txt
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-only
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try testing.expectEqual(Action.deleted, outcome.applied[0].action);
    try testing.expectEqual(@as(usize, 1), outcome.applied[0].removed);

    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "gone.txt", .{}));
}

test "hunks are placed by their text when the numbers are stale" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "note.txt",
        .data = "one\ntarget\nthree\nfour\nfive\nsix\nseven\neight\nnine\n",
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // A model that counted the lines of a file it had not re-read writes the
    // wrong number far more often than it writes the wrong context.
    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -7,3 +7,3 @@
        \\ one
        \\-target
        \\+TARGET
        \\ three
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try expectFileContent(allocator, &tmp, "note.txt", "one\nTARGET\nthree\nfour\nfive\nsix\nseven\neight\nnine\n");
}

test "a hunk that fits nowhere is refused and the file is left alone" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "first\nsecond\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -1,2 +1,2 @@
        \\ first
        \\-nowhere
        \\+anywhere
    );
    defer allocator.free(patch);

    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);

    // The message has to name the file and both sides of the mismatch: that is
    // what the next patch is written from.
    try testing.expect(std.mem.indexOf(u8, message, "note.txt") != null);
    try testing.expect(std.mem.indexOf(u8, message, "nowhere") != null);
    try testing.expect(std.mem.indexOf(u8, message, "second") != null);
    try expectFileContent(allocator, &tmp, "note.txt", "first\nsecond\n");
}

test "a hunk that fits in two places is refused rather than guessed at" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "a\nsame\nb\nsame\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -9,1 +9,1 @@
        \\-same
        \\+other
    );
    defer allocator.free(patch);

    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "two places") != null);
    try expectFileContent(allocator, &tmp, "note.txt", "a\nsame\nb\nsame\n");
}

test "a patch for a file that is not there says what to do" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try patchFor(allocator, dir,
        \\--- {0s}/missing.txt
        \\+++ {0s}/missing.txt
        \\@@ -1,1 +1,1 @@
        \\-old
        \\+new
    );
    defer allocator.free(patch);

    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "missing.txt") != null);
    try testing.expect(std.mem.indexOf(u8, message, "/dev/null") != null);
}

test "a file that is not a diff is refused with the line that gave it away" {
    const allocator = testing.allocator;
    const message = try applyRefused(allocator, "Here is the patch you asked for:\n");
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "not part of a diff") != null);
    try testing.expect(std.mem.indexOf(u8, message, "Here is the patch") != null);
}

test "a hunk whose counts do not match its lines is refused" {
    const allocator = testing.allocator;
    const patch =
        \\--- a/note.txt
        \\+++ b/note.txt
        \\@@ -1,3 +1,3 @@
        \\ first
        \\-second
        \\+SECOND
    ;
    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "accounts for 3 old and 3 new lines, and the hunk carries 2 and 2") != null);
}

test "a git path loses its a/ or b/ prefix, and a timestamp is not part of it" {
    const allocator = testing.allocator;

    const old = try headerPath(allocator, "a/src/main.zig\t2026-09-28 10:00:00 +0800");
    defer if (old) |path| allocator.free(path);
    try testing.expectEqualStrings("src/main.zig", old.?);

    const new = try headerPath(allocator, "b/src/main.zig");
    defer if (new) |path| allocator.free(path);
    try testing.expectEqualStrings("src/main.zig", new.?);

    // A patch written without prefixes — as `diff -u x x` writes one — reads
    // as it is.
    const bare = try headerPath(allocator, "src/main.zig");
    defer if (bare) |path| allocator.free(path);
    try testing.expectEqualStrings("src/main.zig", bare.?);

    try testing.expectEqual(@as(?[]const u8, null), try headerPath(allocator, "/dev/null"));
}

test "a file whose second hunk is wrong is refused whole" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "one\ntwo\nthree\nfour\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // The first hunk reads and the second one does not: the file must come out
    // of this untouched, and nothing the first hunk read may be left behind —
    // which is the one path where a hunk that parsed is not owned by anything.
    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -1,1 +1,1 @@
        \\-one
        \\+ONE
        \\@@ -3,2 +3,2 @@
        \\ three
    );
    defer allocator.free(patch);

    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "accounts for 2 old") != null);
    try expectFileContent(allocator, &tmp, "note.txt", "one\ntwo\nthree\nfour\n");
}

test "a patch that arrives wrapped in a fence, with git's headers, still applies" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });

    // The fixture as the process sees it, so that this patch can carry the `a/`
    // and `b/` prefixes a git patch has and still name a file that is there.
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/note.txt", .{tmp.sub_path[0..]});
    defer allocator.free(path);

    // Everything git writes around a diff is ignored, and the fence a model
    // wraps one in is not part of it either.
    const patch = try patchFor(allocator, path,
        \\```diff
        \\diff --git a/{0s} b/{0s}
        \\index 1234567..89abcde 100644
        \\--- a/{0s}
        \\+++ b/{0s}
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\+TWO
        \\```
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try expectFileContent(allocator, &tmp, "note.txt", "one\nTWO\n");
}

test "a patch keeps a file's missing final newline, and gives it one when a line is added" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "none.txt", .data = "one\ntwo" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // `\\\` is the multiline marker followed by a backslash: the line itself
    // begins with the marker, and it has to.
    const patched = try patchFor(allocator, dir,
        \\--- {0s}/none.txt
        \\+++ {0s}/none.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\\ No newline at end of file
        \\+TWO
        \\\ No newline at end of file
    );
    defer allocator.free(patched);
    const outcome = try applyOk(allocator, patched);
    outcome.deinit(allocator);
    try expectFileContent(allocator, &tmp, "none.txt", "one\nTWO");

    // A line appended after a file's unterminated last line: that line is no
    // longer last, so it takes the newline the new one brings.
    const appended = try patchFor(allocator, dir,
        \\--- {0s}/plain.txt
        \\+++ {0s}/plain.txt
        \\@@ -1,2 +1,3 @@
        \\ one
        \\ two
        \\+three
    );
    defer allocator.free(appended);
    const grown = try applyOk(allocator, appended);
    grown.deinit(allocator);
    try expectFileContent(allocator, &tmp, "plain.txt", "one\ntwo\nthree\n");
}

test "a CRLF file is written back with its own line endings" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "dos.txt", .data = "one\r\ntwo\r\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try patchFor(allocator, dir,
        \\--- {0s}/dos.txt
        \\+++ {0s}/dos.txt
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\+TWO
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    // Every line, not just the patched one: a hunk that touched one line must
    // not turn the rest of the file into a change as well.
    try expectFileContent(allocator, &tmp, "dos.txt", "one\r\nTWO\r\n");
}

test "two hunks apply with the offsets the first one moved" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "note.txt",
        .data = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n",
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // The hunks address the original file, and the first one changes the line
    // count, so an applier that counted in the output would land the second
    // one a line out.
    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -1,2 +1,3 @@
        \\ one
        \\+one and a half
        \\ two
        \\@@ -6,3 +7,3 @@
        \\ six
        \\-seven
        \\+SEVEN
        \\ eight
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try expectFileContent(allocator, &tmp, "note.txt", "one\none and a half\ntwo\nthree\nfour\nfive\nsix\nSEVEN\neight\n");
}

test "a blank line where a context line's space should be is read as context" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "one\n\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // Models write a blank context line as a blank line rather more often than
    // they mean anything else by it.
    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -1,3 +1,3 @@
        \\ one
        \\
        \\-two
        \\+TWO
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try expectFileContent(allocator, &tmp, "note.txt", "one\n\nTWO\n");
}

test "a patch that changes nothing, and one that names no file, are both refused" {
    const allocator = testing.allocator;

    const empty = try applyRefused(allocator, "\n\n");
    defer allocator.free(empty);
    try testing.expect(std.mem.indexOf(u8, empty, "no file headers") != null);

    const nothing = try applyRefused(allocator,
        \\--- /dev/null
        \\+++ /dev/null
        \\@@ -0,0 +0,0 @@
    );
    defer allocator.free(nothing);
    try testing.expect(std.mem.indexOf(u8, nothing, "names no file") != null);
}

test "the diff is drawn in the terminal's red and green, and faint for what goes" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try render(&aw.writer,
        \\--- a/note.txt
        \\+++ b/note.txt
        \\@@ -1,2 +1,2 @@
        \\-gone
        \\+added
        \\ kept
        \\\ No newline at end of file
    );

    try testing.expectEqualStrings(
        "  " ++ sgr.BOLD ++ "--- a/note.txt" ++ sgr.RESET ++ "\n" ++
            "  " ++ sgr.BOLD ++ "+++ b/note.txt" ++ sgr.RESET ++ "\n" ++
            "  " ++ sgr.CYAN ++ "@@ -1,2 +1,2 @@" ++ sgr.RESET ++ "\n" ++
            "  " ++ sgr.DIM ++ sgr.RED ++ "-gone" ++ sgr.RESET ++ "\n" ++
            "  " ++ sgr.GREEN ++ "+added" ++ sgr.RESET ++ "\n" ++
            // Context is left plain, with no escape of its own: a caller that
            // has styled the block around it keeps its styling.
            "   kept\n" ++
            "  " ++ sgr.DIM ++ "\\ No newline at end of file" ++ sgr.RESET ++ "\n",
        aw.written(),
    );
}

test "the drawn diff carries nothing a terminal would act on" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    // A patch is model output: an escape sequence inside a "source line" is
    // text to be looked at, not a colour to be obeyed, and it must not be able
    // to end the colour the line was drawn in either.
    try render(&aw.writer, "+keep \x1b[31mred\x1b[0m\n+bad \xff byte\n");

    try testing.expectEqualStrings(
        "  " ++ sgr.GREEN ++ "+keep red" ++ sgr.RESET ++ "\n" ++
            "  " ++ sgr.GREEN ++ "+bad \\xFF byte" ++ sgr.RESET ++ "\n",
        aw.written(),
    );
}

test "a patch too long for the terminal is cut where it says it was" {
    const allocator = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var long: std.Io.Writer.Allocating = .init(allocator);
    defer long.deinit();
    for (0..render_max_lines + 10) |i| try long.writer.print("+line {d}\n", .{i});

    try render(&aw.writer, long.written());

    const drawn = aw.written();
    try testing.expect(std.mem.endsWith(u8, drawn, "10 more line(s) of the diff are not shown" ++ sgr.RESET ++ "\n"));
    try testing.expect(std.mem.indexOf(u8, drawn, "+line 0" ++ sgr.RESET) != null);
    try testing.expect(std.mem.indexOf(u8, drawn, "+line 400" ++ sgr.RESET) == null);
}
