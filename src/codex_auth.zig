//! ChatGPT device authorization, without a Codex executable dependency.
const std = @import("std");
pub const base_url = "https://chatgpt.com/backend-api/codex";
const issuer = "https://auth.openai.com";
const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const Tokens = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    id_token: []const u8 = "",
};
pub const Credentials = struct {
    parsed: std.json.Parsed(Tokens),
    account_id: []u8,
    pub fn deinit(self: Credentials, a: std.mem.Allocator) void {
        self.parsed.deinit();
        a.free(self.account_id);
    }
};
pub fn path(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const home = env.get("HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(a, "{s}/.config/zagent/codex-auth.json", .{home});
}
fn field(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidAuthResponse;
    const v = value.object.get(name) orelse return error.InvalidAuthResponse;
    if (v != .string or v.string.len == 0) return error.InvalidAuthResponse;
    return v.string;
}
fn jwt(a: std.mem.Allocator, token: []const u8) !std.json.Parsed(std.json.Value) {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next();
    const payload = parts.next() orelse return error.InvalidToken;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(payload));
    defer a.free(bytes);
    try decoder.decode(bytes, payload);
    return std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always });
}
fn save(a: std.mem.Allocator, io: std.Io, auth_path: []const u8, tokens: Tokens) !void {
    const data = try std.json.Stringify.valueAlloc(a, tokens, .{});
    defer a.free(data);
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(auth_path)) |parent| try cwd.createDirPath(io, parent);
    // Exclusive temporary creation avoids following a pre-existing symlink.
    const temporary = try std.fmt.allocPrint(a, "{s}.tmp", .{auth_path});
    defer a.free(temporary);
    const file = try cwd.createFile(io, temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    errdefer cwd.deleteFile(io, temporary) catch {};
    try file.writeStreamingAll(io, data);
    try cwd.rename(temporary, cwd, auth_path, io);
}
const Reply = struct {
    status: std.http.Status,
    body: []u8,
};
fn post(a: std.mem.Allocator, http: *std.http.Client, url: []const u8, payload: anytype) !Reply {
    const data = try std.json.Stringify.valueAlloc(a, payload, .{});
    defer a.free(data);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const result = try http.fetch(.{
        .location = .{ .url = url }, .method = .POST,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .redirect_behavior = .unhandled,
        .payload = data, .response_writer = &out.writer,
    });
    return .{ .status = result.status, .body = try a.dupe(u8, out.written()) };
}
// The authorization-code exchange uses OAuth's form encoding.
fn exchangeCode(a: std.mem.Allocator, http: *std.http.Client, code: []const u8, verifier: []const u8) !Reply {
    const pairs = [_][2][]const u8{
        .{ "grant_type", "authorization_code" }, .{ "client_id", client_id },
        .{ "redirect_uri", issuer ++ "/deviceauth/callback" },
        .{ "code", code }, .{ "code_verifier", verifier },
    };
    var form: std.Io.Writer.Allocating = .init(a);
    defer form.deinit();
    for (pairs, 0..) |pair, i| {
        if (i != 0) try form.writer.writeByte('&');
        try form.writer.writeAll(pair[0]);
        try form.writer.writeByte('=');
        for (pair[1]) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try form.writer.writeByte(c);
            } else {
                const hex = "0123456789ABCDEF";
                try form.writer.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] });
            }
        }
    }
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const result = try http.fetch(.{
        .location = .{ .url = issuer ++ "/oauth/token" }, .method = .POST,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .redirect_behavior = .unhandled,
        .payload = form.written(), .response_writer = &out.writer,
    });
    return .{ .status = result.status, .body = try a.dupe(u8, out.written()) };
}
pub fn login(a: std.mem.Allocator, io: std.Io, auth_path: []const u8) !void {
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();
    const start = try post(a, &http, issuer ++ "/api/accounts/deviceauth/usercode", .{ .client_id = client_id });
    defer a.free(start.body);
    if (start.status != .ok) return error.DeviceLoginUnavailable;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, start.body, .{});
    defer parsed.deinit();
    const id = try field(parsed.value, "device_auth_id");
    const code = field(parsed.value, "user_code") catch try field(parsed.value, "usercode");
    var seconds: i64 = 5;
    if (parsed.value.object.get("interval")) |v| {
        if (v == .string) seconds = std.fmt.parseInt(i64, v.string, 10) catch 5;
        if (v == .integer) seconds = v.integer;
    }
    seconds = std.math.clamp(seconds, 1, 60);
    const prompt = try std.fmt.allocPrint(a, "Sign in with ChatGPT\nOpen https://auth.openai.com/codex/device on any device.\nEnter code: {s}\nWaiting up to 15 minutes...\n", .{code});
    defer a.free(prompt);
    try std.Io.File.stderr().writeStreamingAll(io, prompt);
    var elapsed: i64 = 0;
    while (elapsed < 900) : (elapsed += seconds) {
        const poll = try post(a, &http, issuer ++ "/api/accounts/deviceauth/token", .{ .device_auth_id = id, .user_code = code });
        defer a.free(poll.body);
        if (poll.status == .forbidden or poll.status == .not_found) {
            try io.sleep(.fromMilliseconds(seconds * 1000), .awake);
            continue;
        }
        if (poll.status != .ok) return error.DeviceLoginFailed;
        const grant = try std.json.parseFromSlice(std.json.Value, a, poll.body, .{});
        defer grant.deinit();
        const exchange = try exchangeCode(a, &http,
            try field(grant.value, "authorization_code"),
            try field(grant.value, "code_verifier"));
        defer a.free(exchange.body);
        if (exchange.status != .ok) return error.TokenExchangeFailed;
        const tokens = try std.json.parseFromSlice(Tokens, a, exchange.body, .{ .ignore_unknown_fields = true });
        defer tokens.deinit();
        try save(a, io, auth_path, tokens.value);
        try std.Io.File.stderr().writeStreamingAll(io, "Signed in. Use AI_PROVIDER=codex.\n");
        return;
    }
    return error.DeviceLoginTimedOut;
}
pub fn load(a: std.mem.Allocator, io: std.Io, auth_path: []const u8) !Credentials {
    const data = std.Io.Dir.cwd().readFileAlloc(io, auth_path, a, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.CodexLoginRequired,
        else => return err,
    };
    defer a.free(data);
    var tokens = try std.json.parseFromSlice(Tokens, a, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer tokens.deinit();
    const claims = try jwt(a, tokens.value.access_token);
    defer claims.deinit();
    const expiration = if (claims.value == .object) claims.value.object.get("exp") else null;
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    if (expiration == null or expiration.? != .integer or expiration.?.integer <= now + 60) {
        var http: std.http.Client = .{ .allocator = a, .io = io };
        defer http.deinit();
        const refreshed = try post(a, &http, issuer ++ "/oauth/token", .{
            .grant_type = "refresh_token", .client_id = client_id, .refresh_token = tokens.value.refresh_token,
        });
        defer a.free(refreshed.body);
        if (refreshed.status != .ok) return error.CodexLoginRequired;
        const value = try std.json.parseFromSlice(std.json.Value, a, refreshed.body, .{});
        defer value.deinit();
        const updated = Tokens{
            .access_token = try field(value.value, "access_token"),
            .refresh_token = field(value.value, "refresh_token") catch tokens.value.refresh_token,
            .id_token = field(value.value, "id_token") catch tokens.value.id_token,
        };
        try save(a, io, auth_path, updated);
        const encoded = try std.json.Stringify.valueAlloc(a, updated, .{});
        defer a.free(encoded);
        const replacement = try std.json.parseFromSlice(Tokens, a, encoded, .{ .allocate = .alloc_always });
        tokens.deinit();
        tokens = replacement;
    }
    const account_claims = try jwt(a, tokens.value.access_token);
    defer account_claims.deinit();
    if (account_claims.value != .object) return error.InvalidToken;
    const auth = account_claims.value.object.get("https://api.openai.com/auth") orelse return error.InvalidToken;
    return .{ .parsed = tokens, .account_id = try a.dupe(u8, try field(auth, "chatgpt_account_id")) };
}
pub fn logout(io: std.Io, auth_path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, auth_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
