//! The terminal has one owner. Workers only enqueue output and request answers.
const std = @import("std");
const sgr = @import("../ui/style.zig");
const layout = @import("../ui/layout.zig");
const Agent = @import("../agent/mod.zig").Agent;
const Screen = @import("../ui/screen.zig").Screen;
const menu = @import("../ui/menu.zig");

test "submit relinquishes ownership before tick fails to launch" {
    var vtable = std.testing.io.vtable.*;
    vtable.concurrent = std.Io.failingConcurrent;
    var agent: Agent = undefined;
    agent.allocator = std.testing.allocator;
    agent.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    agent.interrupted = .init(false);
    var runtime: Runtime = .{ .agent = &agent, .screen = undefined };
    defer runtime.queue.deinit(agent.allocator);
    try std.testing.expectError(error.ConcurrencyUnavailable, runtime.submit("queued"));
    try std.testing.expectEqual(@as(usize, 0), runtime.queue.items.len);
    try std.testing.expect(runtime.future == null);
}

pub const Runtime = struct {
    agent: *Agent,
    screen: *Screen,
    future: ?std.Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    queue: std.ArrayList([]u8) = .empty,
    /// The form the worker is waiting on. The worker publishes its questions
    /// under the mutex and sleeps; the main thread draws them, because it is the
    /// one owner of the keyboard, and publishes the answers back.
    question_mutex: std.Io.Mutex = .init,
    request: ?Request = null,
    question_waiting: std.atomic.Value(bool) = .init(false),
    question_served: std.atomic.Value(bool) = .init(false),
    /// Set while the main thread is answering: the free-text row is read with
    /// the same editor, so it must not hand the keyboard back to itself.
    question_serving: std.atomic.Value(bool) = .init(false),

    const Request = struct {
        /// Borrowed from the worker, which keeps them alive until the form is
        /// answered: it waits, and does nothing else, while it is on screen.
        slots: []menu.Slot,
        /// The answers, published back for the worker to take. Owned here until
        /// it does.
        replies: ?menu.Replies = null,
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
        if (self.request) |request| {
            if (request.replies) |replies| replies.deinit(self.agent.allocator);
        }
        self.request = null;
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
        try self.screen.writeLog(sgr.YELLOW ++ layout.indent ++ "Task interrupted (Esc). Input typed while it ran was discarded." ++ sgr.RESET ++ "\n");
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
            try self.screen.writeLog(sgr.DIM ++ layout.indent ++ "Input sent to the running task." ++ sgr.RESET ++ "\n");
            _ = try self.tick();
            return;
        }
        const owned = try self.agent.allocator.dupe(u8, line);
        self.queue.append(self.agent.allocator, owned) catch |err| {
            self.agent.allocator.free(owned);
            return err;
        };
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
            const message = std.fmt.allocPrint(self.agent.allocator, sgr.RED ++ layout.indent ++ "Error: {s}" ++ sgr.RESET ++ "\n", .{@errorName(err)}) catch return;
            defer self.agent.allocator.free(message);
            self.screen.writeLog(message) catch {};
        };
        self.screen.writeLog("\n") catch {};
    }

    /// The worker's side of a form: publish the questions and wait for the main
    /// thread, which owns the keyboard, to put them to the user. Nothing is
    /// drawn or read here — a worker that touched the terminal would fight the
    /// form for the same keys.
    pub fn presentForm(context: ?*anyopaque, slots: []menu.Slot) !menu.Replies {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.question_mutex.lockUncancelable(self.agent.io);
        self.request = .{ .slots = slots };
        self.question_served.store(false, .release);
        self.question_mutex.unlock(self.agent.io);
        self.question_waiting.store(true, .release);

        // Short sleeps: the answers are published by the main thread, and an
        // interrupt cancels this sleep, so the wait ends either way.
        while (!self.question_served.load(.acquire)) {
            try self.agent.io.sleep(.fromMilliseconds(20), .awake);
        }

        self.question_mutex.lockUncancelable(self.agent.io);
        const replies = if (self.request) |request| request.replies else null;
        self.request = null;
        // Cleared under the mutex: the main thread must see the form is
        // consumed before it looks for the next one, or it would draw the same
        // questions twice.
        self.question_waiting.store(false, .release);
        self.question_mutex.unlock(self.agent.io);

        // A dropped form is a dismissed one, so the worker always has an answer
        // for every question, even when the run was interrupted under it.
        return replies orelse menu.dismissedReplies(self.agent.allocator, slots.len);
    }

    /// Whether a question is waiting for the keyboard: the editor stops reading
    /// the line and lets the menu take over.
    pub fn questionPending(context: ?*anyopaque) bool {
        const self: *Runtime = @ptrCast(@alignCast(context));
        if (self.question_serving.load(.acquire)) return false;
        return self.question_waiting.load(.acquire);
    }

    /// Put every pending question to the user, as one form, and hand the
    /// answers back to the worker. The caller owns the keyboard: it has already
    /// parked the line editor and the terminal's prompt rows are free.
    pub fn serveQuestions(self: *Runtime) !void {
        self.question_serving.store(true, .release);
        defer self.question_serving.store(false, .release);
        while (self.question_waiting.load(.acquire)) {
            self.question_mutex.lockUncancelable(self.agent.io);
            const request = self.request orelse {
                self.question_mutex.unlock(self.agent.io);
                return;
            };
            self.question_mutex.unlock(self.agent.io);

            try self.serveForm(request.slots);

            // Wait for the worker to take the answers before looking for the
            // next form; otherwise this loop would draw the same one again.
            while (self.question_waiting.load(.acquire)) {
                try self.agent.io.sleep(.fromMilliseconds(2), .awake);
            }
        }
    }

    /// One form, from its questions to either an answer for every one of them
    /// or a dismissal. Esc in the free-text row steps back to the form, so it
    /// is drawn again until it is settled instead of being thrown away.
    fn serveForm(self: *Runtime, slots: []menu.Slot) !void {
        const replies = menu.resolve(self.agent.allocator, slots, .{
            .context = self,
            .present = presentOnScreen,
            .read = readOnScreen,
        }) catch |err| {
            self.screen.endInput() catch {};
            // The worker must not be left waiting for an answer that is never
            // coming: it gets a dismissed form, and the run carries on.
            self.settle(menu.dismissedReplies(self.agent.allocator, slots.len) catch return err) catch {};
            return err;
        };
        try self.settle(replies);
    }

    /// Draw the form in the rows the prompt had, so the conversation above it
    /// stays where it is instead of scrolling under the menu.
    fn presentOnScreen(context: *anyopaque, slots: []menu.Slot, focus: ?usize) anyerror!menu.Outcome {
        const self: *Runtime = @ptrCast(@alignCast(context));
        try self.reserveRows(menu.formRows(slots, true));
        const outcome = menu.form(self.agent.allocator, self.agent.io, slots, true, focus) catch |err| {
            self.screen.endInput() catch {};
            return err;
        };
        try self.screen.endInput();
        return outcome;
    }

    /// Read the free text a free-text row asks for, with the same editor.
    fn readOnScreen(context: *anyopaque) anyerror!menu.Line {
        const self: *Runtime = @ptrCast(@alignCast(context));
        return self.agent.readChoiceLine();
    }

    /// Reserve bottom rows for the form the way the editor does for its own.
    fn reserveRows(self: *Runtime, rows: usize) !void {
        self.screen.editor_frame = true;
        defer self.screen.editor_frame = false;
        try self.screen.reserveInput(rows, true);
    }

    /// Publish the answers to the worker waiting in `presentForm`.
    fn settle(self: *Runtime, replies: menu.Replies) !void {
        self.question_mutex.lockUncancelable(self.agent.io);
        defer self.question_mutex.unlock(self.agent.io);
        if (self.request) |*request| {
            if (request.replies) |old| old.deinit(self.agent.allocator);
            request.replies = replies;
        } else {
            replies.deinit(self.agent.allocator);
        }
        self.question_served.store(true, .release);
    }
};
