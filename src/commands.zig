const std = @import("std");
const Allocator = std.mem.Allocator;

// Dim, so the hint reads as a suggestion rather than typed text. linenoise's
// width() skips SGR sequences, so the colours cost no columns.
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

/// One REPL command offered to the user.
pub const Command = struct {
    /// Including the leading slash, exactly as it has to be typed.
    name: []const u8,
    description: []const u8,
};

/// Every command the REPL understands, in the order Tab offers them. The
/// dispatcher in main.zig is the authority on behaviour; this table is what the
/// user is shown, so the two are kept in step by hand.
pub const all = [_]Command{
    .{ .name = "/help", .description = "Show this help message" },
    .{ .name = "/clear", .description = "Clear conversation history" },
    .{ .name = "/new", .description = "Start a new conversation (same as /clear)" },
    .{ .name = "/model", .description = "Show current model" },
    .{ .name = "/quit", .description = "Exit zagent" },
    .{ .name = "/exit", .description = "Exit zagent" },
};

/// A line that is still a command being typed: it starts with a slash and has
/// not reached a space yet. Once a space appears the user is writing a query,
/// and completing or hinting would only be in the way.
fn isCommandPrefix(buffer: []const u8) bool {
    if (buffer.len == 0 or buffer[0] != '/') return false;
    return std.mem.indexOfAny(u8, buffer, " \t") == null;
}

/// Completions for Tab. The line is a command in progress, so every command
/// starting with it is a candidate; the whole line is replaced by the one the
/// user picks. An empty list (Tab on ordinary text) makes linenoise beep and
/// leave the line alone.
pub fn complete(allocator: Allocator, buffer: []const u8) Allocator.Error![]const []const u8 {
    var matches: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (matches.items) |match| allocator.free(match);
        matches.deinit(allocator);
    }

    if (isCommandPrefix(buffer)) {
        for (all) |command| {
            if (std.mem.startsWith(u8, command.name, buffer)) {
                try matches.append(allocator, try allocator.dupe(u8, command.name));
            }
        }
    }

    return matches.toOwnedSlice(allocator);
}

/// The dim text drawn after the line: the rest of the command name, like ghost
/// text, followed by what it does. Only shown while a single command still
/// matches — with several candidates the list Tab shows is clearer.
pub fn hint(allocator: Allocator, buffer: []const u8) Allocator.Error!?[]const u8 {
    if (!isCommandPrefix(buffer)) return null;

    var match: ?Command = null;
    for (all) |command| {
        if (std.mem.startsWith(u8, command.name, buffer)) {
            if (match != null) return null; // Ambiguous: let Tab list them.
            match = command;
        }
    }

    const command = match orelse return null;
    const remainder = command.name[buffer.len..];
    if (remainder.len == 0) {
        const text = try std.fmt.allocPrint(allocator, DIM ++ "  {s}" ++ RESET, .{command.description});
        return text;
    }
    const text = try std.fmt.allocPrint(allocator, DIM ++ "{s}  {s}" ++ RESET, .{ remainder, command.description });
    return text;
}

/// Free a completion list handed out by `complete`, matching how linenoise
/// disposes of one.
fn freeCompletions(allocator: Allocator, matches: []const []const u8) void {
    for (matches) |match| allocator.free(match);
    allocator.free(matches);
}

test "complete offers every command matching the prefix" {
    const allocator = std.testing.allocator;

    const slash = try complete(allocator, "/");
    defer freeCompletions(allocator, slash);
    try std.testing.expectEqual(all.len, slash.len);

    const c = try complete(allocator, "/c");
    defer freeCompletions(allocator, c);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqualStrings("/clear", c[0]);

    const e = try complete(allocator, "/e");
    defer freeCompletions(allocator, e);
    try std.testing.expectEqual(@as(usize, 1), e.len);
    try std.testing.expectEqualStrings("/exit", e[0]);
}

test "complete leaves ordinary text and finished commands alone" {
    const allocator = std.testing.allocator;

    const none = try complete(allocator, "hello");
    defer freeCompletions(allocator, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // A space means the line is a query, not a command.
    const query = try complete(allocator, "/model please");
    defer freeCompletions(allocator, query);
    try std.testing.expectEqual(@as(usize, 0), query.len);
}

test "hint completes a unique command and names it" {
    const allocator = std.testing.allocator;

    const partial = (try hint(allocator, "/cl")).?;
    defer allocator.free(partial);
    try std.testing.expectEqualStrings(DIM ++ "ear  Clear conversation history" ++ RESET, partial);

    // A fully typed command hints its description with no ghost text.
    const exact = (try hint(allocator, "/quit")).?;
    defer allocator.free(exact);
    try std.testing.expectEqualStrings(DIM ++ "  Exit zagent" ++ RESET, exact);
}

test "hint stays quiet for ambiguous or non-command input" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(@as(?[]const u8, null), try hint(allocator, "/"));
    try std.testing.expectEqual(@as(?[]const u8, null), try hint(allocator, "/zzz"));
    try std.testing.expectEqual(@as(?[]const u8, null), try hint(allocator, "plain words"));
}
