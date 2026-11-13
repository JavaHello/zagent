const std = @import("std");
const provider = @import("provider.zig");

const Provider = provider.Provider;

/// Whether a request carries DeepSeek's `thinking` field, and with what value.
///
/// DeepSeek enables thinking by default, so asking for the non-thinking mode
/// has to be explicit rather than done by leaving the field out. `omit` exists
/// for a backend that does not define the field at all and would reject it.
pub const ThinkingMode = enum {
    omit,
    enabled,
    disabled,

    /// The member's `type` value, or null when the field is not sent.
    pub fn wireValue(self: ThinkingMode) ?[]const u8 {
        return switch (self) {
            .omit => null,
            .enabled => "enabled",
            .disabled => "disabled",
        };
    }
};

/// The most output tokens a request may ask DeepSeek for: its chat models cap
/// `max_output_tokens` at 8192. The default budget stays inside it, and the
/// truncation retry in `openai.zig` grows no further.
pub const max_output_tokens_ceiling: u32 = 8192;

/// Initial budget per response. Only an endpoint that accepts more than the
/// ceiling needs a larger value, which `AI_MAX_TOKENS` still provides.
const default_max_tokens: u32 = max_output_tokens_ceiling;

const ConfigFile = struct {
    provider: ?[]u8 = null,
    api_key: ?[]u8 = null,
    base_url: ?[]u8 = null,
    model: ?[]u8 = null,
    reasoning_effort: ?[]u8 = null,
    service_tier: ?[]u8 = null,
    thinking: ?[]u8 = null,
    prompt_cache_retention: ?[]u8 = null,
    max_tokens: ?u32 = null,
    debug: ?bool = null,

    pub fn deinit(self: *ConfigFile, allocator: std.mem.Allocator) void {
        if (self.provider) |value| allocator.free(value);
        if (self.api_key) |value| allocator.free(value);
        if (self.base_url) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        if (self.reasoning_effort) |value| allocator.free(value);
        if (self.service_tier) |value| allocator.free(value);
        if (self.thinking) |value| allocator.free(value);
        if (self.prompt_cache_retention) |value| allocator.free(value);
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
        const spec = candidate.spec();
        if (!spec.autodetect) continue;
        if (envHasValue(env, spec.api_key_env)) return candidate;
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
    // Allocate before releasing: a failed allocation must leave the old value
    // in place rather than a pointer to freed memory.
    const owned = try allocator.dupe(u8, value);
    if (slot.*) |old| allocator.free(old);
    slot.* = owned;
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
    } else if (std.ascii.eqlIgnoreCase(key, "AI_REASONING_EFFORT")) {
        try setString(allocator, &config.reasoning_effort, value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_SERVICE_TIER")) {
        try setString(allocator, &config.service_tier, value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_THINKING")) {
        try setString(allocator, &config.thinking, value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_PROMPT_CACHE_RETENTION")) {
        try setString(allocator, &config.prompt_cache_retention, value);
    } else if (std.ascii.eqlIgnoreCase(key, "AI_MAX_TOKENS")) {
        config.max_tokens = std.fmt.parseInt(u32, value, 10) catch default_max_tokens;
    } else if (std.ascii.eqlIgnoreCase(key, "AI_DEBUG")) {
        config.debug = flagValue(value);
    }
}

/// A switch that is on unless it is plainly off: an exported `AI_DEBUG` with
/// any value at all is a request for the trace, and only the spellings of "no"
/// take it back.
fn flagValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return false;
    return !std.mem.eql(u8, trimmed, "0") and
        !std.ascii.eqlIgnoreCase(trimmed, "false") and
        !std.ascii.eqlIgnoreCase(trimmed, "off") and
        !std.ascii.eqlIgnoreCase(trimmed, "no");
}

/// Read a whole file through a `std.Io.File.Reader`, growing the buffer as needed.
fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, max_bytes: usize) ![]u8 {
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn loadConfigFile(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !ConfigFile {
    var config = ConfigFile{};
    errdefer config.deinit(allocator);
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

fn resolveOptionalSetting(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    name: []const u8,
    file_value: *?[]u8,
) !?[]u8 {
    if (try firstEnv(allocator, env, &.{name})) |value| return value;
    if (takeOwnedString(file_value)) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    }
    return null;
}

/// `AI_THINKING` chooses the value; left blank it follows the preset, because a
/// backend that does not define the member would reject a request carrying it.
/// An explicit value is honoured for any provider: the user is describing the
/// endpoint they actually talk to, which a preset only narrows down.
fn resolveThinking(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    file_value: *?[]u8,
    selected: ?Provider,
) !ThinkingMode {
    const asked = try resolveOptionalSetting(allocator, env, "AI_THINKING", file_value);
    defer if (asked) |value| allocator.free(value);
    if (asked) |value| {
        if (std.ascii.eqlIgnoreCase(value, "enabled") or std.ascii.eqlIgnoreCase(value, "on") or std.mem.eql(u8, value, "1")) return .enabled;
        if (std.ascii.eqlIgnoreCase(value, "disabled") or std.ascii.eqlIgnoreCase(value, "off") or std.mem.eql(u8, value, "0")) return .disabled;
        if (std.ascii.eqlIgnoreCase(value, "omit") or std.ascii.eqlIgnoreCase(value, "none")) return .omit;
        return error.InvalidThinking;
    }
    return switch (selected orelse return .omit) {
        .deepseek, .openai_compatible => .enabled,
        else => .omit,
    };
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

    // A preset that cannot know the vendor has no defaults to fall back on,
    // so the settings it needs are reported by name instead of being sent to
    // an empty host.
    if (selected_provider == .openai_compatible) {
        if (base_url.len == 0) return error.MissingProviderUrl;
        if (model.len == 0) return error.MissingProviderModel;
    }

    const reasoning_effort = try resolveOptionalSetting(allocator, env, "AI_REASONING_EFFORT", &file_config.reasoning_effort);
    errdefer if (reasoning_effort) |value| allocator.free(value);
    const service_tier = try resolveOptionalSetting(allocator, env, "AI_SERVICE_TIER", &file_config.service_tier);
    errdefer if (service_tier) |value| allocator.free(value);
    const thinking = try resolveThinking(allocator, env, &file_config.thinking, selected_provider);
    const prompt_cache_retention = try resolveOptionalSetting(allocator, env, "AI_PROMPT_CACHE_RETENTION", &file_config.prompt_cache_retention);
    errdefer if (prompt_cache_retention) |value| allocator.free(value);
    if (prompt_cache_retention) |value| {
        if (!std.mem.eql(u8, value, "in_memory") and !std.mem.eql(u8, value, "24h"))
            return error.InvalidPromptCacheRetention;
    }

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

    // The environment wins over the file, as it does for every other setting:
    // `AI_DEBUG=0 zagent --debug` is a trace anyway, because the flag is read
    // by the command line rather than here.
    const debug = if (env.get("AI_DEBUG")) |value| flagValue(value) else (file_config.debug orelse false);

    return .{
        .allocator = allocator,
        .api_key = api_key,
        .base_url = base_url,
        .model = model,
        .reasoning_effort = reasoning_effort,
        .service_tier = service_tier,
        .thinking = thinking,
        .prompt_cache_retention = prompt_cache_retention,
        .max_tokens = max_tokens,
        .provider = selected_provider,
        .debug = debug,
    };
}

pub const Config = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    reasoning_effort: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    /// Sent as an outer-level `thinking` member. DeepSeek and the generic
    /// compatible preset ask for it by default; the OpenAI and Codex backends
    /// do not define the field and leave it out.
    thinking: ThinkingMode = .omit,
    /// Only "in_memory" and "24h" are accepted; null leaves server defaults.
    prompt_cache_retention: ?[]const u8 = null,
    max_tokens: u32,
    /// The built-in preset that supplied the defaults, if one was selected.
    provider: ?Provider,
    codex_auth_path: ?[]const u8 = null,
    /// Whether to record a debug trace and render its report. `--debug` on the
    /// command line turns it on as well; nothing here can turn it off.
    debug: bool = false,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Config {
        var file_config = try loadConfigFile(io, allocator, env);
        defer file_config.deinit(allocator);

        var config = try resolve(allocator, &file_config, env);
        errdefer config.deinit();
        if (config.provider == .codex) {
            if (!std.mem.eql(u8, config.base_url, @import("codex_auth.zig").base_url)) return error.CodexEndpointMustBeOfficial;
            config.codex_auth_path = try @import("codex_auth.zig").path(allocator, env);
        }
        return config;
    }

    pub fn deinit(self: Config) void {
        if (self.codex_auth_path) |path| self.allocator.free(path);
        if (self.reasoning_effort) |value| self.allocator.free(value);
        if (self.service_tier) |value| self.allocator.free(value);
        if (self.prompt_cache_retention) |value| self.allocator.free(value);
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

fn checkApplyAllocationFailures(allocator: std.mem.Allocator) !void {
    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);
    for ([_][2][]const u8{
        .{ "AI_PROVIDER", "codex" },
        .{ "AI_KEY", "key" },
        .{ "AI_URL", "https://example.test/v1" },
        .{ "AI_MODEL", "model" },
        // Replacing a value already set is a separate path: the old string is
        // released once the new one exists.
        .{ "AI_PROVIDER", "openai" },
    }) |pair| try applyConfigValue(allocator, &file_config, pair[0], pair[1]);
    try std.testing.expectEqualStrings("openai", file_config.provider.?);
    try std.testing.expectEqualStrings("https://example.test/v1", file_config.base_url.?);
}

test "config values are cleaned up and replaced atomically under allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkApplyAllocationFailures, .{});

    const a = std.testing.allocator;
    var slot: ?[]u8 = try a.dupe(u8, "old");
    defer if (slot) |value| a.free(value);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, setString(failing.allocator(), &slot, "new"));
    try std.testing.expectEqualStrings("old", slot.?);
}

test "Codex options resolve from environment and file, or remain absent" {
    const a = std.testing.allocator;
    var env = try testEnv(a, &.{.{ "AI_REASONING_EFFORT", "high" }});
    defer env.deinit();
    var file = try testFile(a, &.{
        .{ "AI_PROVIDER", "codex" },
        .{ "AI_REASONING_EFFORT", "low" },
        .{ "AI_SERVICE_TIER", "fast" },
    });
    defer file.deinit(a);
    const config = try resolve(a, &file, &env);
    defer config.deinit();
    try std.testing.expectEqualStrings("high", config.reasoning_effort.?);
    try std.testing.expectEqualStrings("fast", config.service_tier.?);
    var empty_env = try testEnv(a, &.{.{ "AI_SERVICE_TIER", "" }});
    defer empty_env.deinit();
    var empty_file = try testFile(a, &.{.{ "AI_REASONING_EFFORT", "" }});
    defer empty_file.deinit(a);
    const empty = try resolve(a, &empty_file, &empty_env);
    defer empty.deinit();
    try std.testing.expect(empty.reasoning_effort == null);
    try std.testing.expect(empty.service_tier == null);
}

test "thinking follows the preset unless it is asked for" {
    const a = std.testing.allocator;
    // A preset that documents the member asks for thinking by default; the
    // OpenAI API and the Codex backend do not define it at all.
    const presets = [_]struct { provider: []const u8, expected: ThinkingMode }{
        .{ .provider = "openai", .expected = .omit },
        .{ .provider = "codex", .expected = .omit },
        .{ .provider = "deepseek", .expected = .enabled },
        .{ .provider = "openai-compatible", .expected = .enabled },
    };
    for (presets) |preset| {
        var env = try testEnv(a, &.{
            .{ "AI_PROVIDER", preset.provider },
            .{ "AI_URL", "https://example.test/v1" },
            .{ "AI_MODEL", "test-model" },
        });
        defer env.deinit();
        var file = ConfigFile{};
        defer file.deinit(a);
        const config = try resolve(a, &file, &env);
        defer config.deinit();
        try std.testing.expectEqual(preset.expected, config.thinking);
    }

    // Nothing selected at all is the historical OpenAI default, which sends no
    // member it does not define.
    var bare_env = try testEnv(a, &.{});
    defer bare_env.deinit();
    var bare_file = ConfigFile{};
    defer bare_file.deinit(a);
    const bare = try resolve(a, &bare_file, &bare_env);
    defer bare.deinit();
    try std.testing.expectEqual(ThinkingMode.omit, bare.thinking);
}

test "an explicit thinking value wins over the preset and is validated" {
    const a = std.testing.allocator;
    const cases = [_]struct { asked: []const u8, expected: ThinkingMode }{
        .{ .asked = "enabled", .expected = .enabled },
        .{ .asked = "on", .expected = .enabled },
        .{ .asked = "disabled", .expected = .disabled },
        .{ .asked = "off", .expected = .disabled },
        .{ .asked = "omit", .expected = .omit },
    };
    for (cases) |case| {
        // An explicit value is honoured even where the preset would say no: the
        // setting describes the endpoint the user actually reaches.
        var env = try testEnv(a, &.{
            .{ "AI_PROVIDER", "openai" },
            .{ "AI_THINKING", case.asked },
        });
        defer env.deinit();
        var file = ConfigFile{};
        defer file.deinit(a);
        const config = try resolve(a, &file, &env);
        defer config.deinit();
        try std.testing.expectEqual(case.expected, config.thinking);
        // The environment also overrides the config file.
        var overridden_env = try testEnv(a, &.{.{ "AI_PROVIDER", "deepseek" }});
        defer overridden_env.deinit();
        var overridden_file = try testFile(a, &.{.{ "AI_THINKING", case.asked }});
        defer overridden_file.deinit(a);
        const overridden = try resolve(a, &overridden_file, &overridden_env);
        defer overridden.deinit();
        try std.testing.expectEqual(case.expected, overridden.thinking);
    }

    // A blank setting is no setting: the preset decides.
    var blank_env = try testEnv(a, &.{ .{ "AI_PROVIDER", "deepseek" }, .{ "AI_THINKING", "" } });
    defer blank_env.deinit();
    var blank_file = ConfigFile{};
    defer blank_file.deinit(a);
    const blank = try resolve(a, &blank_file, &blank_env);
    defer blank.deinit();
    try std.testing.expectEqual(ThinkingMode.enabled, blank.thinking);

    // An unknown spelling is a startup error rather than a silent default.
    var invalid_env = try testEnv(a, &.{.{ "AI_THINKING", "maybe" }});
    defer invalid_env.deinit();
    var invalid_file = ConfigFile{};
    defer invalid_file.deinit(a);
    try std.testing.expectError(error.InvalidThinking, resolve(a, &invalid_file, &invalid_env));
}

fn checkCacheAllocationFailures(allocator: std.mem.Allocator) !void {
    var env = try testEnv(allocator, &.{.{ "AI_PROMPT_CACHE_RETENTION", "24h" }});
    defer env.deinit();
    var file = try testFile(allocator, &.{.{ "AI_PROMPT_CACHE_RETENTION", "in_memory" }});
    defer file.deinit(allocator);
    const config = try resolve(allocator, &file, &env);
    defer config.deinit();
    try std.testing.expectEqualStrings("24h", config.prompt_cache_retention.?);
}

test "prompt cache environment precedence and allocation cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkCacheAllocationFailures, .{});
}

test "prompt cache file values, blanks and invalid retention" {
    const a = std.testing.allocator;
    var env = try testEnv(a, &.{});
    defer env.deinit();
    for ([_][]const u8{ "in_memory", "24h", "" }) |retention| {
        var file = try testFile(a, &.{.{ "AI_PROMPT_CACHE_RETENTION", retention }});
        defer file.deinit(a);
        const config = try resolve(a, &file, &env);
        defer config.deinit();
        if (retention.len == 0) {
            try std.testing.expect(config.prompt_cache_retention == null);
        } else try std.testing.expectEqualStrings(retention, config.prompt_cache_retention.?);
    }
    for ([_][]const u8{ "1h", "24H", " in_memory" }) |invalid| {
        var file = try testFile(a, &.{.{ "AI_PROMPT_CACHE_RETENTION", invalid }});
        defer file.deinit(a);
        try std.testing.expectError(error.InvalidPromptCacheRetention, resolve(a, &file, &env));
        var invalid_env = try testEnv(a, &.{.{ "AI_PROMPT_CACHE_RETENTION", invalid }});
        defer invalid_env.deinit();
        var empty_file = ConfigFile{};
        defer empty_file.deinit(a);
        try std.testing.expectError(error.InvalidPromptCacheRetention, resolve(a, &empty_file, &invalid_env));
    }
    var blank_env = try testEnv(a, &.{.{ "AI_PROMPT_CACHE_RETENTION", "" }});
    defer blank_env.deinit();
    var blank_file = ConfigFile{};
    defer blank_file.deinit(a);
    const blank = try resolve(a, &blank_file, &blank_env);
    defer blank.deinit();
    try std.testing.expect(blank.prompt_cache_retention == null);
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
    try std.testing.expect(config.prompt_cache_retention == null);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", config.base_url);
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
    try std.testing.expectEqualStrings("", config.api_key);
    try std.testing.expectEqual(@as(u32, 8192), config.max_tokens);
}

test "removed presentation, compaction, memory and prompt-cache-key settings are ignored" {
    const allocator = std.testing.allocator;
    const pairs = &[_][2][]const u8{
        .{ "AI_MARKDOWN", "false" },
        .{ "AI_COMPACT_KEEP", "1" },
        .{ "AI_MEMORY", "false" },
        .{ "AI_MEMORY_AUTO", "false" },
        .{ "AI_MAX_ITERATIONS", "5" },
        .{ "AI_PROMPT_CACHE_KEY", "project" },
    };
    var env = try testEnv(allocator, pairs);
    defer env.deinit();
    var file_config = try testFile(allocator, pairs);
    defer file_config.deinit(allocator);
    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();
    try std.testing.expectEqual(@as(u32, 8192), config.max_tokens);
    try std.testing.expect(!@hasField(Config, "markdown"));
    try std.testing.expect(!@hasField(Config, "compact_keep"));
    try std.testing.expect(!@hasField(Config, "memory"));
    try std.testing.expect(!@hasField(Config, "memory_auto"));
    try std.testing.expect(!@hasField(Config, "max_iterations"));
    try std.testing.expect(!@hasField(Config, "prompt_cache_key"));
}

test "debug tracing is a switch the file and the environment can both set" {
    const allocator = std.testing.allocator;
    // Off unless asked for: nothing is recorded by accident.
    var env = try testEnv(allocator, &.{});
    defer env.deinit();
    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);
    const quiet = try resolve(allocator, &file_config, &env);
    defer quiet.deinit();
    try std.testing.expect(!quiet.debug);

    // Any value but the spellings of "no" turns it on, in the file...
    var on_text = try testFile(allocator, &.{.{ "AI_DEBUG", "1" }});
    defer on_text.deinit(allocator);
    const from_file = try resolve(allocator, &on_text, &env);
    defer from_file.deinit();
    try std.testing.expect(from_file.debug);

    // ...and in the environment, which wins over the file either way.
    var off_env = try testEnv(allocator, &.{.{ "AI_DEBUG", "off" }});
    defer off_env.deinit();
    var on_file = try testFile(allocator, &.{.{ "AI_DEBUG", "1" }});
    defer on_file.deinit(allocator);
    const off = try resolve(allocator, &on_file, &off_env);
    defer off.deinit();
    try std.testing.expect(!off.debug);
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

test "compatible provider takes its endpoint and model from the user" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "AI_PROVIDER", "openai-compatible" },
        .{ "AI_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1/" },
        .{ "AI_MODEL", "qwen-plus" },
        .{ "AI_KEY", "sk-bailian" },
    });
    defer env.deinit();

    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, Provider.openai_compatible), config.provider);
    try std.testing.expectEqualStrings("https://dashscope.aliyuncs.com/compatible-mode/v1", config.base_url);
    try std.testing.expectEqualStrings("qwen-plus", config.model);
    try std.testing.expectEqualStrings("sk-bailian", config.api_key);
}

test "compatible provider reads the endpoint from the config file too" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_PROVIDER", "compatible" }});
    defer env.deinit();

    var file_config = try testFile(allocator, &.{
        .{ "AI_URL", "https://api.moonshot.cn/v1" },
        .{ "AI_MODEL", "kimi-k2" },
        .{ "AI_KEY", "sk-file" },
    });
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(?Provider, Provider.openai_compatible), config.provider);
    try std.testing.expectEqualStrings("https://api.moonshot.cn/v1", config.base_url);
    try std.testing.expectEqualStrings("kimi-k2", config.model);
    try std.testing.expectEqualStrings("sk-file", config.api_key);
}

test "compatible provider reports the setting it still needs" {
    const allocator = std.testing.allocator;

    {
        var env = try testEnv(allocator, &.{
            .{ "AI_PROVIDER", "openai-compatible" },
            .{ "AI_MODEL", "qwen-plus" },
        });
        defer env.deinit();
        var file_config = ConfigFile{};
        defer file_config.deinit(allocator);
        try std.testing.expectError(error.MissingProviderUrl, resolve(allocator, &file_config, &env));
    }

    {
        var env = try testEnv(allocator, &.{
            .{ "AI_PROVIDER", "openai-compatible" },
            .{ "AI_URL", "https://dashscope.aliyuncs.com/compatible-mode/v1" },
        });
        defer env.deinit();
        var file_config = ConfigFile{};
        defer file_config.deinit(allocator);
        try std.testing.expectError(error.MissingProviderModel, resolve(allocator, &file_config, &env));
    }

    // A blank value is as absent as an unset one; it must not be sent as the
    // endpoint.
    {
        var env = try testEnv(allocator, &.{.{ "AI_PROVIDER", "openai-compatible" }});
        defer env.deinit();
        var file_config = try testFile(allocator, &.{
            .{ "AI_URL", "" },
            .{ "AI_MODEL", "qwen-plus" },
        });
        defer file_config.deinit(allocator);
        try std.testing.expectError(error.MissingProviderUrl, resolve(allocator, &file_config, &env));
    }
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

test "max tokens prefer the environment" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{.{ "AI_MAX_TOKENS", "1234" }});
    defer env.deinit();

    var file_config = try testFile(allocator, &.{
        .{ "AI_MAX_TOKENS", "77" },
    });
    defer file_config.deinit(allocator);

    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 1234), config.max_tokens);
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
        .{ "OPENAI_BASE_URL", "https://obsolete.test" },
        .{ "OPENAI_MODEL", "obsolete-model" },
        .{ "OPENAI_MAX_TOKENS", "1" },
    });
    defer env.deinit();
    var file_config = ConfigFile{};
    defer file_config.deinit(allocator);
    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();
    try std.testing.expectEqualStrings("https://example.test/v1", config.base_url);
    try std.testing.expectEqualStrings("current-model", config.model);
    try std.testing.expectEqual(@as(u32, 1024), config.max_tokens);
}

test "obsolete config names do not populate current settings" {
    const allocator = std.testing.allocator;
    var file_config = try testFile(allocator, &.{
        .{ "PROVIDER", "deepseek" },
        .{ "OPENAI_API_KEY", "old-key" },
        .{ "OPENAI_BASE_URL", "https://obsolete.test" },
        .{ "OPENAI_MODEL", "old-model" },
        .{ "OPENAI_MAX_TOKENS", "1" },
    });
    defer file_config.deinit(allocator);
    try std.testing.expect(file_config.provider == null);
    try std.testing.expect(file_config.api_key == null);
    try std.testing.expect(file_config.base_url == null);
    try std.testing.expect(file_config.model == null);
    try std.testing.expect(file_config.max_tokens == null);
}

test "obsolete environment settings cannot override config values" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator, &.{
        .{ "OPENAI_BASE_URL", "https://obsolete.test" },
        .{ "OPENAI_MODEL", "old-model" },
        .{ "OPENAI_MAX_TOKENS", "1" },
    });
    defer env.deinit();
    var file_config = try testFile(allocator, &.{
        .{ "AI_URL", "https://current.test/v1" },
        .{ "AI_MODEL", "current-model" },
        .{ "AI_MAX_TOKENS", "2048" },
    });
    defer file_config.deinit(allocator);
    const config = try resolve(allocator, &file_config, &env);
    defer config.deinit();
    try std.testing.expectEqualStrings("https://current.test/v1", config.base_url);
    try std.testing.expectEqualStrings("current-model", config.model);
    try std.testing.expectEqual(@as(u32, 2048), config.max_tokens);
}
