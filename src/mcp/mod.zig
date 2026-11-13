//! The MCP client: the servers zagent is configured to talk to, what they
//! offer, and how a call reaches them.
//!
//! A server is described in `mcp.json`, in the zagent config directory, and
//! connected to once at startup: its tools are listed, named so the model can
//! call them, and handed to the agent as extra function tools. `tools/call` on
//! one of those names comes back through here and is forwarded as it is.
//!
//! Only the stateless revision is supported: every request declares the
//! revision and the client's capabilities in `_meta`. Discovery verifies the
//! server before tools are listed; older handshake revisions are rejected.

const std = @import("std");
const transport = @import("transport.zig");
const tools = @import("../tools/mod.zig");
const config = @import("../model/config.zig");
// `text` is the name every other module imports this under, and also the name
// of half the values in this one; it is imported as what it is used for here.
const sanitize = @import("../util/text.zig");
const style = @import("../ui/style.zig");

/// The revision this client speaks. It is the current one: no session, no
/// handshake, everything a request needs carried in the request.
pub const modern_protocol_version = "2026-07-28";

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
    /// Short service-level description for lazy discovery by the model.
    description: ?[]const u8 = null,
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
        if (self.description) |text| allocator.free(text);
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
            errdefer server.deinit(allocator);
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
    const problem = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(problem);
    try problems.append(allocator, problem);
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
    const description = try stringMember(allocator, entry.get("description"));
    errdefer if (description) |text| allocator.free(text);

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
            .description = description,
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
        .description = description,
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
                const owned = try allocator.dupe(u8, item.string);
                errdefer allocator.free(owned);
                try list.append(allocator, owned);
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

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Borrowed from the caller: the server's name, for messages.
    name: []const u8,
    transport: transport.Transport,
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
                connection.transport = .{ .http = transport.Http.init(io, .{
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
        if (self.failed) |reason| self.allocator.free(reason);
        self.server_info = null;
        self.instructions = null;
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

    /// Discover the current stateless revision; never retry an old handshake.
    pub fn negotiate(self: *Connection) !void {
        const response = try self.request(.{
            .method = "server/discover",
            .timeout_ms = @min(self.timeout_ms, probe_timeout_cap_ms),
        });
        defer response.deinit(self.allocator);
        switch (response) {
            .result => |text| try self.readDiscover(self.allocator, text),
            .err => |err| return if (err.code == unsupported_protocol_version or err.code == -32601)
                error.McpUnsupportedVersion
            else
                error.McpServerError,
            .http_error => |refusal| try self.judgeRefusal(refusal.status, refusal.body),
            .accepted => return error.McpProtocol,
        }
    }

    fn readDiscover(self: *Connection, allocator: std.mem.Allocator, result_json: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch
            return error.McpProtocol;
        defer parsed.deinit();
        if (parsed.value != .object) return error.McpProtocol;
        const object = parsed.value.object;
        if (object.get("supportedVersions")) |versions| {
            if (versions != .array) return error.McpProtocol;
            if (!versionOffered(versions.array.items, modern_protocol_version)) return error.McpUnsupportedVersion;
        }
        try self.readIdentity(allocator, object);
    }

    fn judgeRefusal(self: *Connection, status: u16, body: []const u8) !void {
        if (status == 400) {
            if (try readError(self.allocator, body)) |err| {
                defer err.deinit(self.allocator);
                if (isModernErrorCode(err.code)) return error.McpUnsupportedVersion;
            }
        }
        return error.McpRefused;
    }

    fn readIdentity(self: *Connection, allocator: std.mem.Allocator, object: std.json.ObjectMap) !void {
        if (object.get("instructions")) |instructions| {
            if (instructions == .string and instructions.string.len > 0) {
                const capped = instructions.string[0..@min(instructions.string.len, max_instructions_bytes)];
                if (self.instructions) |previous| allocator.free(previous);
                self.instructions = try allocator.dupe(u8, capped);
            }
        }

        const info = if (object.get("_meta")) |meta|
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
            const params = try listParams(allocator, cursor);
            defer allocator.free(params);

            const response = try self.request(.{
                .method = "tools/list",
                .params_json = params,
                .timeout_ms = self.timeout_ms,
            });
            defer response.deinit(self.allocator);

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

            cursor = try readToolPage(allocator, result_json, &listed);
            if (listed.items.len >= max_tools_per_server) break;
            if (cursor == null) break;
        }

        return listed.toOwnedSlice(allocator);
    }

    /// Call one tool. The result is the JSON text of the `result` member, for
    /// the caller to shape into something the model can read.
    /// The response is owned by `self.allocator`, not the params allocator.
    pub fn callTool(
        self: *Connection,
        allocator: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) !transport.Response {
        const params = try callParams(allocator, name, arguments_json);
        defer allocator.free(params);

        return self.request(.{
            .method = "tools/call",
            .params_json = params,
            .name = name,
            .timeout_ms = self.timeout_ms,
        });
    }

    const Request = struct {
        method: []const u8,
        params_json: ?[]const u8 = null,
        name: ?[]const u8 = null,
        timeout_ms: i64,
    };

    /// Send one request and read the answer. Everything that reaches the wire
    /// goes through here, so the id, the `_meta` fields and the headers a
    /// request is routed on are decided in one place.
    fn request(self: *Connection, options: Request) !transport.Response {
        if (self.failed) |_| return error.McpUnavailable;

        const id = self.next_id;
        self.next_id += 1;

        const params = if (options.params_json == null)
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
            .protocol_version = modern_protocol_version,
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
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.McpProtocol,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpProtocol;
    const object = parsed.value.object;

    if (object.get("tools")) |tools_value| {
        if (tools_value == .array) {
            for (tools_value.array.items) |item| {
                if (listed.items.len >= max_tools_per_server) break;
                if (item != .object) continue;
                const tool = try readTool(allocator, item.object) orelse continue;
                errdefer tool.deinit(allocator);
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

    const schema_json = if (object.get("inputSchema")) |schema|
        (if (schema == .object)
            try std.json.Stringify.valueAlloc(allocator, schema, .{})
        else
            try std.json.Stringify.valueAlloc(allocator, .{ .type = "object" }, .{}))
    else
        try std.json.Stringify.valueAlloc(allocator, .{ .type = "object" }, .{});

    return .{
        .name = owned_name,
        .description = owned_description,
        .schema_json = schema_json,
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

/// Typed metadata shared by requests in the stateless protocol revision.
const RequestMeta = struct {
    @"io.modelcontextprotocol/protocolVersion": []const u8 = modern_protocol_version,
    @"io.modelcontextprotocol/clientInfo": ClientInfo = .{},
    @"io.modelcontextprotocol/clientCapabilities": struct {} = .{},
};

const ClientInfo = struct {
    name: []const u8 = client_name,
    version: []const u8 = client_version,
};

fn metaParams(allocator: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ ._meta = RequestMeta{} }, .{});
}

fn listParams(allocator: std.mem.Allocator, cursor: ?[]const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .cursor = cursor,
        ._meta = RequestMeta{},
    }, .{ .emit_null_optional_fields = false });
}

fn callParams(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidArguments;
    return std.json.Stringify.valueAlloc(allocator, .{
        .name = name,
        .arguments = parsed.value,
        ._meta = RequestMeta{},
    }, .{ .emit_null_optional_fields = false });
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

    return tools.finalizeResult(allocator, aw.written(), .{ .is_error = is_error });
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
    return tools.finalizeResult(allocator, raw, .{ .is_error = true });
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
    loaded: bool = false,

    fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        if (self.connection) |*connection| connection.deinit();
        if (self.failure) |failure| allocator.free(failure);
        allocator.free(self.summary);
        self.config.deinit(allocator);
    }
};

pub const Registry = struct {
    const loader_spec = @import("../tools/load_mcp_tools.zig").spec;
    pub const loader_name = loader_spec.name;
    // These static strings contain no JSON escapes; schema tests validate them.
    const loader_json = "{\"name\":\"" ++ loader_spec.name ++
        "\",\"description\":\"" ++ loader_spec.description ++
        "\",\"parameters\":" ++ loader_spec.parameters_json ++ "}";
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
        // Ownership has moved to the registry, including on later errors.

        try self.refreshFunctions();

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

    pub fn refreshFunctions(self: *Registry) !void {
        var views: std.ArrayList([]const u8) = .empty;
        errdefer views.deinit(self.allocator);
        if (self.tools.len > 0) try views.append(self.allocator, loader_json);
        for (self.tools) |tool| {
            if (self.servers[tool.server].loaded) try views.append(self.allocator, tool.function);
        }
        const replacement = try views.toOwnedSlice(self.allocator);
        self.allocator.free(self.tool_json);
        self.tool_json = replacement;
    }

    /// Activate one service, without copying its schemas into conversation history.
    pub fn loadTools(self: *Registry, allocator: std.mem.Allocator, arguments_json: []const u8) !tools.ToolResult {
        return @import("../tools/load_mcp_tools.zig").execute(self, allocator, arguments_json);
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
        if (!server.loaded) {
            return errorResult(allocator, "Load MCP server '{s}' with load_mcp_tools before calling its tools.", .{server.config.name});
        }

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
            var result = try errorResult(
                allocator,
                "Calling '{s}' on \"{s}\" failed: {s}",
                .{ tool.remote_name, server.config.name, describeError(err) },
            );
            result.timed_out = err == error.McpTimeout;
            return result;
        };
        defer response.deinit(connection.allocator);

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

    /// Compact service directory, not full instructions, for the system prompt.
    pub fn instructions(self: *const Registry, allocator: std.mem.Allocator) !?[]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();

        for (self.servers) |server| {
            const connection = server.connection orelse continue;
            if (server.failure != null or server.tool_count == 0) continue;
            const note = server.config.description orelse connection.instructions orelse "No description provided.";
            // Keep the startup directory small even when a server returns a manual.
            var end = @min(note.len, 320);
            while (end > 0 and end < note.len and (note[end] & 0xc0) == 0x80) : (end -= 1) {}
            try aw.writer.print(
                "\n- MCP server \"{s}\": {s}{s}",
                .{ server.config.name, note[0..end], if (end < note.len) "…" else "" },
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
            } else if (server.connection != null) {
                try w.print(
                    style.DIM ++ "  ✓ mcp: {s} — {d} tools, {s}\n" ++ style.RESET,
                    .{ server.config.name, server.tool_count, modern_protocol_version },
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
            } else if (server.connection != null) {
                try w.print("{d} tools  {s}\n", .{ server.tool_count, modern_protocol_version });
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
    // Prefix descriptions with the server they came from.
    const capped = description[0..@min(description.len, max_description_bytes)];
    const prefixed = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ server, capped });
    defer allocator.free(prefixed);
    const schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
    defer schema.deinit();
    if (schema.value != .object) return error.InvalidToolSchema;
    return std.json.Stringify.valueAlloc(allocator, .{
        .type = "function",
        .function = .{ .name = alias, .description = prefixed, .parameters = schema.value },
    }, .{});
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
/// A JSON-RPC peer for discovery, tool listing and calls, requiring no network
/// or package manager. Modes cover normal, noisy, environment-aware and silent
/// servers.
const fake_server_script =
    \\mode=$1
    \\if [ "$mode" = noisy ]; then printf 'npm warn using --force\n'; fi
    \\while IFS= read -r line; do
    \\  id=${line#*'"id":'}
    \\  id=${id%%,*}
    \\  if [ "$mode" = silent ]; then continue; fi
    \\  case $line in
    \\    *'"method":"server/discover"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"instructions":"Say it back."}}\n' "$id" ;;
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

/// These fixtures require a POSIX shell.
fn skipUnlessPosix() !void {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
}

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
    const long_a = try aliasFor(allocator, "server", @import("../util/text.zig").repeat("a", 120));
    defer allocator.free(long_a);
    const long_b = try aliasFor(allocator, "server", @import("../util/text.zig").repeat("a", 119) ++ "b");
    defer allocator.free(long_b);

    try std.testing.expectEqual(@as(usize, max_tool_name), long_a.len);
    try std.testing.expectEqual(@as(usize, max_tool_name), long_b.len);
    try std.testing.expect(!std.mem.eql(u8, long_a, long_b));
    for (long_a) |byte| try std.testing.expect(isNameByte(byte));
}

test "MCP params and schemas round trip escaped strings and optional fields" {
    const a = std.testing.allocator;
    const name = "echo\"\\\n测试";
    {
        const params = try callParams(a, name, "{\n\"nested\":{\"value\":null},\"text\":\"line\\nquote\\\"\"}");
        defer a.free(params);
        const decoded = try std.json.parseFromSlice(std.json.Value, a, params, .{});
        defer decoded.deinit();
        const object = decoded.value.object;
        try std.testing.expectEqualStrings(name, object.get("name").?.string);
        try std.testing.expect(object.contains("_meta"));
        try std.testing.expect(object.get("arguments").?.object.get("nested").?.object.get("value").? == .null);
        try std.testing.expect(std.mem.indexOfScalar(u8, params, '\n') == null);
        const listing = try listParams(a, name);
        defer a.free(listing);
        const page = try std.json.parseFromSlice(std.json.Value, a, listing, .{});
        defer page.deinit();
        try std.testing.expectEqualStrings(name, page.value.object.get("cursor").?.string);
        try std.testing.expect(page.value.object.contains("_meta"));
    }
    const function = try buildFunction(a, name, "server\"", "description\n\\", "{\n\"type\":\"object\",\"x-custom\":null}");
    defer a.free(function);
    const decoded = try std.json.parseFromSlice(std.json.Value, a, function, .{});
    defer decoded.deinit();
    const object = decoded.value.object.get("function").?.object;
    try std.testing.expectEqualStrings(name, object.get("name").?.string);
    try std.testing.expectEqualStrings("server\": description\n\\", object.get("description").?.string);
    try std.testing.expect(object.get("parameters").?.object.get("x-custom").? == .null);
    try std.testing.expectError(error.McpInvalidArguments, callParams(a, name, "[]"));
    try std.testing.expectError(error.SyntaxError, callParams(a, name, "{} , \"injected\":true"));
    try std.testing.expectError(error.InvalidToolSchema, buildFunction(a, name, "s", "d", "[]"));
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
        \\      "description": "Browse local files",
        \\      "args": ["-y", "server-filesystem", "/tmp"],
        \\      "env": {"TOKEN": "secret"},
        \\      "timeoutMs": 5000
        \\    },
        \\    "remote": {"url": "https://example.com/mcp", "description": "Remote service", "headers": {"Authorization": "Bearer t"}},
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
    try std.testing.expectEqualStrings("Browse local files", servers[0].description.?);
    try std.testing.expectEqualStrings("Remote service", servers[1].description.?);
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

fn checkToolPageAllocationFailures(allocator: std.mem.Allocator) !void {
    var listed: std.ArrayList(RemoteTool) = .empty;
    defer {
        for (listed.items) |tool| tool.deinit(allocator);
        listed.deinit(allocator);
    }
    const cursor = try readToolPage(allocator,
        \\{"tools":[{"name":"one"},{"name":"two","description":"second"}],"nextCursor":"more"}
    , &listed);
    defer if (cursor) |value| allocator.free(value);
    try std.testing.expectEqual(@as(usize, 2), listed.items.len);
}

fn checkProblemAllocationFailures(allocator: std.mem.Allocator) !void {
    var problems: std.ArrayList([]u8) = .empty;
    defer {
        for (problems.items) |problem| allocator.free(problem);
        problems.deinit(allocator);
    }
    try addProblem(allocator, &problems, "problem {d}", .{42});
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[\"one\",\"two\"]", .{});
    defer parsed.deinit();
    const strings = try stringList(allocator, parsed.value);
    defer {
        for (strings) |item| allocator.free(item);
        allocator.free(strings);
    }
}

test "MCP page and diagnostic allocation failures release partial results" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkToolPageAllocationFailures, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkProblemAllocationFailures, .{});
}

test "MCP pagination caps each page and frees cursor at the tool limit" {
    const a = std.testing.allocator;
    const page = "{\"tools\":[" ++ sanitize.repeat("{\"name\":\"tool\"},", 256) ++ "{\"name\":\"extra\"}],\"nextCursor\":\"more\"}";
    var connection = scriptedConnection(a, &.{.{ .result = page }});
    defer connection.deinit();
    // A separate arena catches accidental response destruction via this allocator.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const listed = try connection.listTools(arena.allocator());
    defer {
        for (listed) |tool| tool.deinit(arena.allocator());
        arena.allocator().free(listed);
    }
    try std.testing.expectEqual(max_tools_per_server, listed.len);
    try std.testing.expectEqual(@as(usize, 1), connection.transport.scripted.sent.items.len);

    var paged = scriptedConnection(a, &.{
        .{ .result = "{\"tools\":[{\"name\":\"first\"}],\"nextCursor\":\"page2\"}" },
        .{ .result = "{\"tools\":[{\"name\":\"second\"}]}" },
    });
    defer paged.deinit();
    const both = try paged.listTools(a);
    defer {
        for (both) |tool| tool.deinit(a);
        a.free(both);
    }
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqualStrings("second", both[1].name);
    try std.testing.expect(std.mem.indexOf(u8, paged.transport.scripted.sent.items[1], "page2") != null);
}

test "MCP collectTools errors leave transferred tools owned by registry" {
    const a = std.testing.allocator;
    var reached_success = false;
    for (0..200) |fail_index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const f = failing.allocator();
        const servers = try a.alloc(Server, 1);
        servers[0] = .{
            .config = .{
                .name = try a.dupe(u8, "fake"),
                .transport = .{ .http = .{ .url = try a.dupe(u8, "http://unused"), .headers = &.{} } },
            },
            .summary = try a.dupe(u8, "scripted"),
            .connection = scriptedConnection(f, &.{.{ .result = "{\"tools\":[{\"name\":\"one\"},{\"name\":\"two\"}]}" }}),
        };
        var registry: Registry = .{
            .allocator = f,
            .io = std.testing.io,
            .servers = servers,
            .tools = &.{},
            .tool_json = &.{},
        };
        defer registry.deinit();
        var problems: std.ArrayList([]u8) = .empty;
        defer {
            for (problems.items) |problem| f.free(problem);
            problems.deinit(f);
        }
        registry.collectTools(&problems) catch continue;
        if (!failing.has_induced_failure) {
            try std.testing.expectEqual(@as(usize, 2), registry.tools.len);
            reached_success = true;
            break;
        }
    }
    try std.testing.expect(reached_success);
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

    try std.testing.expectEqualStrings("fake", connection.server_info.?);
    try std.testing.expectEqual(@as(usize, 1), connection.transport.scripted.sent.items.len);
    // The request carries the per-request fields that make the revision
    // stateless.
    try std.testing.expect(std.mem.indexOf(u8, connection.transport.scripted.sent.items[0], "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connection.transport.scripted.sent.items[0], "\"io.modelcontextprotocol/clientCapabilities\":{}") != null);
}

test "a server requiring the old handshake is rejected without retry" {
    const allocator = std.testing.allocator;
    var connection = scriptedConnection(allocator, &.{
        .{ .err = .{ .code = -32601, .message = "Method not found" } },
    });
    defer connection.deinit();
    try std.testing.expectError(error.McpUnsupportedVersion, connection.negotiate());
    const sent = connection.transport.scripted.sent.items;
    try std.testing.expectEqual(@as(usize, 1), sent.len);
    try std.testing.expect(std.mem.indexOf(u8, sent[0], "server/discover") != null);
}

test "a silent discovery fails without a handshake retry" {
    const allocator = std.testing.allocator;
    var connection = scriptedConnection(allocator, &.{.silence});
    defer connection.deinit();
    try std.testing.expectError(error.McpTimeout, connection.negotiate());
    try std.testing.expectEqual(@as(usize, 1), connection.transport.scripted.sent.items.len);
}

test "an unsupported protocol version fails without downgrading" {
    const allocator = std.testing.allocator;
    var connection = scriptedConnection(allocator, &.{
        .{ .err = .{
            .code = unsupported_protocol_version,
            .message = "Unsupported protocol version",
            .data = "{\"supported\":[\"2025-11-25\",\"2025-06-18\"]}",
        } },
    });
    defer connection.deinit();
    try std.testing.expectError(error.McpUnsupportedVersion, connection.negotiate());
    try std.testing.expectEqual(@as(usize, 1), connection.transport.scripted.sent.items.len);
}

test "the shell server answers tools over stdio" {
    try skipUnlessPosix();
    const allocator = std.testing.allocator;

    var connection = try startFakeServer(allocator, "modern", 5_000);
    defer connection.deinit();

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

test "a server that prints a banner before its first message still connects" {
    try skipUnlessPosix();
    const allocator = std.testing.allocator;

    // npm and friends write to stdout before the server has said anything.
    var connection = try startFakeServer(allocator, "noisy", 5_000);
    defer connection.deinit();
}

test "a server that never answers is given up on" {
    try skipUnlessPosix();
    const allocator = std.testing.allocator;

    // Discovery has one deadline and no handshake retry.
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
    try skipUnlessPosix();
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
    try skipUnlessPosix();
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

test "HTTP discovery refusals fail without a handshake" {
    const allocator = std.testing.allocator;
    var connection = scriptedConnection(allocator, &.{});
    defer connection.deinit();
    try std.testing.expectError(error.McpUnsupportedVersion, connection.judgeRefusal(400,
        \\{"jsonrpc":"2.0","error":{"code":-32022,"message":"Unsupported protocol version"}}
    ));
    for ([_]u16{ 400, 404, 405, 422, 401, 403, 500 }) |status| {
        try std.testing.expectError(error.McpRefused, connection.judgeRefusal(status, "Bad Request"));
    }
}

test "the registry connects what mcp.json names, end to end" {
    try skipUnlessPosix();
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "zagent", std.Io.File.Permissions.default_dir);

    // The shell server is described in JSON rather than in a file, so nothing
    // has to be written for it but the configuration itself.
    const server = .{
        .description = "Echo service",
        .command = "sh",
        .args = [_][]const u8{ "-c", fake_server_script, "demo", "modern" },
    };
    const contents = try std.json.Stringify.valueAlloc(allocator, .{
        .mcpServers = .{ .demo = server, .other = server },
    }, .{});
    defer allocator.free(contents);
    try tmp.dir.writeFile(io, .{ .sub_path = "zagent/mcp.json", .data = contents });

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
    try std.testing.expectEqual(@as(usize, 2), registry.servers.len);
    try std.testing.expectEqual(@as(usize, 1), registry.functionJson().len);
    try std.testing.expectEqual(@as(usize, 2), registry.tools.len);
    try std.testing.expectEqualStrings("mcp__demo__echo", registry.tools[0].alias);

    const directory = (try registry.instructions(allocator)).?;
    defer allocator.free(directory);
    try std.testing.expect(std.mem.indexOf(u8, directory, "Echo service") != null);
    try std.testing.expect(std.mem.indexOf(u8, directory, "Say it back.") == null);
    try std.testing.expect(std.mem.indexOf(u8, directory, "mcp__demo__echo") == null);

    // Initially only the loader is advertised, not remote descriptions/schemas.
    try std.testing.expect(std.mem.indexOf(u8, registry.functionJson()[0], "\"name\":\"load_mcp_tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.functionJson()[0], "mcp__demo__echo") == null);
    const premature = try registry.call(allocator, "mcp__demo__echo", "{}");
    defer premature.deinit(allocator);
    try std.testing.expect(premature.is_error);
    const missing = try registry.loadTools(allocator, "{\"server\":\"missing\"}");
    defer missing.deinit(allocator);
    try std.testing.expect(missing.is_error);
    const invalid = try registry.loadTools(allocator, "[]");
    defer invalid.deinit(allocator);
    try std.testing.expect(invalid.is_error);
    const loaded = try registry.loadTools(allocator, "{\"server\":\"demo\"}");
    defer loaded.deinit(allocator);
    try std.testing.expect(!loaded.is_error);
    try std.testing.expect(std.mem.indexOf(u8, loaded.content, "Say it back.") != null);
    try std.testing.expectEqual(@as(usize, 2), registry.functionJson().len);
    try std.testing.expect(!registry.servers[1].loaded);
    try std.testing.expect(std.mem.indexOf(u8, registry.functionJson()[1], "\"name\":\"mcp__demo__echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.functionJson()[1], "\"required\":[\"text\"]") != null);
    const again = try registry.loadTools(allocator, "{\"server\":\"demo\"}");
    defer again.deinit(allocator);
    try std.testing.expect(!again.is_error);
    try std.testing.expectEqual(@as(usize, 2), registry.functionJson().len);

    // A label the spinner may show, and nothing at all for a name it invented.
    try std.testing.expectEqualStrings("demo/echo…", registry.progressLabel("mcp__demo__echo").?);
    try std.testing.expectEqual(@as(?[]const u8, null), registry.progressLabel("mcp__demo__guess"));

    // And a call goes all the way out and back.
    const result = try registry.call(allocator, "mcp__demo__echo", "{\"text\":\"hi\"}");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("echoed", result.content);
    try std.testing.expect(!result.is_error);
}
