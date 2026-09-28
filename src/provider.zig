const std = @import("std");

/// Defaults supplied by a built-in provider preset.
///
/// A preset only fills in values that were not set explicitly; `config.zig`
/// owns the precedence rules. Note that the `OPENAI_*` environment variable
/// names are the legacy spelling of "the default endpoint" rather than a
/// naming convention for new providers to extend.
pub const Spec = struct {
    /// Sent alongside "/chat/completions", so it must not end in a slash.
    base_url: []const u8,
    model: []const u8,
    /// Environment variable conventionally holding this provider's API key.
    api_key_env: []const u8,
};

/// Declaration order is autodetection order: when nothing selects a provider,
/// `config.zig` takes the first one, in this order, whose `api_key_env` the
/// environment exports. `openai` has to stay first — it is the historical
/// default, so a shell that already exports `OPENAI_API_KEY` keeps resolving
/// to it.
pub const Provider = enum {
    openai,
    deepseek,

    /// Case-insensitive lookup. Returns null when the name is unknown or blank.
    pub fn fromName(name: []const u8) ?Provider {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0) return null;
        for (std.enums.values(Provider)) |candidate| {
            if (std.ascii.eqlIgnoreCase(trimmed, @tagName(candidate))) return candidate;
        }
        return null;
    }

    pub fn spec(self: Provider) Spec {
        return switch (self) {
            .openai => .{
                .base_url = "https://api.openai.com/v1",
                .model = "gpt-4o-mini",
                .api_key_env = "OPENAI_API_KEY",
            },
            .deepseek => .{
                .base_url = "https://api.deepseek.com",
                .model = "deepseek-flash",
                .api_key_env = "DEEPSEEK_API_KEY",
            },
        };
    }

    /// Valid names in declaration order, for user-facing messages.
    pub fn names() []const []const u8 {
        const out = comptime blk: {
            const tags = std.enums.values(Provider);
            var result: [tags.len][]const u8 = undefined;
            for (tags, 0..) |tag, i| result[i] = @tagName(tag);
            break :blk result;
        };
        return &out;
    }
};

test "provider names are matched case insensitively" {
    try std.testing.expectEqual(Provider.deepseek, Provider.fromName("deepseek").?);
    try std.testing.expectEqual(Provider.deepseek, Provider.fromName("DeepSeek").?);
    try std.testing.expectEqual(Provider.deepseek, Provider.fromName("  DEEPSEEK  ").?);
    try std.testing.expectEqual(Provider.openai, Provider.fromName("OpenAI").?);
}

test "unknown and blank provider names are rejected" {
    try std.testing.expect(Provider.fromName("deepsek") == null);
    try std.testing.expect(Provider.fromName("") == null);
    try std.testing.expect(Provider.fromName("   ") == null);
}

test "provider specs" {
    const deepseek = Provider.deepseek.spec();
    try std.testing.expectEqualStrings("https://api.deepseek.com", deepseek.base_url);
    try std.testing.expectEqualStrings("deepseek-flash", deepseek.model);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", deepseek.api_key_env);

    // The openai preset must stay byte-identical to the built-in defaults so
    // that selecting it is a no-op.
    const openai = Provider.openai.spec();
    try std.testing.expectEqualStrings("https://api.openai.com/v1", openai.base_url);
    try std.testing.expectEqualStrings("gpt-4o-mini", openai.model);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", openai.api_key_env);
}

test "every provider is listed once in names" {
    const names = Provider.names();
    try std.testing.expectEqual(@typeInfo(Provider).@"enum".fields.len, names.len);
    for (names) |name| {
        try std.testing.expect(Provider.fromName(name) != null);
    }
}
