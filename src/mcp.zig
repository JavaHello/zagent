//! The MCP client: the servers zagent is configured to talk to, what they
//! offer, and how a call reaches them.
//!
//! A server is described in `mcp.json`, in the zagent config directory, and
//! connected to once at startup: its tools are listed, named so the model can
//! call them, and handed to the agent as extra function tools. `tools/call` on
//! one of those names comes back through here and is forwarded as it is.
//!
//! Two things about the protocol shape everything below. It is *stateless*: a
//! connection carries no session, every request declares the revision and the
//! client's capabilities in `_meta` (a revision this client calls modern). And
//! it is *new*: the servers in the wild were written for the revision before
//! it, which opened with an `initialize` handshake — so a connection finds out
//! which of the two it is talking to before it does anything else.

const std = @import("std");
const transport = @import("mcp_transport.zig");
const tools = @import("tools.zig");
const config = @import("config.zig");
// `text` is the name every other module imports this under, and also the name
// of half the values in this one; it is imported as what it is used for here.
const sanitize = @import("text.zig");
const style = @import("style.zig");

/// The revision this client speaks. It is the current one: no session, no
/// handshake, everything a request needs carried in the request.
pub const modern_protocol_version = "2026-07-28";

/// The revision it falls back to. 2025-06-18 is what the servers in the wild
/// were built against, and what the official SDKs have shipped for longest.
const legacy_protocol_version = "2025-06-18";

const client_name = "zagent";
const client_version = "0.0.0";

/// A probe is answered at once by a server that knows the method and refused at
/// once by one that does not, so it does not need the whole call timeout — and
/// a server that says nothing at all must not cost one either.
const probe_timeout_cap_ms = 5_000;

/// How long a request waits for its answer by default. Only the stdio
/// transport can honour it: `std.http` has no read timeout, so a Streamable
/// HTTP server that takes a request and says nothing holds the agent.
const default_timeout_ms = 60_000;

/// Every tool that comes from a server is named with this in front, so a call
/// can be told from a built-in one by its name alone.
pub const tool_prefix = "mcp__";

/// Longest function name an OpenAI-compatible endpoint accepts, in the
/// characters it accepts: letters, digits, `_` and `-`. Both are narrower than
/// what MCP allows a tool to be called, so a name is fitted to these.
const max_tool_name = 64;

/// Longest name `mcp.json` may give a server. The name becomes part of every
/// tool name from that server, which is already a tight budget.
const max_server_name = 32;

/// Most tools read from one server, and most pages of them. A server that
/// lists without end must not be able to fill memory.
const max_tools_per_server = 256;
const max_pages = 16;

/// Longest `instructions` text kept from one server.
const max_instructions_bytes = 2_000;

/// Longest `mcp.json` this client reads.
const max_config_bytes = 256 * 1024;

// ---------------------------------------------------------------------------
// mcp.json
// ---------------------------------------------------------------------------

pub const StdioServer = struct {
    command: []const u8,
    args: []const []const u8,
    env: []const [2][]const u8,
};

pub const HttpServer = struct {
    url: []const u8,
    headers: []const [2][]const u8,
};

/// One server as `mcp.json` describes it. Owns its strings.
pub const ServerConfig = struct {
    name: []const u8,
    transport: union(enum) {
        stdio: StdioServer,
        http: HttpServer,
    },
    timeout_ms: i64 = default_timeout_ms,
    /// Listed but not connected to. A way to keep a slow server out of startup
    /// without deleting what its configuration says.
    disabled: bool = false,

    pub fn deinit(self: ServerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        switch (self.transport) {
            .stdio => |stdio| {
                allocator.free(stdio.command);
                for (stdio.args) |arg| allocator.free(arg);
                allocator.free(stdio.args);
                freePairs(allocator, stdio.env);
            },
            .http => |http| {
                allocator.free(http.url);
                freePairs(allocator, http.headers);
            },
        }
    }
};

pub fn freeServers(allocator: std.mem.Allocator, servers: []ServerConfig) void {
    for (servers) |server| server.deinit(allocator);
    allocator.free(servers);
}

fn freePairs(allocator: std.mem.Allocator, pairs: []const [2][]const u8) void {
    for (pairs) |pair| {
        allocator.free(pair[0]);
        allocator.free(pair[1]);
    }
    allocator.free(pairs);
}

/// Read the servers `mcp.json` describes.
///
/// The file lives beside the config file — `$XDG_CONFIG_HOME/zagent/mcp.json`
/// or `~/.config/zagent/mcp.json` — and there being none is not a problem: it
/// means no servers, and an agent with no MCP tools is the agent there was
/// before any of this.
///
/// Anything wrong with the file is written to `problems` as a line for the
/// user, and the rest of the file is still used: one server with a typo in it
/// must not cost the others, and must not stop the session.
pub fn loadServers(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    problems: *std.ArrayList([]u8),
) ![]ServerConfig {
    var servers: std.ArrayList(ServerConfig) = .empty;
    errdefer {
        for (servers.items) |server| server.deinit(allocator);
        servers.deinit(allocator);
    }

    const contents = (try readConfigFile(allocator, io, env, problems)) orelse return servers.toOwnedSlice(allocator);
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
        try addProblem(allocator, problems, "mcp.json is not valid JSON; no MCP servers were loaded", .{});
        return servers.toOwnedSlice(allocator);
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            try addProblem(allocator, problems, "mcp.json must hold a JSON object with an \"mcpServers\" member", .{});
            return servers.toOwnedSlice(allocator);
        },
    };
    const listed = root.get("mcpServers") orelse {
        try addProblem(allocator, problems, "mcp.json has no \"mcpServers\" member", .{});
        return servers.toOwnedSlice(allocator);
    };
    if (listed != .object) {
        try addProblem(allocator, problems, "mcp.json: \"mcpServers\" must be an object", .{});
        return servers.toOwnedSlice(allocator);
    }

    var iterator = listed.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!isUsableServerName(name)) {
            try addProblem(
                allocator,
                problems,
                "mcp.json: \"{s}\" is not a usable server name; use letters, digits, '_' and '-' only, at most {d} of them",
                .{ name, max_server_name },
            );
            continue;
        }
        if (try parseServer(allocator, name, entry.value_ptr.*, problems)) |server| {
            try servers.append(allocator, server);
        }
    }

    return servers.toOwnedSlice(allocator);
}

fn readConfigFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    problems: *std.ArrayList([]u8),
) !?[]u8 {
    const base_path = (try config.configBasePath(allocator, env)) orelse return null;
    defer allocator.free(base_path);

    const path = try std.fmt.allocPrint(allocator, "{s}/mcp.json", .{base_path});
    defer allocator.free(path);

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        // No file is no servers. It is the ordinary case, and says nothing.
        error.FileNotFound => return null,
        // The config path is a file rather than a directory, so there is no
        // directory for mcp.json to live in. Silent here would mean a file the
        // user wrote is never read and never explained.
        error.NotDir => {
            try addProblem(allocator, problems, "{s} is a file, so {s} cannot exist", .{ base_path, path });
            return null;
        },
        else => |other| {
            try addProblem(allocator, problems, "mcp.json cannot be read: {s}", .{@errorName(other)});
            return null;
        },
    };
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_config_bytes)) catch |err| {
        try addProblem(allocator, problems, "mcp.json cannot be read: {s}", .{@errorName(err)});
        return null;
    };
}

fn addProblem(
    allocator: std.mem.Allocator,
    problems: *std.ArrayList([]u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try problems.append(allocator, try std.fmt.allocPrint(allocator, fmt, args));
}

fn isUsableServerName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_server_name) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

/// Read one `mcpServers` entry. Returns null when the entry is unusable, having
/// said why in `problems`.
fn parseServer(
    allocator: std.mem.Allocator,
    name: []const u8,
    value: std.json.Value,
    problems: *std.ArrayList([]u8),
) !?ServerConfig {
    if (value != .object) {
        try addProblem(allocator, problems, "mcp.json: \"{s}\" must be an object", .{name});
        return null;
    }
    const entry = value.object;

    const command = try stringMember(allocator, entry.get("command"));
    defer if (command) |text| allocator.free(text);
    const url = try stringMember(allocator, entry.get("url"));
    defer if (url) |text| allocator.free(text);

    if (command == null and url == null) {
        try addProblem(allocator, problems, "mcp.json: \"{s}\" has neither \"command\" nor \"url\"", .{name});
        return null;
    }
    if (command != null and url != null) {
        try addProblem(allocator, problems, "mcp.json: \"{s}\" has both \"command\" and \"url\"; give it one", .{name});
        return null;
    }

    const timeout_ms = try positiveInteger(entry.get("timeoutMs"));
    const disabled = if (entry.get("disabled")) |flag| (flag == .bool and flag.bool) else false;

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    if (command) |program| {
        const args = try stringList(allocator, entry.get("args"));
        errdefer {
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
        }
        const env = try pairList(allocator, name, "env", entry.get("env"), problems);
        errdefer freePairs(allocator, env);

        return .{
            .name = owned_name,
            .transport = .{ .stdio = .{
                .command = try allocator.dupe(u8, program),
                .args = args,
                .env = env,
            } },
            .timeout_ms = timeout_ms orelse default_timeout_ms,
            .disabled = disabled,
        };
    }

    const headers = try pairList(allocator, name, "headers", entry.get("headers"), problems);
    errdefer freePairs(allocator, headers);

    return .{
        .name = owned_name,
        .transport = .{ .http = .{
            .url = try allocator.dupe(u8, url.?),
            .headers = headers,
        } },
        .timeout_ms = timeout_ms orelse default_timeout_ms,
        .disabled = disabled,
    };
}

/// A string member, or null when it is absent. A member that is present and is
/// not a string is treated as absent: it is a value this client cannot use, and
/// the caller's own "neither command nor url" message is a better explanation
/// than a type mismatch it cannot act on anyway.
fn stringMember(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const field = value orelse return null;
    if (field != .string) return null;
    if (field.string.len == 0) return null;
    return try allocator.dupe(u8, field.string);
}

fn stringList(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    if (value) |field| {
        if (field == .array) {
            for (field.array.items) |item| {
                if (item != .string) continue;
                try list.append(allocator, try allocator.dupe(u8, item.string));
            }
        }
    }

    return list.toOwnedSlice(allocator);
}

/// An object of string values, kept as name/value pairs in the order they were
/// written. A key that cannot be written as an environment variable is refused
/// here rather than passed on: `environ_map.put` asserts on one, and a panic in
/// the middle of startup is no way to learn about a typo.
fn pairList(
    allocator: std.mem.Allocator,
    server: []const u8,
    member: []const u8,
    value: ?std.json.Value,
    problems: *std.ArrayList([]u8),
) ![]const [2][]const u8 {
    var pairs: std.ArrayList([2][]const u8) = .empty;
    errdefer {
        for (pairs.items) |pair| {
            allocator.free(pair[0]);
            allocator.free(pair[1]);
        }
        pairs.deinit(allocator);
    }

    const field = value orelse return pairs.toOwnedSlice(allocator);
    if (field != .object) {
        try addProblem(allocator, problems, "mcp.json: \"{s}\".{s} must be an object of strings", .{ server, member });
        return pairs.toOwnedSlice(allocator);
    }

    var iterator = field.object.iterator();
    while (iterator.next()) |item| {
        if (item.value_ptr.* != .string) {
            try addProblem(allocator, problems, "mcp.json: \"{s}\".{s}.{s} must be a string", .{ server, member, item.key_ptr.* });
            continue;
        }
        const key = item.key_ptr.*;
        if (std.mem.eql(u8, member, "env") and !std.process.Environ.Map.validateKeyForPut(key)) {
            try addProblem(allocator, problems, "mcp.json: \"{s}\".env.{s} is not a usable variable name", .{ server, key });
            continue;
        }
        if (std.mem.indexOfAny(u8, key, ":\r\n") != null or std.mem.indexOfAny(u8, item.value_ptr.string, "\r\n") != null) {
            try addProblem(allocator, problems, "mcp.json: \"{s}\".{s}.{s} cannot be sent in a header line", .{ server, member, key });
            continue;
        }

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, item.value_ptr.string);
        errdefer allocator.free(owned_value);
        try pairs.append(allocator, .{ owned_key, owned_value });
    }

    return pairs.toOwnedSlice(allocator);
}

fn positiveInteger(value: ?std.json.Value) !?i64 {
    const field = value orelse return null;
    if (field != .integer) return null;
    if (field.integer <= 0) return null;
    return field.integer;
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

/// The name the model sees for one of a server's tools: `mcp__<server>__<tool>`,
/// fitted to what an OpenAI-compatible endpoint accepts.
///
/// MCP lets a tool be called things an endpoint will not take — a dot, a name
/// over 64 characters — so each part is reduced to letters, digits, `_` and
/// `-`, and a name that still does not fit is cut short and given a hash of
/// what it was. The hash is there so two long names from one server do not
/// quietly become the same name.
pub fn aliasFor(allocator: std.mem.Allocator, server: []const u8, tool: []const u8) ![]u8 {
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(allocator);

    try plain.appendSlice(allocator, tool_prefix);
    for (server) |byte| try plain.append(allocator, if (isNameByte(byte)) byte else '_');
    try plain.appendSlice(allocator, "__");
    for (tool) |byte| try plain.append(allocator, if (isNameByte(byte)) byte else '_');

    if (plain.items.len <= max_tool_name) return plain.toOwnedSlice(allocator);

    const digest = std.hash.Wyhash.hash(0, plain.items);
    const kept = max_tool_name - 7; // room for '_' and six hex digits
    const shortened = try allocator.alloc(u8, max_tool_name);
    @memcpy(shortened[0..kept], plain.items[0..kept]);
    shortened[kept] = '_';
    _ = std.fmt.bufPrint(shortened[kept + 1 ..], "{x:0>6}", .{digest & 0xff_ffff}) catch unreachable;
    return shortened;
}

// ---------------------------------------------------------------------------
// The connection
// ---------------------------------------------------------------------------

pub const Era = enum {
    /// Per-request `_meta`, no handshake: the revision this client prefers.
    modern,
    /// The `initialize` handshake and a stream that stays one conversation.
    legacy,
};

/// Why a server is not usable, kept as a sentence for the user.
const failure_max_bytes = 400;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Borrowed from the caller: the server's name, for messages.
    name: []const u8,
    transport: transport.Transport,
    era: Era = .modern,
    /// The revision the server named, when it named one. Null means the
    /// revision this client asked for was taken as it is.
    negotiated_version: ?[]u8 = null,
    server_info: ?[]u8 = null,
    /// What the server says about using it, for the system prompt.
    instructions: ?[]u8 = null,
    timeout_ms: i64 = default_timeout_ms,
    /// Set once the connection cannot be trusted to answer again...
    failed: ?[]u8 = null,
    next_id: i64 = 1,

    /// Start a server and find out which revision it speaks. Everything that
    /// can go wrong — the program missing, the endpoint refusing, no answer —
    /// comes back as an error, and the caller keeps the message.
    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: ServerConfig,
        parent_env: *const std.process.Environ.Map,
    ) !Connection {
        var connection: Connection = .{
            .allocator = allocator,
            .io = io,
            .name = server.name,
            .timeout_ms = server.timeout_ms,
            .transport = undefined,
        };

        switch (server.transport) {
            .stdio => |stdio| {
                var argv: std.ArrayList([]const u8) = .empty;
                defer argv.deinit(allocator);
                try argv.append(allocator, stdio.command);
                try argv.appendSlice(allocator, stdio.args);

                connection.transport = .{ .stdio = try transport.Stdio.start(allocator, io, .{
                    .argv = argv.items,
                    .env = stdio.env,
                }, parent_env) };
            },
            .http => |http| {
                connection.transport = .{ .http = transport.Http.init(io, allocator, .{
                    .url = http.url,
                    .headers = http.headers,
                }) };
            },
        }
        errdefer connection.deinit();

        try connection.negotiate();
        return connection;
    }

    pub fn deinit(self: *Connection) void {
        self.transport.close();
        self.transport.deinit();
        if (self.server_info) |info| self.allocator.free(info);
        if (self.instructions) |text| self.allocator.free(text);
        if (self.negotiated_version) |version| self.allocator.free(version);
        if (self.failed) |reason| self.allocator.free(reason);
        self.server_info = null;
        self.instructions = null;
        self.negotiated_version = null;
        self.failed = null;
    }

    /// Remember why this connection cannot be used again, the first time it
    /// happens. A stream whose framing is in doubt must not be read again: what
    /// is left in it belongs to a request nobody is waiting for, and a server
    /// that died must not cost a full timeout on every call after it.
    fn poison(self: *Connection, err: anyerror) !void {
        if (self.failed == null) {
            const reason = std.fmt.allocPrint(
                self.allocator,
                "no usable answer ({s})",
                .{@errorName(err)},
            ) catch null;
            self.failed = reason;
        }
    }

    /// The revision this connection ended up speaking.
    pub fn negotiated(self: *const Connection) []const u8 {
        return self.negotiated_version orelse modern_protocol_version;
    }

    /// Work out which revision the server speaks and get ready to use it.
    ///
    /// The probe goes both ways on purpose. A modern server that never
    /// implemented `server/discover` answers a method-not-found error, which is
    /// indistinguishable from a legacy server's answer to the same request; and
    /// a modern server that is slow to start misses the probe's deadline. Both
    /// are recovered by asking the other revision's question, which costs one
    /// round trip and is harmless to either kind of server.
    pub fn negotiate(self: *Connection) !void {
        const params = try metaParams(self.allocator);
        defer self.allocator.free(params);

        const response = self.request(.{
            .method = "server/discover",
            .params_json = params,
            .meta = .modern,
            .timeout_ms = @min(self.timeout_ms, probe_timeout_cap_ms),
        }) catch |err| switch (err) {
            // Nothing came back at all. Only a legacy server (or a busy one)
            // behaves this way, so the handshake is tried before giving up.
            error.McpTimeout, error.McpClosed => return self.handshake(),
            else => return err,
        };
        defer response.deinit(self.allocator);

        switch (response) {
            .result => |text| switch (try self.readDiscover(self.allocator, text)) {
                .settled => {},
                .ask_for_handshake => try self.handshake(),
            },
            .err => |err| {
                if (err.code == unsupported_protocol_version) {
                    switch (try self.retryWith(self.allocator, err.data_json)) {
                        .settled => {},
                        .ask_for_handshake => try self.handshake(),
                    }
                    return;
                }
                // A method the server does not have, or anything else that is
                // not a protocol error: ask the older question instead.
                try self.handshake();
            },
            .http_error => |refusal| switch (try self.judgeRefusal(refusal.status, refusal.body)) {
                .settled => {},
                .ask_for_handshake => try self.handshake(),
            },
            .accepted => return error.McpProtocol,
        }
    }

    /// The legacy opening: `initialize`, then the notification that says the
    /// client is ready. Nothing about it carries `_meta`, because the revision
    /// it belongs to predates per-request metadata.
    fn handshake(self: *Connection) !void {
        const params = try initializeParams(self.allocator);
        defer self.allocator.free(params);

        // An error here — no answer, a closed stream — is the end of it: both
        // questions have been asked, and there is no third one to try.
        const response = try self.request(.{
            .method = "initialize",
            .params_json = params,
            .meta = .none,
            .timeout_ms = @min(self.timeout_ms, probe_timeout_cap_ms),
        });
        defer response.deinit(self.allocator);

        switch (response) {
            .result => |text| {
                self.era = .legacy;
                try self.readInitialize(self.allocator, text);

                const notification = try transport.buildNotification(self.allocator, "notifications/initialized", null);
                defer self.allocator.free(notification);
                try self.transport.notify(self.allocator, .{
                    .message = notification,
                    .id = 0,
                    .method = "notifications/initialized",
                    .protocol_version = self.negotiated(),
                    .timeout_ms = self.timeout_ms,
                });
            },
            // A server that does not know `initialize` is one written for the
            // modern revision, which rejects the handshake as an unknown
            // method. The probe was wrong; it is not fatal.
            .err => self.era = .modern,
            // Over HTTP a modern server may refuse the handshake with a status
            // rather than a JSON-RPC error; that also means modern.
            .http_error => self.era = .modern,
            .accepted => self.era = .modern,
        }
    }

    /// Whether a question settled the connection, or whether the server turned
    /// out to want the older question asked.
    const Settlement = enum { settled, ask_for_handshake };

    fn readDiscover(self: *Connection, allocator: std.mem.Allocator, result_json: []const u8) !Settlement {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch
            return error.McpProtocol;
        defer parsed.deinit();
        if (parsed.value != .object) return error.McpProtocol;

        const object = parsed.value.object;
        if (object.get("supportedVersions")) |versions| {
            if (versions == .array and !versionOffered(versions.array.items, modern_protocol_version)) {
                // The server speaks the current shape of the protocol but not
                // this revision of it, so what it supports are the older
                // revisions — which are opened with the handshake.
                return .ask_for_handshake;
            }
        }

        self.era = .modern;
        try self.readIdentity(allocator, object);
        return .settled;
    }

    /// The server refused the revision asked for and named the ones it has.
    /// One of them may be this revision after all — a server that lists it has
    /// it — and if none is, the list holds the older revisions, which the
    /// handshake is how to ask for.
    fn retryWith(self: *Connection, allocator: std.mem.Allocator, data_json: ?[]const u8) !Settlement {
        const supported = data_json orelse return .ask_for_handshake;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, supported, .{}) catch
            return .ask_for_handshake;
        defer parsed.deinit();
        if (parsed.value != .object) return .ask_for_handshake;

        const versions = parsed.value.object.get("supported") orelse return .ask_for_handshake;
        if (versions != .array) return .ask_for_handshake;
        if (!versionOffered(versions.array.items, modern_protocol_version)) return .ask_for_handshake;

        self.era = .modern;
        return .settled;
    }

    /// A refusal from the HTTP layer. This is where the era is decided on HTTP:
    /// a modern server uses `400` for a version or header it will not take, and
    /// says so with a JSON-RPC error this client recognizes. Anything else —
    /// an empty body, an old server's plain `400` — means the request was not
    /// understood, which is what a legacy server does to a modern one.
    fn judgeRefusal(self: *Connection, status: u16, body: []const u8) !Settlement {
        if (status == 400 or status == 404 or status == 405) {
            if (try readError(self.allocator, body)) |err| {
                defer err.deinit(self.allocator);
                if (isModernErrorCode(err.code)) {
                    if (err.code == unsupported_protocol_version) {
                        return self.retryWith(self.allocator, err.data_json);
                    }
                    // A header or a capability the server insists on, and
                    // which this client cannot supply.
                    return error.McpUnsupportedVersion;
                }
            }
            return .ask_for_handshake;
        }

        return error.McpRefused;
    }

    fn readInitialize(self: *Connection, allocator: std.mem.Allocator, result_json: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch
            return error.McpProtocol;
        defer parsed.deinit();
        if (parsed.value != .object) return error.McpProtocol;

        const object = parsed.value.object;
        if (object.get("protocolVersion")) |version| {
            if (version == .string) {
                if (self.negotiated_version) |previous| allocator.free(previous);
                self.negotiated_version = try allocator.dupe(u8, version.string);
            }
        }
        // 2024-11-05 and the HTTP+SSE transport that goes with it are not
        // spoken here: a server that answers with them would have to be
        // talked to over a transport this client does not implement.
        if (std.mem.eql(u8, self.negotiated(), "2024-11-05")) return error.McpUnsupportedVersion;
        try self.readIdentity(allocator, object);
    }

    fn readIdentity(self: *Connection, allocator: std.mem.Allocator, object: std.json.ObjectMap) !void {
        if (object.get("instructions")) |instructions| {
            if (instructions == .string and instructions.string.len > 0) {
                const capped = instructions.string[0..@min(instructions.string.len, max_instructions_bytes)];
                if (self.instructions) |previous| allocator.free(previous);
                self.instructions = try allocator.dupe(u8, capped);
            }
        }

        // `serverInfo` is `_meta`'s on a modern result and its own member on an
        // older one, so both are looked for.
        const info = if (object.get("serverInfo")) |info|
            info
        else if (object.get("_meta")) |meta|
            (if (meta == .object) meta.object.get("io.modelcontextprotocol/serverInfo") else null)
        else
            null;

        if (info) |value| {
            if (value == .object) {
                if (value.object.get("name")) |name| {
                    if (name == .string) {
                        if (self.server_info) |previous| allocator.free(previous);
                        self.server_info = try allocator.dupe(u8, name.string);
                    }
                }
            }
        }
    }

    /// Ask the server for its tools, following the pages it hands back.
    pub fn listTools(self: *Connection, allocator: std.mem.Allocator) ![]RemoteTool {
        var listed: std.ArrayList(RemoteTool) = .empty;
        errdefer {
            for (listed.items) |tool| tool.deinit(allocator);
            listed.deinit(allocator);
        }

        var cursor: ?[]u8 = null;
        defer if (cursor) |value| allocator.free(value);

        var page: usize = 0;
        while (page < max_pages) : (page += 1) {
            const params = try listParams(allocator, cursor, self.era == .modern);
            defer allocator.free(params);

            const response = try self.request(.{
                .method = "tools/list",
                .params_json = params,
                .meta = if (self.era == .modern) .modern else .none,
                .timeout_ms = self.timeout_ms,
            });
            defer response.deinit(allocator);

            const result_json = switch (response) {
                .result => |text| text,
                .err => |err| {
                    _ = err;
                    return error.McpServerError;
                },
                .http_error => return error.McpRefused,
                .accepted => return error.McpProtocol,
            };

            if (cursor) |value| {
                allocator.free(value);
                cursor = null;
            }

            const next = try readToolPage(allocator, result_json, &listed);
            if (listed.items.len >= max_tools_per_server) break;
            if (next) |value| {
                cursor = value;
            } else break;
        }

        return listed.toOwnedSlice(allocator);
    }

    /// Call one tool. The result is the JSON text of the `result` member, for
    /// the caller to shape into something the model can read.
    pub fn callTool(
        self: *Connection,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) !transport.Response {
        const params = try callParams(allocator, name, arguments_json, self.era == .modern);
        defer allocator.free(params);

        return self.request(.{
            .method = "tools/call",
            .params_json = params,
            .name = name,
            .meta = if (self.era == .modern) .modern else .none,
            .timeout_ms = self.timeout_ms,
        });
    }

    const Meta = enum { modern, none };

    const Request = struct {
        method: []const u8,
        params_json: ?[]const u8 = null,
        name: ?[]const u8 = null,
        meta: Meta = .modern,
        timeout_ms: i64,
    };

    /// Send one request and read the answer. Everything that reaches the wire
    /// goes through here, so the id, the `_meta` fields and the headers a
    /// request is routed on are decided in one place.
    fn request(self: *Connection, options: Request) !transport.Response {
        if (self.failed) |_| return error.McpUnavailable;

        const id = self.next_id;
        self.next_id += 1;

        const params = if (options.meta == .modern and options.params_json == null)
            try metaParams(self.allocator)
        else
            null;
        defer if (params) |text| self.allocator.free(text);

        const message = try transport.buildRequest(
            self.allocator,
            id,
            options.method,
            options.params_json orelse params,
        );
        defer self.allocator.free(message);

        return self.transport.request(self.allocator, .{
            .message = message,
            .id = id,
            .method = options.method,
            .name = options.name,
            // A legacy connection stops declaring a version once its opening
            // has named one; before that, the modern revision is what is being
            // attempted, and that is what the header says.
            .protocol_version = switch (options.meta) {
                .modern => modern_protocol_version,
                .none => if (self.era == .legacy) self.negotiated() else null,
            },
            .timeout_ms = options.timeout_ms,
        }) catch |err| {
            switch (err) {
                // The framing is lost: whatever is left in the stream cannot be
                // trusted to be the answer to the next request. A timeout is
                // not one of these — it leaves the stream untouched, and the
                // answer that arrives late is stepped over by its id.
                error.McpClosed, error.McpProtocol, error.McpMessageTooLong => try self.poison(err),
                else => {},
            }
            return err;
        };
    }
};

pub const RemoteTool = struct {
    name: []u8,
    description: []u8,
    /// The tool's `inputSchema`, re-rendered. The model is shown this, so it is
    /// JSON this process wrote rather than a slice of what the server sent.
    schema_json: []u8,

    pub fn deinit(self: RemoteTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.schema_json);
    }
};

/// Read one page of `tools/list`, appending to `listed` and handing back the
/// cursor for the next page when the server gave one.
fn readToolPage(
    allocator: std.mem.Allocator,
    result_json: []const u8,
    listed: *std.ArrayList(RemoteTool),
) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch
        return error.McpProtocol;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpProtocol;
    const object = parsed.value.object;

    if (object.get("tools")) |tools_value| {
        if (tools_value == .array) {
            for (tools_value.array.items) |item| {
                if (item != .object) continue;
                const tool = try readTool(allocator, item.object) orelse continue;
                try listed.append(allocator, tool);
            }
        }
    }

    const cursor = object.get("nextCursor") orelse return null;
    if (cursor != .string or cursor.string.len == 0) return null;
    // A server that hands the same cursor back would be paged forever; the
    // page count in `listTools` is what stops that.
    return try allocator.dupe(u8, cursor.string);
}

fn readTool(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?RemoteTool {
    const name = switch (object.get("name") orelse return null) {
        .string => |text| text,
        else => return null,
    };
    if (name.len == 0) return null;

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    const description = switch (object.get("description") orelse std.json.Value{ .null = {} }) {
        .string => |text| text,
        else => "",
    };
    const owned_description = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_description);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    if (object.get("inputSchema")) |schema| {
        if (schema == .object) {
            try std.json.Stringify.value(schema, .{}, &aw.writer);
        } else {
            try aw.writer.writeAll("{\"type\":\"object\"}");
        }
    } else {
        try aw.writer.writeAll("{\"type\":\"object\"}");
    }

    return .{
        .name = owned_name,
        .description = owned_description,
        .schema_json = try aw.toOwnedSlice(),
    };
}

/// `-32022`: the revision named is not one the server has. `-32020` and
/// `-32021` are the other two the specification defines, and all three can only
/// come from a server that speaks it.
const unsupported_protocol_version: i64 = -32022;

fn isModernErrorCode(code: i64) bool {
    return code == -32020 or code == -32021 or code == unsupported_protocol_version;
}

fn versionOffered(versions: []const std.json.Value, wanted: []const u8) bool {
    for (versions) |version| {
        if (version == .string and std.mem.eql(u8, version.string, wanted)) return true;
    }
    return false;
}

/// Read a JSON-RPC error out of a body that may or may not be a full message,
/// and may or may not carry an id: the refusals a server sends with a status
/// are not required to have one.
fn readError(allocator: std.mem.Allocator, body: []const u8) !?transport.RpcError {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const error_value = parsed.value.object.get("error") orelse return null;
    if (error_value != .object) return null;

    const code: i64 = if (error_value.object.get("code")) |code_value|
        (if (code_value == .integer) code_value.integer else 0)
    else
        0;
    const message = if (error_value.object.get("message")) |message_value|
        (if (message_value == .string) message_value.string else "")
    else
        "";

    var data_json: ?[]u8 = null;
    errdefer if (data_json) |data| allocator.free(data);
    if (error_value.object.get("data")) |data_value| {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try std.json.Stringify.value(data_value, .{}, &aw.writer);
        data_json = try aw.toOwnedSlice();
    }

    return .{
        .code = code,
        .message = try allocator.dupe(u8, message),
        .data_json = data_json,
    };
}

// ---------------------------------------------------------------------------
// Request params
// ---------------------------------------------------------------------------

/// The per-request protocol fields every request in the current revision
/// carries. They are what makes the protocol stateless: the version, who is
/// asking, and what the asker can do are all in the request.
fn writeMeta(w: *std.Io.Writer) !void {
    try w.writeAll("\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":");
    try std.json.Stringify.encodeJsonString(modern_protocol_version, .{}, w);
    try w.writeAll(",\"io.modelcontextprotocol/clientInfo\":{\"name\":");
    try std.json.Stringify.encodeJsonString(client_name, .{}, w);
    try w.writeAll(",\"version\":");
    try std.json.Stringify.encodeJsonString(client_version, .{}, w);
    try w.writeAll("},\"io.modelcontextprotocol/clientCapabilities\":{}}");
}

fn metaParams(allocator: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeByte('{');
    try writeMeta(&aw.writer);
    try aw.writer.writeByte('}');
    return aw.toOwnedSlice();
}

/// The opening of the legacy revision. No `_meta`: that belongs to the revision
/// this request is not.
fn initializeParams(allocator: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"protocolVersion\":");
    try std.json.Stringify.encodeJsonString(legacy_protocol_version, .{}, w);
    try w.writeAll(",\"capabilities\":{},\"clientInfo\":{\"name\":");
    try std.json.Stringify.encodeJsonString(client_name, .{}, w);
    try w.writeAll(",\"version\":");
    try std.json.Stringify.encodeJsonString(client_version, .{}, w);
    try w.writeAll("}}");
    return aw.toOwnedSlice();
}

fn listParams(allocator: std.mem.Allocator, cursor: ?[]const u8, meta: bool) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeByte('{');
    var first = true;
    if (cursor) |value| {
        try w.writeAll("\"cursor\":");
        try std.json.Stringify.encodeJsonString(value, .{}, w);
        first = false;
    }
    if (meta) {
        if (!first) try w.writeByte(',');
        try writeMeta(w);
    }
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

fn callParams(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments_json: []const u8,
    meta: bool,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, w);
    try w.writeAll(",\"arguments\":");
    try w.writeAll(arguments_json);
    if (meta) {
        try w.writeByte(',');
        try writeMeta(w);
    }
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

/// Re-render the arguments a model sent for a tool call.
///
/// The model's text is JSON, but it is not necessarily one line: a newline
/// between two tokens is legal JSON and would break the stdio binding, where
/// one message is one line. Reading and writing it back settles that, and
/// settles that it is an object at all.
pub fn normalizeArguments(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch
        return error.McpInvalidArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidArguments;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// Turn a `tools/call` result into what the model is shown.
///
/// Text is what a tool result is for, so it is passed through; anything binary
/// is named rather than carried, because the bytes would cost more context than
/// they could ever repay. A result the server marks as an error stays an error,
/// which is what lets the model correct itself and try again.
pub fn renderCallResult(allocator: std.mem.Allocator, result_json: []const u8) !tools.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch
        return errorResult(allocator, "the server's result was not JSON", .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return errorResult(allocator, "the server's result was not a JSON object", .{}),
    };

    // Older servers do not send `resultType` at all, and the specification says
    // to read that as a finished result.
    if (object.get("resultType")) |result_type| {
        if (result_type == .string and std.mem.eql(u8, result_type.string, "input_required")) {
            return errorResult(
                allocator,
                "the MCP server needs more input to finish this call (elicitation, sampling or roots); zagent does not do multi-round-trip requests",
                .{},
            );
        }
    }

    const is_error = if (object.get("isError")) |flag| (flag == .bool and flag.bool) else false;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    if (is_error) try w.writeAll("Error: ");

    var wrote = false;
    if (object.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |item| {
                if (try writeContent(w, item, wrote)) wrote = true;
            }
        }
    }

    // Structured content is what a tool with an output schema returns; the
    // specification asks servers to repeat it as text as well, and this is the
    // case where they did not.
    if (!wrote) {
        if (object.get("structuredContent")) |structured| {
            try std.json.Stringify.value(structured, .{}, w);
            wrote = true;
        }
    }

    if (!wrote) try w.writeAll("(the tool returned nothing)");

    return .{
        .content = try tools.finalizeToolContentLimited(allocator, aw.written(), tools.http_max_content),
        .is_error = is_error,
    };
}

/// Write one content item, after `following` earlier ones. Returns whether
/// anything was written.
fn writeContent(w: *std.Io.Writer, item: std.json.Value, following: bool) !bool {
    if (item != .object) return false;
    const object = item.object;

    const kind = switch (object.get("type") orelse return false) {
        .string => |text| text,
        else => return false,
    };

    if (std.mem.eql(u8, kind, "text")) {
        const text = switch (object.get("text") orelse return false) {
            .string => |text| text,
            else => return false,
        };
        if (following) try w.writeByte('\n');
        try w.writeAll(text);
        return true;
    }

    if (std.mem.eql(u8, kind, "image") or std.mem.eql(u8, kind, "audio")) {
        const mime = switch (object.get("mimeType") orelse std.json.Value{ .null = {} }) {
            .string => |text| text,
            else => "unknown",
        };
        const data = switch (object.get("data") orelse std.json.Value{ .null = {} }) {
            .string => |text| text,
            else => "",
        };
        if (following) try w.writeByte('\n');
        try w.print("[{s}: {s}, {d} bytes]", .{ kind, mime, decodedSize(data) });
        return true;
    }

    if (std.mem.eql(u8, kind, "resource_link")) {
        const uri = switch (object.get("uri") orelse return false) {
            .string => |text| text,
            else => return false,
        };
        if (following) try w.writeByte('\n');
        try w.print("[resource: {s}]", .{uri});
        return true;
    }

    if (std.mem.eql(u8, kind, "resource")) {
        const resource = switch (object.get("resource") orelse return false) {
            .object => |inner| inner,
            else => return false,
        };
        const uri = switch (resource.get("uri") orelse std.json.Value{ .null = {} }) {
            .string => |text| text,
            else => "",
        };
        if (following) try w.writeByte('\n');
        if (resource.get("text")) |text| {
            if (text == .string) {
                try w.writeAll(text.string);
                return true;
            }
        }
        const mime = switch (resource.get("mimeType") orelse std.json.Value{ .null = {} }) {
            .string => |text| text,
            else => "binary",
        };
        try w.print("[resource: {s} ({s})]", .{ uri, mime });
        return true;
    }

    // A kind this client does not know is named rather than refused: dropping
    // it would lose the rest of a result that may still be readable.
    if (following) try w.writeByte('\n');
    try w.print("[{s} content]", .{kind});
    return true;
}

/// Roughly what a base64 payload expands to. It is here to say how big the
/// thing the model is not being shown was, not to be exact.
fn decodedSize(base64: []const u8) usize {
    if (base64.len == 0) return 0;
    const padding: usize = if (base64.len >= 1 and base64[base64.len - 1] == '=') 1 else 0;
    return base64.len / 4 * 3 - padding;
}

fn errorResult(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !tools.ToolResult {
    const raw = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(raw);
    return .{
        .content = try tools.finalizeToolContentLimited(allocator, raw, tools.http_max_content),
        .is_error = true,
    };
}

/// How long a tool description is allowed to be. A server can send anything,
/// and every byte of it is read on every request.
const max_description_bytes = 1_024;

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

/// One of a server's tools, as the agent offers it to the model.
pub const Tool = struct {
    /// Which server it came from.
    server: usize,
    /// What the model calls it.
    alias: []const u8,
    /// What the server calls it.
    remote_name: []const u8,
    /// The function object advertised in every request, built once: the request
    /// path only joins strings.
    function: []const u8,
    /// The progress line's label, also built once, so what the spinner is given
    /// is never a string the model wrote.
    label: []const u8,
};

/// One server, connected or not.
const Server = struct {
    config: ServerConfig,
    connection: ?Connection = null,
    /// Why it is not connected, as a sentence.
    failure: ?[]u8 = null,
    /// The command line or the URL, for `/mcp`. Never `env` or `headers`: that
    /// is where a token lives.
    summary: []u8,
    tool_count: usize = 0,

    fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        if (self.connection) |*connection| connection.deinit();
        if (self.failure) |failure| allocator.free(failure);
        allocator.free(self.summary);
        self.config.deinit(allocator);
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    servers: []Server,
    tools: []Tool,
    /// The advertised function objects, ready for the request body.
    tool_json: [][]const u8,
    by_alias: std.StringHashMapUnmanaged(usize) = .empty,

    /// A registry with no servers in it, for a caller whose `mcp.json` could
    /// not be read at all: an agent without MCP is still an agent.
    pub fn empty(allocator: std.mem.Allocator, io: std.Io) Registry {
        return .{ .allocator = allocator, .io = io, .servers = &.{}, .tools = &.{}, .tool_json = &.{} };
    }

    /// Called before each server is started, so that a caller can say what is
    /// being waited for. A server can take seconds to come up — `npx` downloads
    /// its package the first time — and a silent wait looks like a hang.
    pub const Progress = struct {
        context: *anyopaque,
        started: *const fn (context: *anyopaque, name: []const u8) void,
    };

    /// Read `mcp.json` and connect every server it names.
    ///
    /// A server that will not start or will not answer is a failure recorded
    /// against it, and nothing more: it must not cost the others, and it must
    /// not stop the session. With no `mcp.json` at all this is an empty
    /// registry, which is an agent with the tools it always had.
    ///
    /// Lines the user should read — a server name that cannot be used, a tool
    /// two servers both want — are appended to `problems`, which stays the
    /// caller's to print.
    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        problems: *std.ArrayList([]u8),
        progress: ?Progress,
    ) !Registry {
        const configs = try loadServers(allocator, io, env, problems);
        defer allocator.free(configs);

        var registry: Registry = .{
            .allocator = allocator,
            .io = io,
            .servers = &.{},
            .tools = &.{},
            .tool_json = &.{},
        };
        errdefer registry.deinit();

        var servers: std.ArrayList(Server) = .empty;
        errdefer {
            for (servers.items) |*server| server.deinit(allocator);
            servers.deinit(allocator);
        }

        // Each configuration is handed to a `Server`, which owns it from then
        // on. `next` therefore steps past a configuration as soon as a server
        // holds it, so the cleanup below frees exactly the ones still unclaimed.
        var next: usize = 0;
        errdefer for (configs[next..]) |unclaimed| unclaimed.deinit(allocator);

        while (next < configs.len) {
            var server: Server = .{
                .config = configs[next],
                .summary = try summarize(allocator, configs[next]),
            };
            next += 1;
            errdefer server.deinit(allocator);

            if (!server.config.disabled) {
                if (progress) |watcher| watcher.started(watcher.context, server.config.name);
                server.connection = Connection.connect(allocator, io, server.config, env) catch |err| failed: {
                    server.failure = try allocator.dupe(u8, describeError(err));
                    break :failed null;
                };
            }

            try servers.append(allocator, server);
        }

        registry.servers = try servers.toOwnedSlice(allocator);
        try registry.collectTools(problems);

        return registry;
    }

    /// List every connected server's tools, name them for the model, and keep
    /// the ones that came back.
    fn collectTools(self: *Registry, problems: *std.ArrayList([]u8)) !void {
        var listed: std.ArrayList(Tool) = .empty;
        errdefer {
            for (listed.items) |tool| self.freeTool(tool);
            listed.deinit(self.allocator);
        }

        for (self.servers, 0..) |*server, index| {
            const connection = if (server.connection) |*connection| connection else continue;
            const before = listed.items.len;

            const remote_tools = connection.listTools(self.allocator) catch |err| {
                server.failure = try std.fmt.allocPrint(
                    self.allocator,
                    "its tools could not be listed: {s}",
                    .{describeError(err)},
                );
                continue;
            };
            defer {
                for (remote_tools) |tool| tool.deinit(self.allocator);
                self.allocator.free(remote_tools);
            }

            for (remote_tools) |remote| {
                const alias = try aliasFor(self.allocator, server.config.name, remote.name);
                errdefer self.allocator.free(alias);

                if (self.by_alias.contains(alias)) {
                    try addProblem(
                        self.allocator,
                        problems,
                        "mcp: \"{s}\" and \"{s}\" both become \"{s}\"; the second is not offered",
                        .{ server.config.name, remote.name, alias },
                    );
                    self.allocator.free(alias);
                    continue;
                }

                const function = try buildFunction(
                    self.allocator,
                    alias,
                    server.config.name,
                    remote.description,
                    remote.schema_json,
                );
                errdefer self.allocator.free(function);
                const label = try buildLabel(self.allocator, server.config.name, remote.name);
                errdefer self.allocator.free(label);
                const remote_name = try self.allocator.dupe(u8, remote.name);
                errdefer self.allocator.free(remote_name);

                try listed.append(self.allocator, .{
                    .server = index,
                    .alias = alias,
                    .remote_name = remote_name,
                    .function = function,
                    .label = label,
                });
            }
            server.tool_count = listed.items.len - before;
        }

        self.tools = try listed.toOwnedSlice(self.allocator);
        errdefer {
            for (self.tools) |tool| self.freeTool(tool);
            self.allocator.free(self.tools);
        }

        const views = try self.allocator.alloc([]const u8, self.tools.len);
        errdefer self.allocator.free(views);
        for (self.tools, 0..) |tool, index| views[index] = tool.function;
        self.tool_json = views;

        for (self.tools, 0..) |tool, index| {
            try self.by_alias.put(self.allocator, tool.alias, index);
        }
    }

    fn freeTool(self: *Registry, tool: Tool) void {
        self.allocator.free(tool.alias);
        self.allocator.free(tool.remote_name);
        self.allocator.free(tool.function);
        self.allocator.free(tool.label);
    }

    pub fn deinit(self: *Registry) void {
        for (self.tools) |tool| self.freeTool(tool);
        self.allocator.free(self.tools);
        self.allocator.free(self.tool_json);
        self.by_alias.deinit(self.allocator);
        for (self.servers) |*server| server.deinit(self.allocator);
        self.allocator.free(self.servers);

        self.tools = &.{};
        self.tool_json = &.{};
        self.servers = &.{};
    }

    /// The tools to advertise, in the form the request body wants them.
    pub fn functionJson(self: *const Registry) []const []const u8 {
        return self.tool_json;
    }

    /// The progress line for a call, or null for anything that is not one of
    /// these tools — including a name the model made up.
    pub fn progressLabel(self: *const Registry, name: []const u8) ?[]const u8 {
        const index = self.by_alias.get(name) orelse return null;
        return self.tools[index].label;
    }

    /// Run one `tools/call`.
    ///
    /// Everything a server can do wrong comes back as a tool result the model
    /// can read and act on: a call that fails is not a failure of the turn, and
    /// the model is the one that can correct it.
    pub fn call(
        self: *Registry,
        allocator: std.mem.Allocator,
        alias: []const u8,
        arguments_json: []const u8,
    ) !tools.ToolResult {
        const index = self.by_alias.get(alias) orelse {
            return errorResult(allocator, "No MCP tool is called '{s}'.", .{alias});
        };
        const tool = self.tools[index];
        const server = &self.servers[tool.server];

        if (server.failure) |reason| {
            return errorResult(
                allocator,
                "The MCP server \"{s}\" is not connected: {s}",
                .{ server.config.name, reason },
            );
        }
        const connection = if (server.connection) |*connection| connection else {
            return errorResult(allocator, "The MCP server \"{s}\" is not connected.", .{server.config.name});
        };

        const arguments = normalizeArguments(allocator, arguments_json) catch {
            return errorResult(
                allocator,
                "The arguments for '{s}' are not a JSON object.",
                .{alias},
            );
        };
        defer allocator.free(arguments);

        var response = connection.callTool(allocator, tool.remote_name, arguments) catch |err| {
            return errorResult(
                allocator,
                "Calling '{s}' on \"{s}\" failed: {s}",
                .{ tool.remote_name, server.config.name, describeError(err) },
            );
        };
        defer response.deinit(allocator);

        return switch (response) {
            .result => |text| renderCallResult(allocator, text),
            .err => |err| errorResult(
                allocator,
                "The MCP server \"{s}\" refused '{s}': {s} (code {d})",
                .{ server.config.name, tool.remote_name, err.message, err.code },
            ),
            .http_error => |refusal| errorResult(
                allocator,
                "The MCP server \"{s}\" answered HTTP {d}.",
                .{ server.config.name, refusal.status },
            ),
            .accepted => errorResult(
                allocator,
                "The MCP server \"{s}\" accepted '{s}' without a result.",
                .{ server.config.name, tool.remote_name },
            ),
        };
    }

    /// What the servers say about using them, for the system prompt.
    pub fn instructions(self: *const Registry, allocator: std.mem.Allocator) !?[]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();

        for (self.servers) |server| {
            const connection = server.connection orelse continue;
            const note = connection.instructions orelse continue;
            try aw.writer.print(
                "\n\nFrom the MCP server \"{s}\":\n{s}",
                .{ server.config.name, note },
            );
        }

        if (aw.written().len == 0) {
            aw.deinit();
            return null;
        }
        return try aw.toOwnedSlice();
    }

    /// One line per server that was started, for the startup banner. Nothing
    /// is written when nothing is configured: an agent without MCP tools should
    /// look exactly like the agent there was before them.
    pub fn writeStartup(self: *const Registry, w: *std.Io.Writer) !void {
        for (self.servers) |server| {
            if (server.config.disabled) continue;
            if (server.failure) |failure| {
                try w.print(style.YELLOW ++ "  ✗ mcp: {s} — {s}\n" ++ style.RESET, .{ server.config.name, failure });
            } else if (server.connection) |connection| {
                try w.print(
                    style.DIM ++ "  ✓ mcp: {s} — {d} tools, {s}\n" ++ style.RESET,
                    .{ server.config.name, server.tool_count, connection.negotiated() },
                );
            }
        }
    }

    /// The `/mcp` listing: which servers are here, and what they brought.
    pub fn writeStatus(self: *const Registry, w: *std.Io.Writer) !void {
        if (self.servers.len == 0) {
            try w.writeAll("No MCP servers are configured. Write them in mcp.json in the zagent config directory.\n");
            return;
        }

        var width: usize = 0;
        for (self.servers) |server| width = @max(width, server.config.name.len);

        try w.writeAll("MCP servers:\n");
        for (self.servers) |server| {
            try w.print("  {s}", .{server.config.name});
            try w.splatByteAll(' ', width - server.config.name.len + 2);
            try w.print("{s}  ", .{@tagName(server.config.transport)});
            // The command line is the user's own, but it is still text from
            // outside this program, and it goes to a terminal.
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            try sanitize.writeSanitized(&aw.writer, server.summary);
            try w.print("{s}  ", .{aw.written()});

            if (server.config.disabled) {
                try w.writeAll("disabled\n");
            } else if (server.failure) |failure| {
                try w.print("not connected: {s}\n", .{failure});
            } else if (server.connection) |connection| {
                try w.print("{d} tools  {s}\n", .{ server.tool_count, connection.negotiated() });
            } else {
                try w.writeAll("no tools\n");
            }
        }
        try w.writeAll("Tools from a server are named mcp__<server>__<tool>.\n");
    }
};

/// How a server is described in `/mcp`: the command it runs, or where it
/// lives. Never what it was given — a token in a header or an environment
/// variable has no business being printed.
fn summarize(allocator: std.mem.Allocator, server: ServerConfig) ![]u8 {
    switch (server.transport) {
        .stdio => |stdio| {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            try aw.writer.writeAll(stdio.command);
            for (stdio.args) |arg| try aw.writer.print(" {s}", .{arg});
            return aw.toOwnedSlice();
        },
        .http => |http| return allocator.dupe(u8, http.url),
    }
}

/// The function object the model is shown for one of a server's tools.
fn buildFunction(
    allocator: std.mem.Allocator,
    alias: []const u8,
    server: []const u8,
    description: []const u8,
    schema_json: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    // The description is prefixed with the server it came from: with several
    // connected, "Create an issue" on its own does not say where.
    const capped = description[0..@min(description.len, max_description_bytes)];
    const prefixed = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ server, capped });
    defer allocator.free(prefixed);

    try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.encodeJsonString(alias, .{}, w);
    try w.writeAll(",\"description\":");
    try std.json.Stringify.encodeJsonString(prefixed, .{}, w);
    try w.writeAll(",\"parameters\":");
    try w.writeAll(schema_json);
    try w.writeAll("}}");

    return aw.toOwnedSlice();
}

/// The spinner's label for a tool call. Built once, here, so the animation is
/// handed a string this process wrote rather than one a server did.
fn buildLabel(allocator: std.mem.Allocator, server: []const u8, tool: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.print("{s}/", .{server});
    try sanitize.writeSanitized(&aw.writer, tool);
    try aw.writer.writeAll("…");
    return aw.toOwnedSlice();
}

/// A failure, as something to say to the user rather than to parse. The errors
/// this client raises itself have a sentence; anything from the operating
/// system or from `std.http` is named, which is what its own documentation
/// calls it.
fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.McpTimeout => "it did not answer in time",
        error.McpClosed => "it closed the connection",
        error.McpProtocol => "it sent something unusable",
        error.McpMessageTooLong => "it sent more than this client reads",
        error.McpUnsupportedVersion => "it speaks no MCP revision this client knows",
        error.McpRefused => "it refused the request",
        error.McpBadEndpoint => "its url is not a url",
        error.McpInvalidEnvKey => "one of its environment variables has an unusable name",
        error.FileNotFound => "its command was not found",
        error.AccessDenied, error.PermissionDenied => "its command could not be run",
        else => @errorName(err),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A server written in the shell.
///
/// It is enough of a JSON-RPC peer to answer what this client asks — a probe,
/// a handshake, a tool list, a call — and it needs no network, no package
/// manager and no fixture file to do it. The mode picks how it behaves: a
/// modern server, one from before the handshake was removed, one that prints a
/// banner before it starts talking, and one that never answers at all.
const fake_server_script =
    \\mode=$1
    \\if [ "$mode" = noisy ]; then printf 'npm warn using --force\n'; fi
    \\while IFS= read -r line; do
    \\  id=${line#*'"id":'}
    \\  id=${id%%,*}
    \\  if [ "$mode" = silent ]; then continue; fi
    \\  case $line in
    \\    *notifications/initialized*) ;;
    \\    *'"method":"server/discover"'*)
    \\      case $mode in
    \\        modern|noisy|env) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"instructions":"Say it back."}}\n' "$id" ;;
    \\        *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    \\      esac ;;
    \\    *'"method":"initialize"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
    \\    *'"method":"tools/list"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"echo","description":"Say it back","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}}\n' "$id" ;;
    \\    *'"method":"tools/call"'*)
    \\      if [ "$mode" = env ]; then
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"token=%s"}]}}\n' "$id" "$MCP_TEST_TOKEN"
    \\      else
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"echoed"}]}}\n' "$id"
    \\      fi ;;
    \\    *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    \\  esac
    \\done
;

/// Start the shell server in `mode` and connect to it the way the agent does.
///
/// Everything it is given is owned here and outlives the connection, which
/// borrows the name it was started under.
fn startFakeServer(allocator: std.mem.Allocator, mode: []const u8, timeout_ms: i64) !Connection {
    // Nothing here is allocated on the connection's behalf: it borrows only the
    // name, which is a literal, and the command line is needed for no longer
    // than spawning the process takes.
    const argv = [_][]const u8{ "sh", "-c", fake_server_script, "fake-server", mode };

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    return Connection.connect(allocator, std.testing.io, .{
        .name = "fake",
        .transport = .{ .stdio = .{ .command = argv[0], .args = argv[1..], .env = &.{} } },
        .timeout_ms = timeout_ms,
    }, &env);
}

/// The same server, given a variable of its own. The child's environment
/// replaces its parent's, so this also proves the copy the client makes.
fn startFakeServerWithEnv(allocator: std.mem.Allocator, mode: []const u8) !Connection {
    const argv = [_][]const u8{ "sh", "-c", fake_server_script, "fake-server", mode };
    const pairs = [_][2][]const u8{.{ "MCP_TEST_TOKEN", "s3cret" }};

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    return Connection.connect(allocator, std.testing.io, .{
        .name = "fake",
        .transport = .{ .stdio = .{ .command = argv[0], .args = argv[1..], .env = &pairs } },
        .timeout_ms = 5_000,
    }, &env);
}

fn scriptedConnection(allocator: std.mem.Allocator, script: []const transport.Answer) Connection {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .name = "fake",
        .transport = .{ .scripted = transport.Scripted.init(allocator, script) },
        .timeout_ms = 200,
    };
}

test "an alias fits what an endpoint accepts" {
    const allocator = std.testing.allocator;

    const plain = try aliasFor(allocator, "github", "create_issue");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("mcp__github__create_issue", plain);

    // A tool named with characters an endpoint will not take keeps its shape:
    // each of them becomes an underscore.
    const dotted = try aliasFor(allocator, "my.server", "tools.list");
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("mcp__my_server__tools_list", dotted);

    // A name too long for an endpoint is cut short and given a hash of what it
    // was, so two long names do not quietly become one name.
    const long_a = try aliasFor(allocator, "server", "a" ** 120);
    defer allocator.free(long_a);
    const long_b = try aliasFor(allocator, "server", "a" ** 119 ++ "b");
    defer allocator.free(long_b);

    try std.testing.expectEqual(@as(usize, max_tool_name), long_a.len);
    try std.testing.expectEqual(@as(usize, max_tool_name), long_b.len);
    try std.testing.expect(!std.mem.eql(u8, long_a, long_b));
    for (long_a) |byte| try std.testing.expect(isNameByte(byte));
}

test "arguments are written back as one line of JSON" {
    const allocator = std.testing.allocator;

    // A newline between two tokens is legal JSON and would break the stdio
    // binding, which is one message per line.
    const spread = try normalizeArguments(allocator, "{\n \"path\": \"/tmp\"\n}");
    defer allocator.free(spread);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", spread);

    // Anything that is not a JSON object is refused rather than sent on.
    try std.testing.expectError(error.McpInvalidArguments, normalizeArguments(allocator, "[]"));
    try std.testing.expectError(error.McpInvalidArguments, normalizeArguments(allocator, "not json"));
    try std.testing.expectError(error.McpInvalidArguments, normalizeArguments(allocator, ""));
}

test "a text result is what the model reads" {
    const allocator = std.testing.allocator;
    const result = try renderCallResult(allocator,
        \\{"resultType":"complete","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("first\nsecond", result.content);
    try std.testing.expect(!result.is_error);
}

test "bytes are named rather than carried" {
    const allocator = std.testing.allocator;
    const result = try renderCallResult(allocator,
        \\{"resultType":"complete","content":[{"type":"text","text":"look"},
        \\ {"type":"image","data":"AAAA","mimeType":"image/png"}]}
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("look\n[image: image/png, 3 bytes]", result.content);
}

test "links, embedded resources and an unknown kind are all readable" {
    const allocator = std.testing.allocator;
    const result = try renderCallResult(allocator,
        \\{"resultType":"complete","content":[
        \\ {"type":"resource_link","uri":"file:///tmp/a.txt","name":"a.txt"},
        \\ {"type":"resource","resource":{"uri":"file:///tmp/b.txt","text":"body"}},
        \\ {"type":"resource","resource":{"uri":"file:///tmp/c.bin","mimeType":"application/pdf"}},
        \\ {"type":"blob","data":"zz"}]}
    );
    defer result.deinit(allocator);

    // An unknown kind is named rather than dropped: refusing it would lose the
    // rest of a result that is still readable.
    try std.testing.expectEqualStrings(
        "[resource: file:///tmp/a.txt]\nbody\n[resource: file:///tmp/c.bin (application/pdf)]\n[blob content]",
        result.content,
    );
}

test "a result the server marked as an error stays an error" {
    const allocator = std.testing.allocator;
    const result = try renderCallResult(allocator,
        \\{"resultType":"complete","isError":true,"content":[{"type":"text","text":"no such file"}]}
    );
    defer result.deinit(allocator);

    // A tool execution error is what the model can correct itself with.
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("Error: no such file", result.content);
}

test "structured content stands in when there is no text" {
    const allocator = std.testing.allocator;
    const result = try renderCallResult(allocator,
        \\{"resultType":"complete","structuredContent":{"count":2}}
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("{\"count\":2}", result.content);
}

test "a request for more input is explained rather than guessed at" {
    const allocator = std.testing.allocator;
    const result = try renderCallResult(allocator,
        \\{"resultType":"input_required","inputRequests":{"login":{"method":"elicitation/create"}}}
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "multi-round-trip") != null);
}

test "an empty result says so" {
    const allocator = std.testing.allocator;
    // A result with no `resultType` at all is what a server from before the
    // current revision sends, and it means the call is complete.
    const result = try renderCallResult(allocator, "{\"content\":[]}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("(the tool returned nothing)", result.content);
}

test "mcp.json is read into servers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "zagent", std.Io.File.Permissions.default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "zagent/mcp.json", .data = 
        \\{
        \\  "mcpServers": {
        \\    "filesystem": {
        \\      "command": "npx",
        \\      "args": ["-y", "server-filesystem", "/tmp"],
        \\      "env": {"TOKEN": "secret"},
        \\      "timeoutMs": 5000
        \\    },
        \\    "remote": {"url": "https://example.com/mcp", "headers": {"Authorization": "Bearer t"}},
        \\    "off": {"command": "slow", "disabled": true},
        \\    "broken": {"command": "a", "url": "b"},
        \\    "nameless": {"timeoutMs": 100}
        \\  }
        \\}
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", home);

    var problems: std.ArrayList([]u8) = .empty;
    defer {
        for (problems.items) |problem| allocator.free(problem);
        problems.deinit(allocator);
    }

    const servers = try loadServers(allocator, io, &env, &problems);
    defer freeServers(allocator, servers);

    // One typo costs the entry it is in, and nothing else.
    try std.testing.expectEqual(@as(usize, 3), servers.len);
    try std.testing.expectEqual(@as(usize, 2), problems.items.len);

    try std.testing.expectEqualStrings("filesystem", servers[0].name);
    try std.testing.expectEqualStrings("npx", servers[0].transport.stdio.command);
    try std.testing.expectEqual(@as(usize, 3), servers[0].transport.stdio.args.len);
    try std.testing.expectEqualStrings("/tmp", servers[0].transport.stdio.args[2]);
    try std.testing.expectEqualStrings("TOKEN", servers[0].transport.stdio.env[0][0]);
    try std.testing.expectEqualStrings("secret", servers[0].transport.stdio.env[0][1]);
    try std.testing.expectEqual(@as(i64, 5000), servers[0].timeout_ms);
    try std.testing.expect(!servers[0].disabled);

    try std.testing.expectEqualStrings("remote", servers[1].name);
    try std.testing.expectEqualStrings("https://example.com/mcp", servers[1].transport.http.url);
    try std.testing.expectEqualStrings("Authorization", servers[1].transport.http.headers[0][0]);
    // A server with no timeout gets the default rather than none.
    try std.testing.expectEqual(@as(i64, default_timeout_ms), servers[1].timeout_ms);

    try std.testing.expect(servers[2].disabled);
}

test "mcp.json is optional and a broken one costs only itself" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "zagent", std.Io.File.Permissions.default_dir);

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", home);

    var problems: std.ArrayList([]u8) = .empty;
    defer {
        for (problems.items) |problem| allocator.free(problem);
        problems.deinit(allocator);
    }

    // No file at all: no servers, and nothing to say about it.
    {
        const servers = try loadServers(allocator, io, &env, &problems);
        defer freeServers(allocator, servers);
        try std.testing.expectEqual(@as(usize, 0), servers.len);
        try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    }

    // A file that is not JSON is reported, and is not fatal.
    try tmp.dir.writeFile(io, .{ .sub_path = "zagent/mcp.json", .data = "{ not json" });
    {
        const servers = try loadServers(allocator, io, &env, &problems);
        defer freeServers(allocator, servers);
        try std.testing.expectEqual(@as(usize, 0), servers.len);
        try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    }

    // An environment key that cannot be written as one is refused, and the
    // process does not die of it.
    try tmp.dir.writeFile(io, .{ .sub_path = "zagent/mcp.json", .data =
        \\{"mcpServers": {"bad": {"command": "srv", "env": {"A=B": "x"}},
        \\                 "good": {"command": "srv"}}}
    });
    {
        const before = problems.items.len;
        const servers = try loadServers(allocator, io, &env, &problems);
        defer freeServers(allocator, servers);

        // The variable is lost and reported; the server is not, because a
        // server that never needed it still works.
        try std.testing.expectEqual(@as(usize, 2), servers.len);
        try std.testing.expectEqualStrings("bad", servers[0].name);
        try std.testing.expectEqual(@as(usize, 0), servers[0].transport.stdio.env.len);
        try std.testing.expectEqualStrings("good", servers[1].name);
        try std.testing.expectEqual(before + 1, problems.items.len);
    }
}

test "a modern server is met without a handshake" {
    const allocator = std.testing.allocator;

    var connection = scriptedConnection(allocator, &.{
        .{ .result = 
            \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},
            \\ "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"fake","version":"1"}}}
        },
    });
    defer connection.deinit();

    try connection.negotiate();

    try std.testing.expectEqual(Era.modern, connection.era);
    try std.testing.expectEqualStrings(modern_protocol_version, connection.negotiated());
    try std.testing.expectEqualStrings("fake", connection.server_info.?);
    try std.testing.expectEqual(@as(usize, 1), connection.transport.scripted.sent.items.len);
    // The request carries the per-request fields that make the revision
    // stateless.
    try std.testing.expect(std.mem.indexOf(u8, connection.transport.scripted.sent.items[0], "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connection.transport.scripted.sent.items[0], "\"io.modelcontextprotocol/clientCapabilities\":{}") != null);
}

test "a server from before the handshake was removed is opened the old way" {
    const allocator = std.testing.allocator;

    var connection = scriptedConnection(allocator, &.{
        // The probe is answered the way a server that has never heard of it
        // answers: a method it does not have.
        .{ .err = .{ .code = -32601, .message = "Method not found" } },
        .{ .result = "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}}" },
    });
    defer connection.deinit();

    try connection.negotiate();

    try std.testing.expectEqual(Era.legacy, connection.era);
    try std.testing.expectEqualStrings("2025-06-18", connection.negotiated());

    const sent = connection.transport.scripted.sent.items;
    try std.testing.expectEqual(@as(usize, 3), sent.len);
    try std.testing.expect(std.mem.indexOf(u8, sent[0], "server/discover") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent[1], "initialize") != null);
    // The handshake belongs to a revision without per-request metadata, so it
    // must not carry any.
    try std.testing.expect(std.mem.indexOf(u8, sent[1], "_meta") == null);
    // And the notification that follows has no id: nothing answers it.
    try std.testing.expect(std.mem.indexOf(u8, sent[2], "notifications/initialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent[2], "\"id\"") == null);
}

test "a server that is silent on the probe but knows the handshake is modern" {
    const allocator = std.testing.allocator;

    var connection = scriptedConnection(allocator, &.{
        .silence,
        .{ .err = .{ .code = -32601, .message = "Method not found" } },
    });
    defer connection.deinit();

    try connection.negotiate();

    // A server that does not know `initialize` cannot be an old one, however
    // the probe went.
    try std.testing.expectEqual(Era.modern, connection.era);
}

test "a version the server does not have is read from its refusal" {
    const allocator = std.testing.allocator;

    {
        var connection = scriptedConnection(allocator, &.{
            .{ .err = .{
                .code = unsupported_protocol_version,
                .message = "Unsupported protocol version",
                .data = "{\"supported\":[\"2026-07-28\"],\"requested\":\"1900-01-01\"}",
            } },
        });
        defer connection.deinit();

        // A server that answers like this is modern, and this client knows the
        // revision it lists.
        try connection.negotiate();
        try std.testing.expectEqual(Era.modern, connection.era);
    }

    {
        var connection = scriptedConnection(allocator, &.{
            .{ .err = .{
                .code = unsupported_protocol_version,
                .message = "Unsupported protocol version",
                .data = "{\"supported\":[\"2025-11-25\",\"2025-06-18\"]}",
            } },
            .{ .result = "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{}}" },
        });
        defer connection.deinit();

        // One whose list holds only the revisions from before the current one
        // is opened the old way, which is what that list is for.
        try connection.negotiate();
        try std.testing.expectEqual(Era.legacy, connection.era);
        try std.testing.expectEqualStrings("2025-06-18", connection.negotiated());
    }
}

test "the shell server answers tools over stdio" {
    const allocator = std.testing.allocator;

    var connection = try startFakeServer(allocator, "modern", 5_000);
    defer connection.deinit();

    try std.testing.expectEqual(Era.modern, connection.era);
    try std.testing.expectEqualStrings("Say it back.", connection.instructions.?);

    const listed = try connection.listTools(allocator);
    defer {
        for (listed) |tool| tool.deinit(allocator);
        allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("echo", listed[0].name);
    try std.testing.expect(std.mem.indexOf(u8, listed[0].schema_json, "\"text\"") != null);

    var response = try connection.callTool(allocator, "echo", "{\"text\":\"hi\"}");
    defer response.deinit(allocator);

    var rendered = try renderCallResult(allocator, response.result);
    defer rendered.deinit(allocator);
    try std.testing.expectEqualStrings("echoed", rendered.content);
    try std.testing.expect(!rendered.is_error);
}

test "the shell server is opened the old way when it needs the handshake" {
    const allocator = std.testing.allocator;

    var connection = try startFakeServer(allocator, "legacy", 5_000);
    defer connection.deinit();

    try std.testing.expectEqual(Era.legacy, connection.era);
    try std.testing.expectEqualStrings("2025-06-18", connection.negotiated());

    // The tool list still comes back: it is asked for in the revision the
    // handshake settled on.
    const listed = try connection.listTools(allocator);
    defer {
        for (listed) |tool| tool.deinit(allocator);
        allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
}

test "a server that prints a banner before its first message still connects" {
    const allocator = std.testing.allocator;

    // npm and friends write to stdout before the server has said anything.
    var connection = try startFakeServer(allocator, "noisy", 5_000);
    defer connection.deinit();

    try std.testing.expectEqual(Era.modern, connection.era);
}

test "a server that never answers is given up on" {
    const allocator = std.testing.allocator;

    // Both questions go unanswered, so the second one's deadline is what ends
    // this: the probe's, then the handshake's.
    try std.testing.expectError(error.McpTimeout, startFakeServer(allocator, "silent", 150));
}

test "a tool the registry does not have is named as such" {
    const allocator = std.testing.allocator;

    var registry: Registry = .{
        .allocator = allocator,
        .io = std.testing.io,
        .servers = &.{},
        .tools = &.{},
        .tool_json = &.{},
    };
    defer registry.deinit();

    const result = try registry.call(allocator, "mcp__nobody__nothing", "{}");
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "mcp__nobody__nothing") != null);
    // Nothing is advertised and nothing has a label: a name the model invented
    // is not a reason to write anything to the terminal.
    try std.testing.expectEqual(@as(usize, 0), registry.functionJson().len);
    try std.testing.expectEqual(@as(?[]const u8, null), registry.progressLabel("mcp__nobody__nothing"));
}

test "a server is given the variables its configuration adds" {
    const allocator = std.testing.allocator;

    var connection = try startFakeServerWithEnv(allocator, "env");
    defer connection.deinit();

    var response = try connection.callTool(allocator, "echo", "{}");
    defer response.deinit(allocator);

    var rendered = try renderCallResult(allocator, response.result);
    defer rendered.deinit(allocator);

    // The variable reached the child, which means the environment the client
    // built for it carried both what it was configured with and what this
    // process already had.
    try std.testing.expectEqualStrings("token=s3cret", rendered.content);
}

test "the /mcp listing names the servers and what they brought" {
    const allocator = std.testing.allocator;

    // Everything here is handed to the registry, which is then what frees it:
    // a copy left on the stack would be freed twice.
    var connection = try startFakeServer(allocator, "modern", 5_000);
    errdefer connection.deinit();

    const servers = try allocator.alloc(Server, 1);
    servers[0] = .{
        .config = .{
            .name = try allocator.dupe(u8, "fake"),
            .transport = .{ .stdio = .{ .command = try allocator.dupe(u8, "sh"), .args = &.{}, .env = &.{} } },
            .timeout_ms = 5_000,
        },
        .connection = connection,
        .summary = try allocator.dupe(u8, "sh -c …"),
        .tool_count = 1,
    };

    var registry: Registry = .{
        .allocator = allocator,
        .io = std.testing.io,
        .servers = servers,
        .tools = &.{},
        .tool_json = &.{},
    };
    defer registry.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try registry.writeStatus(&aw.writer);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "MCP servers:") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "fake") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "1 tools  2026-07-28") != null);
    // The summary is the command, never the environment: that is where a token
    // lives.
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "s3cret") == null);
}

test "over http the era is read from a refusal" {
    const allocator = std.testing.allocator;

    // A `400` whose body is a JSON-RPC error this client recognizes: the
    // server speaks the current protocol and is refusing this revision of it.
    {
        var connection = scriptedConnection(allocator, &.{});
        defer connection.deinit();

        try std.testing.expectEqual(Connection.Settlement.settled, try connection.judgeRefusal(
            400,
            \\{"jsonrpc":"2.0","error":{"code":-32022,"message":"Unsupported protocol version",
            \\ "data":{"supported":["2026-07-28","2025-11-25"]}}}
        ));
        try std.testing.expectEqual(Era.modern, connection.era);
    }

    // The same status with a body that is not one: a server from before the
    // current revision, which has never heard of the headers a modern request
    // carries. That is the case the handshake exists for.
    {
        var connection = scriptedConnection(allocator, &.{});
        defer connection.deinit();

        try std.testing.expectEqual(Connection.Settlement.ask_for_handshake, try connection.judgeRefusal(400, "Bad Request"));
        try std.testing.expectEqual(Connection.Settlement.ask_for_handshake, try connection.judgeRefusal(404, ""));
    }

    // Any other status is not a question about the era at all.
    {
        var connection = scriptedConnection(allocator, &.{});
        defer connection.deinit();

        try std.testing.expectError(error.McpRefused, connection.judgeRefusal(403, "{}"));
        try std.testing.expectError(error.McpRefused, connection.judgeRefusal(500, "{}"));
    }
}

test "the registry connects what mcp.json names, end to end" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "zagent", std.Io.File.Permissions.default_dir);

    // The shell server is described in JSON rather than in a file, so nothing
    // has to be written for it but the configuration itself.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"mcpServers\":{\"demo\":{\"command\":\"sh\",\"args\":[");
    for ([_][]const u8{ "-c", fake_server_script, "demo", "modern" }, 0..) |arg, index| {
        if (index > 0) try aw.writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(arg, .{}, &aw.writer);
    }
    try aw.writer.writeAll("]}}}");
    try tmp.dir.writeFile(io, .{ .sub_path = "zagent/mcp.json", .data = aw.written() });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", home);

    var problems: std.ArrayList([]u8) = .empty;
    defer {
        for (problems.items) |problem| allocator.free(problem);
        problems.deinit(allocator);
    }

    var registry = try Registry.connect(allocator, io, &env, &problems, null);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), registry.servers.len);
    try std.testing.expectEqual(@as(usize, 1), registry.functionJson().len);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.len);
    try std.testing.expectEqualStrings("mcp__demo__echo", registry.tools[0].alias);

    // What the model is offered is a function object with the server's schema.
    try std.testing.expect(std.mem.indexOf(u8, registry.functionJson()[0], "\"name\":\"mcp__demo__echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.functionJson()[0], "\"required\":[\"text\"]") != null);

    // A label the spinner may show, and nothing at all for a name it invented.
    try std.testing.expectEqualStrings("demo/echo…", registry.progressLabel("mcp__demo__echo").?);
    try std.testing.expectEqual(@as(?[]const u8, null), registry.progressLabel("mcp__demo__guess"));

    // And a call goes all the way out and back.
    const result = try registry.call(allocator, "mcp__demo__echo", "{\"text\":\"hi\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("echoed", result.content);
    try std.testing.expect(!result.is_error);
}
