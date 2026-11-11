//! The terminal has one owner. Workers only enqueue output and request answers.
const std = @import("std");
const sgr = @import("style.zig");
const Agent = @import("agent.zig").Agent;
const Screen = @import("screen.zig").Screen;
const menu = @import("menu.zig");

pub const Runtime = struct {
    agent: *Agent,
    screen: *Screen,
    future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    waiting: std.atomic.Value(bool) = .init(false),
    answered: std.atomic.Value(bool) = .init(false),
    answer: ?[]u8 = null,
    queue: std.ArrayList([]u8) = .empty,

    pub fn busy(self: *Runtime) bool {
        return self.future != null;
    }

    pub fn deinit(self: *Runtime) void {
        self.agent.interrupted.store(true, .release);
        if (self.future) |*f| _ = f.cancel(self.agent.io);
        _ = self.screen.drain() catch false;
        self.screen.replay() catch {};
        for (self.queue.items) |line| self.agent.allocator.free(line);
        self.queue.deinit(self.agent.allocator);
        if (self.answer) |answer| self.agent.allocator.free(answer);
    }

    pub fn interrupt(self: *Runtime) !void {
        if (!self.busy()) return;
        self.agent.interrupted.store(true, .release);
        if (self.future) |*f| f.cancel(self.agent.io);
        self.future = null;
        self.done.store(false, .release);
        self.waiting.store(false, .release);
        self.answered.store(false, .release);
        if (self.answer) |answer| self.agent.allocator.free(answer);
        self.answer = null;
        // Do not silently start another queued task after an explicit stop.
        for (self.queue.items) |line| self.agent.allocator.free(line);
        self.queue.clearRetainingCapacity();
        // Neither should a line typed while the task ran outlive the stop.
        self.agent.clearSteering();
        try self.agent.finishInterruption();
        _ = try self.screen.drain();
        try self.screen.writeLog(sgr.YELLOW ++ "Task interrupted (Esc). Input typed while it ran was discarded." ++ sgr.RESET ++ "\n");
        _ = try self.screen.drain();
    }

    pub fn submit(self: *Runtime, line: []const u8) !void {
        if (self.waiting.load(.acquire)) {
            self.answer = try self.agent.allocator.dupe(u8, line);
            self.waiting.store(false, .release);
            self.answered.store(true, .release);
            return;
        }
        // A running task takes the line itself: the worker sends it with its
        // next request, so the instruction redirects the work in progress
        // instead of waiting for it to end.
        if (self.busy()) {
            try self.agent.steer(line);
            try self.screen.writeLog(sgr.DIM ++ "Input sent to the running task." ++ sgr.RESET ++ "\n");
            _ = try self.tick();
            return;
        }
        const owned = try self.agent.allocator.dupe(u8, line);
        errdefer self.agent.allocator.free(owned);
        try self.queue.append(self.agent.allocator, owned);
        _ = try self.tick();
    }

    pub fn tick(self: *Runtime) !bool {
        if (self.done.load(.acquire)) {
            if (self.future) |*f| f.await(self.agent.io);
            self.future = null;
            self.done.store(false, .release);
            // A line that arrived just as the task settled found no request
            // left to join, so it runs as the next turn.
            try self.agent.takeSteering(&self.queue);
        }
        if (!self.busy() and self.queue.items.len > 0) {
            const line = self.queue.orderedRemove(0);
            self.agent.interrupted.store(false, .release);
            self.future = self.agent.io.concurrent(run, .{ self, line }) catch |err| {
                self.agent.allocator.free(line);
                return err;
            };
        }
        return self.screen.drain();
    }

    fn run(self: *Runtime, line: []u8) void {
        defer self.done.store(true, .release);
        defer self.agent.allocator.free(line);
        self.agent.processQuery(line) catch |err| {
            if (self.agent.interrupted.load(.acquire)) return;
            const message = std.fmt.allocPrint(self.agent.allocator, sgr.RED ++ "Error: {s}" ++ sgr.RESET ++ "\n", .{@errorName(err)}) catch return;
            defer self.agent.allocator.free(message);
            self.screen.writeLog(message) catch {};
        };
        self.screen.writeLog("\n") catch {};
    }

    pub fn choose(context: ?*anyopaque, question: []const u8, options: []const menu.Option) !?[]u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        var aw: std.Io.Writer.Allocating = .init(self.agent.allocator);
        defer aw.deinit();
        try menu.writeMenu(&aw.writer, question, options);
        try aw.writer.writeAll("Enter an option number or your own answer below (commands remain available).\n");
        self.answered.store(false, .release);
        try self.screen.writeLog(aw.written());
        self.waiting.store(true, .release);
        defer self.waiting.store(false, .release);
        while (!self.answered.load(.acquire)) try self.agent.io.sleep(.fromMilliseconds(50), .awake);
        const answer = self.answer orelse return null;
        self.answer = null;
        defer self.agent.allocator.free(answer);
        if (std.fmt.parseInt(usize, answer, 10)) |number| {
            if (number > 0 and number <= options.len)
                return try menu.describeAnswer(self.agent.allocator, .{ .option = number - 1 }, options);
        } else |_| {}
        if (answer.len == 0) {
            if (menu.recommendedIndex(options)) |index|
                return try menu.describeAnswer(self.agent.allocator, .{ .option = index }, options);
            return null;
        }
        return try menu.describeAnswer(self.agent.allocator, .{ .custom = answer }, options);
    }
};
