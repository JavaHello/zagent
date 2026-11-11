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
    queue: std.ArrayList([]u8) = .empty,
    /// The question the worker is waiting on. The worker publishes it under the
    /// mutex and sleeps; the main thread draws the menu, because it is the one
    /// owner of the keyboard, and publishes the answer back.
    question_mutex: std.Io.Mutex = .init,
    question: ?Question = null,
    question_waiting: std.atomic.Value(bool) = .init(false),
    question_served: std.atomic.Value(bool) = .init(false),
    /// Set while the main thread is answering: the free-text row is read with
    /// the same editor, so it must not hand the keyboard back to itself.
    question_serving: std.atomic.Value(bool) = .init(false),

    const Question = struct {
        /// Borrowed from the worker, which keeps them alive until it is served.
        text: []const u8,
        options: []const menu.Option,
        choice: menu.Choice = .cancel,
        /// The free text of a `custom` choice; owned by this runtime.
        answer: ?[]u8 = null,
    };

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
        self.dropQuestion();
    }

    fn dropQuestion(self: *Runtime) void {
        self.question_mutex.lockUncancelable(self.agent.io);
        defer self.question_mutex.unlock(self.agent.io);
        if (self.question) |asked| {
            if (asked.answer) |answer| self.agent.allocator.free(answer);
        }
        self.question = null;
        self.question_waiting.store(false, .release);
    }

    pub fn interrupt(self: *Runtime) !void {
        if (!self.busy()) return;
        self.agent.interrupted.store(true, .release);
        if (self.future) |*f| f.cancel(self.agent.io);
        self.future = null;
        self.done.store(false, .release);
        self.dropQuestion();
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
        // A running task takes the line itself: the worker sends it with its
        // next request, so the instruction redirects the work in progress
        // instead of waiting for it to end. A question is not answered here:
        // while a question is open the menu has the keyboard, so nothing can
        // reach this function from it.
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

    /// The worker's side of a question: publish it and wait for the main
    /// thread, which owns the keyboard, to put it to the user. Nothing is drawn
    /// or read here — a worker that touched the terminal would fight the menu
    /// for the same keys.
    pub fn choose(context: ?*anyopaque, question: []const u8, options: []const menu.Option) !?[]u8 {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.question_mutex.lockUncancelable(self.agent.io);
        self.question = .{ .text = question, .options = options };
        self.question_served.store(false, .release);
        self.question_mutex.unlock(self.agent.io);
        self.question_waiting.store(true, .release);

        // Short sleeps: the answer is published by the main thread, and an
        // interrupt cancels this sleep, so the wait ends either way.
        while (!self.question_served.load(.acquire)) {
            try self.agent.io.sleep(.fromMilliseconds(20), .awake);
        }

        self.question_mutex.lockUncancelable(self.agent.io);
        const asked = self.question orelse Question{ .text = question, .options = options };
        self.question = null;
        // Cleared under the mutex: the main thread must see the question is
        // consumed before it looks for the next one, or it would draw the same
        // menu twice.
        self.question_waiting.store(false, .release);
        self.question_mutex.unlock(self.agent.io);
        defer if (asked.answer) |answer| self.agent.allocator.free(answer);

        return switch (asked.choice) {
            .option => |index| try menu.describeAnswer(self.agent.allocator, .{ .option = index }, options),
            .custom => if (asked.answer) |answer|
                try menu.describeAnswer(self.agent.allocator, .{ .custom = answer }, options)
            else
                null,
            .cancel => null,
        };
    }

    /// Whether a question is waiting for the keyboard: the editor stops reading
    /// the line and lets the menu take over.
    pub fn questionPending(context: ?*anyopaque) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.question_serving.load(.acquire)) return false;
        return self.question_waiting.load(.acquire);
    }

    /// Put every pending question to the user, one menu each, and hand each
    /// answer back to the worker. The caller owns the keyboard: it has already
    /// parked the line editor and the terminal's prompt rows are free.
    pub fn serveQuestions(self: *Runtime) !void {
        self.question_serving.store(true, .release);
        defer self.question_serving.store(false, .release);
        while (self.question_waiting.load(.acquire)) {
            self.question_mutex.lockUncancelable(self.agent.io);
            const asked = self.question orelse {
                self.question_mutex.unlock(self.agent.io);
                return;
            };
            self.question_mutex.unlock(self.agent.io);

            // The question takes the rows the prompt had, so the conversation
            // above it stays where it is instead of scrolling under the menu.
            try self.reserveRows(menu.rowsFor(asked.options.len, true));
            const choice = menu.select(self.agent.allocator, self.agent.io, asked.text, asked.options) catch |err| {
                self.screen.endInput() catch {};
                return err;
            };
            try self.screen.endInput();

            switch (choice) {
                // A dismissed question leaves the run alone: the worker gets
                // no answer and decides for itself what to do next.
                .cancel => try self.settle(.cancel, null),
                .option => |index| try self.settle(.{ .option = index }, null),
                .custom => {
                    const answer = try self.agent.readChoiceLine();
                    if (answer) |text| {
                        defer self.agent.allocator.free(text);
                        try self.settle(.custom, text);
                    } else {
                        // Nothing typed: the question is dismissed, not answered.
                        try self.settle(.cancel, null);
                    }
                },
            }

            // Wait for the worker to take the answer before looking for the
            // next question; otherwise this loop would draw the same menu again.
            while (self.question_waiting.load(.acquire)) {
                try self.agent.io.sleep(.fromMilliseconds(2), .awake);
            }
        }
    }

    /// Reserve bottom rows for the menu the way the editor does for its own.
    fn reserveRows(self: *Runtime, rows: usize) !void {
        self.screen.editor_frame = true;
        defer self.screen.editor_frame = false;
        try self.screen.reserveInput(rows, true);
    }

    /// Publish the user's answer to the worker waiting in `choose`.
    fn settle(self: *Runtime, choice: menu.Choice, answer: ?[]const u8) !void {
        const owned = if (answer) |text| try self.agent.allocator.dupe(u8, text) else null;
        self.question_mutex.lockUncancelable(self.agent.io);
        defer self.question_mutex.unlock(self.agent.io);
        if (self.question) |*asked| {
            asked.choice = choice;
            if (asked.answer) |old| self.agent.allocator.free(old);
            asked.answer = owned;
        } else if (owned) |text| {
            self.agent.allocator.free(text);
        }
        self.question_served.store(true, .release);
    }
};
