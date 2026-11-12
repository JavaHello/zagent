//! Candidate sources for the interactive prompt.
const std = @import("std");
const commands = @import("commands.zig");
const fzy = @import("fzy.zig");
const Item = @import("../editor/linenoise.zig").PopupItem;
const Allocator = std.mem.Allocator;

pub const Trigger = struct { start: usize, kind: u8, query: []const u8 };

pub fn trigger(prefix: []const u8) ?Trigger {
    var start = prefix.len;
    while (start > 0 and !std.ascii.isWhitespace(prefix[start - 1])) start -= 1;
    if (start == prefix.len) return null;
    const kind = prefix[start];
    if (kind != '@' and kind != '$' and !(kind == '/' and start == 0)) return null;
    return .{ .start = start, .kind = kind, .query = prefix[start + 1 ..] };
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

pub fn candidates(allocator: Allocator, io: std.Io, prefix: []const u8) Allocator.Error![]Item {
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
        '@' => try files(allocator, io, &items, prefix[0..active.start], active.query),
        '$' => try append(allocator, &items, "", "$", "待定 / Coming soon", false),
        else => unreachable,
    }
    if (items.items.len == 0) try append(allocator, &items, "", if (active.kind == '/') "No matching commands" else "No matching files", "", false);
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

fn files(allocator: Allocator, io: std.Io, items: *std.ArrayList(Item), before: []const u8, query: []const u8) !void {
    const root = std.Io.Dir.cwd();
    // Bound traversal so a large workspace cannot stall the editor indefinitely.
    var budget: usize = 10000;
    var scratch: fzy.Scratch = .{};
    defer scratch.deinit(allocator);
    try scratch.initQuery(allocator, query);
    var ranking: Ranking = .{};
    defer ranking.deinit(allocator);
    try search(allocator, io, root, "", &ranking, &scratch, 0, &budget);
    for (ranking.entries.items) |entry| try appendFile(allocator, items, before, entry.path);
}

fn search(allocator: Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, ranking: *Ranking, scratch: *fzy.Scratch, depth: usize, budget: *usize) Allocator.Error!void {
    var dir = root.openDir(io, if (path.len == 0) "." else path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (budget.* == 0) return;
        budget.* -= 1;
        if (ignored(entry.name) or std.mem.indexOfAny(u8, entry.name, "\x00\r\n\t\x1b") != null or !std.unicode.utf8ValidateSlice(entry.name)) continue;
        const relative = if (path.len == 0) try allocator.dupe(u8, entry.name) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        defer allocator.free(relative);
        if (entry.kind == .directory) {
            if (depth < 12) try search(allocator, io, root, relative, ranking, scratch, depth + 1, budget);
        } else if (entry.kind == .file) {
            if (try scratch.score(allocator, relative)) |score| try ranking.add(allocator, relative, score);
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

test "triggers recognize commands and references at token boundaries" {
    try std.testing.expectEqual(@as(?Trigger, null), trigger("hello/"));
    try std.testing.expectEqual(@as(?Trigger, null), trigger("email@example.com"));
    try std.testing.expectEqual(@as(?Trigger, null), trigger("hello /"));
    try std.testing.expectEqualStrings("src", trigger("看看 @src").?.query);
    try std.testing.expectEqual(@as(u8, '$'), trigger("$skill").?.kind);
}

test "command filtering and reserved dollar entry" {
    const allocator = std.testing.allocator;
    const commands_list = try candidates(allocator, std.testing.io, "/cl");
    defer {
        for (commands_list) |item| item.deinit(allocator);
        allocator.free(commands_list);
    }
    try std.testing.expectEqual(@as(usize, 1), commands_list.len);
    try std.testing.expectEqualStrings("/clear", commands_list[0].value.?);
    const reserved = try candidates(allocator, std.testing.io, "$");
    defer {
        for (reserved) |item| item.deinit(allocator);
        allocator.free(reserved);
    }
    try std.testing.expect(reserved[0].value == null);
}
