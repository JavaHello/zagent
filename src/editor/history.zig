const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const File = std.Io.File;

const term = @import("term.zig");

const is_windows = builtin.os.tag == .windows;

/// The longest entry that is stored between runs. A line this long is not
/// something a prompt can usefully recall, and leaving entries unbounded would
/// let a single pasted blob grow the file that every new entry rewrites.
const max_line_len = 4096;

/// The longest line the file itself can hold: the bytes of an entry, each of
/// which may have been escaped as two.
const max_stored_len = 2 * max_line_len + 1;

/// The first line of a history this version writes. Every line after it is one
/// entry, with the line breaks and backslashes inside it escaped, so a prompt
/// that spans several lines is stored as one entry and read back whole. A file
/// without this line was written when such prompts were left out, and reads
/// back exactly as it always did.
const marker = "zagent-history 2";

pub const History = struct {
    allocator: Allocator,
    hist: ArrayList([]const u8) = .empty,
    max_len: usize = 100,
    current: usize = 0,

    const Self = @This();

    /// Creates a new empty history
    pub fn empty(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Deinitializes the history
    pub fn deinit(self: *Self) void {
        for (self.hist.items) |x| self.allocator.free(x);
        self.hist.deinit(self.allocator);
    }

    /// Ensures that at most self.max_len items are in the history
    fn truncate(self: *Self) void {
        if (self.hist.items.len > self.max_len) {
            const surplus = self.hist.items.len - self.max_len;
            for (self.hist.items[0..surplus]) |x| self.allocator.free(x);
            std.mem.copyForwards(
                []const u8,
                self.hist.items[0..self.max_len],
                self.hist.items[surplus..],
            );
            self.hist.shrinkAndFree(self.allocator, self.max_len);
        }
    }

    /// Adds this line to the history. Does not take ownership of the line, but
    /// instead copies it
    pub fn add(self: *Self, line: []const u8) !void {
        if (self.hist.items.len < 1 or !std.mem.eql(u8, line, self.hist.items[self.hist.items.len - 1])) {
            const owned = try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(owned);
            try self.hist.append(self.allocator, owned);
            self.truncate();
        }
    }

    /// Removes the last item (newest item) of the history
    pub fn pop(self: *Self) void {
        self.allocator.free(self.hist.pop().?);
    }

    /// Loads the history from a file. The path may be absolute; a file that is
    /// not there is reported as `error.FileNotFound`.
    pub fn load(self: *Self, io: std.Io, path: []const u8) !void {
        const file = try openFile(io, path);
        defer file.close(io);

        var escaped = false;
        var first = true;
        while (true) {
            const line = term.readLineAlloc(io, self.allocator, file, max_stored_len) catch |err| switch (err) {
                // Skipping an over-long line instead of failing keeps one bad
                // entry from costing every entry stored after it.
                error.StreamTooLong => {
                    try skipLine(io, file);
                    first = false;
                    continue;
                },
                else => |e| return e,
            } orelse break;
            defer self.allocator.free(line);

            // The first line says how the rest is to be read.
            if (first) {
                first = false;
                if (std.mem.eql(u8, line, marker)) {
                    escaped = true;
                    continue;
                }
            }

            if (line.len == 0) continue;
            const entry = if (escaped) try unescapeEntry(self.allocator, line) else try self.allocator.dupe(u8, line);
            errdefer self.allocator.free(entry);
            try self.hist.append(self.allocator, entry);
        }

        self.truncate();
    }

    /// Saves the history to a file. The path may be absolute.
    pub fn save(self: *Self, io: std.Io, path: []const u8) !void {
        const file = try createFile(io, path);
        defer file.close(io);

        // A history holds whatever was typed at the prompt — a pasted key, a
        // private path — so it is not left readable by other users on the
        // machine. A new file's mode is filtered by the umask, hence the
        // explicit chmod.
        if (!is_windows) file.setPermissions(io, File.Permissions.fromMode(0o600)) catch {};

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        const writer = &file_writer.interface;

        try writeMarker(writer);

        for (self.hist.items) |line| {
            // Only what `load` can read back is written, so that an entry too
            // long to be stored cannot take the tail of the file with it.
            if (line.len > max_line_len) continue;
            try writeEntry(writer, line);
            try writer.writeAll("\n");
        }

        try writer.flush();
    }
};

/// Says how the entries after it are stored, so that a file written before
/// prompts could span lines is still read the way it was written.
fn writeMarker(writer: *std.Io.Writer) !void {
    try writer.writeAll(marker);
    try writer.writeAll("\n");
}

/// Writes one entry as one line of the file: the bytes that would end the line,
/// and the backslash that would otherwise be read as one of them, are escaped.
fn writeEntry(writer: *std.Io.Writer, line: []const u8) !void {
    for (line) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        else => try writer.writeByte(byte),
    };
}

/// The entry `line` holds, with the escapes `writeEntry` put in it undone. A
/// backslash that starts no escape is left where it is, so an entry written by
/// hand into the file keeps the character it typed.
fn unescapeEntry(allocator: Allocator, line: []const u8) ![]u8 {
    var entry: ArrayList(u8) = .empty;
    errdefer entry.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '\\' or i + 1 == line.len) {
            try entry.append(allocator, line[i]);
            continue;
        }
        switch (line[i + 1]) {
            '\\' => try entry.append(allocator, '\\'),
            'n' => try entry.append(allocator, '\n'),
            'r' => try entry.append(allocator, '\r'),
            else => {
                try entry.append(allocator, '\\');
                continue;
            },
        }
        i += 1;
    }
    return entry.toOwnedSlice(allocator);
}

/// Reads the history from `path`, which the caller may spell either absolutely
/// or relative to the working directory.
fn openFile(io: std.Io, path: []const u8) !File {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{});
}

/// Creates (or truncates) the history at `path`.
fn createFile(io: std.Io, path: []const u8) !File {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.createFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().createFile(io, path, .{});
}

/// Consumes the rest of an over-long line, so that reading resumes at the
/// start of the next one.
fn skipLine(io: std.Io, file: File) !void {
    var byte_buf: [1]u8 = undefined;
    while (true) {
        if ((try term.read(io, file, &byte_buf)) < 1) return;
        if (byte_buf[0] == '\n') return;
    }
}

test "history add cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var history = History.empty(allocator);
            defer history.deinit();
            try history.add("first");
            try history.add("second");
            try std.testing.expectEqualStrings("first", history.hist.items[0]);
            try std.testing.expectEqualStrings("second", history.hist.items[1]);
        }
    }.run, .{});
}

test "history" {
    var hist = History.empty(std.testing.allocator);
    defer hist.deinit();

    try hist.add("Hello");
    hist.pop();
}

/// A path to a history file in a temporary directory, for the tests that read
/// and write one.
fn testPath(allocator: Allocator) !struct { tmp: std.testing.TmpDir, path: []u8 } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);
    return .{ .tmp = tmp, .path = try std.fs.path.join(allocator, &.{ directory, "history" }) };
}

test "an entry that spans lines comes back with them" {
    const allocator = std.testing.allocator;
    var file = try testPath(allocator);
    defer allocator.free(file.path);
    defer file.tmp.cleanup();

    var history = History.empty(allocator);
    defer history.deinit();
    try history.add("first");
    // A backslash of the entry's own, which the file must not read as the start
    // of an escape either.
    try history.add("two lines\nand a \\ backslash");

    try history.save(std.testing.io, file.path);

    var restored = History.empty(allocator);
    defer restored.deinit();
    try restored.load(std.testing.io, file.path);
    try std.testing.expectEqual(@as(usize, 2), restored.hist.items.len);
    try std.testing.expectEqualStrings("first", restored.hist.items[0]);
    try std.testing.expectEqualStrings("two lines\nand a \\ backslash", restored.hist.items[1]);
}

test "a history written before the marker still reads as it was written" {
    const allocator = std.testing.allocator;
    var file = try testPath(allocator);
    defer allocator.free(file.path);
    defer file.tmp.cleanup();

    // One prompt per line, unescaped: what an earlier version wrote.
    const contents = "a previous question\nprintf \\n stays two characters\n";
    const handle = try std.Io.Dir.createFileAbsolute(std.testing.io, file.path, .{});
    {
        defer handle.close(std.testing.io);
        try handle.writeStreamingAll(std.testing.io, contents);
    }

    var history = History.empty(allocator);
    defer history.deinit();
    try history.load(std.testing.io, file.path);
    try std.testing.expectEqual(@as(usize, 2), history.hist.items.len);
    try std.testing.expectEqualStrings("a previous question", history.hist.items[0]);
    try std.testing.expectEqualStrings("printf \\n stays two characters", history.hist.items[1]);
}
