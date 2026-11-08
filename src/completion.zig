//! Candidate sources for the interactive prompt.
const std = @import("std");
const commands = @import("commands.zig");
const Item = @import("linenoise").PopupItem;
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

fn containsIgnoreCase(path: []const u8, query: []const u8) bool {
    if (query.len > path.len) return false;
    for (0..path.len - query.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(path[start..][0..query.len], query)) return true;
    }
    return false;
}

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
    try search(allocator, io, root, "", items, before, query, 0, &budget);
    std.mem.sort(Item, items.items, {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.label, b.label);
        }
    }.less);
}

fn search(allocator: Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, items: *std.ArrayList(Item), before: []const u8, query: []const u8, depth: usize, budget: *usize) Allocator.Error!void {
    var dir = root.openDir(io, if (path.len == 0) "." else path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (budget.* == 0 or items.items.len >= 100) return;
        budget.* -= 1;
        if (ignored(entry.name) or std.mem.indexOfAny(u8, entry.name, "\x00\r\n\t\x1b") != null or !std.unicode.utf8ValidateSlice(entry.name)) continue;
        const relative = if (path.len == 0) try allocator.dupe(u8, entry.name) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        defer allocator.free(relative);
        if (entry.kind == .directory) {
            if (depth < 12) try search(allocator, io, root, relative, items, before, query, depth + 1, budget);
        } else if (entry.kind == .file and containsIgnoreCase(relative, query)) {
            const label = try std.fmt.allocPrint(allocator, "@{s}", .{relative});
            defer allocator.free(label);
            // Quote paths with spaces so the reference remains one readable token.
            const value = if (std.mem.indexOfScalar(u8, relative, ' ') != null)
                try std.fmt.allocPrint(allocator, "{s}@\"{s}\"", .{ before, relative })
            else
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ before, label });
            defer allocator.free(value);
            try append(allocator, items, "", label, "File", true);
            const item = &items.items[items.items.len - 1];
            const owned_value = try allocator.dupe(u8, value);
            allocator.free(item.value.?);
            item.value = owned_value;
        }
    }
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
