//! Candidate sources for the interactive prompt.
const std = @import("std");
const commands = @import("commands.zig");
const fzy = @import("fzy.zig");
const skills_mod = @import("../state/skills.zig");
const Skills = skills_mod.Skills;
const Item = @import("../editor/linenoise.zig").PopupItem;
const Allocator = std.mem.Allocator;

pub const Trigger = struct { start: usize, kind: u8, query: []const u8 };

pub fn trigger(prefix: []const u8) ?Trigger {
    var start = prefix.len;
    while (start > 0 and !std.ascii.isWhitespace(prefix[start - 1])) start -= 1;
    if (start == prefix.len) return null;
    // A path with a space is inserted as `@"a b.txt"`, so the quote holds the
    // reference together: it runs to the closing quote, and a closed one is a
    // finished reference that no longer wants a popup.
    if (prefix[start] == '@' and start + 1 < prefix.len and prefix[start + 1] == '"') {
        const rest = prefix[start + 2 ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
        return .{ .start = start, .kind = '@', .query = rest[0..end] };
    }
    const kind = prefix[start];
    if (kind == '@' or kind == '$' or (kind == '/' and start == 0))
        return .{ .start = start, .kind = kind, .query = prefix[start + 1 ..] };
    // While `@"sub dir` is still being typed the space splits the word, so the
    // open quote has to be found behind it; a quote that is not the last one,
    // or that does not follow a `@`, belongs to prose instead.
    const quote = std.mem.lastIndexOfScalar(u8, prefix, '"') orelse return null;
    if (quote == 0 or prefix[quote - 1] != '@') return null;
    return .{ .start = quote - 1, .kind = '@', .query = prefix[quote + 1 ..] };
}

fn append(allocator: Allocator, items: *std.ArrayList(Item), prefix: []const u8, label: []const u8, description: []const u8, selectable: bool) !void {
    const value = if (selectable) try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, label }) else null;
    errdefer if (value) |v| allocator.free(v);
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    const owned_description = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_description);
    try items.append(allocator, .{ .value = value, .label = owned_label, .description = owned_description });
}

/// What the prompt's completion needs from its host: the installed
/// [skills](../state/skills.zig) a `$` mention offers, and the file lists an `@`
/// mention keeps between keystrokes.
pub const Context = struct {
    skills: *const Skills,
    files: Files = .{},
};

/// The candidates for the line being typed. `context` is the host's
/// [Context](#Context), or null for a host that offers neither skills nor a
/// place to keep what a walk found.
pub fn candidates(context: ?*anyopaque, allocator: Allocator, io: std.Io, prefix: []const u8) Allocator.Error![]Item {
    const host: ?*Context = if (context) |raw| @ptrCast(@alignCast(raw)) else null;
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(allocator);
        items.deinit(allocator);
    }
    const active = trigger(prefix) orelse return items.toOwnedSlice(allocator);
    switch (active.kind) {
        '/' => for (commands.all) |command| {
            if (std.mem.startsWith(u8, command.name[1..], active.query))
                try append(allocator, &items, "", command.name, command.description, true);
        },
        '@' => try files(allocator, io, host, &items, prefix[0..active.start], active.query),
        '$' => try skills(allocator, &items, prefix[0..active.start], active.query, host),
        else => unreachable,
    }
    if (items.items.len == 0) {
        const none = switch (active.kind) {
            '/' => "No matching commands",
            '@' => "No matching files",
            '$' => "No matching skills",
            else => unreachable,
        };
        try append(allocator, &items, "", none, "", false);
    }
    return items.toOwnedSlice(allocator);
}

const Ranked = struct { path: []const u8, score: f64 };
const Ranking = struct {
    entries: std.ArrayList(Ranked) = .empty,

    fn deinit(self: *Ranking, allocator: Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.path);
        self.entries.deinit(allocator);
    }

    fn better(a: Ranked, b: Ranked) bool {
        return a.score > b.score or (a.score == b.score and std.mem.lessThan(u8, a.path, b.path));
    }

    fn add(self: *Ranking, allocator: Allocator, path: []const u8, score: f64) !void {
        // Two walks can reach the same file; the first sighting is already the
        // better ranked one, so the duplicate would only crowd out another.
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return;
        }
        const entry: Ranked = .{ .path = path, .score = score };
        var index: usize = 0;
        while (index < self.entries.items.len and !better(entry, self.entries.items[index])) index += 1;
        if (index >= 100) return;
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        try self.entries.insert(allocator, index, .{ .path = owned, .score = score });
        if (self.entries.items.len > 100) allocator.free(self.entries.pop().?.path);
    }
};

fn ignored(name: []const u8) bool {
    for ([_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", ".runs", ".cache" }) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

/// `$` mentions: the installed skills, by the name each is addressed with. A
/// skill is offered with the description the catalog shows, because that is
/// what tells one from another before it is loaded.
fn skills(allocator: Allocator, items: *std.ArrayList(Item), before: []const u8, query: []const u8, host: ?*Context) !void {
    const installed: *const Skills = if (host) |found| found.skills else return;
    for (installed.items) |skill| {
        if (!std.mem.startsWith(u8, skill.name, query)) continue;
        const label = try std.fmt.allocPrint(allocator, "${s}", .{skill.name});
        defer allocator.free(label);
        try append(allocator, items, before, label, skill.description, true);
    }
}

fn files(allocator: Allocator, io: std.Io, host: ?*Context, items: *std.ArrayList(Item), before: []const u8, query: []const u8) !void {
    // A host with no place to keep them answers from a walk of its own, which
    // is correct and no slower than it ever was.
    var local: Files = .{};
    defer if (host == null) local.deinit(allocator);
    const cache = if (host) |found| &found.files else &local;
    return filesIn(allocator, io, std.Io.Dir.cwd(), cache, items, before, query);
}

fn filesIn(allocator: Allocator, io: std.Io, root: std.Io.Dir, cache: *Files, items: *std.ArrayList(Item), before: []const u8, query: []const u8) !void {
    // The files a walk found last time stand in for the walk itself, as long as
    // they were found in this same workspace.
    cache.use(allocator, root);
    var scratch: fzy.Scratch = .{};
    defer scratch.deinit(allocator);
    try scratch.initQuery(allocator, query);
    var ranking: Ranking = .{};
    defer ranking.deinit(allocator);
    // A query that names a directory searches that directory first, so its
    // whole subtree is reachable however large the workspace is; the budgeted
    // walk from the top of the workspace then only adds what else matches.
    if (try directory(allocator, io, root, query)) |named| {
        defer allocator.free(named);
        var named_budget: usize = 12000;
        try search(allocator, io, root, cache, named, &ranking, &scratch, &named_budget);
        var rest: usize = 5000;
        if (ranking.entries.items.len < 100) try search(allocator, io, root, cache, "", &ranking, &scratch, &rest);
    } else {
        var budget: usize = 10000;
        try search(allocator, io, root, cache, "", &ranking, &scratch, &budget);
    }
    for (ranking.entries.items) |entry| try appendFile(allocator, items, before, entry.path);
}

/// The directory a query names, or null when it names none.
///
/// `docs`, `docs/` and `site/docs/gu` all name a directory to search, and the
/// longest prefix that exists wins, so a half-typed component still narrows the
/// walk. Anything absolute or reaching outside the workspace names nothing.
fn directory(allocator: Allocator, io: std.Io, root: std.Io.Dir, query: []const u8) Allocator.Error!?[]u8 {
    if (query.len == 0 or query[0] == '/' or std.mem.indexOf(u8, query, "..") != null) return null;
    var end = std.mem.lastIndexOfScalar(u8, query, '/') orelse query.len;
    while (true) {
        const candidate = std.mem.trimEnd(u8, query[0..end], "/");
        if (candidate.len == 0) return null;
        if (root.openDir(io, candidate, .{})) |dir| {
            dir.close(io);
            return try allocator.dupe(u8, candidate);
        } else |_| {}
        end = std.mem.lastIndexOfScalar(u8, query[0..end], '/') orelse return null;
    }
}

/// The files one workspace holds, kept between keystrokes.
///
/// Walking the tree for every character typed is what makes a popup stop
/// keeping up in a large workspace: reading the directories costs far more than
/// scoring the names it offers, and it is the same tree each time. So a
/// directory is read once and remembered with the time it was read at. That
/// time is the directory's own: it moves when an entry in it is added, removed
/// or renamed — exactly when its entries have to be read again — and not when a
/// file below it is edited, which is not a change to what the popup offers.
pub const Files = struct {
    /// The workspace these lists were read in; another one is never answered
    /// with them.
    root: ?std.Io.Dir = null,
    /// One entry per directory, by its path relative to the workspace.
    dirs: std.StringHashMapUnmanaged(Listing) = .empty,
    /// Directories read, so that a test can tell a list that was reused from one
    /// that was read again and only looks the same.
    reads: usize = 0,

    const Listing = struct {
        /// The directory's own time when its entries were read.
        modified: std.Io.Timestamp,
        /// The files it holds, by their path relative to the workspace.
        files: std.ArrayList([]u8) = .empty,
        /// The directories it holds, the same way.
        subdirs: std.ArrayList([]u8) = .empty,
    };

    /// What a directory holds, as the walk reads it.
    const Entries = struct {
        files: []const []const u8 = &.{},
        subdirs: []const []const u8 = &.{},
    };

    pub fn deinit(self: *Files, allocator: Allocator) void {
        self.clear(allocator);
        self.dirs.deinit(allocator);
        self.root = null;
    }

    /// Forget every list, keeping the room for the next ones.
    fn clear(self: *Files, allocator: Allocator) void {
        var it = self.dirs.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeListing(allocator, entry.value_ptr);
        }
        self.dirs.clearRetainingCapacity();
        self.reads = 0;
    }

    /// Read `root`'s entries rather than the ones held for another workspace.
    fn use(self: *Files, allocator: Allocator, root: std.Io.Dir) void {
        if (self.root) |known| if (known.handle == root.handle) return;
        self.clear(allocator);
        self.root = root;
    }

    /// What `path` holds: the entries read last time when the directory has not
    /// changed since, and a fresh reading of it when it has.
    fn entries(self: *Files, allocator: Allocator, io: std.Io, root: std.Io.Dir, path: []const u8) Allocator.Error!Entries {
        // A directory that cannot be statted is one nothing can be said about:
        // it offers no candidate rather than costing the popup its answers.
        const modified = modifiedTime(io, root, path) catch return .{};
        const known = self.dirs.getPtr(path);
        if (known) |listing| {
            if (listing.modified.nanoseconds == modified.nanoseconds)
                return .{ .files = listing.files.items, .subdirs = listing.subdirs.items };
        }
        // A fresh reading is kept apart until it is complete, so one that fails
        // leaves what was held before rather than half a directory.
        var fresh: Listing = .{ .modified = modified };
        errdefer freeListing(allocator, &fresh);
        self.reads += 1;
        try readListing(allocator, io, root, path, &fresh);
        if (known) |listing| {
            var stale = listing.*;
            listing.* = fresh;
            freeListing(allocator, &stale);
            return .{ .files = listing.files.items, .subdirs = listing.subdirs.items };
        }
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        try self.dirs.put(allocator, owned, fresh);
        const listing = self.dirs.getPtr(path).?;
        return .{ .files = listing.files.items, .subdirs = listing.subdirs.items };
    }
};

fn freeListing(allocator: Allocator, listing: *Files.Listing) void {
    for (listing.files.items) |path| allocator.free(path);
    listing.files.deinit(allocator);
    for (listing.subdirs.items) |path| allocator.free(path);
    listing.subdirs.deinit(allocator);
    listing.* = .{ .modified = .zero };
}

/// When the directory `path` last changed. Its own time is what says whether
/// the entries read from it are still the ones it holds.
fn modifiedTime(io: std.Io, root: std.Io.Dir, path: []const u8) !std.Io.Timestamp {
    const stat = try root.statFile(io, if (path.len == 0) "." else path, .{});
    return stat.mtime;
}

/// Read the entries `path` holds now, by their path relative to the workspace.
///
/// A directory that cannot be opened holds nothing to offer, which is what the
/// walk has always done with one: the budget is a guard against a tree that
/// never ends, not a reason to refuse what is readable.
fn readListing(allocator: Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, listing: *Files.Listing) Allocator.Error!void {
    var dir = root.openDir(io, if (path.len == 0) "." else path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch return) |entry| {
        if (ignored(entry.name) or std.mem.indexOfAny(u8, entry.name, "\x00\r\n\t\x1b") != null or !std.unicode.utf8ValidateSlice(entry.name)) continue;
        const relative = if (path.len == 0) try allocator.dupe(u8, entry.name) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        errdefer allocator.free(relative);
        switch (entry.kind) {
            .directory => try listing.subdirs.append(allocator, relative),
            .file => try listing.files.append(allocator, relative),
            else => allocator.free(relative),
        }
    }
}

const Pending = struct { path: []u8, depth: usize };

/// Walk the tree below `base` breadth first, reading a directory again only when
/// it has changed since it was last read.
///
/// The budget is spent level by level, so every shallow directory is looked at
/// before the deep subtrees of its neighbours are: a depth-first walk finishes
/// the first large subtree it meets and can exhaust its budget without ever
/// reaching a sibling such as `docs/`, which then offers no candidate at all.
fn search(
    allocator: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    cache: *Files,
    base: []const u8,
    ranking: *Ranking,
    scratch: *fzy.Scratch,
    budget: *usize,
) Allocator.Error!void {
    var queue: std.ArrayList(Pending) = .empty;
    defer {
        for (queue.items) |pending| allocator.free(pending.path);
        queue.deinit(allocator);
    }
    try queue.append(allocator, .{ .path = try allocator.dupe(u8, base), .depth = 0 });
    var head: usize = 0;
    while (head < queue.items.len and budget.* > 0) : (head += 1) {
        const pending = queue.items[head];
        const entries = try cache.entries(allocator, io, root, pending.path);
        for (entries.files) |path| {
            if (budget.* == 0) return;
            budget.* -= 1;
            if (try scratch.score(allocator, path)) |score| try ranking.add(allocator, path, score);
        }
        if (pending.depth >= 12) continue;
        for (entries.subdirs) |path| {
            if (budget.* == 0) return;
            budget.* -= 1;
            // The queue takes the path over, so it outlives this reading.
            const copy = try allocator.dupe(u8, path);
            errdefer allocator.free(copy);
            try queue.append(allocator, .{ .path = copy, .depth = pending.depth + 1 });
        }
    }
}

fn appendFile(allocator: Allocator, items: *std.ArrayList(Item), before: []const u8, relative: []const u8) !void {
    const label = try std.fmt.allocPrint(allocator, "@{s}", .{relative});
    errdefer allocator.free(label);
    // Quote paths with spaces so the reference remains one readable token.
    const value = if (std.mem.indexOfScalar(u8, relative, ' ') != null)
        try std.fmt.allocPrint(allocator, "{s}@\"{s}\"", .{ before, relative })
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ before, label });
    errdefer allocator.free(value);
    const description = try allocator.dupe(u8, "File");
    errdefer allocator.free(description);
    try items.append(allocator, .{ .label = label, .value = value, .description = description });
}

test "ranking keeps best hundred, late matches, alphabetical ties and handles OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: Allocator) !void {
            var ranking: Ranking = .{};
            defer ranking.deinit(a);
            var buffer: [32]u8 = undefined;
            for (0..150) |i| {
                const path = try std.fmt.bufPrint(&buffer, "file-{d:0>3}", .{149 - i});
                try ranking.add(a, path, 0);
            }
            try std.testing.expectEqual(@as(usize, 100), ranking.entries.items.len);
            try std.testing.expectEqualStrings("file-000", ranking.entries.items[0].path);
            try std.testing.expectEqualStrings("file-099", ranking.entries.items[99].path);
            try ranking.add(a, "late-best", 2);
            try std.testing.expectEqualStrings("late-best", ranking.entries.items[0].path);
            try std.testing.expectEqualStrings("file-098", ranking.entries.items[99].path);
        }
    }.run, .{});
}

test "file candidates transfer ownership and clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var items: std.ArrayList(Item) = .empty;
            defer {
                for (items.items) |item| item.deinit(allocator);
                items.deinit(allocator);
            }
            try appendFile(allocator, &items, "read ", "src/a.zig");
            try appendFile(allocator, &items, "read ", "a b.txt");
            try std.testing.expectEqualStrings("@src/a.zig", items.items[0].label);
            try std.testing.expectEqualStrings("read @src/a.zig", items.items[0].value.?);
            try std.testing.expectEqualStrings("read @\"a b.txt\"", items.items[1].value.?);
            try std.testing.expectEqualStrings("File", items.items[1].description);
        }
    }.run, .{});
}

test "search covers a shallow directory before a deep subtree spends the budget" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A subtree far bigger than the budget, next to the directory a reader is
    // likelier to name: a depth-first walk would never leave the subtree.
    try tmp.dir.createDirPath(io, "aaa/nested");
    for (0..40) |index| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "aaa/nested/f{d:0>2}", .{index});
        const file = try tmp.dir.createFile(io, path, .{});
        file.close(io);
    }
    try tmp.dir.createDirPath(io, "docs");
    const guide = try tmp.dir.createFile(io, "docs/guide.md", .{});
    guide.close(io);

    var scratch: fzy.Scratch = .{};
    defer scratch.deinit(allocator);
    try scratch.initQuery(allocator, "guide");
    var ranking: Ranking = .{};
    defer ranking.deinit(allocator);
    var cache: Files = .{};
    defer cache.deinit(allocator);
    var budget: usize = 6;
    try search(allocator, io, tmp.dir, &cache, "", &ranking, &scratch, &budget);
    try std.testing.expectEqual(@as(usize, 1), ranking.entries.items.len);
    try std.testing.expectEqualStrings("docs/guide.md", ranking.entries.items[0].path);
}

test "a walk that runs out of memory at any point cleans up after itself" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/guides");
    try tmp.dir.createDirPath(io, "src");
    for ([_][]const u8{ "docs/index.md", "docs/guides/setup.md", "src/main.zig" }) |path| {
        const file = try tmp.dir.createFile(io, path, .{});
        file.close(io);
    }
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: Allocator, root: std.Io.Dir) !void {
            var cache: Files = .{};
            defer cache.deinit(allocator);
            var scratch: fzy.Scratch = .{};
            defer scratch.deinit(allocator);
            try scratch.initQuery(allocator, "set");
            var ranking: Ranking = .{};
            defer ranking.deinit(allocator);
            var budget: usize = 100;
            try search(allocator, std.testing.io, root, &cache, "", &ranking, &scratch, &budget);
            try std.testing.expectEqual(@as(usize, 1), ranking.entries.items.len);
        }
    }.run, .{tmp.dir});
}

test "a query names the directory whose subtree it searches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.createDirPath(io, "site/docs");
    const file = try tmp.dir.createFile(io, "docs/guide.md", .{});
    file.close(io);

    const cases = [_]struct { query: []const u8, expected: ?[]const u8 }{
        .{ .query = "docs", .expected = "docs" },
        .{ .query = "docs/", .expected = "docs" },
        .{ .query = "docs/gu", .expected = "docs" },
        .{ .query = "site/docs/re", .expected = "site/docs" },
        // A component that is only being typed narrows to the directory above
        // it, and a path that names no directory keeps the walk at the top.
        .{ .query = "site/do", .expected = "site" },
        .{ .query = "nosuch/x", .expected = null },
        .{ .query = "", .expected = null },
        // Absolute paths and ones that climb out of the workspace name nothing.
        .{ .query = "/etc", .expected = null },
        .{ .query = "../docs", .expected = null },
    };
    for (cases) |case| {
        const found = try directory(allocator, io, tmp.dir, case.query);
        defer if (found) |path| allocator.free(path);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, found orelse return error.TestUnexpectedResult);
        } else try std.testing.expect(found == null);
    }
}

test "a reference names the files under the directory it points at" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/guides");
    try tmp.dir.createDirPath(io, "src");
    for ([_][]const u8{ "docs/index.md", "docs/guides/setup.md", "src/main.zig", "README.md" }) |path| {
        const file = try tmp.dir.createFile(io, path, .{});
        file.close(io);
    }

    const cases = [_]struct { query: []const u8, expected: []const []const u8 }{
        .{ .query = "docs", .expected = &.{ "@docs/index.md", "@docs/guides/setup.md" } },
        .{ .query = "docs/", .expected = &.{ "@docs/index.md", "@docs/guides/setup.md" } },
        .{ .query = "docs/gui", .expected = &.{"@docs/guides/setup.md"} },
    };
    var cache: Files = .{};
    defer cache.deinit(allocator);
    for (cases) |case| {
        var items: std.ArrayList(Item) = .empty;
        defer {
            for (items.items) |item| item.deinit(allocator);
            items.deinit(allocator);
        }
        try filesIn(allocator, io, tmp.dir, &cache, &items, "read ", case.query);
        for (case.expected) |label| {
            var found = false;
            for (items.items) |item| {
                if (std.mem.eql(u8, item.label, label)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

test "a workspace is walked once and read again only where it changed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/guides");
    try tmp.dir.createDirPath(io, "src");
    for ([_][]const u8{ "docs/index.md", "src/main.zig" }) |path| {
        const file = try tmp.dir.createFile(io, path, .{});
        file.close(io);
    }

    var cache: Files = .{};
    defer cache.deinit(allocator);
    var scratch: fzy.Scratch = .{};
    defer scratch.deinit(allocator);
    try scratch.initQuery(allocator, "");

    var ranking: Ranking = .{};
    defer ranking.deinit(allocator);
    var budget: usize = 100;
    try search(allocator, io, tmp.dir, &cache, "", &ranking, &scratch, &budget);
    try std.testing.expectEqual(@as(usize, 2), ranking.entries.items.len);
    // Every directory the walk reached was read: the workspace's own, `docs`
    // and `src`, and nothing twice.
    const read_once = cache.reads;
    try std.testing.expectEqual(@as(usize, 4), read_once);

    // Nothing changed, so nothing is read again: the same names come from the
    // lists the first walk kept.
    budget = 100;
    try search(allocator, io, tmp.dir, &cache, "", &ranking, &scratch, &budget);
    try std.testing.expectEqual(read_once, cache.reads);

    // A file added below a directory is a change to that directory, whose
    // entries are read again; the ones beside it are not read at all.
    const added = try tmp.dir.createFile(io, "docs/guides/setup.md", .{});
    added.close(io);
    budget = 100;
    try search(allocator, io, tmp.dir, &cache, "", &ranking, &scratch, &budget);
    try std.testing.expectEqual(read_once + 1, cache.reads);
    var found = false;
    for (ranking.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, "docs/guides/setup.md")) found = true;
    }
    try std.testing.expect(found);
}

test "triggers recognize commands and references at token boundaries" {
    try std.testing.expectEqual(@as(?Trigger, null), trigger("hello/"));
    try std.testing.expectEqual(@as(?Trigger, null), trigger("email@example.com"));
    try std.testing.expectEqual(@as(?Trigger, null), trigger("hello /"));
    try std.testing.expectEqualStrings("src", trigger("看看 @src").?.query);
    try std.testing.expectEqual(@as(u8, '$'), trigger("$skill").?.kind);
}

test "triggers follow a quoted reference over the spaces in a path" {
    const quoted = trigger("看看 @\"sub dir/de") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 7), quoted.start);
    try std.testing.expectEqualStrings("sub dir/de", quoted.query);
    try std.testing.expectEqualStrings("a b", trigger("@\"a b").?.query);
    // A closed reference is finished, so it keeps the popup shut.
    try std.testing.expectEqual(@as(?Trigger, null), trigger("@\"a b.txt\""));
    try std.testing.expectEqual(@as(?Trigger, null), trigger("看了 @\"a b.txt\" 再改"));
    // A quote that starts no reference, or that closed an earlier one, is prose.
    try std.testing.expectEqual(@as(?Trigger, null), trigger("say \"hi there"));
    try std.testing.expectEqual(@as(?Trigger, null), trigger("看了 \"a b\" 和"));
}

test "command filtering and a dollar mention without skills" {
    const allocator = std.testing.allocator;
    const commands_list = try candidates(null, allocator, std.testing.io, "/cl");
    defer {
        for (commands_list) |item| item.deinit(allocator);
        allocator.free(commands_list);
    }
    try std.testing.expectEqual(@as(usize, 1), commands_list.len);
    try std.testing.expectEqualStrings("/clear", commands_list[0].value.?);
    const none = try candidates(null, allocator, std.testing.io, "$");
    defer {
        for (none) |item| item.deinit(allocator);
        allocator.free(none);
    }
    try std.testing.expectEqualStrings("No matching skills", none[0].label);
    try std.testing.expect(none[0].value == null);
}

test "dollar candidates list installed skills and complete to a mention" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "skills/demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "skills/demo/SKILL.md", .data = "---\nname: demo\ndescription: Demo skill.\n---\nBody\n" });
    try tmp.dir.createDirPath(io, "skills/other");
    try tmp.dir.writeFile(io, .{ .sub_path = "skills/other/SKILL.md", .data = "---\nname: other\ndescription: Another skill.\n---\nBody\n" });
    const root = try tmp.dir.realPathFileAlloc(io, "skills", allocator);
    defer allocator.free(root);
    var installed = try skills_mod.initWithRoots(allocator, io, &.{root});
    defer installed.deinit();

    var host: Context = .{ .skills = &installed };
    defer host.files.deinit(allocator);
    const items = try candidates(&host, allocator, io, "run $de");
    defer {
        for (items) |item| item.deinit(allocator);
        allocator.free(items);
    }
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("$demo", items[0].label);
    try std.testing.expectEqualStrings("run $demo", items[0].value.?);
    try std.testing.expectEqualStrings("Demo skill.", items[0].description);

    const all = try candidates(&host, allocator, io, "$");
    defer {
        for (all) |item| item.deinit(allocator);
        allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
}
