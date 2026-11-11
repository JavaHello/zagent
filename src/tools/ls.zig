const std = @import("std");
const result_mod = @import("result.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const page_room_bytes = result_mod.page_room_bytes;
const lessString = util.lessString;

pub const Page = struct {
    limit: usize = 100,
};

pub fn listDirPage(io: std.Io, allocator: std.mem.Allocator, path: []const u8, page: Page) !ToolResult {
    if (page.limit == 0 or page.limit > 1000) return error.InvalidArguments;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer dir.close(io);

    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }
    // Keep only the lexicographically first limit formatted rows. Comparing
    // the rows (not just names) preserves ordering even for unusual filenames.
    try entries.ensureTotalCapacity(allocator, page.limit);
    var has_more = false;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const kind_char: u8 = switch (entry.kind) {
            .directory => 'd',
            .file => 'f',
            .sym_link => 'l',
            else => '?',
        };
        const line = try std.fmt.allocPrint(allocator, "{s}\t{c}\n", .{ entry.name, kind_char });
        var low: usize = 0;
        var high = entries.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (lessString({}, line, entries.items[mid])) high = mid else low = mid + 1;
        }
        if (entries.items.len == page.limit) {
            has_more = true;
            if (low == entries.items.len) {
                allocator.free(line);
                continue;
            }
            allocator.free(entries.pop().?);
        }
        // Capacity was reserved before iteration; no fallible operation can
        // strand the newly allocated row while shifting the bounded array.
        entries.insertAssumeCapacity(low, line);
    }
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var index: usize = 0;
    while (index < entries.items.len and index < page.limit) : (index += 1) {
        const entry = entries.items[index];
        if (aw.written().len + entry.len > page_room_bytes) break;
        try aw.writer.writeAll(entry);
    }
    const truncated = has_more or index < entries.items.len;
    if (truncated) try aw.writer.writeAll("[More entries than listed; narrow 'path' or raise 'limit' to see the rest.]\n");
    if (aw.written().len == 0) try aw.writer.writeAll("(no entries)");
    return .{ .content = try aw.toOwnedSlice(), .is_error = false, .truncated = truncated };
}

test "ls is sorted, capped by limit, and says when entries were left out" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "z", "a", "m" }) |name|
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const capped = try listDirPage(io, a, path, .{ .limit = 2 });
    defer capped.deinit(a);
    try std.testing.expect(capped.truncated);
    try std.testing.expect(std.mem.startsWith(u8, capped.content, "a\tf\nm\tf\n"));
    // There is no cursor to continue from: the call is narrowed instead.
    try std.testing.expect(std.mem.indexOf(u8, capped.content, "offset") == null);
    try std.testing.expect(std.mem.indexOf(u8, capped.content, "More entries") != null);
    const all = try listDirPage(io, a, path, .{ .limit = 1000 });
    defer all.deinit(a);
    try std.testing.expect(!all.truncated);
    try std.testing.expectEqualStrings("a\tf\nm\tf\nz\tf\n", all.content);
}
