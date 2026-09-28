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
            try self.hist.append(self.allocator, try self.allocator.dupe(u8, line));
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

        while (true) {
            const line = term.readLineAlloc(io, self.allocator, file, max_line_len) catch |err| switch (err) {
                // Skipping an over-long line instead of failing keeps one bad
                // entry from costing every entry stored after it.
                error.StreamTooLong => {
                    try skipLine(io, file);
                    continue;
                },
                else => |e| return e,
            } orelse break;

            if (line.len == 0) {
                self.allocator.free(line);
                continue;
            }
            errdefer self.allocator.free(line);
            try self.hist.append(self.allocator, line);
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

        for (self.hist.items) |line| {
            // Only what `load` can read back is written, so that an entry too
            // long to be stored cannot take the tail of the file with it.
            if (line.len > max_line_len) continue;
            try writer.writeAll(line);
            try writer.writeAll("\n");
        }

        try writer.flush();
    }

    /// Sets the maximum number of history items. If more history
    /// items than len exist, this will truncate the history to the
    /// len most recent items.
    pub fn setMaxLen(self: *Self, len: usize) !void {
        self.max_len = len;
        self.truncate();
    }
};

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

test "history" {
    var hist = History.empty(std.testing.allocator);
    defer hist.deinit();

    try hist.add("Hello");
    hist.pop();
}
