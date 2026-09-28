const std = @import("std");
const text = @import("text.zig");

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub fn executeShell(io: std.Io, allocator: std.mem.Allocator, command: []const u8) !ToolResult {
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "sh", "-c", command },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    if (result.stdout.len > 0) {
        const normalized = try normalizeToolText(allocator, result.stdout);
        defer allocator.free(normalized);
        try aw.writer.writeAll(normalized);
    }
    if (result.stderr.len > 0) {
        if (aw.written().len > 0) try aw.writer.writeAll("\n");
        try aw.writer.writeAll("stderr: ");
        const normalized = try normalizeToolText(allocator, result.stderr);
        defer allocator.free(normalized);
        try aw.writer.writeAll(normalized);
    }
    if (aw.written().len == 0) {
        try aw.writer.writeAll("(no output)");
    }

    const content = try finalizeToolContent(allocator, aw.written());
    aw.deinit();

    return .{
        .content = content,
        .is_error = exit_code != 0,
    };
}

pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ToolResult {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer file.close(io);

    const max_size = 1 * 1024 * 1024;
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const content = file_reader.interface.allocRemaining(allocator, .limited(max_size)) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error reading '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };

    const normalized = try finalizeToolContent(allocator, content);
    allocator.free(content);
    return .{ .content = normalized, .is_error = false };
}

pub fn writeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !ToolResult {
    if (std.Io.Dir.path.dirname(path)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error creating '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer file.close(io);

    file.writeStreamingAll(io, content) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error writing '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };

    return .{
        .content = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to '{s}'", .{ content.len, path }),
        .is_error = false,
    };
}

pub fn listDir(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ToolResult {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(allocator, "Error opening '{s}': {s}", .{ path, @errorName(err) }),
            .is_error = true,
        };
    };
    defer dir.close(io);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const kind_char: u8 = switch (entry.kind) {
            .directory => 'd',
            .file => 'f',
            .sym_link => 'l',
            else => '?',
        };
        try aw.writer.print("{c} {s}\n", .{ kind_char, entry.name });
    }

    if (aw.written().len == 0) {
        try aw.writer.writeAll("(empty directory)");
    }

    return .{ .content = try aw.toOwnedSlice(), .is_error = false };
}

/// Longest response text the model is shown. Larger than the cap the other
/// tools use, because an API response cut off mid-JSON is useless.
pub const http_max_content: usize = 32 * 1024;

/// How many redirects a request without a body is followed through.
const http_max_redirects: u16 = 5;

/// An HTTP request as the model described it. Owns its strings.
pub const HttpRequest = struct {
    method: []const u8,
    url: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
    /// Write the response body to this path instead of returning it.
    save_to: ?[]const u8,

    pub fn deinit(self: HttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        for (self.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        if (self.body) |body| allocator.free(body);
        if (self.save_to) |path| allocator.free(path);
    }
};

/// Parse an http_request tool call's arguments.
pub fn parseHttpRequest(allocator: std.mem.Allocator, arguments_json: []const u8) !HttpRequest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const arguments = parsed.value.object;

    const url_value = arguments.get("url") orelse return error.MissingUrl;
    if (url_value != .string or url_value.string.len == 0) return error.MissingUrl;

    // The method keeps the casing the model used; it is matched when the
    // request is sent, so an unsupported one is reported back as an answer
    // rather than failing the parse.
    const method = if (arguments.get("method")) |value| blk: {
        if (value != .string or value.string.len == 0) break :blk "GET";
        break :blk value.string;
    } else "GET";
    if (parseHttpMethod(method) == null) return error.UnsupportedMethod;

    const url = try allocator.dupe(u8, url_value.string);
    errdefer allocator.free(url);
    const owned_method = try allocator.dupe(u8, method);
    errdefer allocator.free(owned_method);

    const headers = try parseHttpHeaders(allocator, arguments.get("headers"));
    errdefer {
        for (headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(headers);
    }

    const body = try optionalString(allocator, arguments.get("body"));
    errdefer if (body) |value| allocator.free(value);
    const save_to = try optionalString(allocator, arguments.get("save_to"));
    errdefer if (save_to) |value| allocator.free(value);

    return .{
        .method = owned_method,
        .url = url,
        .headers = headers,
        .body = body,
        .save_to = save_to,
    };
}

/// The methods the tool offers. CONNECT and TRACE are left out: neither is
/// useful to an agent, and CONNECT would take the connection over entirely.
fn parseHttpMethod(name: []const u8) ?std.http.Method {
    const offered = [_]std.http.Method{ .GET, .HEAD, .POST, .PUT, .PATCH, .DELETE, .OPTIONS };
    for (offered) |method| {
        if (std.ascii.eqlIgnoreCase(name, @tagName(method))) return method;
    }
    return null;
}

/// Parse the `headers` object, rejecting anything that could not be written as
/// a header line. std splits a header at its first colon when it sends it, so a
/// name carrying one — or either half carrying a newline — would let a value
/// forge headers of its own.
fn parseHttpHeaders(allocator: std.mem.Allocator, value: ?std.json.Value) ![]std.http.Header {
    const object = value orelse return &.{};
    if (object != .object) return error.InvalidHeaders;

    var headers: std.ArrayList(std.http.Header) = .empty;
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        headers.deinit(allocator);
    }

    var iterator = object.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidHeaders;
        const name = entry.key_ptr.*;
        const header_value = entry.value_ptr.string;
        if (name.len == 0 or std.mem.indexOfAny(u8, name, ":\r\n") != null) return error.InvalidHeaders;
        if (std.mem.indexOfAny(u8, header_value, "\r\n") != null) return error.InvalidHeaders;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_value = try allocator.dupe(u8, header_value);
        errdefer allocator.free(owned_value);

        try headers.append(allocator, .{ .name = owned_name, .value = owned_value });
    }

    return headers.toOwnedSlice(allocator);
}

/// A string argument that may be absent. An empty string counts as absent, so a
/// model that sends `"body": ""` gets a request with no body rather than one
/// with a zero-length body.
fn optionalString(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const field = value orelse return null;
    if (field != .string) return error.InvalidArguments;
    if (field.string.len == 0) return null;
    return try allocator.dupe(u8, field.string);
}

/// Perform an HTTP request and return the status line, the response headers,
/// and the body. With `save_to` the body is streamed to that file and only a
/// summary comes back.
///
/// A delivery failure is an error result, but an HTTP status never is, however
/// unhelpful: the request did reach the server, and the status line says so.
pub fn httpRequest(io: std.Io, allocator: std.mem.Allocator, request: HttpRequest) !ToolResult {
    const method = parseHttpMethod(request.method) orelse return toolError(
        allocator,
        "Error: unsupported HTTP method '{s}'. Use GET, HEAD, POST, PUT, PATCH, DELETE, or OPTIONS.",
        .{request.method},
    );

    const uri = std.Uri.parse(request.url) catch |err| return toolError(
        allocator,
        "Error: '{s}' is not a valid URL: {s}",
        .{ request.url, @errorName(err) },
    );

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Every method that takes a body always goes through the body path, even
    // with nothing to send, and every method that does not always goes through
    // the bodiless one: std asserts the two agree with the method.
    const sends_body = method.requestHasBody();
    const body = request.body orelse "";
    if (!sends_body and body.len != 0) return toolError(
        allocator,
        "Error: an HTTP {s} request cannot carry a body.",
        .{@tagName(method)},
    );

    var req = client.request(method, uri, .{
        // A body is already on the wire by the time a redirect arrives and std
        // cannot replay it, so a method that sends one gets the redirect
        // response back for the model to follow instead of following it here.
        // This must match the send path below, which routes by method too.
        .redirect_behavior = if (sends_body)
            .unhandled
        else
            std.http.Client.Request.RedirectBehavior.init(http_max_redirects),
        // The model's headers go through the privileged slot so that a
        // credential is not carried to another domain by a redirect.
        .privileged_headers = request.headers,
    }) catch |err| return toolError(
        allocator,
        "Error: could not send a request to '{s}': {s}",
        .{ request.url, @errorName(err) },
    );
    defer req.deinit();

    if (sends_body) {
        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| return toolError(
            allocator,
            "Error: could not send the request body to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
        body_writer.writer.writeAll(body) catch |err| return toolError(
            allocator,
            "Error: could not send the request body to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
        body_writer.end() catch |err| return toolError(
            allocator,
            "Error: could not send the request body to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
        req.connection.?.flush() catch |err| return toolError(
            allocator,
            "Error: could not send the request body to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
    } else {
        req.sendBodiless() catch |err| return toolError(
            allocator,
            "Error: could not send a request to '{s}': {s}",
            .{ request.url, @errorName(err) },
        );
    }

    const redirect_buffer = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(redirect_buffer);

    var response = req.receiveHead(redirect_buffer) catch |err| return toolError(
        allocator,
        "Error: no response from '{s}': {s}",
        .{ request.url, @errorName(err) },
    );

    // The status line and headers are written out here, before the body is
    // touched: reading the body invalidates the buffer they point into.
    var head_aw: std.Io.Writer.Allocating = .init(allocator);
    defer head_aw.deinit();
    const head = response.head;
    try writeResponseHead(&head_aw.writer, head.version, head.status, head.reason, head.iterateHeaders());

    const has_body = responseHasBody(&response);
    if (!has_body) {
        // Nothing will drain the body, and deinit's own drain would block on a
        // response whose framing never ends. Closing the connection instead
        // costs nothing: this client is not reused.
        if (req.connection) |connection| connection.closing = true;
    }

    if (request.save_to) |path| {
        const written = saveResponseBody(io, allocator, &response, path) catch |err| return toolError(
            allocator,
            "Error: could not save the response from '{s}' to '{s}': {s}",
            .{ request.url, path, @errorName(err) },
        );

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print("Saved {d} bytes to '{s}'\n", .{ written, path });
        try aw.writer.writeAll(head_aw.written());
        return .{
            .content = try finalizeToolContentLimited(allocator, aw.written(), http_max_content),
            .is_error = false,
        };
    }

    const body_text = if (has_body)
        try readResponseBody(allocator, &response)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(body_text);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll(head_aw.written());
    try aw.writer.writeByte('\n');
    if (body_text.len > 0) {
        try aw.writer.writeAll(body_text);
    } else {
        try aw.writer.writeAll("(empty body)");
    }

    return .{
        .content = try finalizeToolContentLimited(allocator, aw.written(), http_max_content),
        .is_error = false,
    };
}

/// Write the status line and every response header. Takes the head's parts
/// rather than the response so that the shape of what the model sees can be
/// tested without a socket.
fn writeResponseHead(
    w: *std.Io.Writer,
    version: std.http.Version,
    status: std.http.Status,
    server_reason: []const u8,
    iterator: std.http.HeaderIterator,
) !void {
    // Prefer the reason the server sent over the one std has for the code:
    // servers are free to phrase it themselves.
    const reason = if (server_reason.len > 0) server_reason else status.phrase() orelse "";
    if (reason.len > 0) {
        try w.print("{s} {d} {s}\n", .{ @tagName(version), @intFromEnum(status), reason });
    } else {
        try w.print("{s} {d}\n", .{ @tagName(version), @intFromEnum(status) });
    }

    var headers = iterator;
    while (headers.next()) |header| {
        try w.print("{s}: {s}\n", .{ header.name, header.value });
    }
}

/// Whether the response carries a body. A reader taken on one of the exceptions
/// would stream from the raw connection instead of the message framing and
/// block until the server closes it, because std only knows to expect no body
/// for a HEAD — not for these statuses.
fn responseHasBody(response: *const std.http.Client.Response) bool {
    if (!response.request.method.responseHasBody()) return false;
    const status = response.head.status;
    if (status == .no_content or status == .reset_content or status == .not_modified) return false;
    return status.class() != .informational;
}

/// Read the response body into memory, stopping at `http_max_content` rather
/// than failing, so an oversized body still shows its beginning.
fn readResponseBody(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    while (aw.written().len < http_max_content) {
        // A short read is not the end of the body: the stream reports zero when
        // nothing has arrived yet, so only EndOfStream or the cap ends this
        // loop. Stopping at the cap leaves the rest unread, which deinit closes
        // the connection over rather than draining.
        _ = reader.stream(&aw.writer, .limited(http_max_content - aw.written().len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }
    return aw.toOwnedSlice();
}

/// Stream the response body into `path`, creating parent directories as needed,
/// and return the number of bytes written.
fn saveResponseBody(io: std.Io, allocator: std.mem.Allocator, response: *std.http.Client.Response, path: []const u8) !u64 {
    if (std.Io.Dir.path.dirname(path)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    // A bodyless response still gets its file, empty, so that a download's
    // result does not depend on the server having sent one.
    if (!responseHasBody(response)) return 0;

    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const written = reader.streamRemaining(&file_writer.interface) catch |err| {
        // A write failure is reported as WriteFailed, with the real error kept
        // on the writer.
        if (file_writer.err) |write_err| return write_err;
        return err;
    };
    try file_writer.end();
    return written;
}

/// The buffer a decompressing reader needs. Empty for an uncompressed body,
/// which is the usual case.
fn allocDecompressBuffer(allocator: std.mem.Allocator, encoding: std.http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => error.UnsupportedCompressionMethod,
    };
}

fn toolError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !ToolResult {
    return .{ .content = try std.fmt.allocPrint(allocator, fmt, args), .is_error = true };
}

test "shell echo" {
    const result = try executeShell(std.testing.io, std.testing.allocator, "echo hello");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "hello") != null);
}

test "shell exit code" {
    const result = try executeShell(std.testing.io, std.testing.allocator, "exit 1");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

test "read missing file" {
    const result = try readFile(std.testing.io, std.testing.allocator, "/nonexistent/path/file.txt");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.is_error);
}

fn finalizeToolContent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    return finalizeToolContentLimited(allocator, raw, 8192);
}

fn finalizeToolContentLimited(allocator: std.mem.Allocator, raw: []const u8, max_len: usize) ![]u8 {
    const normalized = try normalizeToolText(allocator, raw);
    defer allocator.free(normalized);

    const suffix = "\n... (truncated)";
    if (normalized.len <= max_len) return allocator.dupe(u8, normalized);

    var cut = max_len - suffix.len;
    while (cut > 0 and !std.unicode.utf8ValidateSlice(normalized[0..cut])) : (cut -= 1) {}
    if (cut == 0) cut = max_len - suffix.len;

    return std.fmt.allocPrint(allocator, "{s}{s}", .{ normalized[0..cut], suffix });
}

fn normalizeToolText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        const byte = raw[i];

        // Strip common ANSI escape sequences used by terminal-oriented tools.
        if (byte == 0x1b) {
            i = text.skipAnsiEscape(raw, i);
            continue;
        }

        if (byte < 0x80) {
            if (byte == '\n' or byte == '\r' or byte == '\t' or byte >= 0x20) {
                try out.append(allocator, byte);
            } else {
                try out.append(allocator, ' ');
            }
            i += 1;
            continue;
        }

        var escape_buf: [4]u8 = undefined;

        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.appendSlice(allocator, text.escapeByte(&escape_buf, byte));
            i += 1;
            continue;
        };
        if (i + seq_len > raw.len or !std.unicode.utf8ValidateSlice(raw[i .. i + seq_len])) {
            try out.appendSlice(allocator, text.escapeByte(&escape_buf, byte));
            i += 1;
            continue;
        }

        try out.appendSlice(allocator, raw[i .. i + seq_len]);
        i += seq_len;
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "(no output)");
    }

    return out.toOwnedSlice(allocator);
}

test "normalize tool text strips ansi sequences" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeToolText(allocator, "\x1b[32mgreen\x1b[0m");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("green", normalized);
}

test "normalize tool text escapes invalid utf8" {
    const allocator = std.testing.allocator;
    const normalized = try normalizeToolText(allocator, &[_]u8{ 'o', 'k', 0xff });
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("ok\\xFF", normalized);
}

test "parse http request defaults to GET without a body" {
    const allocator = std.testing.allocator;
    const request = try parseHttpRequest(allocator, "{\"url\":\"https://example.com\"}");
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("https://example.com", request.url);
    try std.testing.expectEqual(@as(usize, 0), request.headers.len);
    try std.testing.expect(request.body == null);
    try std.testing.expect(request.save_to == null);
}

test "parse http request reads method headers and body" {
    const allocator = std.testing.allocator;
    const request = try parseHttpRequest(allocator,
        \\{"url":"https://api.example.com/items","method":"post",
        \\ "headers":{"Content-Type":"application/json","X-Trace":"  spaced  "},
        \\ "body":"{\"name\":\"widget\"}","save_to":"out/items.json"}
    );
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("post", request.method);
    try std.testing.expectEqual(@as(usize, 2), request.headers.len);
    try std.testing.expectEqualStrings("Content-Type", request.headers[0].name);
    try std.testing.expectEqualStrings("application/json", request.headers[0].value);
    try std.testing.expectEqualStrings("X-Trace", request.headers[1].name);
    try std.testing.expectEqualStrings("  spaced  ", request.headers[1].value);
    try std.testing.expectEqualStrings("{\"name\":\"widget\"}", request.body.?);
    try std.testing.expectEqualStrings("out/items.json", request.save_to.?);
}

test "parse http request rejects arguments it cannot use" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingUrl, parseHttpRequest(allocator, "{\"method\":\"GET\"}"));
    try std.testing.expectError(error.MissingUrl, parseHttpRequest(allocator, "{\"url\":\"\"}"));
    try std.testing.expectError(error.UnsupportedMethod, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"method\":\"BREW\"}",
    ));
    try std.testing.expectError(error.InvalidArguments, parseHttpRequest(allocator, "[]"));
    try std.testing.expectError(error.InvalidArguments, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"body\":5}",
    ));
    // A header that cannot be written as a header line is rejected rather than
    // sent: std asserts on the first two, and the third would forge a second
    // header of its own.
    try std.testing.expectError(error.InvalidHeaders, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"headers\":{\"X-Count\":1}}",
    ));
    try std.testing.expectError(error.InvalidHeaders, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"headers\":{\"X-Trace\":\"a\\r\\nInjected: 1\"}}",
    ));
    try std.testing.expectError(error.InvalidHeaders, parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"headers\":{\"X-Trace: Injected\":\"a\"}}",
    ));
}

test "an empty body argument counts as no body" {
    const allocator = std.testing.allocator;
    const request = try parseHttpRequest(
        allocator,
        "{\"url\":\"https://example.com\",\"method\":\"POST\",\"body\":\"\"}",
    );
    defer request.deinit(allocator);
    try std.testing.expect(request.body == null);
}

test "http methods are matched case-insensitively" {
    try std.testing.expectEqual(std.http.Method.GET, parseHttpMethod("get").?);
    try std.testing.expectEqual(std.http.Method.PATCH, parseHttpMethod("Patch").?);
    try std.testing.expectEqual(std.http.Method.OPTIONS, parseHttpMethod("OPTIONS").?);
    try std.testing.expect(parseHttpMethod("") == null);
    try std.testing.expect(parseHttpMethod("get / HTTP/1.1") == null);
    // Taking the connection over is not something the tool offers.
    try std.testing.expect(parseHttpMethod("CONNECT") == null);
}

test "the response head is written as a status line then its headers" {
    const allocator = std.testing.allocator;
    const raw_headers = "HTTP/1.1 200 OK\r\n" ++
        "content-type: application/json\r\n" ++
        "content-length: 11\r\n\r\n";

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeResponseHead(
        &aw.writer,
        .@"HTTP/1.1",
        .ok,
        "OK",
        std.http.HeaderIterator.init(raw_headers),
    );

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\ncontent-type: application/json\ncontent-length: 11\n",
        aw.written(),
    );
}

test "a status the server left unphrased still gets its code" {
    const allocator = std.testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeResponseHead(
        &aw.writer,
        .@"HTTP/1.1",
        .not_found,
        "",
        std.http.HeaderIterator.init("HTTP/1.1 404 Not Found\r\n\r\n"),
    );

    // The phrase comes from std when the server sent none, so the line still
    // reads as a status rather than a bare number.
    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found\n", aw.written());
}

test "http request reports a method it cannot send" {
    const allocator = std.testing.allocator;
    // Reaching httpRequest at all is the point: the test build only compiles
    // the bodies it can see referenced, and this one is otherwise never
    // analyzed until an executable is built.
    const result = try httpRequest(std.testing.io, allocator, .{
        .method = "BREW",
        .url = "http://127.0.0.1:1/",
        .headers = &.{},
        .body = null,
        .save_to = null,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "BREW") != null);
}

test "http request reports a url it cannot use" {
    const allocator = std.testing.allocator;
    const result = try httpRequest(std.testing.io, allocator, .{
        .method = "GET",
        .url = "not a url",
        .headers = &.{},
        .body = null,
        .save_to = null,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "valid URL") != null);
}

test "http content is truncated at its own larger limit" {
    const allocator = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    for (0..http_max_content + 512) |_| try raw.append(allocator, 'x');

    const finalized = try finalizeToolContentLimited(allocator, raw.items, http_max_content);
    defer allocator.free(finalized);

    try std.testing.expect(std.mem.endsWith(u8, finalized, "\n... (truncated)"));
    try std.testing.expect(finalized.len <= http_max_content);
}

test "finalize tool content truncates on utf8 boundary" {
    const allocator = std.testing.allocator;
    var repeated: std.ArrayList(u8) = .empty;
    defer repeated.deinit(allocator);
    for (0..1500) |_| {
        try repeated.appendSlice(allocator, "你好");
    }

    const finalized = try finalizeToolContent(allocator, repeated.items);
    defer allocator.free(finalized);
    try std.testing.expect(std.mem.endsWith(u8, finalized, "\n... (truncated)"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(finalized));
}
