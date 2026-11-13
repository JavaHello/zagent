const std = @import("std");
const args_mod = @import("args.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");

const ToolResult = result_mod.ToolResult;
const toolError = result_mod.toolError;
const optionalString = args_mod.optionalString;

/// The http tool: one request, its answer, or the file its body was saved to.
pub const spec: tool.Tool = .{
    .name = "http",
    .description = "Make an HTTP request and return its status line, headers and body, or save the body to a file.",
    .parameters_json =
    \\{"type":"object","properties":{"url":{"type":"string","description":"The full URL, including the scheme"},"method":{"type":"string","description":"HTTP method: GET, HEAD, POST, PUT, PATCH, DELETE, or OPTIONS. Defaults to GET"},"headers":{"type":"object","description":"Request headers as name/value pairs","additionalProperties":{"type":"string"}},"body":{"type":"string","description":"Request body, for a method that takes one"},"save_to":{"type":"string","description":"Write the response body to this file path instead of returning it"}},"required":["url"]}
    ,
    .label = "http…",
    .run = run,
};

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    const request = parseHttpRequest(ctx.allocator, arguments) catch |err| return ctx.refuseFmt(
        "Error: http arguments are unusable ({s}); it needs a 'url', and a 'method', 'headers', 'body', and 'save_to' it can use",
        .{@errorName(err)},
    );
    defer request.deinit(ctx.allocator);
    return httpRequest(ctx.io, ctx.allocator, request);
}

/// How many redirects a request without a body is followed through.
const http_max_redirects: u16 = 5;

/// How long one request may take, in all. Every other host tool is bounded by
/// the deadline it gives the program it runs; this one has to carry its own,
/// because `std.http` reads a socket with no timeout and a server that takes a
/// request and says nothing would hold the session for ever.
pub const timeout_seconds: u32 = 180;

/// An `Io` that gives every socket operation a deadline, so a client built on
/// it cannot wait on a server past one.
///
/// `std.http` reads through whatever `Io` it is given, and the interface hands
/// the deadline down to the poll it waits in — which is the one way to bound a
/// client that has none of its own. The table is the process's own with the one
/// entry that performs socket operations replaced, so everything else behaves
/// as it did. The deadline itself is reached through a thread-local: every
/// other entry of that table expects this process's `Io` state and cannot carry
/// one of ours, and the thread that made the request is the only one that reads
/// it.
const Deadline = struct {
    inner: std.Io,
    vtable: std.Io.VTable,
    expires: std.Io.Clock.Timestamp,

    threadlocal var running: ?*Deadline = null;

    fn init(inner: std.Io, seconds: u32) Deadline {
        var deadline: Deadline = .{
            .inner = inner,
            .vtable = inner.vtable.*,
            .expires = .{
                .raw = std.Io.Timestamp.addDuration(.now(inner, .awake), std.Io.Duration.fromSeconds(seconds)),
                .clock = .awake,
            },
        };
        deadline.vtable.operate = &operate;
        return deadline;
    }

    /// The `Io` a client is built with: this process's own, with a deadline on
    /// the operations that wait for a network.
    fn io(self: *Deadline) std.Io {
        return .{ .userdata = self.inner.userdata, .vtable = &self.vtable };
    }

    /// Whether the request has run out of time. An operation that ends with
    /// `error.Canceled` says only that it stopped, and this is what says why.
    fn passed(self: *const Deadline) bool {
        return self.expires.untilNow(self.inner).raw.nanoseconds > 0;
    }

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        _ = userdata;
        const self = running orelse return error.Canceled;
        return switch (operation) {
            .net_read, .net_write, .net_receive, .net_send => self.inner.operateTimeout(
                operation,
                .{ .deadline = self.expires },
            ) catch |err| switch (err) {
                // The interface has no way to say "too slow" through one
                // operation, and the deadline above says it for the request.
                error.Timeout => error.Canceled,
                error.Canceled => error.Canceled,
                // A platform whose waits cannot be polled is left to block, as
                // it did before: a request that cannot be bounded still works.
                error.ConcurrencyUnavailable => self.inner.operate(operation),
            },
            else => self.inner.operate(operation),
        };
    }
};

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

/// Parse an http tool call's arguments.
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

/// Perform an HTTP request and return the status line, the response headers,
/// and the body. With `save_to` the body is streamed to that file and only a
/// summary comes back.
///
/// Delivery failures and HTTP 4xx/5xx statuses are error results. Failed
/// downloads leave the destination unchanged.
pub fn httpRequest(io: std.Io, allocator: std.mem.Allocator, request: HttpRequest) !ToolResult {
    return httpRequestWithin(io, allocator, request, timeout_seconds);
}

pub fn httpRequestWithin(io: std.Io, allocator: std.mem.Allocator, request: HttpRequest, seconds: u32) !ToolResult {
    var deadline: Deadline = .init(io, seconds);
    const outer = Deadline.running;
    Deadline.running = &deadline;
    defer Deadline.running = outer;

    const result = try perform(allocator, &deadline, request);
    // A request that ran out of time is reported as one: what the deadline
    // leaves behind is a read that failed or a connection that closed, and
    // neither says what the wait was really about.
    if (!result.is_error or !deadline.passed()) return result;
    allocator.free(result.output);
    return .{
        .output = try std.fmt.allocPrint(allocator, "Error: '{s}' did not answer within {d}s; the request was stopped.", .{ request.url, seconds }),
        .is_error = true,
        .timed_out = true,
    };
}

/// The request itself, on a client whose every socket waits no longer than the
/// deadline it is given.
fn perform(allocator: std.mem.Allocator, deadline: *Deadline, request: HttpRequest) !ToolResult {
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

    var client: std.http.Client = .{ .allocator = allocator, .io = deadline.io() };
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
    const http_error = @backingInt(head.status) >= 400;
    try writeResponseHead(&head_aw.writer, head.version, head.status, head.reason, head.iterateHeaders());

    const has_body = responseHasBody(&response);
    if (!has_body) {
        // Nothing will drain the body, and deinit's own drain would block on a
        // response whose framing never ends. Closing the connection instead
        // costs nothing: this client is not reused.
        if (req.connection) |connection| connection.closing = true;
    }

    if (request.save_to) |path| {
        if (http_error) return .{
            .output = try std.fmt.allocPrint(allocator, "{s}\nHTTP error: destination '{s}' was not changed.", .{ head_aw.written(), path }),
            .is_error = true,
        };
        const written = saveResponseBody(deadline.inner, allocator, &response, path) catch |err| return toolError(
            allocator,
            "Error: could not save the response from '{s}' to '{s}': {s}",
            .{ request.url, path, @errorName(err) },
        );

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try aw.writer.print("Saved {d} bytes to '{s}'\n", .{ written, path });
        try aw.writer.writeAll(head_aw.written());
        return .{ .output = try aw.toOwnedSlice(), .is_error = false };
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

    return .{ .output = try aw.toOwnedSlice(), .is_error = http_error };
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
        try w.print("{s} {d} {s}\n", .{ @tagName(version), @backingInt(status), reason });
    } else {
        try w.print("{s} {d}\n", .{ @tagName(version), @backingInt(status) });
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

/// Read the complete response body; CCR owns caching and presentation limits.
fn readResponseBody(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    while (true) {
        _ = reader.stream(&aw.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }
    try checkResponseBodyComplete(response);
    return aw.toOwnedSlice();
}

// A decompressor can finish before the transfer reader consumes the final
// chunk framing. Advance that reader to EOF without accepting extra payload.
// Zig's content-length reader can also forward a premature socket EOF while
// framed bytes remain, so verify the state after observing EOF.
fn checkResponseBodyComplete(response: *std.http.Client.Response) !void {
    const transfer = &response.request.reader;
    switch (transfer.state) {
        .body_remaining_content_length, .body_remaining_chunk_len => {
            if (transfer.interface.takeByte()) |_| {
                return error.UnexpectedTrailingData;
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
            switch (transfer.state) {
                .body_remaining_content_length, .body_remaining_chunk_len => return error.UnexpectedEndOfStream,
                else => {},
            }
        },
        else => {},
    }
}

/// Stream the response body into `path`, creating parent directories as needed,
/// and return the number of bytes written.
fn saveResponseBody(io: std.Io, allocator: std.mem.Allocator, response: *std.http.Client.Response, path: []const u8) !u64 {
    if (std.Io.Dir.path.dirname(path)) |dir_path| {
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    }

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);

    // A bodyless response still gets its file, empty, so that a download's
    // result does not depend on the server having sent one.
    if (!responseHasBody(response)) {
        try atomic.replace(io);
        return 0;
    }

    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_writer = atomic.file.writer(io, &file_buffer);
    const written = reader.streamRemaining(&file_writer.interface) catch |err| {
        // A write failure is reported as WriteFailed, with the real error kept
        // on the writer.
        if (file_writer.err) |write_err| return write_err;
        return err;
    };
    try checkResponseBodyComplete(response);
    try file_writer.end();
    try atomic.replace(io);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "BREW") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "valid URL") != null);
}

/// A server on the loopback interface that answers the one connection a test
/// makes, or, when `response` is null, takes it and says nothing at all.
const Server = struct {
    listener: std.Io.net.Server,
    port: u16,
    response: ?[]const u8,
    /// Set to let the thread holding a silent connection go.
    released: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    fn init(io: std.Io, response: ?[]const u8) !Server {
        // Port 0 asks the kernel for a free one; `listen` fills in the one it
        // took, which is the port the request is made to.
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const listener = try address.listen(io, .{});
        return .{ .listener = listener, .port = listener.socket.address.getPort(), .response = response };
    }

    fn start(self: *Server, io: std.Io) !void {
        self.thread = try std.Thread.spawn(.{}, serve, .{ self, io });
    }

    fn serve(self: *Server, io: std.Io) void {
        const stream = self.listener.accept(io) catch return;
        defer stream.close(io);
        const response = self.response orelse {
            // Hold the connection open without answering it: this is the server
            // the deadline exists for.
            io.futexWaitTimeout(u32, &self.released.raw, 0, .{ .duration = .{
                .raw = .fromSeconds(30),
                .clock = .awake,
            } }) catch {};
            return;
        };
        var buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(response) catch {};
        writer.interface.flush() catch {};
    }

    fn deinit(self: *Server, io: std.Io) void {
        _ = self.released.swap(1, .release);
        io.futexWake(u32, &self.released.raw, 1);
        if (self.thread) |thread| thread.join();
        self.listener.deinit(io);
    }

    fn url(self: Server, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/", .{self.port});
    }
};

test "an answered request comes back with its status and body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var server = try Server.init(io, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi");
    try server.start(io);
    defer server.deinit(io);

    var url_buffer: [64]u8 = undefined;
    const result = try httpRequestWithin(std.testing.io, allocator, .{
        .method = "GET",
        .url = try server.url(&url_buffer),
        .headers = &.{},
        .body = null,
        .save_to = null,
    }, 30);
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(!result.timed_out);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hi") != null);
}

test "a server that never answers is stopped by the deadline" {
    const allocator = std.testing.allocator;
    // No answer at all: without a deadline this call would wait for ever.
    const io = std.testing.io;
    var server = try Server.init(io, null);
    try server.start(io);
    defer server.deinit(io);

    var url_buffer: [64]u8 = undefined;
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const result = try httpRequestWithin(std.testing.io, allocator, .{
        .method = "GET",
        .url = try server.url(&url_buffer),
        .headers = &.{},
        .body = null,
        .save_to = null,
    }, 1);
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error and result.timed_out);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "did not answer within 1s") != null);
    try std.testing.expect(started.untilNow(std.testing.io).raw.toSeconds() < 30);
}
