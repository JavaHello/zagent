const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const term = @import("term.zig");

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

    /// Loads the history from a file
    pub fn load(self: *Self, io: std.Io, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        while (try term.readLineAlloc(io, self.allocator, file, max_line_len)) |line| {
            errdefer self.allocator.free(line);
            try self.hist.append(self.allocator, line);
        }

        self.truncate();
    }

    /// Saves the history to a file
    pub fn save(self: *Self, io: std.Io, path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var write_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &write_buf);
        const writer = &file_writer.interface;

        for (self.hist.items) |line| {
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

test "history" {
    var hist = History.empty(std.testing.allocator);
    defer hist.deinit();

    try hist.add("Hello");
    hist.pop();
}
