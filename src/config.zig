const std = @import("std");

pub const Config = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    max_tokens: u32,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const api_key = std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch
            try allocator.dupe(u8, "");
        errdefer allocator.free(api_key);

        const base_url = std.process.getEnvVarOwned(allocator, "OPENAI_BASE_URL") catch
            try allocator.dupe(u8, "https://api.openai.com/v1");
        errdefer allocator.free(base_url);

        const model = std.process.getEnvVarOwned(allocator, "OPENAI_MODEL") catch
            try allocator.dupe(u8, "gpt-4o-mini");
        errdefer allocator.free(model);

        const max_tokens_str = std.process.getEnvVarOwned(allocator, "OPENAI_MAX_TOKENS") catch
            try allocator.dupe(u8, "4096");
        defer allocator.free(max_tokens_str);
        const max_tokens = std.fmt.parseInt(u32, max_tokens_str, 10) catch 4096;

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
    const config = try Config.load(std.testing.allocator);
    defer config.deinit();
    try std.testing.expectEqualStrings("gpt-4o-mini", config.model);
    try std.testing.expect(config.max_tokens == 4096);
}
