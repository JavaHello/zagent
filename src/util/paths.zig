//! Where zagent's own files live on disk.
//!
//! Nothing outside the workspace is written or read without asking this file
//! first: the XDG base directories and the `HOME` that stands in for them are
//! resolved here and nowhere else, so one set of rules holds for the config
//! file, the prompt history, the workspace state, the skills directories and
//! the Codex credentials alike.
//!
//! The rules are the ones the XDG specification states:
//!
//!   * an empty variable is not set;
//!   * a relative one is ignored, because a path built on it would be relative
//!     to wherever the process happens to run;
//!   * `HOME` is the fallback a variable that is not set falls back to, and it
//!     has to be absolute for the same reason.
//!
//! Each function returns a string the caller owns, or null when the environment
//! names no base directory at all — a file that cannot be stored, which is not
//! an error: a session without a history file still runs.
const std = @import("std");

pub const Environ = std.process.Environ.Map;

/// The value of an environment variable, treating an empty one as unset.
pub fn envValue(env: *const Environ, name: []const u8) ?[]const u8 {
    const found = env.get(name) orelse return null;
    return if (found.len == 0) null else found;
}

/// The user's home directory, when the environment names an absolute one.
pub fn home(env: *const Environ) ?[]const u8 {
    const found = envValue(env, "HOME") orelse return null;
    return if (std.fs.path.isAbsolute(found)) found else null;
}

/// `$XDG_CONFIG_HOME/<relative>`, or `~/.config/<relative>`.
pub fn configPath(allocator: std.mem.Allocator, env: *const Environ, relative: []const u8) !?[]u8 {
    return try basePath(allocator, env, "XDG_CONFIG_HOME", ".config", relative);
}

/// `$XDG_STATE_HOME/<relative>`, or `~/.local/state/<relative>`.
///
/// State rather than config: data the program produces, not something the user
/// writes, and not worth carrying between machines.
pub fn statePath(allocator: std.mem.Allocator, env: *const Environ, relative: []const u8) !?[]u8 {
    return try basePath(allocator, env, "XDG_STATE_HOME", ".local/state", relative);
}

/// `~/<relative>`, or null when the environment names no home directory.
pub fn homePath(allocator: std.mem.Allocator, env: *const Environ, relative: []const u8) !?[]u8 {
    const home_dir = home(env) orelse return null;
    return try std.fs.path.join(allocator, &.{ home_dir, relative });
}

/// A path below one of the base directories: the one the variable names, or the
/// one below `HOME` that the specification puts in its place.
fn basePath(
    allocator: std.mem.Allocator,
    env: *const Environ,
    name: []const u8,
    fallback: []const u8,
    relative: []const u8,
) !?[]u8 {
    if (envValue(env, name)) |dir| {
        if (std.fs.path.isAbsolute(dir)) return try std.fs.path.join(allocator, &.{ dir, relative });
    }
    const home_dir = home(env) orelse return null;
    return try std.fs.path.join(allocator, &.{ home_dir, fallback, relative });
}

/// A configured path with a leading `~` spelled out, so a line in a shell
/// profile does not depend on the shell expanding it. A `~` with no home
/// directory to stand for stays as it was written.
pub fn expandHome(allocator: std.mem.Allocator, env: *const Environ, path: []const u8) ![]u8 {
    if (path.len > 1 and path[0] == '~' and path[1] == '/') {
        if (home(env)) |home_dir| return try std.fs.path.join(allocator, &.{ home_dir, path[2..] });
    }
    return allocator.dupe(u8, path);
}

/// Build a hermetic environment map, so the developer's own shell cannot reach
/// these tests.
fn testEnv(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !Environ {
    var env = Environ.init(allocator);
    errdefer env.deinit();
    for (pairs) |pair| try env.put(pair[0], pair[1]);
    return env;
}

test "the xdg directories are preferred and HOME stands in for them" {
    const a = std.testing.allocator;

    {
        var env = try testEnv(a, &.{
            .{ "XDG_CONFIG_HOME", "/config" },
            .{ "XDG_STATE_HOME", "/state" },
            .{ "HOME", "/home/user" },
        });
        defer env.deinit();

        const config = (try configPath(a, &env, "zagent/config")).?;
        defer a.free(config);
        try std.testing.expectEqualStrings("/config/zagent/config", config);

        const state = (try statePath(a, &env, "zagent/history")).?;
        defer a.free(state);
        try std.testing.expectEqualStrings("/state/zagent/history", state);

        const skills = (try homePath(a, &env, ".agents/skills")).?;
        defer a.free(skills);
        try std.testing.expectEqualStrings("/home/user/.agents/skills", skills);
    }

    // Only HOME: the directories the specification names as the fallbacks.
    {
        var env = try testEnv(a, &.{.{ "HOME", "/home/user" }});
        defer env.deinit();

        const config = (try configPath(a, &env, "zagent/config")).?;
        defer a.free(config);
        try std.testing.expectEqualStrings("/home/user/.config/zagent/config", config);

        const state = (try statePath(a, &env, "zagent/history")).?;
        defer a.free(state);
        try std.testing.expectEqualStrings("/home/user/.local/state/zagent/history", state);
    }
}

test "an empty or relative base directory is not one" {
    const a = std.testing.allocator;

    {
        // An empty variable means "not set", and a relative one cannot name a
        // place a file goes: both leave the fallback below HOME.
        var env = try testEnv(a, &.{
            .{ "XDG_CONFIG_HOME", "" },
            .{ "XDG_STATE_HOME", "relative/state" },
            .{ "HOME", "/home/user" },
        });
        defer env.deinit();

        const config = (try configPath(a, &env, "zagent")).?;
        defer a.free(config);
        try std.testing.expectEqualStrings("/home/user/.config/zagent", config);

        const state = (try statePath(a, &env, "zagent")).?;
        defer a.free(state);
        try std.testing.expectEqualStrings("/home/user/.local/state/zagent", state);
    }

    {
        // A relative HOME is no better than a relative variable.
        var env = try testEnv(a, &.{.{ "HOME", "user" }});
        defer env.deinit();

        try std.testing.expectEqual(@as(?[]u8, null), try configPath(a, &env, "zagent"));
        try std.testing.expectEqual(@as(?[]u8, null), try statePath(a, &env, "zagent"));
        try std.testing.expectEqual(@as(?[]u8, null), try homePath(a, &env, ".agents/skills"));
    }
}

test "no home directory names no path" {
    const a = std.testing.allocator;

    var env = try testEnv(a, &.{});
    defer env.deinit();

    try std.testing.expectEqual(@as(?[]u8, null), try configPath(a, &env, "zagent"));
    try std.testing.expectEqual(@as(?[]u8, null), try statePath(a, &env, "zagent"));
    try std.testing.expectEqual(@as(?[]u8, null), try homePath(a, &env, ".agents/skills"));
    try std.testing.expectEqual(@as(?[]const u8, null), home(&env));
}

test "a leading tilde is spelled out against HOME" {
    const a = std.testing.allocator;

    var env = try testEnv(a, &.{.{ "HOME", "/home/user" }});
    defer env.deinit();

    const expanded = try expandHome(a, &env, "~/skills");
    defer a.free(expanded);
    try std.testing.expectEqualStrings("/home/user/skills", expanded);

    // Everything that is not a leading `~/` is left exactly as it was: an
    // absolute path, a bare `~`, and a `~name` another shell would expand.
    for ([_][]const u8{ "/absolute/skills", "~", "~name/skills", "relative/skills" }) |path| {
        const kept = try expandHome(a, &env, path);
        defer a.free(kept);
        try std.testing.expectEqualStrings(path, kept);
    }

    var no_home = try testEnv(a, &.{});
    defer no_home.deinit();
    const unresolved = try expandHome(a, &no_home, "~/skills");
    defer a.free(unresolved);
    try std.testing.expectEqualStrings("~/skills", unresolved);
}
