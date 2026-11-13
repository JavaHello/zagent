const std = @import("std");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const args_mod = @import("args.zig");
const util = @import("util.zig");

const ToolResult = result_mod.ToolResult;
const lessString = util.lessString;

/// The most entries one call may ask for.
const max_limit: usize = 1000;

/// The ls tool: one directory, sorted, at most `limit` entries.
pub const spec: tool.Tool = .{
    .name = "ls",
    .description = "List directory entries in sorted order, at most 'limit' of them, each with its kind.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Directory path, defaults to the current directory","default":"."},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Most entries to list, default 100"}},"required":[]}
    ,
    .label = "ls…",
    .run = run,
};

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    if (args_mod.hasField(ctx.allocator, arguments, "offset")) return ctx.refuseOffset("ls");
    const args = parseArgs(ctx.allocator, arguments) catch
        return ctx.refuse("Error: ls expects an optional 'path' string (defaults to the current directory) and a 'limit' integer");
    defer args.deinit(ctx.allocator);
    return listDirPage(ctx.io, ctx.allocator, args.path, .{ .limit = args.limit });
}

/// The arguments of one ls call, owned.
const Arguments = struct {
    path: []const u8,
    limit: usize,

    fn deinit(self: Arguments, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

fn parseArgs(allocator: std.mem.Allocator, arguments: []const u8) !Arguments {
    const Parsed = struct {
        path: []const u8 = ".",
        limit: usize = 100,
    };
    // Unknown fields are not read, so a call carrying something this tool does
    // not take is answered rather than refused for it.
    const parsed = try std.json.parseFromSlice(Parsed, allocator, arguments, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.limit == 0 or parsed.value.limit > max_limit) return error.InvalidArguments;
    return .{ .path = try allocator.dupe(u8, parsed.value.path), .limit = parsed.value.limit };
}

pub const Page = struct {
    limit: usize = 100,
};

pub fn listDirPage(io: std.Io, allocator: std.mem.Allocator, path: []const u8, page: Page) !ToolResult {
    if (page.limit == 0 or page.limit > max_limit) return error.InvalidArguments;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return .{
            .output = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
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
        try aw.writer.writeAll(entry);
    }
    const capped = has_more or index < entries.items.len;
    if (capped) try aw.writer.writeAll("[More entries than listed; narrow 'path' or raise 'limit' to see the rest.]\n");
    if (aw.written().len == 0) try aw.writer.writeAll("(no entries)");
    return .{ .output = try aw.toOwnedSlice(), .is_error = false };
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
    try std.testing.expect(std.mem.startsWith(u8, capped.output, "a\tf\nm\tf\n"));
    // There is no cursor to continue from: the call is narrowed instead.
    try std.testing.expect(std.mem.indexOf(u8, capped.output, "offset") == null);
    try std.testing.expect(std.mem.indexOf(u8, capped.output, "More entries") != null);
    const all = try listDirPage(io, a, path, .{ .limit = 1000 });
    defer all.deinit(a);
    try std.testing.expectEqualStrings("a\tf\nm\tf\nz\tf\n", all.output);
}
