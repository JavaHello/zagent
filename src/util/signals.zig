//! Naming the signals that end a program.
//!
//! A status carries the signal that ended a call as a name — `SIGTERM` — because
//! the name is what gets read: on the line under the call and in the header
//! above the result. The names all come from the table here, which is the point:
//! a status holds a name without owning it, so one restored from a session
//! snapshot looks its name up here rather than carrying a copy of it.

const std = @import("std");

/// What a status says when the signal it was given has no name here: a signal
/// nobody can name is one nobody can act on, and the result says as much.
pub const fallback = "an unknown signal";

/// The name of `signal` as a shell writes it — `SIGTERM`. The first tag of a
/// value is the name used even where the platform also gives it an alias.
pub fn name(signal: std.posix.SIG) []const u8 {
    inline for (std.enums.values(std.posix.SIG)) |candidate| {
        if (@backingInt(signal) == @backingInt(candidate)) return "SIG" ++ @tagName(candidate);
    }
    unreachable;
}

/// The table's own slice for a name written down earlier, so a status read back
/// from a snapshot points at this table exactly as a live one does.
pub fn canonical(text: []const u8) []const u8 {
    inline for (std.enums.values(std.posix.SIG)) |candidate| {
        if (std.mem.eql(u8, text, "SIG" ++ @tagName(candidate))) return "SIG" ++ @tagName(candidate);
    }
    return fallback;
}

test "every signal has a name, and a name reads back as itself" {
    try std.testing.expectEqualStrings("SIGTERM", name(.TERM));
    try std.testing.expectEqualStrings("SIGKILL", name(.KILL));
    inline for (std.enums.values(std.posix.SIG)) |signal| {
        const written = name(signal);
        try std.testing.expect(std.mem.startsWith(u8, written, "SIG"));
        // The slice a name is read back with is the one that was written out,
        // not a copy: a restored status holds no memory of its own.
        try std.testing.expectEqual(written.ptr, canonical(written).ptr);
    }
    try std.testing.expectEqualStrings(fallback, canonical("SIGPIZZA"));
    try std.testing.expectEqualStrings(fallback, canonical(""));
}
