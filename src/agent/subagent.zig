//! The handshake between the agent that handed a task over and the agent that
//! took it.
//!
//! A sub-agent is not bounded by an iteration budget or a clock. It is bounded
//! by its caller looking at it: the caller picks how long the child works
//! before it is asked for a progress report, reads that report, and then either
//! lets the child carry on or stops it. This file is the state both sides share
//! to do that, and the two halves of the protocol:
//!
//! * the caller asks for a report (`requestReport`), waits for it or for the
//!   end of the run (`wait`), and answers with `resume` or `stop`;
//! * the child answers at a request boundary (`takeDue`), hands a report over
//!   and takes the verdict back (`report`), and announces its last reply
//!   (`finish`).
//!
//! The two sides alternate rather than run at once: while the child works the
//! caller waits on this struct, and while the caller reads a report the child
//! waits on it inside the report tool. Nothing a child does — its history, its
//! tools, the registry it shares with the caller — is touched while the caller
//! is running, so the handshake is also what keeps the process free of data
//! races without a lock around the agent itself.
const std = @import("std");

pub const Verdict = enum {
    /// The report was read and the task goes on.
    continue_task,
    /// The report was read and the task is over: the child writes its final
    /// report and stops.
    stop,
};

/// What a child must do at its next request boundary.
pub const Due = struct {
    report: bool = false,
    stop: bool = false,

    pub fn any(due: Due) bool {
        return due.report or due.stop;
    }
};

/// How one wait ended, from the caller's side.
pub const Outcome = union(enum) {
    /// The child is paused at a progress report: the caller decides now.
    report: []u8,
    /// The child's turn is over. Its answer is wherever the child was told to
    /// put it, not here.
    done,
    /// The child's turn ended in an error, with no answer.
    failed: anyerror,
};

pub const WaitError = error{Canceled};

/// How long a wait sleeps before it looks at the cancel flags again. Small
/// enough that Esc reaches the child while a caller is waiting on it, large
/// enough to be free: this is a status check, not a poll for work.
const poll_ms: i64 = 100;

pub const Supervisor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Guards every field below. Held for the length of every wait, which is
    /// what makes the hand-over of a report a hand-over and not a race.
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    /// The child's own cancel flag, which is how Esc reaches a run that is
    /// waiting rather than calling a model. Set once the child exists.
    canceled: ?*const std.atomic.Value(bool) = null,
    /// The flag of whoever owns the run: a terminal that asked for the task to
    /// stop stops the child with it, wherever the child is waiting.
    caller_canceled: ?*const std.atomic.Value(bool) = null,

    /// A progress report is due at the child's next boundary.
    report_due: bool = false,
    /// The task is over: say so again at the next boundary, in case the last
    /// reply tried to go on instead of finishing.
    stop_due: bool = false,
    /// The report the caller has not read yet. Owned here until it is taken.
    report: ?[]u8 = null,
    /// The child is inside the report tool, waiting for the verdict.
    awaiting_verdict: bool = false,
    verdict: ?Verdict = null,
    /// The child's turn ended, one way or the other.
    done: bool = false,
    failure: ?anyerror = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Supervisor {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn deinit(self: *Supervisor) void {
        if (self.report) |text| self.allocator.free(text);
        self.report = null;
    }

    /// Ask the child for a progress report at its next request boundary.
    pub fn requestReport(self: *Supervisor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.report_due = true;
        self.cond.broadcast(self.io);
    }

    /// Wait until the child reports or its turn ends.
    ///
    /// `checkin_at` is when the caller gets tired of waiting: once that moment
    /// passes, the child is asked for a report and this keeps waiting for it.
    /// There is no second deadline — a child that is in the middle of a long
    /// command is left to finish it, because cutting the command and calling it
    /// finished would be the lie this design exists to avoid.
    pub fn wait(self: *Supervisor, checkin_at: ?std.Io.Timestamp) WaitError!Outcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (true) {
            if (self.failure) |err| return .{ .failed = err };
            if (self.done) return .done;
            if (self.report) |text| {
                self.report = null;
                return .{ .report = text };
            }
            if (self.canceledNow()) return error.Canceled;
            if (checkin_at) |deadline| {
                if (!self.report_due and deadline.untilNow(self.io, .awake).nanoseconds >= 0) {
                    // The child is not waiting on this: it looks here at its
                    // next request boundary, which is why the flag is the whole
                    // message and the wake below is for a waiter in `report`.
                    self.report_due = true;
                    self.cond.broadcast(self.io);
                }
            }
            self.cond.waitTimeout(self.io, &self.mutex, .{ .duration = .{
                .raw = .fromMilliseconds(poll_ms),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
        }
    }

    /// Let a child that is paused at a report carry on.
    ///
    /// `report_now` asks for the next report in the same breath as the verdict,
    /// under the same lock: a child that woke up between the two would reach
    /// its next boundary before the request was made, and a check-in of zero
    /// would then mean "the boundary after next" instead of "the next one".
    pub fn carryOn(self: *Supervisor, report_now: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.verdict = .continue_task;
        self.report_due = report_now;
        // A report the child sent while the verdict was pending would be a
        // duplicate of the one just read; the next check-in asks for another.
        if (self.report) |text| {
            self.allocator.free(text);
            self.report = null;
        }
        self.cond.broadcast(self.io);
    }

    /// Stop the run: the paused report ends the task, and a child that went on
    /// anyway is told again at its next boundary.
    pub fn stop(self: *Supervisor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.verdict = .stop;
        self.stop_due = true;
        self.cond.broadcast(self.io);
    }

    /// The child's side of the boundary: what it has been asked to do since
    /// its last request, which is nothing most of the time.
    pub fn takeDue(self: *Supervisor) Due {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const due = Due{ .report = self.report_due, .stop = self.stop_due };
        self.report_due = false;
        self.stop_due = false;
        return due;
    }

    /// Hand a progress report to the caller and wait until it decides.
    ///
    /// The text is owned by this struct from here on: the caller reads it out
    /// of `wait`. A child stopped before it read anything leaves the text here,
    /// and `deinit` frees it.
    pub fn handOver(self: *Supervisor, text: []u8) WaitError!Verdict {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // A verdict that is already here was given to a report that has been
        // read: this one is late, and the caller is not waiting for it.
        if (self.verdict) |verdict| {
            self.allocator.free(text);
            return verdict;
        }
        if (self.report) |old| self.allocator.free(old);
        self.report = text;
        self.awaiting_verdict = true;
        self.cond.broadcast(self.io);

        while (self.verdict == null) {
            if (self.canceledNow()) return error.Canceled;
            self.cond.waitTimeout(self.io, &self.mutex, .{ .duration = .{
                .raw = .fromMilliseconds(poll_ms),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
        }
        self.awaiting_verdict = false;
        const verdict = self.verdict.?;
        self.verdict = null;
        return verdict;
    }

    /// The child's turn is over: its caller can stop waiting and read what it
    /// answered.
    pub fn finish(self: *Supervisor, failure: ?anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (failure) |err| self.failure = err else self.done = true;
        self.awaiting_verdict = false;
        self.cond.broadcast(self.io);
    }

    /// Whether either side has asked for this run to stop. Both flags are
    /// checked here so no wait in this file has to know which side set one.
    fn canceledNow(self: *Supervisor) bool {
        if (self.canceled) |flag| {
            if (flag.load(.acquire)) return true;
        }
        if (self.caller_canceled) |flag| {
            if (flag.load(.acquire)) return true;
        }
        return false;
    }
};

test "a caller asks for a report, reads it, and lets the child continue" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var supervisor = Supervisor.init(io, allocator);
    defer supervisor.deinit();

    supervisor.requestReport();
    const due = supervisor.takeDue();
    try std.testing.expect(due.report);
    try std.testing.expect(!due.stop);
    // A boundary only reports what happened since the last one.
    try std.testing.expect(!supervisor.takeDue().any());

    const text = try allocator.dupe(u8, "half the files are split");
    // The child blocks in `report` until the caller answers; drive both sides
    // from one task, which is exactly the alternation the handshake enforces.
    var child_verdict: ?Verdict = null;
    const step = struct {
        fn child(sup: *Supervisor, out: *?Verdict, report_text: []u8) void {
            out.* = sup.handOver(report_text) catch null;
        }
    };
    var future = try io.concurrent(step.child, .{ &supervisor, &child_verdict, text });
    const outcome = try supervisor.wait(null);
    switch (outcome) {
        .report => |report| {
            defer allocator.free(report);
            try std.testing.expectEqualStrings("half the files are split", report);
        },
        else => return error.UnexpectedOutcome,
    }
    supervisor.carryOn(false);
    _ = future.await(io);
    try std.testing.expectEqual(Verdict.continue_task, child_verdict.?);
}

test "a stop reaches a paused child and ends the run" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var supervisor = Supervisor.init(io, allocator);
    defer supervisor.deinit();

    const stop_due = supervisor.takeDue();
    try std.testing.expect(!stop_due.any());
    supervisor.stop();
    const due = supervisor.takeDue();
    try std.testing.expect(due.stop);
    try std.testing.expect(!supervisor.takeDue().any());

    supervisor.finish(null);
    const outcome = try supervisor.wait(null);
    try std.testing.expect(outcome == .done);
}

test "a failure is what the caller waits on" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var supervisor = Supervisor.init(io, allocator);
    defer supervisor.deinit();
    supervisor.finish(error.OutOfMemory);
    const outcome = try supervisor.wait(null);
    try std.testing.expectEqual(error.OutOfMemory, outcome.failed);
}

test "a canceled caller does not wait for a report" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var flag = std.atomic.Value(bool).init(true);
    var supervisor = Supervisor.init(io, allocator);
    defer supervisor.deinit();
    supervisor.caller_canceled = &flag;
    try std.testing.expectError(error.Canceled, supervisor.wait(null));
}
