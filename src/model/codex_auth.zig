//! ChatGPT device authorization, without a Codex executable dependency.
const std = @import("std");
const paths = @import("../util/paths.zig");
pub const base_url = "https://chatgpt.com/backend-api/codex";

/// The Codex CLI version this client reports to the backend when
/// `AI_CODEX_CLIENT_VERSION` sets nothing else.
///
/// `/models` requires the parameter and answers only with the models whose own
/// `minimal_client_version` such a client satisfies. A stale value here does
/// not fail: the list quietly shrinks — at 0.101.0 it held one hidden
/// auto-review model — and a name picked from it is one the backend then
/// refuses with `model_not_in_accessible_catalog`. Bump this when the installed
/// CLI moves on (`codex --version`); it only affects model discovery, because
/// the request itself is sent without it.
pub const client_version = "0.172.0";
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
    if (paths.envValue(env, "AI_CODEX_AUTH_FILE")) |configured| return try a.dupe(u8, configured);
    // Beside the config file, so the credentials belong to the same
    // installation the rest of the Codex settings came from.
    return (try paths.configPath(a, env, "zagent/codex-auth.json")) orelse error.HomeNotSet;
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
/// A temporary path no other writer can be using: two turns that refresh at
/// the same moment each save to their own file, and one left behind by a crash
/// never stops the next save. Exclusive creation still keeps the write off a
/// pre-existing path.
var save_sequence: std.atomic.Value(u64) = .init(0);
fn temporaryPath(a: std.mem.Allocator, io: std.Io, auth_path: []const u8) ![]u8 {
    const stamp = std.Io.Timestamp.now(io, .real);
    const sequence = save_sequence.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(a, "{s}.{d}.{d}.tmp", .{ auth_path, stamp.nanoseconds, sequence });
}
fn save(a: std.mem.Allocator, io: std.Io, auth_path: []const u8, tokens: Tokens) !void {
    const data = try std.json.Stringify.valueAlloc(a, tokens, .{});
    defer a.free(data);
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(auth_path)) |parent| try cwd.createDirPath(io, parent);
    const temporary = try temporaryPath(a, io, auth_path);
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
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .redirect_behavior = .unhandled,
        .payload = data,
        .response_writer = &out.writer,
    });
    return .{ .status = result.status, .body = try a.dupe(u8, out.written()) };
}
// The authorization-code exchange uses OAuth's form encoding.
fn exchangeCode(a: std.mem.Allocator, http: *std.http.Client, code: []const u8, verifier: []const u8) !Reply {
    const pairs = [_][2][]const u8{
        .{ "grant_type", "authorization_code" },               .{ "client_id", client_id },
        .{ "redirect_uri", issuer ++ "/deviceauth/callback" }, .{ "code", code },
        .{ "code_verifier", verifier },
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
        .location = .{ .url = issuer ++ "/oauth/token" },
        .method = .POST,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .redirect_behavior = .unhandled,
        .payload = form.written(),
        .response_writer = &out.writer,
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
        const exchange = try exchangeCode(a, &http, try field(grant.value, "authorization_code"), try field(grant.value, "code_verifier"));
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
/// Read what the file holds, without contacting the server.
fn read(a: std.mem.Allocator, io: std.Io, auth_path: []const u8) !std.json.Parsed(Tokens) {
    const data = std.Io.Dir.cwd().readFileAlloc(io, auth_path, a, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.CodexLoginRequired,
        else => return err,
    };
    defer a.free(data);
    return std.json.parseFromSlice(Tokens, a, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

/// When the access token stops working, from the token itself. A token whose
/// claim cannot be read is treated as expired.
fn expiresAt(a: std.mem.Allocator, access_token: []const u8) ?i64 {
    const claims = jwt(a, access_token) catch return null;
    defer claims.deinit();
    if (claims.value != .object) return null;
    const expiration = claims.value.object.get("exp") orelse return null;
    return if (expiration == .integer) expiration.integer else null;
}

/// The account a token belongs to, which the Codex backend wants beside the
/// token on every request.
fn accountOf(a: std.mem.Allocator, access_token: []const u8) ![]u8 {
    const claims = try jwt(a, access_token);
    defer claims.deinit();
    if (claims.value != .object) return error.InvalidToken;
    const auth = claims.value.object.get("https://api.openai.com/auth") orelse return error.InvalidToken;
    return a.dupe(u8, try field(auth, "chatgpt_account_id"));
}

fn wrap(a: std.mem.Allocator, tokens: std.json.Parsed(Tokens)) !Credentials {
    errdefer tokens.deinit();
    return .{ .parsed = tokens, .account_id = try accountOf(a, tokens.value.access_token) };
}

/// Exchange the refresh token for a new pair, and save it.
///
/// `error.RefreshRejected` is the server refusing the grant itself, which no
/// further attempt with the same token can repair.
fn refreshTokens(a: std.mem.Allocator, io: std.Io, auth_path: []const u8, current: Tokens) !std.json.Parsed(Tokens) {
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();
    const reply = try post(a, &http, issuer ++ "/oauth/token", .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = current.refresh_token,
    });
    defer a.free(reply.body);
    if (reply.status != .ok) return error.RefreshRejected;
    const value = try std.json.parseFromSlice(std.json.Value, a, reply.body, .{});
    defer value.deinit();
    const updated = Tokens{
        .access_token = try field(value.value, "access_token"),
        // A rotated grant comes with a new refresh token; one that does not
        // still leaves the old token as the one to use next time.
        .refresh_token = field(value.value, "refresh_token") catch current.refresh_token,
        .id_token = field(value.value, "id_token") catch current.id_token,
    };
    try save(a, io, auth_path, updated);
    const encoded = try std.json.Stringify.valueAlloc(a, updated, .{});
    defer a.free(encoded);
    return std.json.parseFromSlice(Tokens, a, encoded, .{ .allocate = .alloc_always });
}

/// One exchange at a time in this process.
///
/// A sub-agent holds its own credentials but shares the file with its caller,
/// and a refresh token can be spent only once: two turns refreshing at the same
/// moment would retire each other's. Whoever waits finds the new token in the
/// file instead of spending the old one.
var refresh_lock: std.Io.Mutex = .init;

/// Whether the file's token has to be exchanged before it can be sent.
///
/// A token a request was just refused with is no longer worth sending, whatever
/// its clock says; otherwise the token is refreshed a minute early, so that a
/// request starting now cannot expire while it is in flight.
fn needsRefresh(a: std.mem.Allocator, io: std.Io, access_token: []const u8, rejected: ?[]const u8) bool {
    if (rejected) |refused| return std.mem.eql(u8, access_token, refused);
    const expiration = expiresAt(a, access_token) orelse return true;
    return expiration <= std.Io.Timestamp.now(io, .real).toSeconds() + 60;
}

/// The credentials to use, refreshed only when the file's own token cannot be
/// sent.
///
/// `rejected` is the token a request was just refused with: a different token
/// in the file was written after that request left, which is the refresh some
/// other turn — or another zagent — already made, and it is used as it is.
fn resolve(a: std.mem.Allocator, io: std.Io, auth_path: []const u8, rejected: ?[]const u8) !Credentials {
    refresh_lock.lockUncancelable(io);
    defer refresh_lock.unlock(io);

    const tokens = try read(a, io, auth_path);
    if (!needsRefresh(a, io, tokens.value.access_token, rejected)) return wrap(a, tokens);

    // Every path below owns the tokens it read and frees them exactly once:
    // `wrap` takes them over, and an error on the way out frees them here.
    const refreshed = refreshTokens(a, io, auth_path, tokens.value) catch |err| {
        if (err != error.RefreshRejected) {
            tokens.deinit();
            return err;
        }
        // Another process of zagent may have won this same exchange: its token
        // is in the file a moment from now.
        const won = awaitAnotherRefresh(a, io, auth_path, tokens.value.access_token) catch |waited_err| {
            tokens.deinit();
            return waited_err;
        };
        tokens.deinit();
        return won;
    };
    tokens.deinit();
    return wrap(a, refreshed);
}

/// A refused exchange ends the sign-in unless a second client of the same file
/// won the same race: a token this request did not send is that client's
/// refresh, and using it costs nothing.
fn awaitAnotherRefresh(a: std.mem.Allocator, io: std.Io, auth_path: []const u8, sent: []const u8) !Credentials {
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        if (attempt > 0) io.sleep(.fromMilliseconds(150), .awake) catch {};
        const tokens = try read(a, io, auth_path);
        if (!std.mem.eql(u8, tokens.value.access_token, sent)) return wrap(a, tokens);
        tokens.deinit();
    }
    return error.CodexLoginRequired;
}

pub fn load(a: std.mem.Allocator, io: std.Io, auth_path: []const u8) !Credentials {
    return resolve(a, io, auth_path, null);
}

/// Replace an access token the backend has just rejected with a fresh one.
///
/// `rejected` is the token the failed request carried. A token the server
/// refuses while its clock still says it is valid usually means the same
/// sign-in was refreshed by another turn, so the file is read again before the
/// refresh token is spent: whoever refreshed it last has already written out
/// the token to use.
pub fn refresh(a: std.mem.Allocator, io: std.Io, auth_path: []const u8, rejected: []const u8) !Credentials {
    return resolve(a, io, auth_path, rejected);
}

pub fn logout(io: std.Io, auth_path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, auth_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "the account and its expiration are read from the access token" {
    const a = std.testing.allocator;
    const payload =
        \\{"exp":1700000000,"https://api.openai.com/auth":{"chatgpt_account_id":"acct_1"}}
    ;
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(payload.len));
    defer a.free(encoded);
    _ = encoder.encode(encoded, payload);
    const token = try std.fmt.allocPrint(a, "header.{s}.signature", .{encoded});
    defer a.free(token);

    try std.testing.expectEqual(@as(?i64, 1700000000), expiresAt(a, token));
    const account = try accountOf(a, token);
    defer a.free(account);
    try std.testing.expectEqualStrings("acct_1", account);

    // A token whose claims cannot be read is treated as expired, so it is
    // refreshed instead of being sent, and it belongs to no account.
    try std.testing.expectEqual(@as(?i64, null), expiresAt(a, "not-a-token"));
    try std.testing.expectError(error.InvalidToken, accountOf(a, "not-a-token"));
}

/// A signed-looking token that carries an expiration and an account, which is
/// all this module reads before it sends one.
fn testToken(a: std.mem.Allocator, expiration: i64) ![]u8 {
    const payload = try std.fmt.allocPrint(a, "{{\"exp\":{d},\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"acct_1\"}}}}", .{expiration});
    defer a.free(payload);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(payload.len));
    defer a.free(encoded);
    _ = encoder.encode(encoded, payload);
    return std.fmt.allocPrint(a, "header.{s}.signature", .{encoded});
}

/// A credential file of the shape `login` writes, in a directory of its own.
fn testAuthFile(a: std.mem.Allocator, expiration: i64) !struct { tmp: std.testing.TmpDir, path: []u8, access: []u8 } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const auth_path = try std.fs.path.join(a, &.{ directory, "codex-auth.json" });
    errdefer a.free(auth_path);
    const access = try testToken(a, expiration);
    errdefer a.free(access);
    const file = try std.Io.Dir.createFileAbsolute(std.testing.io, auth_path, .{ .permissions = .fromMode(0o600) });
    defer file.close(std.testing.io);
    const body = try std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt.1.test\",\"id_token\":\"\"}}", .{access});
    defer a.free(body);
    try file.writeStreamingAll(std.testing.io, body);
    return .{ .tmp = tmp, .path = auth_path, .access = access };
}

test "a token that is still good is used without an exchange" {
    const a = std.testing.allocator;
    const now = std.Io.Timestamp.now(std.testing.io, .real).toSeconds();
    var file = try testAuthFile(a, now + 3600);
    defer a.free(file.path);
    defer a.free(file.access);
    defer file.tmp.cleanup();

    const credentials = try load(a, std.testing.io, file.path);
    defer credentials.deinit(a);
    // The token the file holds is the one handed out: no exchange was made,
    // and the account the backend needs came with it.
    try std.testing.expectEqualStrings(file.access, credentials.parsed.value.access_token);
    try std.testing.expectEqualStrings("acct_1", credentials.account_id);

    // No credential file at all is a sign-in that has to be made, not a fault.
    const missing = try std.fs.path.join(a, &.{ std.fs.path.dirname(file.path).?, "absent.json" });
    defer a.free(missing);
    try std.testing.expectError(error.CodexLoginRequired, load(a, std.testing.io, missing));
}

test "a token is exchanged when its clock or the server says it is spent" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const good = try testToken(a, now + 3600);
    defer a.free(good);
    const spent = try testToken(a, now - 1);
    defer a.free(spent);

    // A token that has expired, or one whose expiration cannot be read, is
    // exchanged before it is sent.
    try std.testing.expect(needsRefresh(a, io, spent, null));
    try std.testing.expect(needsRefresh(a, io, "not-a-token", null));
    // So is one that is about to expire, rather than one that expires after
    // the request it is sent with.
    const nearly = try testToken(a, now + 30);
    defer a.free(nearly);
    try std.testing.expect(needsRefresh(a, io, nearly, null));
    try std.testing.expect(!needsRefresh(a, io, good, null));

    // A token a request was just refused with is exchanged whatever its clock
    // says; the same token in the file is that one, another is a refresh
    // someone else already made.
    try std.testing.expect(needsRefresh(a, io, good, good));
    try std.testing.expect(!needsRefresh(a, io, good, spent));
}

test "a refused exchange waits for the refresh another process already made" {
    const a = std.testing.allocator;
    const now = std.Io.Timestamp.now(std.testing.io, .real).toSeconds();
    var file = try testAuthFile(a, now + 3600);
    defer a.free(file.path);
    defer a.free(file.access);
    defer file.tmp.cleanup();

    // The file holds a token this request did not send, so it is another
    // writer's refresh: it is worth more than the refusal, and costs nothing.
    const stale = try testToken(a, now + 60);
    defer a.free(stale);
    const credentials = try awaitAnotherRefresh(a, std.testing.io, file.path, stale);
    defer credentials.deinit(a);
    try std.testing.expectEqualStrings(file.access, credentials.parsed.value.access_token);

    // The token the request sent is still the only one there is: the sign-in
    // itself is gone, which is the one thing waiting cannot fix.
    try std.testing.expectError(error.CodexLoginRequired, awaitAnotherRefresh(a, std.testing.io, file.path, file.access));
}
