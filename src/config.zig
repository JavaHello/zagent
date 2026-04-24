const std = @import("std");

const ConfigFile = struct {
    api_key: ?[]u8 = null,
    base_url: ?[]u8 = null,
    model: ?[]u8 = null,
    max_tokens: ?u32 = null,

    pub fn deinit(self: *ConfigFile, allocator: std.mem.Allocator) void {
        if (self.api_key) |value| allocator.free(value);
        if (self.base_url) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        self.* = .{};
    }
};

fn envVarOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

fn configBasePath(allocator: std.mem.Allocator) !?[]u8 {
    if (try envVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg_dir| {
        defer allocator.free(xdg_dir);
        return try std.fmt.allocPrint(allocator, "{s}/zagent", .{xdg_dir});
    }
    if (try envVarOwned(allocator, "HOME")) |home_dir| {
        defer allocator.free(home_dir);
        return try std.fmt.allocPrint(allocator, "{s}/.config/zagent", .{home_dir});
    }
    return null;
}

fn openConfigFile(allocator: std.mem.Allocator) !?std.fs.File {
    const base_path = (try configBasePath(allocator)) orelse return null;
    defer allocator.free(base_path);

    const cwd = std.fs.cwd();
    if (cwd.openFile(base_path, .{})) |file| {
        return file;
    } else |err| switch (err) {
        error.FileNotFound => return null,
        error.IsDir => {
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{base_path});
            defer allocator.free(config_path);
            return cwd.openFile(config_path, .{}) catch |open_err| switch (open_err) {
                error.FileNotFound => return null,
                else => return open_err,
            };
        },
        else => return err,
    }
}

fn setString(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, value);
}

fn applyConfigValue(allocator: std.mem.Allocator, config: *ConfigFile, key: []const u8, value: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(key, "OPENAI_API_KEY") or std.ascii.eqlIgnoreCase(key, "AI_KEY")) {
        try setString(allocator, &config.api_key, value);
    } else if (std.ascii.eqlIgnoreCase(key, "OPENAI_BASE_URL") or std.ascii.eqlIgnoreCase(key, "AI_URL")) {
        try setString(allocator, &config.base_url, value);
    } else if (std.ascii.eqlIgnoreCase(key, "OPENAI_MODEL") or std.ascii.eqlIgnoreCase(key, "AI_MODEL")) {
        try setString(allocator, &config.model, value);
    } else if (std.ascii.eqlIgnoreCase(key, "OPENAI_MAX_TOKENS") or std.ascii.eqlIgnoreCase(key, "AI_MAX_TOKENS")) {
        config.max_tokens = std.fmt.parseInt(u32, value, 10) catch 4096;
    }
}

fn loadConfigFile(allocator: std.mem.Allocator) !ConfigFile {
    var config = ConfigFile{};
    var file = (try openConfigFile(allocator)) orelse return config;
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 64 * 1024);
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

pub const Config = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    max_tokens: u32,

    pub fn load(allocator: std.mem.Allocator) !Config {
        var file_config = try loadConfigFile(allocator);
        defer file_config.deinit(allocator);

        var api_key = takeOwnedString(&file_config.api_key) orelse try allocator.dupe(u8, "");
        errdefer allocator.free(api_key);

        var base_url = takeOwnedString(&file_config.base_url) orelse try allocator.dupe(u8, "https://api.openai.com/v1");
        errdefer allocator.free(base_url);

        var model = takeOwnedString(&file_config.model) orelse try allocator.dupe(u8, "gpt-4o-mini");
        errdefer allocator.free(model);

        var max_tokens: u32 = file_config.max_tokens orelse 4096;

        if (try envVarOwned(allocator, "OPENAI_API_KEY")) |env_api_key| {
            allocator.free(api_key);
            api_key = env_api_key;
        }

        if (try envVarOwned(allocator, "OPENAI_BASE_URL")) |env_base_url| {
            allocator.free(base_url);
            base_url = env_base_url;
        }

        if (try envVarOwned(allocator, "OPENAI_MODEL")) |env_model| {
            allocator.free(model);
            model = env_model;
        }

        if (try envVarOwned(allocator, "OPENAI_MAX_TOKENS")) |max_tokens_str| {
            defer allocator.free(max_tokens_str);
            max_tokens = std.fmt.parseInt(u32, max_tokens_str, 10) catch 4096;
        }

        return .{
            .allocator = allocator,
            .api_key = api_key,
            .base_url = base_url,
            .model = model,
            .max_tokens = max_tokens,
        };
    }

    pub fn deinit(self: Config) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        self.allocator.free(self.model);
    }
};

test "config defaults" {
    const allocator = std.testing.allocator;
    const config = try Config.load(allocator);
    defer config.deinit();

    const expected_model = try envVarOwned(allocator, "OPENAI_MODEL") orelse try allocator.dupe(u8, "gpt-4o-mini");
    defer allocator.free(expected_model);

    const expected_max_tokens: u32 = blk: {
        if (try envVarOwned(allocator, "OPENAI_MAX_TOKENS")) |value| {
            defer allocator.free(value);
            break :blk std.fmt.parseInt(u32, value, 10) catch 4096;
        }
        break :blk 4096;
    };

    try std.testing.expectEqualStrings(expected_model, config.model);
    try std.testing.expect(config.max_tokens == expected_max_tokens);
}
