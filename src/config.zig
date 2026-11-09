const std = @import("std");
const provider = @import("provider.zig");

const Provider = provider.Provider;

/// The most output tokens a request may ask DeepSeek for: its chat models cap
/// `max_output_tokens` at 8192. The default budget stays inside it, and the
/// truncation retry in `openai.zig` grows no further.
pub const max_output_tokens_ceiling: u32 = 8192;

/// Initial budget per response. Only an endpoint that accepts more than the
/// ceiling needs a larger value, which `AI_MAX_TOKENS` still provides.
const default_max_tokens: u32 = max_output_tokens_ceiling;
const default_max_iterations: u32 = 200;
const default_max_verifications: u32 = 3;
const default_markdown = true;
/// Estimated tokens at which older messages are summarized. 0 switches
/// automatic compaction off.
const default_compact_threshold: u32 = 48_000;
/// Newest messages kept verbatim when the rest of the conversation is
/// summarized.
const default_compact_keep: u32 = 16;
const default_memory = true;
const default_memory_auto = true;

const ConfigFile = struct {
    provider: ?[]u8 = null,
    api_key: ?[]u8 = null,
    base_url: ?[]u8 = null,
    model: ?[]u8 = null,
    max_tokens: ?u32 = null,
    max_iterations: ?u32 = null,
    max_verifications: ?u32 = null,
    markdown: ?bool = null,
    compact_threshold: ?u32 = null,
    compact_keep: ?u32 = null,
    memory: ?bool = null,
    memory_auto: ?bool = null,

    pub fn deinit(self: *ConfigFile, allocator: std.mem.Allocator) void {
        if (self.provider) |value| allocator.free(value);
        if (self.api_key) |value| allocator.free(value);
        if (self.base_url) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        self.* = .{};
    }
};

fn envVarOwned(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) !?[]u8 {
    const value = env.get(name) orelse return null;
    return try allocator.dupe(u8, value);
}

/// Return the first of `names` that is set to a non-empty value.
fn firstEnv(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    names: []const []const u8,
) !?[]u8 {
    for (names) |name| {
        const value = try envVarOwned(allocator, env, name) orelse continue;
        if (value.len == 0) {
            allocator.free(value);
            continue;
        }
        return value;
    }
    return null;
}

/// True when `name` is exported with a non-empty value.
fn envHasValue(env: *const std.process.Environ.Map, name: []const u8) bool {
    const value = env.get(name) orelse return false;
    return value.len > 0;
}

/// The provider whose API key variable the environment exports, if any.
///
/// `Provider` is declared in preference order, which is what makes openai win
/// when a shell exports both keys. Only the presence of a key is read here; the
/// value is resolved with everything else by `resolve`.
fn autodetectProvider(env: *const std.process.Environ.Map) ?Provider {
    for (std.enums.values(Provider)) |candidate| {
        if (envHasValue(env, candidate.spec().api_key_env)) return candidate;
    }
    return null;
}

/// Where zagent's configuration lives: `$XDG_CONFIG_HOME/zagent`, or
/// `~/.config/zagent`. The path may be a file — that is one of the shapes the
/// config file itself is read from — or a directory, which is also where
/// `mcp.json` is looked for.
pub fn configBasePath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (try envVarOwned(allocator, env, "XDG_CONFIG_HOME")) |xdg_dir| {
        defer allocator.free(xdg_dir);
        return try std.fmt.allocPrint(allocator, "{s}/zagent", .{xdg_dir});
    }
    if (try envVarOwned(allocator, env, "HOME")) |home_dir| {
        defer allocator.free(home_dir);
        return try std.fmt.allocPrint(allocator, "{s}/.config/zagent", .{home_dir});
    }
    return null;
}

/// Open the configuration, which is either the path itself or a file named
/// `config` inside it.
///
/// Which of the two it is has to be asked for rather than inferred: on POSIX
/// `openFile` succeeds on a directory, and it is the read that follows that
/// would fail — as a `ReadFailed` with nothing to say about the directory the
/// user actually meant.
fn openConfigFile(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?std.Io.File {
    const base_path = (try configBasePath(allocator, env)) orelse return null;
    defer allocator.free(base_path);

    const cwd = std.Io.Dir.cwd();
    if (try isDirectory(io, base_path)) {
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{base_path});
        defer allocator.free(config_path);
        // A directory there too would be opened and then fail to read, so it is
        // the same question one level down.
        if (try isDirectory(io, config_path)) return null;
        return cwd.openFile(io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    return cwd.openFile(io, base_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Whether a path is a directory. A path that is not there is not one.
fn isDirectory(io: std.Io, path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return stat.kind == .directory;
}

fn setString(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, value);
}

fn applyConfigValue(allocator: std.mem.Allocator, config: *ConfigFile, key: []const u8, value: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(key, "AI_PROVIDER")) {
        try setString(allocator, &config.provider, value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_KEY")) {
        try setString(allocator, &config.api_key, value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_URL")) {
        try setString(allocator, &config.base_url, value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_MODEL")) {
        try setString(allocator, &config.model, value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_MAX_TOKENS")) {
        config.max_tokens = std.fmt.parseInt(u32, value, 10) catch default_max_tokens;
    } else if (std.ascii.eqlIgnoreCase(key, "AI_MAX_ITERATIONS")) {
        config.max_iterations = std.fmt.parseInt(u32, value, 10) catch default_max_iterations;
    } else if (std.ascii.eqlIgnoreCase(key, "AI_MAX_VERIFICATIONS")) {
        config.max_verifications = std.fmt.parseInt(u32, value, 10) catch default_max_verifications;
    } else if (std.ascii.eqlIgnoreCase(key, "AI_MARKDOWN")) {
        config.markdown = parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_COMPACT_THRESHOLD")) {
        config.compact_threshold = std.fmt.parseInt(u32, value, 10) catch default_compact_threshold;
    } else if (std.ascii.eqlIgnoreCase(key, "AI_COMPACT_KEEP")) {
        config.compact_keep = std.fmt.parseInt(u32, value, 10) catch default_compact_keep;
    } else if (std.ascii.eqlIgnoreCase(key, "AI_MEMORY")) {
        config.memory = parseBool(value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_MEMORY_AUTO")) {
        config.memory_auto = parseBool(value);
    }
}

/// Read a whole file through a `std.Io.File.Reader`, growing the buffer as needed.
fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, max_bytes: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn loadConfigFile(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !ConfigFile {
    var config = ConfigFile{};
    var file = (try openConfigFile(io, allocator, env)) orelse return config;
    defer file.close(io);

    const contents = try readFileAlloc(io, allocator, file, 64 * 1024);
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        var value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        try applyConfigValue(allocator, &config, key, value);
    }

    return config;
}

fn takeOwnedString(field: *?[]u8) ?[]u8 {
    const value = field.* orelse return null;
    field.* = null;
    return value;
}

/// Parse a provider name, mapping the empty name to "no provider".
fn parseProviderName(name: []const u8) !?Provider {
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return null;
    return Provider.fromName(name) orelse error.UnknownProvider;
}

fn resolveProvider(
    allocator: std.mem.Allocator,
    file_config: *ConfigFile,
    env: *const std.process.Environ.Map,
) !?Provider {
    // An exported AI_PROVIDER wins over the config file. Exporting it blank
    // cancels a provider set in the file, which gives a one-off escape hatch.
    if (try envVarOwned(allocator, env, "AI_PROVIDER")) |name| {
        defer allocator.free(name);
        if (file_config.provider) |file_name| {
            allocator.free(file_name);
            file_config.provider = null;
        }
        return parseProviderName(name);
    }

    if (takeOwnedString(&file_config.provider)) |name| {
        defer allocator.free(name);
        return parseProviderName(name);
    }

    // Nothing selected a provider, so fall back to whichever API key the
    // environment already exports. A key in the config file suppresses that:
    // such a user has already chosen their credentials, and an unrelated
    // exported variable must not move the endpoint out from under their key.
    if (file_config.api_key != null) return null;
    return autodetectProvider(env);
}

/// Resolve one string setting: environment, then config file, then the
/// fallback supplied by the provider preset. Takes ownership of `file_value`.
fn resolveSetting(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    env_names: []const []const u8,
    file_value: *?[]u8,
    fallback: []const u8,
) ![]u8 {
    if (try firstEnv(allocator, env, env_names)) |value| return value;
    if (takeOwnedString(file_value)) |value| return value;
    return allocator.dupe(u8, fallback);
}

fn resolveU32(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    env_names: []const []const u8,
    file_value: ?u32,
    fallback: u32,
) !u32 {
    for (env_names) |name| {
        const raw = try envVarOwned(allocator, env, name) orelse continue;
        defer allocator.free(raw);
        if (raw.len == 0) continue;
        return std.fmt.parseInt(u32, raw, 10) catch fallback;
    }
    return file_value orelse fallback;
}

const truthy = [_][]const u8{ "1", "true", "yes", "on", "y", "t" };
const falsy = [_][]const u8{ "0", "false", "no", "off", "n", "f" };

/// Parse a boolean setting. Anything unrecognised reads as "unset", so a typo
/// leaves the default in place rather than silently flipping a feature off.
fn parseBool(raw: []const u8) ?bool {
    const value = std.mem.trim(u8, raw, " \t");
    for (truthy) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    for (falsy) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return false;
    }
    return null;
}

fn resolveBool(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    env_names: []const []const u8,
    file_value: ?bool,
    fallback: bool,
) !bool {
    for (env_names) |name| {
        const raw = try envVarOwned(allocator, env, name) orelse continue;
        defer allocator.free(raw);
        // An empty value means "not set", matching `firstEnv`.
        if (raw.len == 0) continue;
        return parseBool(raw) orelse fallback;
    }
    return file_value orelse fallback;
}

/// `openai.zig` appends "/responses" to the base URL, so a trailing
/// slash here would produce a doubled separator. Takes ownership of `url`.
fn trimTrailingSlashes(allocator: std.mem.Allocator, url: []u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    if (trimmed.len == url.len) return url;
    const shortened = try allocator.dupe(u8, trimmed);
    allocator.free(url);
    return shortened;
}

/// Turn a parsed config file plus the environment into the effective settings.
/// Takes ownership of the strings held by `file_config`.
fn resolve(
    allocator: std.mem.Allocator,
    file_config: *ConfigFile,
    env: *const std.process.Environ.Map,
) !Config {
    const selected_provider = try resolveProvider(allocator, file_config, env);

    // With nothing selected — no preset, and no API key to autodetect one from
    // — the fallback is the openai preset, which is byte-identical to the
    // historical built-in defaults.
    const spec = if (selected_provider) |p| p.spec() else Provider.openai.spec();

    var base_url = try resolveSetting(
        allocator,
        env,
        &.{"AI_URL"},
        &file_config.base_url,
        spec.base_url,
    );
    errdefer allocator.free(base_url);
    base_url = try trimTrailingSlashes(allocator, base_url);

    const model = try resolveSetting(
        allocator,
        env,
        &.{"AI_MODEL"},
        &file_config.model,
        spec.model,
    );
    errdefer allocator.free(model);

    const api_key = blk: {
        // AI_KEY is the provider-agnostic spelling and wins outright.
        if (try firstEnv(allocator, env, &.{"AI_KEY"})) |value| break :blk value;

        // Otherwise consult the selected provider's own variable. The legacy
        // OPENAI_API_KEY is deliberately not consulted for another provider, so
        // a key exported for unrelated tooling cannot be sent to the wrong
        // endpoint and produce an opaque 401.
        const key_env_name = if (selected_provider) |p| p.spec().api_key_env else "OPENAI_API_KEY";
        if (try firstEnv(allocator, env, &.{key_env_name})) |value| break :blk value;

        if (takeOwnedString(&file_config.api_key)) |value| break :blk value;
        break :blk try allocator.dupe(u8, "");
    };
    errdefer allocator.free(api_key);

    const max_tokens = try resolveU32(
        allocator,
        env,
        &.{"AI_MAX_TOKENS"},
        file_config.max_tokens,
        default_max_tokens,
    );
    const max_iterations = try resolveU32(
        allocator,
        env,
        &.{"AI_MAX_ITERATIONS"},
        file_config.max_iterations,
        default_max_iterations,
    );
    const max_verifications = try resolveU32(
        allocator,
        env,
        &.{"AI_MAX_VERIFICATIONS"},
        file_config.max_verifications,
        default_max_verifications,
    );
    const markdown = try resolveBool(
        allocator,
        env,
        &.{"AI_MARKDOWN"},
        file_config.markdown,
        default_markdown,
    );
    const compact_threshold = try resolveU32(
        allocator,
        env,
        &.{"AI_COMPACT_THRESHOLD"},
        file_config.compact_threshold,
        default_compact_threshold,
    );
    const compact_keep = @max(
        try resolveU32(
            allocator,
            env,
            &.{"AI_COMPACT_KEEP"},
            file_config.compact_keep,
            default_compact_keep,
        ),
        2,
    );
    const memory = try resolveBool(
        allocator,
        env,
        &.{"AI_MEMORY"},
        file_config.memory,
        default_memory,
    );
    const memory_auto = try resolveBool(
        allocator,
        env,
        &.{"AI_MEMORY_AUTO"},
        file_config.memory_auto,
        default_memory_auto,
    );

    return .{
        .allocator = allocator,
        .api_key = api_key,
        .base_url = base_url,
        .model = model,
        .max_tokens = max_tokens,
        .max_iterations = max_iterations,
        .max_verifications = max_verifications,
        .markdown = markdown,
        .compact_threshold = compact_threshold,
        .compact_keep = compact_keep,
        .memory = memory,
        .memory_auto = memory_auto,
        .provider = selected_provider,
    };
}

pub const Config = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    max_tokens: u32,
    max_iterations: u32,
    /// How many completion checks one user query may cost. 0 turns the check
    /// off entirely.
    max_verifications: u32,
    /// Render assistant markdown for a terminal instead of printing it raw.
    /// A stdout that is not a terminal always prints raw, whatever this says.
    markdown: bool,
    /// Estimated token budget. Older messages are summarized when the
    /// conversation is about to exceed it. 0 disables automatic compaction.
    compact_threshold: u32,
    /// Newest messages kept verbatim across a compaction.
    compact_keep: u32,
    /// Keep durable notes between sessions, and expose the remember tool.
    memory: bool,
    /// Ask the model after each turn whether anything should be remembered.
    memory_auto: bool,
    /// The built-in preset that supplied the defaults, if one was selected.
    provider: ?Provider,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Config {
        var file_config = try loadConfigFile(io, allocator, env);
        defer file_config.deinit(allocator);

        return resolve(allocator, &file_config, env);
    }

    pub fn deinit(self: Config) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        self.allocator.free(self.model);
    }
};

/// Build a hermetic environment map so tests never observe the developer's
/// shell, and never read a real config file (no HOME means no config path).
fn testEnv(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();
    for (pairs) |pair| try env.put(pair[0], pair[1]);
    return env;
}

fn testFile(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !ConfigFile {
    var file_config = ConfigFile{};
    errdefer file_config.deinit(allocator);
    for (pairs) |pair| try applyConfigValue(allocator, &file_config, pair[0], pair[1]);
    return file_config;
}

test "config defaults" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{});
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, null), config.provider);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", config.base_url);
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
    try std.testing.expectEqualStrings("", config.api_key);
    try std.testing.expectEqual(@as(u32, 8192), config.max_tokens);
    try std.testing.expectEqual(@as(u32, 200), config.max_iterations);
    try std.testing.expectEqual(@as(u32, 3), config.max_verifications);
    try std.testing.expect(config.markdown);
    try std.testing.expectEqual(default_compact_threshold, config.compact_threshold);
    try std.testing.expectEqual(default_compact_keep, config.compact_keep);
    try std.testing.expect(config.memory);
    try std.testing.expect(config.memory_auto);
}

fn markdownSetting(
    allocator: std.mem.Allocator,
    env_pairs: []const [2][]const u8,
    file_value: ?bool,
) !bool {
    var env = try testEnv(allocator, env_pairs);
    defer env.deinit();

    var file_config = ConfigFile{ .markdown = file_value };
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();
    return config.markdown;
}

test "AI_MARKDOWN reads booleans from either source" {
    const allocator = std.testing.allocator;

    // The environment wins over the file.
    try std.testing.expect(!try markdownSetting(allocator, &.{.{ "AI_MARKDOWN", "false" }}, true));
    try std.testing.expect(try markdownSetting(allocator, &.{.{ "AI_MARKDOWN", "true" }}, false));

    // The file alone is honoured, in any of the accepted spellings.
    try std.testing.expect(!try markdownSetting(allocator, &.{}, false));
    try std.testing.expect(try markdownSetting(allocator, &.{}, true));
}

test "an unusable AI_MARKDOWN value leaves the default in place" {
    const allocator = std.testing.allocator;

    // A typo must not silently turn the feature off.
    try std.testing.expect(try markdownSetting(allocator, &.{.{ "AI_MARKDOWN", "maybe" }}, null));
    // An empty value means "not set", as it does for every other setting.
    try std.testing.expect(try markdownSetting(allocator, &.{.{ "AI_MARKDOWN", "" }}, null));
}

test "parseBool accepts the documented spellings" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("true"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("ON"));
    try std.testing.expectEqual(@as(?bool, true), parseBool(" 1 "));
    try std.testing.expectEqual(@as(?bool, false), parseBool("No"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("off"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("yep"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("2"));
}

test "verification budget prefers the environment and keeps zero" {
    const allocator = std.testing.allocator;

    {
        var env = try testEnv(allocator, &.{.{ "AI_MAX_VERIFICATIONS", "0" }});
        defer env.deinit();

        var file_config = try testFile(allocator, &.{.{ "AI_MAX_VERIFICATIONS", "5" }});
        defer file_config.deinit(allocator);

        const config = try resolve(allocator, &file_config, &env);
        defer config.deinit();

        // A configured zero is a value, not a missing setting — it has to
        // survive as a way to switch the completion check off.
        try std.testing.expectEqual(@as(u32, 0), config.max_verifications);
    }

    {
        var env = try testEnv(allocator, &.{});
        defer env.deinit();

        var file_config = try testFile(allocator, &.{.{ "AI_MAX_VERIFICATIONS", "2" }});
        defer file_config.deinit(allocator);

        const config = try resolve(allocator, &file_config, &env);
        defer config.deinit();

        try std.testing.expectEqual(@as(u32, 2), config.max_verifications);
    }
}

test "compaction and memory settings prefer the environment and keep zero" {
    const allocator = std.testing.allocator;

    {
        var env = try testEnv(allocator, &.{
            .{ "AI_COMPACT_THRESHOLD", "0" },
            .{ "AI_COMPACT_KEEP", "4" },
            .{ "AI_MEMORY", "false" },
            .{ "AI_MEMORY_AUTO", "off" },
        });
        defer env.deinit();

        var file_config = try testFile(allocator, &.{
            .{ "AI_COMPACT_THRESHOLD", "12000" },
            .{ "AI_COMPACT_KEEP", "8" },
            .{ "AI_MEMORY", "true" },
            .{ "AI_MEMORY_AUTO", "true" },
        });
        defer file_config.deinit(allocator);

        const config = try resolve(allocator, &file_config, &env);
        defer config.deinit();

        // A zero threshold is a value, not a missing setting: it turns
        // automatic compaction off.
        try std.testing.expectEqual(@as(u32, 0), config.compact_threshold);
        try std.testing.expectEqual(@as(u32, 4), config.compact_keep);
        try std.testing.expect(!config.memory);
        try std.testing.expect(!config.memory_auto);
    }

    {
        var env = try testEnv(allocator, &.{});
        defer env.deinit();

        var file_config = try testFile(allocator, &.{
            .{ "AI_COMPACT_THRESHOLD", "12000" },
            .{ "AI_COMPACT_KEEP", "1" },
            .{ "AI_MEMORY", "0" },
        });
        defer file_config.deinit(allocator);

        const config = try resolve(allocator, &file_config, &env);
        defer config.deinit();

        try std.testing.expectEqual(@as(u32, 12000), config.compact_threshold);
        // Fewer than two kept messages would make every cut unsafe.
        try std.testing.expectEqual(@as(u32, 2), config.compact_keep);
        try std.testing.expect(!config.memory);
        // The extractor default stays on; the memory flag is what switches
        // the feature off, and Agent pairs the two.
        try std.testing.expect(config.memory_auto);
    }
}

test "provider preset supplies defaults" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_PROVIDER", "deepseek" }});
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, Provider.deepseek), config.provider);
    try std.testing.expectEqualStrings("https://api.deepseek.com", config.base_url);
    try std.testing.expectEqualStrings("deepseek-flash", config.model);
    try std.testing.expectEqualStrings("", config.api_key);
}

test "openai preset matches the built-in defaults" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_PROVIDER", "openai" }});
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqualStrings("https://api.openai.com/v1", config.base_url);
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
}

test "provider key comes from the provider's own variable" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "AI_PROVIDER", "deepseek" },
        .{ "DEEPSEEK_API_KEY", "sk-deepseek" },
        .{ "OPENAI_API_KEY", "sk-openai" },
    });
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqualStrings("sk-deepseek", config.api_key);
}

test "legacy openai key is ignored when another provider is selected" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "AI_PROVIDER", "deepseek" },
        .{ "OPENAI_API_KEY", "sk-openai" },
    });
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    // Falling back would send the OpenAI key to api.deepseek.com.
    try std.testing.expectEqualStrings("", config.api_key);
}

test "ai key overrides the provider variable" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "AI_PROVIDER", "deepseek" },
        .{ "AI_KEY", "sk-generic" },
        .{ "DEEPSEEK_API_KEY", "sk-deepseek" },
    });
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqualStrings("sk-generic", config.api_key);
}

test "explicit environment beats the preset" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "AI_PROVIDER", "deepseek" },
        .{ "AI_URL", "https://proxy.example/v1/" },
        .{ "AI_MODEL", "deepseek-v4-pro" },
    });
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    // The trailing slash is trimmed so the request path is not doubled.
    try std.testing.expectEqualStrings("https://proxy.example/v1", config.base_url);
    try std.testing.expectEqualStrings("deepseek-v4-pro", config.model);
}

test "config file beats the preset and loses to the environment" {
    const allocator = std.testing.allocator;

    {
        var env = try testEnv(allocator, &.{.{ "AI_PROVIDER", "deepseek" }});
        defer env.deinit();

        var file_config = try testFile(allocator, &.{
            .{ "AI_PROVIDER", "deepseek" },
            .{ "AI_MODEL", "deepseek-v4-pro" },
            .{ "AI_URL", "https://from-file/v1" },
            .{ "AI_KEY", "sk-file" },
        });
        defer file_config.deinit(allocator);

        const config = try resolve(allocator, &file_config, &env);
        defer config.deinit();

        try std.testing.expectEqualStrings("deepseek-v4-pro", config.model);
        try std.testing.expectEqualStrings("https://from-file/v1", config.base_url);
        try std.testing.expectEqualStrings("sk-file", config.api_key);
    }

    {
        var env = try testEnv(allocator, &.{
            .{ "AI_PROVIDER", "deepseek" },
            .{ "AI_MODEL", "from-env" },
        });
        defer env.deinit();

        var file_config = try testFile(allocator, &.{
            .{ "AI_MODEL", "deepseek-v4-pro" },
            .{ "AI_URL", "https://from-file/v1" },
        });
        defer file_config.deinit(allocator);

        const config = try resolve(allocator, &file_config, &env);
        defer config.deinit();

        try std.testing.expectEqualStrings("from-env", config.model);
        try std.testing.expectEqualStrings("https://from-file/v1", config.base_url);
    }
}

test "provider name is matched case insensitively" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_PROVIDER", "DeepSeek" }});
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, Provider.deepseek), config.provider);
}

test "blank environment provider cancels the file provider" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_PROVIDER", "" }});
    defer env.deinit();

    var file_config = try testFile(allocator, &.{.{ "AI_PROVIDER", "deepseek" }});
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, null), config.provider);
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
}

test "unknown provider is an error" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_PROVIDER", "deepsek" }});
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    try std.testing.expectError(error.UnknownProvider, resolve(allocator, &file_config, &env));
}

test "autodetection selects the provider whose key is exported" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "DEEPSEEK_API_KEY", "sk-deepseek" }});
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, Provider.deepseek), config.provider);
    try std.testing.expectEqualStrings("https://api.deepseek.com", config.base_url);
    try std.testing.expectEqualStrings("deepseek-flash", config.model);
    try std.testing.expectEqualStrings("sk-deepseek", config.api_key);
}

test "autodetection prefers openai when both keys are exported" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "OPENAI_API_KEY", "sk-openai" },
        .{ "DEEPSEEK_API_KEY", "sk-deepseek" },
    });
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    // Both keys work, but the legacy default has to keep winning so an existing
    // shell does not silently switch endpoints.
    try std.testing.expectEqual(@as(?Provider, Provider.openai), config.provider);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", config.base_url);
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
    try std.testing.expectEqualStrings("sk-openai", config.api_key);
}

test "blank api keys do not trigger autodetection" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "OPENAI_API_KEY", "" },
        .{ "DEEPSEEK_API_KEY", "" },
    });
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, null), config.provider);
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
}

test "a provider-agnostic key cannot autodetect a provider" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_KEY", "sk-generic" }});
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    // AI_KEY names no host, so the endpoint stays the openai default.
    try std.testing.expectEqual(@as(?Provider, null), config.provider);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", config.base_url);
    try std.testing.expectEqualStrings("sk-generic", config.api_key);
}

test "an explicit provider wins over autodetection" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "AI_PROVIDER", "openai" },
        .{ "DEEPSEEK_API_KEY", "sk-deepseek" },
    });
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, Provider.openai), config.provider);
    // And the deepseek key is not sent to the endpoint that was asked for.
    try std.testing.expectEqualStrings("", config.api_key);
}

test "a config file provider wins over autodetection" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "OPENAI_API_KEY", "sk-openai" }});
    defer env.deinit();

    var file_config = try testFile(allocator, &.{.{ "AI_PROVIDER", "deepseek" }});
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, Provider.deepseek), config.provider);
    try std.testing.expectEqualStrings("https://api.deepseek.com", config.base_url);
    try std.testing.expectEqualStrings("", config.api_key);
}

test "a config file key disables autodetection" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "DEEPSEEK_API_KEY", "sk-deepseek" }});
    defer env.deinit();

    var file_config = try testFile(allocator, &.{.{ "AI_KEY", "sk-file" }});
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    // The configured key has to stay paired with the endpoint it was written
    // for, so the exported deepseek key does not get to move it.
    try std.testing.expectEqual(@as(?Provider, null), config.provider);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", config.base_url);
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
    try std.testing.expectEqualStrings("sk-file", config.api_key);
}

test "max tokens and iterations prefer the environment" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_MAX_TOKENS", "1234" }});
    defer env.deinit();

    var file_config = try testFile(allocator, &.{
        .{ "AI_MAX_TOKENS", "77" },
        .{ "AI_MAX_ITERATIONS", "5" },
    });
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 1234), config.max_tokens);
    try std.testing.expectEqual(@as(u32, 5), config.max_iterations);
}

test "the config is read from the path itself or from a config file inside it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", home);

    // Nothing there at all: no config, and no complaint about it.
    try std.testing.expectEqual(@as(?std.Io.File, null), try openConfigFile(io, allocator, &env));

    // The path is the file.
    try tmp.dir.writeFile(io, .{ .sub_path = "zagent", .data = "AI_MODEL=from-the-path\n" });
    {
        var file = (try openConfigFile(io, allocator, &env)).?;
        defer file.close(io);
        const contents = try readFileAlloc(io, allocator, file, 4096);
        defer allocator.free(contents);
        try std.testing.expect(std.mem.indexOf(u8, contents, "from-the-path") != null);
    }

    // The path is a directory holding one named `config`. Reading a directory
    // is what a plain `openFile` would have led to, so the kind is checked.
    try tmp.dir.deleteFile(io, "zagent");
    try tmp.dir.createDir(io, "zagent", std.Io.File.Permissions.default_dir);
    try std.testing.expectEqual(@as(?std.Io.File, null), try openConfigFile(io, allocator, &env));

    try tmp.dir.writeFile(io, .{ .sub_path = "zagent/config", .data = "AI_MODEL=from-the-directory\n" });
    {
        var file = (try openConfigFile(io, allocator, &env)).?;
        defer file.close(io);
        const contents = try readFileAlloc(io, allocator, file, 4096);
        defer allocator.free(contents);
        try std.testing.expect(std.mem.indexOf(u8, contents, "from-the-directory") != null);
    }
}

test "provider neutral settings win independently of obsolete environment aliases" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "AI_URL", "https://example.test/v1///" },
        .{ "AI_MODEL", "current-model" },
        .{ "AI_MAX_TOKENS", "1024" },
        .{ "AI_MAX_ITERATIONS", "12" },
        .{ "AI_MAX_VERIFICATIONS", "2" },
        .{ "OPENAI_BASE_URL", "https://obsolete.test" },
        .{ "OPENAI_MODEL", "obsolete-model" },
        .{ "OPENAI_MAX_TOKENS", "1" },
        .{ "OPENAI_MAX_ITERATIONS", "1" },
        .{ "OPENAI_MAX_VERIFICATIONS", "1" },
    });
    defer env.deinit();
    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);
    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();
    try std.testing.expectEqualStrings("https://example.test/v1", config.base_url);
    try std.testing.expectEqualStrings("current-model", config.model);
    try std.testing.expectEqual(@as(u32, 1024), config.max_tokens);
    try std.testing.expectEqual(@as(u32, 12), config.max_iterations);
    try std.testing.expectEqual(@as(u32, 2), config.max_verifications);
}

test "obsolete config names do not populate current settings" {
    const allocator = std.testing.allocator;
    var file_config = try testFile(allocator, &.{
        .{ "PROVIDER", "deepseek" },
        .{ "OPENAI_API_KEY", "old-key" },
        .{ "OPENAI_BASE_URL", "https://obsolete.test" },
        .{ "OPENAI_MODEL", "old-model" },
        .{ "OPENAI_MAX_TOKENS", "1" },
        .{ "OPENAI_MAX_ITERATIONS", "1" },
        .{ "OPENAI_MAX_VERIFICATIONS", "1" },
    });
    defer file_config.deinit(allocator);
    try std.testing.expect(file_config.provider == null);
    try std.testing.expect(file_config.api_key == null);
    try std.testing.expect(file_config.base_url == null);
    try std.testing.expect(file_config.model == null);
    try std.testing.expect(file_config.max_tokens == null);
    try std.testing.expect(file_config.max_iterations == null);
    try std.testing.expect(file_config.max_verifications == null);
}

test "obsolete environment settings cannot override config values" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "OPENAI_BASE_URL", "https://obsolete.test" },
        .{ "OPENAI_MODEL", "old-model" },
        .{ "OPENAI_MAX_TOKENS", "1" },
        .{ "OPENAI_MAX_ITERATIONS", "1" },
        .{ "OPENAI_MAX_VERIFICATIONS", "1" },
    });
    defer env.deinit();
    var file_config = try testFile(allocator, &.{
        .{ "AI_URL", "https://current.test/v1" },
        .{ "AI_MODEL", "current-model" },
        .{ "AI_MAX_TOKENS", "2048" },
        .{ "AI_MAX_ITERATIONS", "10" },
        .{ "AI_MAX_VERIFICATIONS", "0" },
    });
    defer file_config.deinit(allocator);
    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();
    try std.testing.expectEqualStrings("https://current.test/v1", config.base_url);
    try std.testing.expectEqualStrings("current-model", config.model);
    try std.testing.expectEqual(@as(u32, 2048), config.max_tokens);
    try std.testing.expectEqual(@as(u32, 10), config.max_iterations);
    try std.testing.expectEqual(@as(u32, 0), config.max_verifications);
}
