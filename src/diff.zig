//! Git Unified Diffs: reading one, applying one, and drawing one.
//!
//! The format is the one `git diff` and `diff -u` write, and what `git apply`
//! reads: `diff --git a/old b/new` sections carrying `index`, `similarity
//! index`, `old mode`/`new mode`, `new file mode`, `deleted file mode` and
//! `rename from`/`rename to`; `--- a/path` / `+++ b/path` headers whose paths
//! may be git-quoted (`"a/caf\303\251.txt"`, with the C escapes undoing back to
//! bytes); and `@@ -l,c +l,c @@` hunks of space, `-` and `+` lines with their
//! `\ No newline at end of file` markers.
//!
//! The agent edits files by writing these, so the parser is lenient about
//! everything that does not change what a patch means — git's metadata headers,
//! a count left out of a hunk header, the blank line a model writes where a
//! blank *context* line should be, the fence a patch arrives wrapped in — and
//! strict about the one thing that does: the text a hunk says it replaces has
//! to be the text the file holds. A hunk that does not match is reported, never
//! guessed at, and one that would fit in two places is reported rather than
//! placed in the nearer of them, because a patch landing in the wrong place is
//! worse than a patch that did not land at all.
//!
//! Nothing is written until every file of the patch has been rebuilt in memory,
//! so a patch whose last hunk fails leaves the tree exactly as it was.
//!
//! The permissions git prints are carried out: a `new file mode 100755` creates
//! an executable, `old mode`/`new mode` changes one, and a section that changes
//! nothing but the mode is applied as that change on its own. What is
//! deliberately not supported: binary patches (`GIT binary patch`, `Binary
//! files … differ`), copies, symlinks and submodules (mode 120000/160000), and
//! the fuzz that lets `patch(1)` apply a hunk to text it does not quite match.
//!
//! A rename is read the way git writes one — a `diff --git a/old b/new` section
//! with `rename from`/`rename to`, and either no `---`/`+++` pair at all
//! (nothing but the name changes) or one whose hunks apply to the old file —
//! because that is the form that says "rename" rather than "these two headers
//! disagree". A bare `--- old` / `+++ new` with no such section is still
//! refused: that is what a mistyped path looks like, and the pair of headers is
//! the one part of a patch whose mismatch is more likely a typo than an intent.

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

pub const Action = enum { modified, created, deleted, renamed, mode_changed };

/// One file the patch changed, as it was changed. Owns `path`.
pub const FileStat = struct {
    /// The file's path after the patch: the new name of a rename.
    path: []const u8,
    /// For a rename, the path the file had before. Owned; null otherwise.
    from: ?[]const u8 = null,
    action: Action,
    added: usize,
    removed: usize,
    /// The mode the patch set on the file, as git prints one — `100755` — when
    /// it said anything about it at all. Nothing owns it: it is a number.
    mode: ?u32 = null,
};

/// What applying a patch came to.
pub const Outcome = union(enum) {
    /// The files that were written, in the order the patch named them.
    applied: []const FileStat,
    /// Nothing was written, and this says why. Owns its text.
    failed: []const u8,

    pub fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .applied => |stats| freeStats(allocator, stats),
            .failed => |message| allocator.free(message),
        }
    }
};

fn freeStats(allocator: std.mem.Allocator, stats: []const FileStat) void {
    for (stats) |stat| {
        allocator.free(stat.path);
        if (stat.from) |from| allocator.free(from);
    }
    allocator.free(stats);
}

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
        for (stats[0..filled]) |stat| {
            allocator.free(stat.path);
            if (stat.from) |from| allocator.free(from);
        }
        allocator.free(stats);
    }
    for (plans.items, 0..) |plan, i| {
        stats[i] = .{
            .path = try allocator.dupe(u8, plan.path),
            .from = if (plan.old_path) |old| try allocator.dupe(u8, old) else null,
            .action = plan.action,
            .added = plan.added,
            .removed = plan.removed,
            .mode = plan.mode,
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
            freeStats(allocator, stats);
            return .{ .failed = message };
        };
    }

    return .{ .applied = stats };
}

/// Write one planned file: a new body for a modified or created file, the same
/// bytes under a new name for a rename, nothing at all but a removal for a
/// deletion, and nothing but the permissions for a patch that changes only
/// those.
fn writePlan(io: std.Io, plan: Plan) !void {
    const cwd = std.Io.Dir.cwd();
    switch (plan.action) {
        .deleted => try cwd.deleteFile(io, plan.path),
        .mode_changed => try setMode(io, plan.path, plan.mode.?),
        .renamed => {
            const old = plan.old_path.?;
            const content = plan.content orelse {
                // Nothing but the name changes, so nothing has to be rewritten:
                // a plain rename keeps the bytes, the mode and the timestamps —
                // unless the patch named a mode of its own.
                if (std.Io.Dir.path.dirname(plan.path)) |dir_path| {
                    cwd.createDirPath(io, dir_path) catch {};
                }
                try cwd.rename(old, cwd, plan.path, io);
                if (plan.mode) |mode| try setMode(io, plan.path, mode);
                return;
            };
            // The body is rewritten, so the mode has to be carried across by
            // hand: an executable script that is renamed stays executable.
            var permissions: ?std.Io.Dir.Permissions = null;
            if (plan.mode) |mode| {
                permissions = permissionsOf(mode);
            } else if (cwd.statFile(io, old, .{})) |stat| {
                permissions = stat.permissions;
            } else |_| {}
            try writeBytes(io, plan.path, content, permissions);
            // On a case-insensitive file system a rename that only changes case
            // writes the file it is about to delete, so the deletion is skipped
            // when both names turn out to be the one file.
            if (!sameFile(io, old, plan.path)) try cwd.deleteFile(io, old);
        },
        else => try writeBytes(io, plan.path, plan.content.?, if (plan.mode) |mode| permissionsOf(mode) else null),
    }
}

/// The permissions a git mode stands for. Git prints the whole `st_mode` as
/// octal — `100644`, `100755` — so what a file gets is the low nine bits of it.
fn permissionsOf(mode: u32) std.Io.File.Permissions {
    return .fromMode(@intCast(mode & 0o777));
}

/// Change one file's permissions, for a patch whose whole change is the mode.
fn setMode(io: std.Io, path: []const u8, mode: u32) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try file.setPermissions(io, permissionsOf(mode));
}

fn writeBytes(io: std.Io, path: []const u8, content: []const u8, permissions: ?std.Io.Dir.Permissions) !void {
    if (std.Io.Dir.path.dirname(path)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
    if (permissions) |perms| file.setPermissions(io, perms) catch {};
}

/// Whether two paths name one file on disk. Only a rename asks: it is what keeps
/// a case-only rename on a case-insensitive file system from deleting the file
/// it has just written.
fn sameFile(io: std.Io, a: []const u8, b: []const u8) bool {
    var buf_a: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var buf_b: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len_a = std.Io.Dir.cwd().realPathFile(io, a, &buf_a) catch return false;
    const len_b = std.Io.Dir.cwd().realPathFile(io, b, &buf_b) catch return false;
    return std.mem.eql(u8, buf_a[0..len_a], buf_b[0..len_b]);
}

/// What one file of a patch came to, once every hunk of it has been matched.
const Plan = struct {
    /// The path the file has after the patch.
    path: []const u8,
    /// For a rename, the path it had before. Owned; null otherwise.
    old_path: ?[]const u8,
    action: Action,
    /// The file's new contents, or null for a deletion, and for a rename that
    /// changes nothing but the name, and for a patch that changes only the
    /// permissions. Owned.
    content: ?[]u8,
    added: usize,
    removed: usize,
    /// The mode the patch named, as git prints one. Null when it named none.
    mode: ?u32 = null,

    fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.old_path) |old| allocator.free(old);
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
    // Two names that are not the same name are a rename, and a rename read out
    // of two headers alone is how a mistyped path turns into a lost file. So the
    // difference is only taken as a rename when the patch said so in git's own
    // words; a bare pair that disagrees is refused, and the agent can delete and
    // create instead, in two patches whose results it can check.
    const rename = file.renamed and file.old_path != null and file.new_path != null and
        !std.mem.eql(u8, file.old_path.?, file.new_path.?);

    if (!rename) {
        if (file.old_path) |old| {
            if (file.new_path) |new| {
                if (!std.mem.eql(u8, old, new)) {
                    diag.say("the patch names two different files, '{s}' and '{s}'. A rename is sent the way git writes it — 'diff --git a/{s} b/{s}' with 'rename from' and 'rename to', or with '--- a/{s}' and '+++ b/{s}' hunks — and anything else is a create of the new file plus a delete of the old one", .{ old, new, old, new, old, new });
                    return error.BadPatch;
                }
            }
        }
    }

    const action: Action = if (file.old_path == null)
        .created
    else if (file.new_path == null)
        .deleted
    else if (rename)
        .renamed
    else
        .modified;
    // The name the file had before the patch: the old side of a rename, and the
    // file a patch against one name changes.
    const original_path = file.old_path orelse file.new_path.?;
    // The name the file has after it.
    const path = file.new_path orelse file.old_path.?;

    // The permissions the section asked for, if it asked for any.
    const mode = file.mode;

    if (action == .created and pathExists(io, path)) {
        diag.say("'{s}' already exists, so it cannot be created: send it as a patch against the file it is now", .{path});
        return error.BadPatch;
    }
    if (action == .renamed) {
        if (!pathExists(io, original_path)) {
            diag.say("'{s}' cannot be renamed because it does not exist: a rename has to start from a file the tree has", .{original_path});
            return error.BadPatch;
        }
        // Checking before reading rather than while writing: the new name is
        // what the patch would otherwise overwrite without saying so.
        if (pathExists(io, path)) {
            diag.say("the rename target '{s}' already exists, so '{s}' cannot be renamed onto it: move it away first, or patch it in place", .{ path, original_path });
            return error.BadPatch;
        }
    }

    // A rename that changes nothing but the name is not read at all: the bytes
    // are the old file's, and moving them is cheaper and more exact than
    // rebuilding them from the lines they split into.
    if (action == .renamed and file.hunks.len == 0) {
        return buildPlan(allocator, path, original_path, action, null, 0, 0, mode);
    }

    // A section that changes nothing but the permissions has no text to apply:
    // git writes 'old mode' and 'new mode' and no headers at all for one.
    if (action == .modified and file.hunks.len == 0 and mode != null) {
        if (!pathExists(io, path)) {
            diag.say("'{s}' cannot have its mode changed because it does not exist: a mode change names a file the tree has", .{path});
            return error.BadPatch;
        }
        return buildPlan(allocator, path, null, .mode_changed, null, 0, 0, mode);
    }

    const original: []u8 = if (action == .created)
        try allocator.dupe(u8, "")
    else
        std.Io.Dir.cwd().readFileAlloc(io, original_path, allocator, .limited(max_file_bytes)) catch |err| {
            if (err == error.StreamTooLong) {
                diag.say("'{s}' is larger than the {d} MB this tool reads", .{ original_path, max_file_bytes / (1024 * 1024) });
                return error.BadPatch;
            }
            diag.say("'{s}' could not be read ({s}): it has to exist before it can be patched, and a new file is sent with '--- /dev/null'", .{ original_path, @errorName(err) });
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
    // The last matched hunk anchors stale line numbers in the same file.
    var anchor: ?HunkAnchor = null;

    for (file.hunks) |hunk| {
        // A zero-length old range names the line *before* an insertion.
        const stated = if (oldSideLen(hunk) == 0)
            hunk.header.old_start
        else if (hunk.header.old_start > 0)
            hunk.header.old_start - 1
        else
            0;
        // `locate` has more than one way to find nothing, and each explains
        // itself; `describeMiss` is for the one that has nothing to say yet.
        const already_said = diag.written().len;
        const at = locate(diag, original_path, source.lines.items, consumed, hunk, stated, anchor) orelse {
            if (diag.written().len == already_said) describeMiss(diag, original_path, source.lines.items, hunk, stated);
            return error.BadPatch;
        };
        if (oldSideLen(hunk) > 0) anchor = .{ .stated = stated, .actual = at };

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

    return buildPlan(allocator, path, if (action == .renamed) original_path else null, action, content, added, removed, mode);
}

/// The plan for one file, taking its own copy of both names.
fn buildPlan(
    allocator: std.mem.Allocator,
    path: []const u8,
    old_path: ?[]const u8,
    action: Action,
    content: ?[]u8,
    added: usize,
    removed: usize,
    mode: ?u32,
) error{OutOfMemory}!Plan {
    const owned_path = try allocator.dupe(u8, path);
    const owned_old = if (old_path) |old| try allocator.dupe(u8, old) else null;
    return .{
        .path = owned_path,
        .old_path = owned_old,
        .action = action,
        .content = content,
        .added = added,
        .removed = removed,
        .mode = mode,
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

/// A confirmed match supplies an offset without signed arithmetic on untrusted
/// header numbers. Overflow/underflow means there is no usable prediction.
const HunkAnchor = struct {
    stated: usize,
    actual: usize,

    fn predict(self: HunkAnchor, stated: usize) ?usize {
        if (self.actual >= self.stated)
            return std.math.add(usize, stated, self.actual - self.stated) catch null;
        return std.math.sub(usize, stated, self.stated - self.actual) catch null;
    }
};

/// Try the stated position, then the offset established by the previous hunk,
/// always requiring an exact old-side match outside already consumed text.
/// Otherwise only a unique text match is accepted: proximity alone is not
/// evidence that one of two identical blocks is the intended target.
fn locate(diag: *Diagnostic, path: []const u8, lines: []const []const u8, consumed: usize, hunk: Hunk, stated: usize, anchor: ?HunkAnchor) ?usize {
    const need = oldSideLen(hunk);
    // A hunk that only adds lines has nothing to match against; it goes where
    // it says it goes, which is how the first lines of a new file are placed.
    if (need == 0) {
        if (stated < consumed or stated > lines.len) {
            diag.say("the insertion at patch line {d} names position {d} in '{s}', outside the remaining range {d}..{d}; add context or correct the line number", .{ hunk.patch_line, stated, path, consumed, lines.len });
            return null;
        }
        return stated;
    }

    if (stated >= consumed and matchesAt(lines, stated, hunk)) return stated;
    if (anchor) |previous| {
        if (previous.predict(stated)) |predicted| {
            if (predicted >= consumed and matchesAt(lines, predicted, hunk)) return predicted;
        }
    }

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
    /// Whether the patch says in git's own words that these two names are one
    /// rename, rather than two headers that happen to disagree.
    renamed: bool = false,
    /// The mode the section named, as git prints one: `new file mode`, or the
    /// `new mode` of an `old mode`/`new mode` pair. Null when it named none, in
    /// which case the file keeps the permissions it has.
    mode: ?u32 = null,
    hunks: []Hunk,

    fn deinit(self: FilePatch, allocator: std.mem.Allocator) void {
        if (self.old_path) |path| allocator.free(path);
        if (self.new_path) |path| allocator.free(path);
        for (self.hunks) |hunk| hunk.deinit(allocator);
        allocator.free(self.hunks);
    }
};

/// What a git section says about the file before its hunks: the file it is
/// about, the mode change it may announce, and the `rename from`/`rename to`
/// pair that makes it a rename.
///
/// Kept between the lines that carry it rather than read where it is used,
/// because a rename's two names are written before the headers that repeat them,
/// and because a rename with no hunks at all has nothing else to be read from.
/// Owns its names.
const Section = struct {
    /// The name the section starts from: the `rename from` line.
    from: ?[]const u8 = null,
    /// The name it goes to: the `rename to` line.
    to: ?[]const u8 = null,
    /// The file `diff --git` says the section is about. Kept for the refusals
    /// that have no rename lines to name a file with.
    subject: ?[]const u8 = null,
    /// The line the section began on, so a refusal can point at it.
    line: usize = 0,
    /// `new file mode`: the permissions a file this section creates is written
    /// with, and — when the section has no hunks at all — what makes it the
    /// creation of an empty file.
    new_file_mode: ?u32 = null,
    /// `deleted file mode`: a deletion of a file that had nothing in it, which
    /// git writes with no hunks to remove.
    deleted_file_mode: bool = false,
    /// `old mode`/`new mode`: the permissions the file ends up with, applied
    /// after whatever the hunks wrote.
    old_mode: ?u32 = null,
    new_mode: ?u32 = null,
    /// `copy from`/`copy to`. A copy leaves the original in place, so reading it
    /// as a rename would delete a file the patch never mentions again.
    copy: bool = false,

    fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.* = .{};
    }

    fn clear(self: *Section, allocator: std.mem.Allocator) void {
        if (self.from) |from| allocator.free(from);
        if (self.to) |to| allocator.free(to);
        if (self.subject) |subject| allocator.free(subject);
        self.from = null;
        self.to = null;
        self.subject = null;
        self.line = 0;
        self.new_file_mode = null;
        self.deleted_file_mode = false;
        self.old_mode = null;
        self.new_mode = null;
        self.copy = false;
    }

    fn isRename(self: Section) bool {
        return self.from != null and self.to != null and !std.mem.eql(u8, self.from.?, self.to.?);
    }

    /// The mode this section gives the file it ends up with, if any. A pair of
    /// mode lines that say the same thing is no change at all, and a `new file
    /// mode` is the whole of a creation's mode.
    fn givenMode(self: Section) ?u32 {
        if (self.new_file_mode) |created| return created;
        if (self.old_mode) |old| {
            if (self.new_mode) |new| {
                if (old != new) return new;
            }
        }
        return null;
    }

    /// The file to name when explaining what this section cannot be applied as.
    fn named(self: Section) []const u8 {
        return self.from orelse self.to orelse self.subject orelse "a file";
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
    // Git's metadata for the file whose hunks are being read, or for the rename
    // that has none.
    var section: Section = .{};
    defer section.deinit(allocator);

    while (cursor.take()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t");

        if (std.mem.startsWith(u8, line, "diff --git ")) {
            // Whatever the section before this one announced and never got to
            // apply is finished here: a rename that changes nothing but the name
            // is the whole of its section.
            if (try finishSection(allocator, &section, diag)) |file_patch| {
                try appendFile(allocator, &files, file_patch, diag);
            }
            section.clear(allocator);
            section.line = cursor.i;
            section.subject = try diffGitSubject(allocator, line);
            continue;
        }
        if (gitMeta(line)) |what| {
            // A section that git did not open with `diff --git` is still a
            // section, and its first metadata line is where it starts.
            if (section.line == 0) section.line = cursor.i;
            switch (what) {
                // A rename is read from these two lines and from nowhere else:
                // they are the only part of a git patch that says "one file, two
                // names" rather than "these headers disagree", and git writes
                // both for every rename it finds, hunks or none.
                .rename_from => try setSectionPath(allocator, &section.from, line["rename from ".len..]),
                .rename_to => try setSectionPath(allocator, &section.to, line["rename to ".len..]),
                .copy => section.copy = true,
            }
            continue;
        }
        if (modeLine(line)) |meta| {
            if (section.line == 0) section.line = cursor.i;
            // Git prints a whole `st_mode`, so the type bits say whether this is
            // a file this tool can write at all: a symlink's "contents" are a
            // path, and a submodule's are a commit.
            if (meta.mode & 0o170000 != 0o100000) {
                diag.say("the section on line {d} gives '{s}' mode {o}, which is a symlink or a submodule rather than a regular file: this tool writes regular files only", .{ section.line, section.named(), meta.mode });
                return error.BadPatch;
            }
            switch (meta.kind) {
                .new_file => section.new_file_mode = meta.mode,
                .deleted_file => section.deleted_file_mode = true,
                .old => section.old_mode = meta.mode,
                .new => section.new_mode = meta.mode,
            }
            continue;
        }
        // A binary change is a git patch nothing here can carry out: refusing at
        // the line that says so beats reading base85 as though it were a diff.
        if (std.mem.startsWith(u8, line, "Binary files ") or std.mem.startsWith(u8, line, "GIT binary patch")) {
            if (section.line == 0) section.line = cursor.i;
            diag.say("the section on line {d} changes '{s}' in binary, which this tool does not apply: change the file with 'write' instead", .{ section.line, section.named() });
            return error.BadPatch;
        }
        if (isDecoration(line)) continue;

        if (std.mem.startsWith(u8, line, "--- ")) {
            // A copy with hunks is still a copy: its hunks would land, and then
            // the original would be deleted as though this were a rename.
            try rejectCopy(&section, diag);
            const file_patch = try parseFile(allocator, &cursor, line, &section, diag);
            // The section's names are the file's now; the next file starts a new
            // one.
            section.clear(allocator);
            try appendFile(allocator, &files, file_patch, diag);
            continue;
        }

        diag.say("line {d} is not part of a diff: \"{s}\". A patch reads '--- a/path', '+++ b/path', then '@@ -1,2 +1,2 @@' hunks whose lines each start with a space, '-' or '+'", .{ cursor.i, line });
        return error.BadPatch;
    }

    // A rename with no hunks is the last thing in a patch as often as it is the
    // first, so the section is finished here too.
    if (try finishSection(allocator, &section, diag)) |file_patch| {
        try appendFile(allocator, &files, file_patch, diag);
    }

    if (files.items.len == 0) {
        diag.say("no file headers found: a patch starts with '--- a/path' followed by '+++ b/path', or with a git 'diff --git a/path b/path' section", .{});
        return error.BadPatch;
    }

    return .{ .files = try files.toOwnedSlice(allocator) };
}

/// The git metadata lines that decide what a section means, as opposed to the
/// ones that only say what it came from and are skipped as decoration.
const Meta = enum { rename_from, rename_to, copy };

fn gitMeta(line: []const u8) ?Meta {
    if (std.mem.startsWith(u8, line, "rename from ")) return .rename_from;
    if (std.mem.startsWith(u8, line, "rename to ")) return .rename_to;
    if (std.mem.startsWith(u8, line, "copy from ") or std.mem.startsWith(u8, line, "copy to ")) return .copy;
    return null;
}

const ModeKind = enum { new_file, deleted_file, old, new };

/// One of git's four mode lines, with the mode it names.
const ModeMeta = struct {
    kind: ModeKind,
    /// The whole `st_mode` as git prints it, in octal: `100755`.
    mode: u32,
};

fn modeLine(line: []const u8) ?ModeMeta {
    const kinds = [_]struct { prefix: []const u8, kind: ModeKind }{
        .{ .prefix = "new file mode ", .kind = .new_file },
        .{ .prefix = "deleted file mode ", .kind = .deleted_file },
        .{ .prefix = "old mode ", .kind = .old },
        .{ .prefix = "new mode ", .kind = .new },
    };
    for (kinds) |kind| {
        if (!std.mem.startsWith(u8, line, kind.prefix)) continue;
        const digits = std.mem.trimEnd(u8, line[kind.prefix.len..], " \t");
        const mode = std.fmt.parseInt(u32, digits, 8) catch return null;
        return .{ .kind = kind.kind, .mode = mode };
    }
    return null;
}

fn appendFile(
    allocator: std.mem.Allocator,
    files: *std.ArrayList(FilePatch),
    file: FilePatch,
    diag: *Diagnostic,
) (error{ OutOfMemory, BadPatch })!void {
    if (files.items.len >= max_files) {
        var given = file;
        given.deinit(allocator);
        diag.say("the patch changes more than {d} files", .{max_files});
        return error.BadPatch;
    }
    try files.append(allocator, file);
}

/// The `b/` side of a `diff --git` line: the file the section is about.
///
/// A name git had to escape is written quoted on both sides — `diff --git
/// "a/caf\303\251.txt" "b/caf\303\251.txt"` — so the quoted form is read first
/// and the plain form, whose two names are separated by " b/", second.
fn diffGitSubject(allocator: std.mem.Allocator, line: []const u8) error{OutOfMemory}!?[]const u8 {
    const rest = line["diff --git ".len..];
    if (rest.len > 0 and rest[0] == '"') {
        const end = quotedEnd(rest) orelse return null;
        const second = std.mem.trimStart(u8, rest[end..], " ");
        if (second.len == 0) return null;
        return headerPath(allocator, second);
    }
    const split = std.mem.indexOf(u8, rest, " b/") orelse return null;
    return headerPath(allocator, rest[split + 1 ..]);
}

fn setSectionPath(allocator: std.mem.Allocator, slot: *?[]const u8, rest: []const u8) error{OutOfMemory}!void {
    const path = (try headerPath(allocator, rest)) orelse return;
    if (slot.*) |old| allocator.free(old);
    slot.* = path;
}

/// A copy is not a rename, and the difference is a file: this tool would land
/// the copied hunks and then take the original away.
fn rejectCopy(section: *Section, diag: *Diagnostic) error{BadPatch}!void {
    if (!section.copy) return;
    diag.say("the section on line {d} copies into '{s}', which this tool does not do: send the copied file as a new file and leave the original where it is", .{ section.line, section.named() });
    return error.BadPatch;
}

/// Finish a section that ended without hunks. Git writes three of those: a
/// rename, whose two names are the whole change; a new or deleted empty file,
/// which `new file mode`/`deleted file mode` announce with nothing to show; and
/// a change to the permissions alone. Anything else has nothing to apply.
fn finishSection(allocator: std.mem.Allocator, section: *Section, diag: *Diagnostic) error{ BadPatch, OutOfMemory }!?FilePatch {
    try rejectCopy(section, diag);
    if ((section.from == null) != (section.to == null)) {
        diag.say("the section on line {d} has only one of 'rename from' and 'rename to': a rename names the file it starts from and the file it becomes, and '{s}' cannot be moved on one of them", .{ section.line, section.named() });
        return error.BadPatch;
    }
    if (section.isRename()) {
        const from = section.from.?;
        const to = section.to.?;
        const mode = section.givenMode();
        section.from = null;
        section.to = null;
        return FilePatch{
            .old_path = from,
            .new_path = to,
            .renamed = true,
            .mode = mode,
            .hunks = &.{},
        };
    }
    // An empty file is all that `new file mode` says on its own: git writes no
    // headers and no hunks for one, because there are no lines to add.
    if (section.new_file_mode) |mode| {
        const path = (try headerPath(allocator, section.named())) orelse {
            diag.say("the section on line {d} creates a file but names none", .{section.line});
            return error.BadPatch;
        };
        return FilePatch{ .old_path = null, .new_path = path, .mode = mode, .hunks = &.{} };
    }
    if (section.deleted_file_mode) {
        const path = (try headerPath(allocator, section.named())) orelse {
            diag.say("the section on line {d} deletes a file but names none", .{section.line});
            return error.BadPatch;
        };
        return FilePatch{ .old_path = path, .new_path = null, .hunks = &.{} };
    }
    // `old mode`/`new mode` with nothing else is a change of permissions and
    // only of those. The file is named by the section's `diff --git` line, and
    // the change is a pair of names that are the same, so it reads as a
    // modification with no hunks.
    if (section.givenMode()) |mode| {
        const path = (try headerPath(allocator, section.named())) orelse {
            diag.say("the section on line {d} changes a mode but names no file", .{section.line});
            return error.BadPatch;
        };
        // Both sides are the same file, and each is freed from its own field.
        const new_path = allocator.dupe(u8, path) catch |err| {
            allocator.free(path);
            return err;
        };
        return FilePatch{ .old_path = path, .new_path = new_path, .mode = mode, .hunks = &.{} };
    }
    return null;
}

/// Read one file of a patch: its `+++` header and every hunk up to the next
/// file, or the end.
///
/// `section` is what the git metadata before the headers said, which is where
/// a rename's two names are already known and where the headers may only agree.
fn parseFile(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    old_line: []const u8,
    section: *Section,
    diag: *Diagnostic,
) (error{ OutOfMemory, BadPatch })!FilePatch {
    const header_number = cursor.i;
    var file: FilePatch = .{
        .old_path = try headerPath(allocator, old_line[4..]),
        .new_path = null,
        .renamed = section.isRename(),
        .mode = section.givenMode(),
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

    // Git's rename lines are the authority on a rename's two names, and the
    // headers repeat them. Agreement is required: a patch that says one thing in
    // 'rename to' and another in '+++' is a patch whose file would go missing.
    if (section.from) |from| {
        try adoptSectionPath(allocator, &file.old_path, from, "---", header_number, diag);
    }
    if (section.to) |to| {
        try adoptSectionPath(allocator, &file.new_path, to, "+++", header_number, diag);
    }

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
        // The next section begins here, and its own `rename from`/`rename to`
        // lines have to be read by the caller's loop rather than skipped as
        // decoration of this file.
        if (std.mem.startsWith(u8, line, "diff --git ")) break;
        if (isDecoration(line)) {
            _ = cursor.take();
            continue;
        }
        // The next file's header, which the caller's loop reads.
        if (std.mem.startsWith(u8, line, "--- ")) break;
        if (!std.mem.startsWith(u8, line, "@@")) {
            // A hunk line here means the hunk before this one read its counts as
            // complete while lines of its own were still coming, which is the
            // '@@' under-counting what follows it — a fault of the counts, not
            // a line that belongs to nothing, and it is named as one.
            if (hunks.items.len > 0 and isHunkLine(line)) {
                const previous = hunks.items[hunks.items.len - 1];
                diag.say(
                    "line {d} reads as a hunk line, but the hunk header on line {d} accounts for {d} old and {d} new lines, and the lines before this one already fill it. Count the lines under that '@@' again and raise the counts to match",
                    .{ cursor.number(), previous.patch_line, previous.header.old_count, previous.header.new_count },
                );
                return error.BadPatch;
            }
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
        if (body.items.len == 0) {
            diag.say("the hunk header on line {d} has no body", .{at});
            return error.BadPatch;
        }
        // Counts are redundant: the body supplies them. Never relax the text
        // comparison when repairing a model's arithmetic.
        var corrected = header;
        corrected.old_count = actual_old;
        corrected.new_count = actual_new;

        try hunks.append(allocator, .{
            .header = corrected,
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
/// Structural boundaries delimit a hunk; declared counts are only a hint for
/// unprefixed blank lines. Text is still matched exactly when applying it.
/// A file boundary needs a complete header triple, not just a removed line
/// whose text happens to start with '-- '.
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

        if (std.mem.startsWith(u8, line, "--- ") and
            cursor.lines.len - cursor.i >= 3 and
            std.mem.startsWith(u8, cursor.lines[cursor.i + 1], "+++ ") and
            std.mem.startsWith(u8, cursor.lines[cursor.i + 2], "@@")) break;
        // A git mail trailer is not a removed line.
        if (std.mem.eql(u8, line, "-- ") and
            old_seen >= header.old_count and new_seen >= header.new_count) break;

        if (line.len == 0) {
            if (old_seen >= header.old_count and new_seen >= header.new_count) break;
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

/// Whether a line reads as one of a hunk's: the space, '-' or '+' every line
/// under a '@@' starts with.
fn isHunkLine(line: []const u8) bool {
    return line.len > 0 and (line[0] == ' ' or line[0] == '-' or line[0] == '+');
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

/// The path out of a `---` or `+++` header, a `diff --git` name, or a `rename
/// from`/`rename to` line, or null for `/dev/null`.
///
/// A git patch writes `a/path` and `b/path`, and `-p1` is what strips those two
/// off. A name git had to escape is written the way git quotes one — as a C
/// string whose octal escapes are the name's own bytes, `"a/caf\303\251.txt"`
/// for `a/café.txt` — and is read back unquoted. Doing both here rather than
/// asking the model to is what lets the output of `git diff` be pasted in as it
/// comes.
fn headerPath(allocator: std.mem.Allocator, rest: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return null;

    // A quoted name ends where its quote closes, so nothing after it — a
    // timestamp, say — can be mistaken for part of the name.
    if (trimmed[0] == '"') {
        const name = try unquotePath(allocator, trimmed);
        defer allocator.free(name);
        if (std.mem.eql(u8, name, "/dev/null")) return null;
        return stripDiffPrefix(allocator, name);
    }

    // A timestamp may follow the path, separated by a tab.
    const path = if (std.mem.indexOfScalar(u8, trimmed, '\t')) |tab| trimmed[0..tab] else trimmed;
    const bare = std.mem.trim(u8, path, " ");
    if (bare.len == 0) return null;
    if (std.mem.eql(u8, bare, "/dev/null")) return null;
    return stripDiffPrefix(allocator, bare);
}

/// `a/path` and `b/path` are git's two sides of one name; what the file is
/// called is what is left of it.
fn stripDiffPrefix(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
    const stripped = if (std.mem.startsWith(u8, name, "a/") or std.mem.startsWith(u8, name, "b/")) name[2..] else name;
    if (stripped.len == 0) return null;
    return try allocator.dupe(u8, stripped);
}

/// The end of a quoted name: just past the quote that closes it, or null when
/// the patch has one that never closes.
fn quotedEnd(name: []const u8) ?usize {
    var i: usize = 1; // past the opening quote
    while (i < name.len) : (i += 1) {
        switch (name[i]) {
            // The byte after a backslash is escaped, quote or not.
            '\\' => i += 1,
            '"' => return i + 1,
            else => {},
        }
    }
    return null;
}

/// One of git's quoted names, unquoted: the escapes are gone and the octal ones
/// are the bytes they stand for. An unterminated quote is taken as the rest of
/// the line rather than refused, since what follows it on a header line is a
/// timestamp and not a name.
fn unquotePath(allocator: std.mem.Allocator, quoted: []const u8) error{OutOfMemory}![]u8 {
    const end = quotedEnd(quoted) orelse quoted.len;
    const stop = if (end > 1 and end <= quoted.len and quoted[end - 1] == '"') end - 1 else end;

    var name: std.ArrayList(u8) = .empty;
    errdefer name.deinit(allocator);
    var i: usize = 1;
    while (i < stop) {
        if (quoted[i] != '\\') {
            try name.append(allocator, quoted[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= stop) break;
        const escape = quoted[i];
        i += 1;
        switch (escape) {
            'a' => try name.append(allocator, 0x07),
            'b' => try name.append(allocator, 0x08),
            'f' => try name.append(allocator, 0x0c),
            'n' => try name.append(allocator, '\n'),
            'r' => try name.append(allocator, '\r'),
            't' => try name.append(allocator, '\t'),
            'v' => try name.append(allocator, 0x0b),
            '\\', '"' => try name.append(allocator, escape),
            '0'...'7' => {
                var value: u16 = escape - '0';
                var digits: usize = 1;
                while (digits < 3 and i < stop and quoted[i] >= '0' and quoted[i] <= '7') : (digits += 1) {
                    value = value * 8 + (quoted[i] - '0');
                    i += 1;
                }
                try name.append(allocator, @intCast(value & 0xff));
            },
            // Not an escape git writes; the byte speaks for itself.
            else => try name.append(allocator, escape),
        }
    }
    return name.toOwnedSlice(allocator);
}

/// Make one side of a file header agree with the name the git section gave it.
///
/// A header that names nothing — `/dev/null` — takes the section's name, since
/// the rename lines are the only place a rename's names are written in full. A
/// header that names another file is refused: between "rename to b" and
/// "+++ b/other" only one can be what the patch meant, and a guess here either
/// renames onto the wrong file or leaves the right one behind.
fn adoptSectionPath(
    allocator: std.mem.Allocator,
    slot: *?[]const u8,
    name: []const u8,
    marker: []const u8,
    header_number: usize,
    diag: *Diagnostic,
) (error{ OutOfMemory, BadPatch })!void {
    if (slot.*) |header| {
        if (!std.mem.eql(u8, header, name)) {
            diag.say("the '{s}' header on line {d} names '{s}', but the rename in the same section names '{s}': a rename has to name the same file in both places", .{ marker, header_number, header, name });
            return error.BadPatch;
        }
        return;
    }
    slot.* = try allocator.dupe(u8, name);
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

/// Use git as the patch producer, not a second implementation of unified diff.
/// Only file headers are retargeted to the fixture; hunk headers, bodies, EOF
/// markers and git metadata are kept verbatim. No cwd changes or user git
/// configuration are needed. Hosts without git skip only these producer tests.
fn gitFixturePatch(allocator: std.mem.Allocator, tmp: *testing.TmpDir, before: ?[]const u8, after: ?[]const u8, context: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(tmp, &buf);
    const old_path = try std.fmt.allocPrint(allocator, "{s}/old.txt", .{dir});
    defer allocator.free(old_path);
    const new_path = try std.fmt.allocPrint(allocator, "{s}/new.txt", .{dir});
    defer allocator.free(new_path);
    if (before) |data| try tmp.dir.writeFile(testing.io, .{ .sub_path = "old.txt", .data = data });
    if (after) |data| try tmp.dir.writeFile(testing.io, .{ .sub_path = "new.txt", .data = data });
    const result = std.process.run(allocator, testing.io, .{
        .argv = &.{ "git", "--no-pager", "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", context, "--", if (before != null) old_path else "/dev/null", if (after != null) new_path else "/dev/null" },
        .stdout_limit = .limited(max_patch_bytes),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    var patch: std.ArrayList(u8) = .empty;
    errdefer patch.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var in_hunk = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@ ")) in_hunk = true;
        if (!in_hunk and (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ "))) {
            const absent = if (line[0] == '-') before == null else after == null;
            const header = if (absent)
                try std.fmt.allocPrint(allocator, "{s}/dev/null", .{line[0..4]})
            else
                try std.fmt.allocPrint(allocator, "{s}{s}/target.txt", .{ line[0..4], dir });
            defer allocator.free(header);
            try patch.appendSlice(allocator, header);
        } else {
            try patch.appendSlice(allocator, line);
        }
        if (lines.peek() != null) try patch.append(allocator, '\n');
    }
    return patch.toOwnedSlice(allocator);
}

test "git generated patches round trip text changes with full and zero context" {
    const Case = struct {
        name: []const u8,
        before: ?[]const u8,
        after: ?[]const u8,
        added: usize,
        removed: usize,
    };
    const cases = [_]Case{
        .{ .name = "replace one line", .before = "old\n", .after = "new\n", .added = 1, .removed = 1 },
        .{ .name = "prepend", .before = "one\ntwo\n", .after = "zero\none\ntwo\n", .added = 1, .removed = 0 },
        .{ .name = "append", .before = "one\ntwo\n", .after = "one\ntwo\nthree\n", .added = 1, .removed = 0 },
        .{ .name = "insert in middle", .before = "one\nthree\n", .after = "one\ntwo\nthree\n", .added = 1, .removed = 0 },
        .{ .name = "remove first", .before = "one\ntwo\n", .after = "two\n", .added = 0, .removed = 1 },
        .{ .name = "remove last", .before = "one\ntwo\n", .after = "one\n", .added = 0, .removed = 1 },
        .{ .name = "remove middle", .before = "one\ntwo\nthree\n", .after = "one\nthree\n", .added = 0, .removed = 1 },
        .{ .name = "empty existing file", .before = "one\ntwo\n", .after = "", .added = 0, .removed = 2 },
        .{ .name = "populate empty file", .before = "", .after = "one\ntwo\n", .added = 2, .removed = 0 },
        .{ .name = "create text file", .before = null, .after = "one\ntwo\n", .added = 2, .removed = 0 },
        .{ .name = "delete file", .before = "one\ntwo\n", .after = null, .added = 0, .removed = 2 },
        .{ .name = "create unterminated file", .before = null, .after = "one", .added = 1, .removed = 0 },
        .{ .name = "delete unterminated file", .before = "one", .after = null, .added = 0, .removed = 1 },
        .{ .name = "both sides unterminated", .before = "one\ntwo", .after = "one\nTWO", .added = 1, .removed = 1 },
        .{ .name = "add final newline", .before = "one", .after = "one\n", .added = 1, .removed = 1 },
        .{ .name = "remove final newline", .before = "one\n", .after = "one", .added = 1, .removed = 1 },
        .{ .name = "append after unterminated line", .before = "one", .after = "one\ntwo\n", .added = 2, .removed = 1 },
        .{ .name = "CRLF", .before = "one\r\ntwo\r\n", .after = "one\r\nTWO\r\nthree\r\n", .added = 2, .removed = 1 },
        .{ .name = "UTF8", .before = "你好\n旧值🙂\n", .after = "你好\n新值🚀\n", .added = 1, .removed = 1 },
        .{ .name = "significant whitespace", .before = "\told  \n\nend\n", .after = "\tnew \t\n\nend\n", .added = 1, .removed = 1 },
        .{ .name = "header like payload", .before = "-- old\n++ old\n@@ old\n", .after = "-- new\n++ new\n@@ new\n", .added = 3, .removed = 3 },
        .{ .name = "blank lines", .before = "start\n\nend\n", .after = "start\n\n\nend\n", .added = 1, .removed = 0 },
        .{ .name = "separated growing and shrinking hunks", .before = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq\nr\ns\nt\n", .after = "a\nB\nextra\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq\ns\nt\n", .added = 2, .removed = 2 },
    };
    const allocator = testing.allocator;
    for (cases) |case| {
        for ([_][]const u8{ "--unified=3", "--unified=0" }) |context| {
            errdefer std.debug.print("git patch case: {s}, {s}\n", .{ case.name, context });
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            if (case.before) |data| try tmp.dir.writeFile(testing.io, .{ .sub_path = "target.txt", .data = data });
            const patch = try gitFixturePatch(allocator, &tmp, case.before, case.after, context);
            defer allocator.free(patch);
            const outcome = try applyOk(allocator, patch);
            defer outcome.deinit(allocator);
            const stats = outcome.applied;
            try testing.expectEqual(@as(usize, 1), stats.len);
            try testing.expectEqual(if (case.before == null) Action.created else if (case.after == null) Action.deleted else Action.modified, stats[0].action);
            try testing.expectEqual(case.added, stats[0].added);
            try testing.expectEqual(case.removed, stats[0].removed);
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const expected_path = try std.fmt.allocPrint(allocator, "{s}/target.txt", .{try fixturePath(&tmp, &buf)});
            defer allocator.free(expected_path);
            try testing.expectEqualStrings(expected_path, stats[0].path);
            if (case.after) |data| {
                try expectFileContent(allocator, &tmp, "target.txt", data);
            } else {
                try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "target.txt", allocator, .limited(1024)));
            }
        }
    }
}

test "multi file patches plan all changes before creating modifying or deleting" {
    const allocator = testing.allocator;
    // The last file is invalid on the first pass, then valid on the second.
    for ([_]bool{ false, true }) |valid| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "edit.txt", .data = "old\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "delete.txt", .data = "gone\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "last.txt", .data = if (valid) "expected\n" else "different\n" });
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = try fixturePath(&tmp, &buf);
        const patch = try patchFor(allocator, dir,
            \\--- /dev/null
            \\+++ {0s}/nested/new.txt
            \\@@ -0,0 +1 @@
            \\+created
            \\--- {0s}/edit.txt
            \\+++ {0s}/edit.txt
            \\@@ -1 +1 @@
            \\-old
            \\+new
            \\--- {0s}/delete.txt
            \\+++ /dev/null
            \\@@ -1 +0,0 @@
            \\-gone
            \\--- {0s}/last.txt
            \\+++ {0s}/last.txt
            \\@@ -1 +1 @@
            \\-expected
            \\+done
        );
        defer allocator.free(patch);
        if (valid) {
            const outcome = try applyOk(allocator, patch);
            defer outcome.deinit(allocator);
            try testing.expectEqual(@as(usize, 4), outcome.applied.len);
            for (outcome.applied, [_]Action{ .created, .modified, .deleted, .modified }) |stat, action| {
                try testing.expectEqual(action, stat.action);
            }
            try expectFileContent(allocator, &tmp, "nested/new.txt", "created\n");
            try expectFileContent(allocator, &tmp, "edit.txt", "new\n");
            try expectFileContent(allocator, &tmp, "last.txt", "done\n");
            try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "delete.txt", allocator, .limited(1024)));
        } else {
            const message = try applyRefused(allocator, patch);
            defer allocator.free(message);
            try testing.expect(std.mem.indexOf(u8, message, "last.txt") != null);
            try expectFileContent(allocator, &tmp, "edit.txt", "old\n");
            try expectFileContent(allocator, &tmp, "delete.txt", "gone\n");
            try expectFileContent(allocator, &tmp, "last.txt", "different\n");
            try testing.expectError(error.FileNotFound, tmp.dir.openDir(testing.io, "nested", .{}));
        }
    }
}

test "malformed and unsupported patches fail without touching files" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "original\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);
    const cases = .{
        "--- {0s}/note.txt\n",
        "--- {0s}/note.txt\nnot a plus header\n",
        "--- /dev/null\n+++ /dev/null\n@@ -0,0 +1 @@\n+oops\n",
        "--- {0s}/note.txt\n+++ {0s}/other.txt\n@@ -1 +1 @@\n-original\n+new\n",
        "--- /dev/null\n+++ {0s}/note.txt\n@@ -0,0 +1 @@\n+overwrite\n",
        "--- {0s}/note.txt\n+++ {0s}/note.txt\n@@ invalid @@\n-original\n+new\n",
        "--- {0s}/note.txt\n+++ {0s}/note.txt\n@@ -1 +1 @@\n",
        "--- {0s}/note.txt\n+++ {0s}/note.txt\n@@ -999999999999999999999999999999 +1 @@\n-original\n+new\n",
        "--- {0s}/note.txt\n+++ {0s}/note.txt\n@@ -1 +1 @@\n-original \n+new\n",
        "--- {0s}/note.txt\n+++ /dev/null\n@@ -0,0 +1 @@\n+not a deletion\n",
        "diff --git a/note.txt b/note.txt\nGIT binary patch\nliteral 3\nKcmZQzWC8#H2mk;8\n",
        "diff --git a/note.txt b/other.txt\nrename from note.txt\n",
    };
    inline for (cases) |body| {
        const patch = if (comptime std.mem.indexOf(u8, body, "{0s}") != null)
            try patchFor(allocator, dir, body)
        else
            try allocator.dupe(u8, body);
        defer allocator.free(patch);
        const message = try applyRefused(allocator, patch);
        defer allocator.free(message);
        try testing.expect(message.len > 0);
        try expectFileContent(allocator, &tmp, "note.txt", "original\n");
        try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "other.txt", allocator, .limited(1024)));
    }
}

test "git renames apply as renames, with and without hunks" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // Nothing but the name changes, so git writes no headers and no hunks: the
    // two rename lines are the whole section.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "one\ntwo\nthree\n" });
    {
        const patch = try patchFor(allocator, dir,
            \\diff --git a/{0s}/note.txt b/{0s}/moved.txt
            \\similarity index 100%
            \\rename from {0s}/note.txt
            \\rename to {0s}/moved.txt
        );
        defer allocator.free(patch);
        const outcome = try applyOk(allocator, patch);
        defer outcome.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), outcome.applied.len);
        const stat = outcome.applied[0];
        try testing.expectEqual(Action.renamed, stat.action);
        try testing.expectEqual(@as(usize, 0), stat.added);
        try testing.expectEqual(@as(usize, 0), stat.removed);
        const expected_to = try std.fmt.allocPrint(allocator, "{s}/moved.txt", .{dir});
        defer allocator.free(expected_to);
        const expected_from = try std.fmt.allocPrint(allocator, "{s}/note.txt", .{dir});
        defer allocator.free(expected_from);
        try testing.expectEqualStrings(expected_to, stat.path);
        try testing.expectEqualStrings(expected_from, stat.from.?);
        try expectFileContent(allocator, &tmp, "moved.txt", "one\ntwo\nthree\n");
        try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "note.txt", allocator, .limited(1024)));
    }

    // A rename that also changes the text: the hunks are matched against the old
    // file, and the result is written under the new name, in a directory that
    // the patch does not have to mention.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "one\ntwo\nthree\n" });
    {
        const patch = try patchFor(allocator, dir,
            \\diff --git a/{0s}/note.txt b/{0s}/nested/renamed.txt
            \\similarity index 66%
            \\rename from {0s}/note.txt
            \\rename to {0s}/nested/renamed.txt
            \\index 1111111..2222222 100644
            \\--- {0s}/note.txt
            \\+++ {0s}/nested/renamed.txt
            \\@@ -1,2 +1,2 @@
            \\ one
            \\-two
            \\+TWO
        );
        defer allocator.free(patch);
        const outcome = try applyOk(allocator, patch);
        defer outcome.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), outcome.applied.len);
        try testing.expectEqual(Action.renamed, outcome.applied[0].action);
        try testing.expectEqual(@as(usize, 1), outcome.applied[0].added);
        try testing.expectEqual(@as(usize, 1), outcome.applied[0].removed);
        try expectFileContent(allocator, &tmp, "nested/renamed.txt", "one\nTWO\nthree\n");
        try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "note.txt", allocator, .limited(1024)));
    }

    // A rename with no hunks into a directory that is not there yet: the move is
    // still a move, and the directory is made for it.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "kept as it is\n" });
    {
        const patch = try patchFor(allocator, dir,
            \\diff --git a/{0s}/note.txt b/{0s}/deep/inside/moved.txt
            \\similarity index 100%
            \\rename from {0s}/note.txt
            \\rename to {0s}/deep/inside/moved.txt
        );
        defer allocator.free(patch);
        const outcome = try applyOk(allocator, patch);
        defer outcome.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), outcome.applied.len);
        try testing.expectEqual(Action.renamed, outcome.applied[0].action);
        try expectFileContent(allocator, &tmp, "deep/inside/moved.txt", "kept as it is\n");
        try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "note.txt", allocator, .limited(1024)));
    }

    // Two renames with a patch between them: what a section said belongs to the
    // file that follows it, not to the next section that repeats it.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "a\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "b\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "keep.txt", .data = "old\n" });
    {
        const patch = try patchFor(allocator, dir,
            \\diff --git a/{0s}/a.txt b/{0s}/a2.txt
            \\similarity index 100%
            \\rename from {0s}/a.txt
            \\rename to {0s}/a2.txt
            \\diff --git a/{0s}/keep.txt b/{0s}/keep.txt
            \\--- {0s}/keep.txt
            \\+++ {0s}/keep.txt
            \\@@ -1 +1 @@
            \\-old
            \\+new
            \\diff --git a/{0s}/b.txt b/{0s}/b2.txt
            \\similarity index 100%
            \\rename from {0s}/b.txt
            \\rename to {0s}/b2.txt
        );
        defer allocator.free(patch);
        const outcome = try applyOk(allocator, patch);
        defer outcome.deinit(allocator);
        try testing.expectEqual(@as(usize, 3), outcome.applied.len);
        const actions = [_]Action{ .renamed, .modified, .renamed };
        for (outcome.applied, actions) |stat, action| try testing.expectEqual(action, stat.action);
        try expectFileContent(allocator, &tmp, "a2.txt", "a\n");
        try expectFileContent(allocator, &tmp, "b2.txt", "b\n");
        try expectFileContent(allocator, &tmp, "keep.txt", "new\n");
        for ([_][]const u8{ "a.txt", "b.txt" }) |gone| {
            try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, gone, allocator, .limited(1024)));
        }
    }
}

test "renames that cannot be carried out are refused without touching either name" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "original\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "taken.txt", .data = "kept\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);
    const cases = .{
        // The new name is already someone else's file.
        "diff --git a/{0s}/note.txt b/{0s}/taken.txt\nsimilarity index 100%\nrename from {0s}/note.txt\nrename to {0s}/taken.txt\n",
        // The old name is not there, so there is nothing to rename.
        "diff --git a/{0s}/missing.txt b/{0s}/elsewhere.txt\nsimilarity index 100%\nrename from {0s}/missing.txt\nrename to {0s}/elsewhere.txt\n",
        // Half a rename says nothing about where the file goes.
        "diff --git a/{0s}/note.txt b/{0s}/moved.txt\nrename from {0s}/note.txt\n",
        // The rename and the headers below it disagree about the new name.
        "diff --git a/{0s}/note.txt b/{0s}/moved.txt\nrename from {0s}/note.txt\nrename to {0s}/moved.txt\n--- {0s}/note.txt\n+++ {0s}/elsewhere.txt\n@@ -1 +1 @@\n-original\n+new\n",
        // A copy keeps the original, which a rename cannot express.
        "diff --git a/{0s}/note.txt b/{0s}/copied.txt\ncopy from {0s}/note.txt\ncopy to {0s}/copied.txt\n",
        "diff --git a/{0s}/note.txt b/{0s}/copied.txt\ncopy from {0s}/note.txt\ncopy to {0s}/copied.txt\n--- {0s}/note.txt\n+++ {0s}/copied.txt\n@@ -1 +1 @@\n-original\n+new\n",
    };
    inline for (cases) |body| {
        errdefer std.debug.print("rename refusal case did not refuse: {s}\n", .{body});
        const patch = try patchFor(allocator, dir, body);
        defer allocator.free(patch);
        const message = try applyRefused(allocator, patch);
        defer allocator.free(message);
        try testing.expect(message.len > 0);
        // Nothing is half-done: whatever the section could not carry out, both
        // names are as they were and no third one appeared.
        try expectFileContent(allocator, &tmp, "note.txt", "original\n");
        try expectFileContent(allocator, &tmp, "taken.txt", "kept\n");
        for ([_][]const u8{ "moved.txt", "elsewhere.txt", "copied.txt" }) |absent| {
            try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, absent, allocator, .limited(1024)));
        }
    }
}

test "a rename is planned with the rest of the patch, so a failure leaves both names alone" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "original\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.txt", .data = "different\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const patch = try patchFor(allocator, try fixturePath(&tmp, &buf),
        \\diff --git a/{0s}/note.txt b/{0s}/moved.txt
        \\similarity index 100%
        \\rename from {0s}/note.txt
        \\rename to {0s}/moved.txt
        \\--- {0s}/other.txt
        \\+++ {0s}/other.txt
        \\@@ -1 +1 @@
        \\-expected
        \\+done
    );
    defer allocator.free(patch);
    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "other.txt") != null);
    try expectFileContent(allocator, &tmp, "note.txt", "original\n");
    try expectFileContent(allocator, &tmp, "other.txt", "different\n");
    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "moved.txt", allocator, .limited(1024)));
}

test "patch byte and file count limits are refused before any write" {
    const allocator = testing.allocator;
    const oversized = try allocator.alloc(u8, max_patch_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    const message = try applyRefused(allocator, oversized);
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "at most") != null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);
    var patch: std.ArrayList(u8) = .empty;
    defer patch.deinit(allocator);
    for (0..max_files + 1) |i| {
        const part = try std.fmt.allocPrint(allocator, "--- /dev/null\n+++ {s}/file-{d}.txt\n@@ -0,0 +1 @@\n+new\n", .{ dir, i });
        defer allocator.free(part);
        try patch.appendSlice(allocator, part);
    }
    const count_message = try applyRefused(allocator, patch.items);
    defer allocator.free(count_message);
    try testing.expect(std.mem.indexOf(u8, count_message, "more than") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "file-0.txt", allocator, .limited(1024)));
}

test "oversized source files are refused without truncating the original" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try allocator.alloc(u8, max_file_bytes + 1);
    defer allocator.free(content);
    @memset(content, 'x');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "large.txt", .data = content });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const patch = try patchFor(allocator, try fixturePath(&tmp, &buf),
        \\--- {0s}/large.txt
        \\+++ {0s}/large.txt
        \\@@ -0,0 +1 @@
        \\+new
    );
    defer allocator.free(patch);
    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "larger than") != null);
    const unchanged = try tmp.dir.readFileAlloc(testing.io, "large.txt", allocator, .limited(max_file_bytes + 2));
    defer allocator.free(unchanged);
    try testing.expectEqualSlices(u8, content, unchanged);
}

test "overlapping hunks cannot reuse already consumed original text" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "one\ntwo\nthree\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const patch = try patchFor(allocator, try fixturePath(&tmp, &buf),
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -1,2 +1,2 @@
        \\-one
        \\+ONE
        \\ two
        \\@@ -2,2 +2,2 @@
        \\-two
        \\+TWO
        \\ three
    );
    defer allocator.free(patch);
    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);
    try testing.expect(message.len > 0);
    try expectFileContent(allocator, &tmp, "note.txt", "one\ntwo\nthree\n");
}

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

test "a relocated hunk anchors later repeated text in original coordinates" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Exercise offsets in both directions. An insertion in the first hunk
    // must not contribute to the offset: all hunks read the original file.
    for ([_]usize{ 1, 5 }) |start| {
        try tmp.dir.writeFile(testing.io, .{
            .sub_path = "note.txt",
            .data = "prefix\nanchor\ngap\nsame\nseparator\nsame\n",
        });
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = try fixturePath(&tmp, &buf);
        const patch = try std.fmt.allocPrint(
            allocator,
            "--- {s}/note.txt\n+++ {s}/note.txt\n@@ -{d},1 +{d},2 @@\n-anchor\n+ANCHOR\n+inserted\n@@ -{d},1 +{d},1 @@\n-same\n+CHANGED\n",
            .{ dir, dir, start, start, start + 2, start + 3 },
        );
        defer allocator.free(patch);
        const outcome = try applyOk(allocator, patch);
        defer outcome.deinit(allocator);
        try expectFileContent(allocator, &tmp, "note.txt", "prefix\nANCHOR\ninserted\ngap\nCHANGED\nseparator\nsame\n");
    }
}

test "stated positions are not clamped to the consumed boundary" {
    var diag: Diagnostic = .init(testing.allocator);
    defer diag.deinit();
    var body = [_]Line{.{ .kind = .remove, .text = "same" }};
    const hunk: Hunk = .{
        .header = .{ .old_start = 1, .old_count = 1, .new_count = 1 },
        .lines = &body,
        .patch_line = 3,
    };
    const lines = [_][]const u8{ "same", "same", "gap", "same" };
    try testing.expectEqual(@as(?usize, null), locate(&diag, "note.txt", &lines, 1, hunk, 0, null));
    try testing.expect(std.mem.indexOf(u8, diag.written(), "two places") != null);
}

test "anchor predictions cannot wrap or override an exact stated match" {
    try testing.expectEqual(@as(?usize, null), (HunkAnchor{ .stated = 5, .actual = 0 }).predict(2));
    try testing.expectEqual(@as(?usize, null), (HunkAnchor{ .stated = 0, .actual = 5 }).predict(std.math.maxInt(usize)));
    var diag: Diagnostic = .init(testing.allocator);
    defer diag.deinit();
    var body = [_]Line{.{ .kind = .remove, .text = "same" }};
    const hunk: Hunk = .{
        .header = .{ .old_start = 1, .old_count = 1, .new_count = 1 },
        .lines = &body,
        .patch_line = 3,
    };
    const lines = [_][]const u8{ "same", "gap", "same" };
    try testing.expectEqual(@as(?usize, 0), locate(&diag, "note.txt", &lines, 0, hunk, 0, .{ .stated = 0, .actual = 2 }));
    // A prediction that does not match must not select the nearest duplicate.
    try testing.expectEqual(@as(?usize, null), locate(&diag, "note.txt", &lines, 0, hunk, 9, .{ .stated = 8, .actual = 0 }));
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

test "incorrect hunk counts are recomputed without weakening text matching" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);
    for ([_][]const u8{ "3", "1" }) |count| {
        try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "first\nsecond\n" });
        const patch = try std.fmt.allocPrint(allocator, "--- {s}/note.txt\n+++ {s}/note.txt\n@@ -1,{s} +1,{s} @@\n first\n-second\n+SECOND\n", .{ dir, dir, count, count });
        defer allocator.free(patch);
        const outcome = try applyOk(allocator, patch);
        defer outcome.deinit(allocator);
        try expectFileContent(allocator, &tmp, "note.txt", "first\nSECOND\n");
        // Reapplying still fails: arithmetic repair must not repair text.
        const message = try applyRefused(allocator, patch);
        defer allocator.free(message);
        try expectFileContent(allocator, &tmp, "note.txt", "first\nSECOND\n");
    }
}

test "zero length ranges insert after the stated old line" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\nthree\n" });
    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -2,0 +3 @@
        \\+inserted
    );
    defer allocator.free(patch);
    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try expectFileContent(allocator, &tmp, "note.txt", "one\ntwo\ninserted\nthree\n");
}

test "context free insertions at both ends work and out of range is refused" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);
    for ([_]usize{ 0, 2, 99 }) |position| {
        try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "one\ntwo\n" });
        const patch = try std.fmt.allocPrint(allocator, "--- {s}/note.txt\n+++ {s}/note.txt\n@@ -{d},0 +1 @@\n+new\n", .{ dir, dir, position });
        defer allocator.free(patch);
        if (position == 99) {
            const message = try applyRefused(allocator, patch);
            defer allocator.free(message);
            try testing.expect(std.mem.indexOf(u8, message, "outside") != null);
            try expectFileContent(allocator, &tmp, "note.txt", "one\ntwo\n");
        } else {
            const outcome = try applyOk(allocator, patch);
            defer outcome.deinit(allocator);
            try expectFileContent(allocator, &tmp, "note.txt", if (position == 0) "new\none\ntwo\n" else "one\ntwo\nnew\n");
        }
    }
}

test "recounted hunks stop at file headers but not header like removed text" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "-- old\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.txt", .data = "old\n" });
    const patch = try std.fmt.allocPrint(allocator,
        \\--- {s}/one.txt
        \\+++ {s}/one.txt
        \\@@ -1,7 +1,7 @@
        \\--- old
        \\+++ new
        \\--- {s}/two.txt
        \\+++ {s}/two.txt
        \\@@ -1,8 +1,8 @@
        \\-old
        \\+new
    , .{ dir, dir, dir, dir });
    defer allocator.free(patch);
    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), outcome.applied.len);
    try expectFileContent(allocator, &tmp, "one.txt", "++ new\n");
    try expectFileContent(allocator, &tmp, "two.txt", "new\n");
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

    // The first hunk matches but the second does not. Planning must leave the
    // entire file untouched, even after a previous hunk has been rebuilt.
    const patch = try patchFor(allocator, dir,
        \\--- {0s}/note.txt
        \\+++ {0s}/note.txt
        \\@@ -1,1 +1,1 @@
        \\-one
        \\+ONE
        \\@@ -3,2 +3,2 @@
        \\-not-three
        \\+THREE
    );
    defer allocator.free(patch);

    const message = try applyRefused(allocator, patch);
    defer allocator.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "not-three") != null);
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

test "a quoted name is unquoted to its bytes, and a header's timestamp is not part of it" {
    const allocator = testing.allocator;

    // What git writes for a name it had to escape: the octal escapes are the
    // bytes of the UTF-8 name, and the a/ prefix is not part of it either.
    const utf8 = (try headerPath(allocator, "\"a/caf\\303\\251.txt\"")).?;
    defer allocator.free(utf8);
    try testing.expectEqualStrings("café.txt", utf8);

    // A quote or a backslash in the name is escaped rather than ended.
    const escaped = (try headerPath(allocator, "\"b/say \\\"hi\\\" \\\\ there.txt\"")).?;
    defer allocator.free(escaped);
    try testing.expectEqualStrings("say \"hi\" \\ there.txt", escaped);

    // The plain form shadows neither: a timestamp after a tab is not the name.
    const plain = (try headerPath(allocator, "a/plain.txt\t2024-01-01 00:00:00")).?;
    defer allocator.free(plain);
    try testing.expectEqualStrings("plain.txt", plain);

    try testing.expect(try headerPath(allocator, "/dev/null") == null);
    try testing.expect(try headerPath(allocator, "\"/dev/null\"") == null);
    // An unterminated quote is the rest of the line rather than a refusal.
    const open = (try headerPath(allocator, "\"a/never ends.txt")).?;
    defer allocator.free(open);
    try testing.expectEqualStrings("never ends.txt", open);
}

test "a patch for a quoted name applies to that name" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "café.txt", .data = "one\ntwo\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // The same patch `git diff` writes for this file: quoted on the `diff --git`
    // line as one C string per side, and quoted in both headers.
    const patch = try patchFor(allocator, dir,
        \\diff --git "a/{0s}/caf\303\251.txt" "b/{0s}/caf\303\251.txt"
        \\index 1111111..2222222 100644
        \\--- "a/{0s}/caf\303\251.txt"
        \\+++ "b/{0s}/caf\303\251.txt"
        \\@@ -1,2 +1,2 @@
        \\ one
        \\-two
        \\+TWO
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try testing.expectEqual(Action.modified, outcome.applied[0].action);
    try expectFileContent(allocator, &tmp, "café.txt", "one\nTWO\n");
}

test "a rename of a quoted name is read from git's rename lines" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "café.txt", .data = "kept as it is\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const patch = try patchFor(allocator, dir,
        \\diff --git "a/{0s}/caf\303\251.txt" "b/{0s}/th\303\251.txt"
        \\similarity index 100%
        \\rename from "{0s}/caf\303\251.txt"
        \\rename to "{0s}/th\303\251.txt"
    );
    defer allocator.free(patch);

    const outcome = try applyOk(allocator, patch);
    defer outcome.deinit(allocator);
    try testing.expectEqual(Action.renamed, outcome.applied[0].action);
    try expectFileContent(allocator, &tmp, "thé.txt", "kept as it is\n");
    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "café.txt", allocator, .limited(1024)));
}

/// The permission bits of a fixture file, as the file system has them.
fn fixtureMode(tmp: *testing.TmpDir, sub_path: []const u8) !std.posix.mode_t {
    const stat = try tmp.dir.statFile(testing.io, sub_path, .{});
    return stat.permissions.toMode() & 0o777;
}

test "the modes git states are applied, alone and alongside text" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "script.sh", .data = "echo one\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // A section that changes nothing but the permissions: no headers, no hunks.
    const alone = try patchFor(allocator, dir,
        \\diff --git a/{0s}/script.sh b/{0s}/script.sh
        \\old mode 100644
        \\new mode 100755
    );
    defer allocator.free(alone);
    const mode_change = try applyOk(allocator, alone);
    defer mode_change.deinit(allocator);
    try testing.expectEqual(Action.mode_changed, mode_change.applied[0].action);
    try testing.expectEqual(@as(?u32, 0o100755), mode_change.applied[0].mode);
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), try fixtureMode(&tmp, "script.sh"));
    try expectFileContent(allocator, &tmp, "script.sh", "echo one\n");

    // The same pair of lines above hunks: the text lands and so does the mode.
    const with_text = try patchFor(allocator, dir,
        \\diff --git a/{0s}/script.sh b/{0s}/script.sh
        \\old mode 100755
        \\new mode 100700
        \\index 1111111..2222222
        \\--- a/{0s}/script.sh
        \\+++ b/{0s}/script.sh
        \\@@ -1 +1 @@
        \\-echo one
        \\+echo two
    );
    defer allocator.free(with_text);
    const changed = try applyOk(allocator, with_text);
    defer changed.deinit(allocator);
    try testing.expectEqual(Action.modified, changed.applied[0].action);
    try testing.expectEqual(@as(?u32, 0o100700), changed.applied[0].mode);
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), try fixtureMode(&tmp, "script.sh"));
    try expectFileContent(allocator, &tmp, "script.sh", "echo two\n");

    // `new file mode` is what a file the patch creates is written with.
    const created = try patchFor(allocator, dir,
        \\diff --git a/{0s}/run.sh b/{0s}/run.sh
        \\new file mode 100755
        \\index 0000000..e69de29
        \\--- /dev/null
        \\+++ b/{0s}/run.sh
        \\@@ -0,0 +1 @@
        \\+#!/bin/sh
    );
    defer allocator.free(created);
    const made = try applyOk(allocator, created);
    defer made.deinit(allocator);
    try testing.expectEqual(Action.created, made.applied[0].action);
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), try fixtureMode(&tmp, "run.sh"));
    try expectFileContent(allocator, &tmp, "run.sh", "#!/bin/sh\n");
}

test "an empty file is created and deleted by git's mode lines alone" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    // Git writes no headers and no hunks for an empty file: there are no lines
    // to show, and the mode line is the whole of the change.
    const created = try patchFor(allocator, dir,
        \\diff --git a/{0s}/empty.txt b/{0s}/empty.txt
        \\new file mode 100644
        \\index 0000000..e69de29
    );
    defer allocator.free(created);
    const made = try applyOk(allocator, created);
    defer made.deinit(allocator);
    try testing.expectEqual(Action.created, made.applied[0].action);
    try testing.expectEqual(@as(?u32, 0o100644), made.applied[0].mode);
    try expectFileContent(allocator, &tmp, "empty.txt", "");

    const deleted = try patchFor(allocator, dir,
        \\diff --git a/{0s}/empty.txt b/{0s}/empty.txt
        \\deleted file mode 100644
        \\index e69de29..0000000
    );
    defer allocator.free(deleted);
    const gone = try applyOk(allocator, deleted);
    defer gone.deinit(allocator);
    try testing.expectEqual(Action.deleted, gone.applied[0].action);
    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, "empty.txt", allocator, .limited(1024)));
}

test "changes that are not text this tool can write are refused with the reason" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "note.txt", .data = "original\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try fixturePath(&tmp, &buf);

    const Case = struct { body: []const u8, reason: []const u8 };
    const cases = [_]Case{
        // A symlink's "contents" are a path, and writing them as text would
        // make it a file that happens to read like one.
        .{
            .body = "diff --git a/{0s}/link b/{0s}/link\nnew file mode 120000\nindex 0000000..1111111\n--- /dev/null\n+++ b/{0s}/link\n@@ -0,0 +1 @@\n+{0s}/note.txt\n",
            .reason = "symlink",
        },
        // A binary change has no lines to apply.
        .{
            .body = "diff --git a/{0s}/blob b/{0s}/blob\nindex 0000000..1111111 100644\nGIT binary patch\nliteral 4\nLcmZQzU|?VY0RR91\n",
            .reason = "binary",
        },
        .{
            .body = "diff --git a/{0s}/blob b/{0s}/blob\nindex 0000000..1111111 100644\nBinary files a/{0s}/blob and b/{0s}/blob differ\n",
            .reason = "binary",
        },
        // A mode change names a file the tree has to hold.
        .{
            .body = "diff --git a/{0s}/missing.txt b/{0s}/missing.txt\nold mode 100644\nnew mode 100755\n",
            .reason = "does not exist",
        },
    };
    inline for (cases) |case| {
        errdefer std.debug.print("the patch was not refused for its {s}: {s}\n", .{ case.reason, case.body });
        const patch = try patchFor(allocator, dir, case.body);
        defer allocator.free(patch);
        const message = try applyRefused(allocator, patch);
        defer allocator.free(message);
        try testing.expect(std.mem.indexOf(u8, message, case.reason) != null);
        try expectFileContent(allocator, &tmp, "note.txt", "original\n");
        for ([_][]const u8{ "link", "blob", "missing.txt" }) |absent| {
            try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(testing.io, absent, allocator, .limited(1024)));
        }
    }
}
