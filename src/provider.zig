const std = @import("std");

/// Defaults supplied by a built-in provider preset.
///
/// A preset only fills in values that were not set explicitly; `config.zig`
/// owns the precedence rules. Shared settings use the `AI_` prefix.
pub const Spec = struct {
    /// Sent alongside "/responses", so it must not end in a slash.
    base_url: []const u8,
    model: []const u8,
    /// Environment variable conventionally holding this provider's API key.
    api_key_env: []const u8,
    /// Whether exporting `api_key_env` alone may select this provider.
    ///
    /// A preset for a vendor without a known host keys off `AI_KEY`, which
    /// names no endpoint, so autodetecting it would move a generic key onto a
    /// URL the user never chose.
    autodetect: bool = true,
};

/// Declaration order is autodetection order: when nothing selects a provider,
/// `config.zig` takes the first one, in this order, whose `api_key_env` the
/// environment exports. `openai` has to stay first — it is the historical
/// default, so a shell that already exports `OPENAI_API_KEY` keeps resolving
/// to it.
pub const Provider = enum {
    openai,
    deepseek,
    codex,
    /// Any endpoint implementing the OpenAI Responses API — Alibaba Cloud
    /// Model Studio (百炼), Moonshot, Zhipu, a local vLLM server, and so on.
    /// The vendor, and therefore the base URL, is unknown here: the preset
    /// supplies nothing but the generic `AI_KEY` variable, so `AI_URL` and
    /// `AI_MODEL` are required and a missing one is a startup error.
    openai_compatible,

    /// The spelling a user writes in `AI_PROVIDER`: the tag name, except where
    /// the user-facing name reads better with a hyphen.
    pub fn name(self: Provider) []const u8 {
        return switch (self) {
            .openai_compatible => "openai-compatible",
            else => @tagName(self),
        };
    }

    /// Further spellings accepted by `fromName`. They are deliberately absent
    /// from `names`, which stays the canonical list.
    fn aliases(self: Provider) []const []const u8 {
        return switch (self) {
            .openai_compatible => &.{ "openai_compatible", "compatible" },
            else => &.{},
        };
    }

    /// Case-insensitive lookup. Returns null when the name is unknown or blank.
    pub fn fromName(written: []const u8) ?Provider {
        const trimmed = std.mem.trim(u8, written, " \t\r\n");
        if (trimmed.len == 0) return null;
        for (std.enums.values(Provider)) |candidate| {
            if (std.ascii.eqlIgnoreCase(trimmed, candidate.name())) return candidate;
            for (candidate.aliases()) |alias| {
                if (std.ascii.eqlIgnoreCase(trimmed, alias)) return candidate;
            }
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
            .codex => .{
                .base_url = @import("codex_auth.zig").base_url,
                .model = "gpt-5.4",
                .api_key_env = "ZAGENT_CODEX_UNUSED_API_KEY",
            },
            .deepseek => .{
                .base_url = "https://api.deepseek.com",
                .model = "deepseek-flash",
                .api_key_env = "DEEPSEEK_API_KEY",
            },
            .openai_compatible => .{
                // Filled in by the user; `config.zig` turns an empty value
                // into a startup error naming the setting that is missing.
                .base_url = "",
                .model = "",
                .api_key_env = "AI_KEY",
                .autodetect = false,
            },
        };
    }

    /// Valid names in declaration order, for user-facing messages.
    pub fn names() []const []const u8 {
        const out = comptime blk: {
            const tags = std.enums.values(Provider);
            var result: [tags.len][]const u8 = undefined;
            for (tags, 0..) |tag, i| result[i] = tag.name();
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
    try std.testing.expectEqual(Provider.openai_compatible, Provider.fromName("OpenAI-Compatible").?);
}

test "the compatible provider accepts its common spellings" {
    try std.testing.expectEqual(Provider.openai_compatible, Provider.fromName("openai-compatible").?);
    try std.testing.expectEqual(Provider.openai_compatible, Provider.fromName("openai_compatible").?);
    try std.testing.expectEqual(Provider.openai_compatible, Provider.fromName("compatible").?);
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

    // No vendor is assumed: the endpoint and model are the user's to supply,
    // and the generic key variable is the only one it can use.
    const compatible = Provider.openai_compatible.spec();
    try std.testing.expectEqualStrings("", compatible.base_url);
    try std.testing.expectEqualStrings("", compatible.model);
    try std.testing.expectEqualStrings("AI_KEY", compatible.api_key_env);
    try std.testing.expect(!compatible.autodetect);
}

test "every provider is listed once in names" {
    const names = Provider.names();
    try std.testing.expectEqual(@typeInfo(Provider).@"enum".field_names.len, names.len);
    for (names) |name| {
        try std.testing.expect(Provider.fromName(name) != null);
    }
    // The hyphenated spelling is what a user is told to write.
    try std.testing.expectEqualStrings("openai-compatible", names[names.len - 1]);
}
