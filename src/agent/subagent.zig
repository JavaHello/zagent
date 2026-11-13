//! What a caller and the sub-agent it started share while the task runs.
//!
//! A sub-agent is bounded by two clocks the caller sets: how often it checks
//! itself, and by when it must be done. Neither of them is a conversation. The
//! caller sets a flag and looks at what comes back; the child reads the flag at
//! its next request boundary, prints a progress report on the terminal, or
//! writes its final report when the deadline has passed. The caller waits for
//! that last report and for nothing else in between, so there is no verdict to
//! hand back and no protocol to keep: a self-check costs the child one tool
//! call and costs the caller nothing at all.
//!
//! The two sides take turns through this struct rather than run at once: while
//! the child works the caller waits here, and nothing the child does — its
//! history, its tools, the registry it shares with the caller — is touched
//! while the caller is running. That is what keeps the process free of data
//! races without a lock around the agent itself.

const std = @import("std");

/// What a child must do at its next request boundary.
pub const Due = struct {
    /// Send a progress report now, and carry on afterwards.
    progress: bool = false,
    /// The deadline passed: the work stops here and the final report is
    /// written now.
    deadline: bool = false,

    pub fn any(due: Due) bool {
        return due.progress or due.deadline;
    }
};

/// How one wait ended, from the caller's side.
pub const Wake = union(enum) {
    /// The child sent a self-check. The caller shows it and waits again.
    progress: []u8,
    /// The child's turn is over: its final report is where it was told to put
    /// it, not here.
    done,
    /// The child's turn ended in an error, with no answer.
    failed: anyerror,
    /// Nothing happened before the moment the caller named. What is due now —
    /// a self-check, the deadline — is the caller's to decide and to set.
    timeout,
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

    /// A self-check is due at the child's next boundary.
    progress_due: bool = false,
    /// The deadline passed: the child writes its final report at its next
    /// boundary, so a reply that tried to go on is answered with another.
    deadline_due: bool = false,
    /// The self-check the caller has not shown yet. Owned here until it is
    /// taken, and never the final report: that one the child answers with.
    self_check: ?[]u8 = null,
    /// The child's turn ended, one way or the other.
    done: bool = false,
    failure: ?anyerror = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Supervisor {
        return .{ .io = io, .allocator = allocator };
    }

    pub fn deinit(self: *Supervisor) void {
        if (self.self_check) |text| self.allocator.free(text);
        self.self_check = null;
    }

    /// Ask the child for a self-check at its next request boundary.
    pub fn requestProgress(self: *Supervisor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.progress_due = true;
        self.cond.broadcast(self.io);
    }

    /// Whether a self-check is already waiting for the child to reach a
    /// boundary, so the caller does not ask twice for the same one.
    pub fn progressPending(self: *Supervisor) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.progress_due;
    }

    /// Tell the child its deadline has passed: the work ends and the final
    /// report is written now.
    pub fn setDeadline(self: *Supervisor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.deadline_due = true;
        self.cond.broadcast(self.io);
    }

    /// The child's side of the boundary: what it has been asked to do since
    /// its last request, which is nothing most of the time.
    pub fn takeDue(self: *Supervisor) Due {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const due = Due{ .progress = self.progress_due, .deadline = self.deadline_due };
        self.progress_due = false;
        self.deadline_due = false;
        return due;
    }

    /// Hand a self-check over to the caller. The text is owned by this struct
    /// from here on; the caller reads it out of `wait` and frees it.
    pub fn publish(self: *Supervisor, text: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // A self-check the caller has not picked up yet is replaced rather
        // than queued: one that is already old is not worth showing.
        if (self.self_check) |old| self.allocator.free(old);
        self.self_check = text;
        self.cond.broadcast(self.io);
    }

    /// Wait until the child reports or its turn ends, or until `until` passes.
    ///
    /// `until` is when the caller has something else to do — the next
    /// self-check, or the deadline. A null `until` waits for an event alone,
    /// which is what the deadline grace and the end of a run both want.
    pub fn wait(self: *Supervisor, until: ?std.Io.Timestamp) WaitError!Wake {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (true) {
            if (self.failure) |err| return .{ .failed = err };
            if (self.done) return .done;
            if (self.self_check) |text| {
                self.self_check = null;
                return .{ .progress = text };
            }
            if (self.canceledNow()) return error.Canceled;
            var wait_ms: i64 = poll_ms;
            if (until) |moment| {
                // A moment is in the past once the elapsed time to it is
                // positive; that is when the caller has something else to do.
                const left_ms = -moment.untilNow(self.io, .awake).toMilliseconds();
                if (left_ms <= 0) return .timeout;
                wait_ms = @min(wait_ms, left_ms);
            }
            self.cond.waitTimeout(self.io, &self.mutex, .{ .duration = .{
                .raw = .fromMilliseconds(wait_ms),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
        }
    }

    /// The child's turn is over: its caller can stop waiting and read what it
    /// answered.
    pub fn finish(self: *Supervisor, failure: ?anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (failure) |err| self.failure = err else self.done = true;
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

/// A moment this many milliseconds from now, on the clock the waits use.
fn inMs(io: std.Io, ms: i64) std.Io.Timestamp {
    return std.Io.Timestamp.addDuration(std.Io.Timestamp.now(io, .awake), .fromMilliseconds(ms));
}

test "a self-check is asked for at the boundary and read by the caller" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var supervisor = Supervisor.init(io, allocator);
    defer supervisor.deinit();

    try std.testing.expect(!supervisor.takeDue().any());
    supervisor.requestProgress();
    const due = supervisor.takeDue();
    try std.testing.expect(due.progress);
    try std.testing.expect(!due.deadline);
    // A boundary only carries what happened since the last one.
    try std.testing.expect(!supervisor.takeDue().any());

    supervisor.publish(try allocator.dupe(u8, "half the files are split"));
    switch (try supervisor.wait(null)) {
        .progress => |report| {
            defer allocator.free(report);
            try std.testing.expectEqualStrings("half the files are split", report);
        },
        else => return error.UnexpectedOutcome,
    }
    // Reading it hands it over: there is nothing left to read twice.
    try std.testing.expect((try supervisor.wait(inMs(io, 20))) == .timeout);
}

test "the deadline reaches the child and ends the run" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var supervisor = Supervisor.init(io, allocator);
    defer supervisor.deinit();

    supervisor.setDeadline();
    const due = supervisor.takeDue();
    try std.testing.expect(due.deadline);
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

test "a moment that has already passed is not waited for" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var supervisor = Supervisor.init(io, allocator);
    defer supervisor.deinit();
    // The caller's next clock is due, and nothing happened: it must not block
    // on a child that has nothing to say.
    try std.testing.expect((try supervisor.wait(inMs(io, -1))) == .timeout);
}
