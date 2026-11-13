//! The HTTP client the two web tools share: one GET, its answer, and the
//! deadline that bounds it.
//!
//! Neither `web_fetch` nor `web_search` writes its own request: both hand a
//! URL and headers to `get`, and both read the answer the same way. A call that
//! fails comes back as a `Failure` naming the step it stopped at, so the tool
//! can say which part of the request was refused without guessing from an error
//! name it cannot see.
const std = @import("std");
const result_mod = @import("result.zig");

const ToolResult = result_mod.ToolResult;

/// How long one request may take, in all. Every other host tool is bounded by
/// the deadline it gives the program it runs; this one has to carry its own,
/// because `std.http` reads a socket with no timeout and a server that takes a
/// request and says nothing would hold the session for ever.
pub const timeout_seconds: u32 = 180;

/// How many redirects a request is followed through.
const max_redirects: u16 = 5;

/// The most of a body that is read into memory. A page larger than this is cut,
/// and the answer says so.
pub const max_body_bytes: usize = 8 * 1024 * 1024;

/// What a request that names no `User-Agent` of its own sends.
pub const default_user_agent = "zagent/0.1";

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

/// One request as a web tool describes it: a URL to read and the headers to read
/// it with.
pub const Request = struct {
    url: []const u8,
    /// Request headers beyond the user agent. A `User-Agent` here replaces the
    /// default one. A request that carries an `authorization` header is not
    /// followed through a redirect: the credential would be handed to whatever
    /// host the redirect names, and the status is answered instead.
    headers: []const std.http.Header = &.{},
    /// How long this request may take, in all.
    seconds: u32 = timeout_seconds,
    /// How much of the body may be read into memory.
    max_body_bytes: usize = max_body_bytes,
};

/// An answer: the status, the headers a tool reads, and the body.
pub const Response = struct {
    allocator: std.mem.Allocator,
    /// The address the answer came from: the requested one, or the one a
    /// redirect led to.
    url: []u8,
    status: std.http.Status,
    /// The server's phrase for the status, or the one std has for it.
    reason: []const u8,
    /// The media type of the body, lowercased and without its parameters; empty
    /// when the server named none.
    content_type: []const u8,
    /// The body; empty when the server sent none.
    body: []u8,
    /// Whether the body was cut at the request's limit.
    truncated: bool = false,

    pub fn deinit(self: Response) void {
        self.allocator.free(self.url);
        self.allocator.free(self.reason);
        self.allocator.free(self.content_type);
        self.allocator.free(self.body);
    }

    /// Whether the server answered with something other than an error status.
    pub fn ok(self: Response) bool {
        return @backingInt(self.status) < 400;
    }

    /// The status line, as a server writes it and as the model reads it.
    pub fn statusLine(self: Response, allocator: std.mem.Allocator) ![]u8 {
        return formatStatusLine(allocator, self.status, self.reason);
    }
};

pub fn formatStatusLine(allocator: std.mem.Allocator, status: std.http.Status, reason: []const u8) ![]u8 {
    const phrase = if (reason.len > 0) reason else (status.phrase() orelse "");
    if (phrase.len > 0) return std.fmt.allocPrint(allocator, "{d} {s}", .{ @backingInt(status), phrase });
    return std.fmt.allocPrint(allocator, "{d}", .{@backingInt(status)});
}

/// Why a request did not produce an answer, and where it stopped.
pub const Failure = struct {
    step: Step,
    reason: anyerror,

    pub const Step = enum {
        /// The URL is not one this client can parse.
        invalid_url,
        /// The request could not be sent.
        send,
        /// Nothing came back.
        receive,
        /// The body could not be read.
        body,
        /// The server answered with a compression this client cannot undo.
        compression,
        /// The request ran out of time.
        timed_out,
    };

    /// The result a call gets when its request failed: the message names the
    /// URL and what went wrong, so the model can correct the call.
    pub fn result(self: Failure, allocator: std.mem.Allocator, request: Request) !ToolResult {
        const url = request.url;
        return switch (self.step) {
            .invalid_url => .{
                .output = try std.fmt.allocPrint(allocator, "Error: '{s}' is not a valid URL.", .{url}),
                .is_error = true,
            },
            .send => .{
                .output = try std.fmt.allocPrint(allocator, "Error: could not send a request to '{s}': {s}", .{ url, @errorName(self.reason) }),
                .is_error = true,
            },
            .receive => .{
                .output = try std.fmt.allocPrint(allocator, "Error: no response from '{s}': {s}", .{ url, @errorName(self.reason) }),
                .is_error = true,
            },
            .body => .{
                .output = try std.fmt.allocPrint(allocator, "Error: could not read the response from '{s}': {s}", .{ url, @errorName(self.reason) }),
                .is_error = true,
            },
            .compression => .{
                .output = try std.fmt.allocPrint(allocator, "Error: '{s}' was answered with a compression this client cannot read.", .{url}),
                .is_error = true,
            },
            .timed_out => .{
                .output = try std.fmt.allocPrint(
                    allocator,
                    "Error: '{s}' did not answer within {d}s; the request was stopped.",
                    .{ url, request.seconds },
                ),
                .is_error = true,
                .timed_out = true,
            },
        };
    }
};

/// What one request produced: an answer, or the step it stopped at.
pub const Reply = union(enum) {
    response: Response,
    failure: Failure,
};

/// Read one URL. The answer owns its body; a request that ran out of time says
/// so rather than reporting whatever the cut socket left behind.
pub fn get(io: std.Io, allocator: std.mem.Allocator, request: Request) !Reply {
    var deadline: Deadline = .init(io, request.seconds);
    const outer = Deadline.running;
    Deadline.running = &deadline;
    defer Deadline.running = outer;

    const reply = try perform(allocator, &deadline, request);
    switch (reply) {
        .response => return reply,
        .failure => |failure| if (failure.step != .invalid_url and deadline.passed())
            return .{ .failure = .{ .step = .timed_out, .reason = error.Timeout } },
    }
    return reply;
}

fn perform(allocator: std.mem.Allocator, deadline: *Deadline, request: Request) !Reply {
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    var named_agent = false;
    var credentialed = false;
    for (request.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) named_agent = true;
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) credentialed = true;
    }
    if (!named_agent) try headers.append(allocator, .{ .name = "user-agent", .value = default_user_agent });
    try headers.appendSlice(allocator, request.headers);

    // Redirects are followed here rather than by `std.http`: a redirect that
    // changes scheme reaches a path in std that expects a TLS client to have
    // been set up already, and a credential must not travel to the host a
    // redirect names, which is a decision this loop can make per hop.
    var current: []u8 = try allocator.dupe(u8, request.url);
    defer allocator.free(current);

    var hop: u16 = 0;
    while (true) {
        const uri = std.Uri.parse(current) catch |err| return .{
            .failure = .{ .step = .invalid_url, .reason = err },
        };

        var client: std.http.Client = .{ .allocator = allocator, .io = deadline.io() };
        defer client.deinit();

        var req = client.request(.GET, uri, .{
            // `std.http` writes `extra_headers` and keeps `privileged_headers`
            // for itself without ever sending them, so a header reaches the
            // wire only through this slot.
            .extra_headers = headers.items,
            .redirect_behavior = .unhandled,
        }) catch |err| return .{ .failure = .{ .step = .send, .reason = err } };
        defer req.deinit();

        req.sendBodiless() catch |err| return .{ .failure = .{ .step = .send, .reason = err } };

        const head_buffer = try allocator.alloc(u8, 8 * 1024);
        defer allocator.free(head_buffer);

        var response = req.receiveHead(head_buffer) catch |err| return .{ .failure = .{ .step = .receive, .reason = err } };

        // A redirect is an answer only when it cannot be followed: the request
        // that asked for a credential stays where it was sent.
        const head = response.head;
        if (!credentialed and hop < max_redirects and isRedirect(@backingInt(head.status))) {
            if (head.location) |location| {
                const target = try allocator.dupe(u8, location);
                defer allocator.free(target);
                const next = (join(allocator, current, target) catch null) orelse return .{
                    .failure = .{ .step = .invalid_url, .reason = error.InvalidRedirect },
                };
                if (req.connection) |connection| connection.closing = true;
                allocator.free(current);
                current = next;
                hop += 1;
                continue;
            }
        }

        return try answer(allocator, request, &response, current);
    }
}

/// Whether a status asks the client to read somewhere else.
fn isRedirect(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

/// One response, read into the answer the tool is given.
fn answer(
    allocator: std.mem.Allocator,
    request: Request,
    response: *std.http.Client.Response,
    url: []const u8,
) !Reply {
    // The status line and headers are read out here, before the body is
    // touched: reading the body invalidates the buffer they point into.
    const head = response.head;
    const reason = if (head.reason.len > 0) head.reason else (head.status.phrase() orelse "");
    var result: Response = .{
        .allocator = allocator,
        .url = try allocator.dupe(u8, url),
        .status = head.status,
        .reason = try allocator.dupe(u8, reason),
        .content_type = try mediaType(allocator, head.content_type),
        .body = try allocator.dupe(u8, ""),
    };
    errdefer result.deinit();

    const has_body = responseHasBody(response);
    if (!has_body) {
        // Nothing will drain the body, and deinit's own drain would block on a
        // response whose framing never ends. Closing the connection instead
        // costs nothing: this client is not reused.
        if (response.request.connection) |connection| connection.closing = true;
    }

    if (has_body) {
        const body = readResponseBody(allocator, response, request.max_body_bytes) catch |err| return .{
            .failure = .{ .step = if (err == error.UnsupportedCompressionMethod) .compression else .body, .reason = err },
        };
        allocator.free(result.body);
        result.body = body.text;
        result.truncated = body.truncated;
    }

    return .{ .response = result };
}

/// The media type of an answer, lowercased and without its parameters.
fn mediaType(allocator: std.mem.Allocator, raw: ?[]const u8) ![]u8 {
    const value = raw orelse return allocator.dupe(u8, "");
    const media = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " \t");
    const owned = try allocator.dupe(u8, media);
    return std.ascii.lowerString(owned, owned);
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

const Body = struct {
    text: []u8,
    truncated: bool,
};

/// The first `limit` bytes of `text`, backed off to a character boundary so
/// that what is handed over is text rather than half of a character.
fn cutAt(text: []const u8, limit: usize) []const u8 {
    var end = @min(limit, text.len);
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

/// Read the body, up to `limit` bytes. A body longer than that is cut, and the
/// caller is told so: CCR owns caching and presentation, not the bound on what a
/// single page may cost the session.
fn readResponseBody(
    allocator: std.mem.Allocator,
    response: *std.http.Client.Response,
    limit: usize,
) !Body {
    const decompress_buffer = try allocDecompressBuffer(allocator, response.head.content_encoding);
    defer allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var truncated = false;
    while (true) {
        _ = reader.stream(&aw.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (aw.written().len > limit) {
            truncated = true;
            break;
        }
    }

    // A complete body is checked for the framing it promised; a cut one is not,
    // because what is missing is exactly what the check would complain about.
    if (!truncated) {
        try checkResponseBodyComplete(response);
        return .{ .text = try aw.toOwnedSlice(), .truncated = false };
    }
    const kept = try allocator.dupe(u8, cutAt(aw.written(), limit));
    aw.deinit();
    return .{ .text = kept, .truncated = true };
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

test "a cut body ends on a character boundary" {
    const text = "ab\u{00e9}cd"; // 'é' is two bytes
    try std.testing.expectEqualStrings("ab", cutAt(text, 3));
    try std.testing.expectEqualStrings("ab\u{00e9}", cutAt(text, 4));
    try std.testing.expectEqualStrings(text, cutAt(text, 16));
    try std.testing.expectEqualStrings("", cutAt(text, 0));
}

test "a media type is lowercased and loses its parameters" {
    const a = std.testing.allocator;
    const plain = try mediaType(a, "Text/HTML; charset=UTF-8");
    defer a.free(plain);
    try std.testing.expectEqualStrings("text/html", plain);

    const bare = try mediaType(a, " application/json ");
    defer a.free(bare);
    try std.testing.expectEqualStrings("application/json", bare);

    const absent = try mediaType(a, null);
    defer a.free(absent);
    try std.testing.expectEqualStrings("", absent);
}

test "a failure names the step the request stopped at" {
    const a = std.testing.allocator;
    const request: Request = .{ .url = "https://example.test/page" };
    const cases = [_]struct { failure: Failure, expected: []const u8 }{
        .{ .failure = .{ .step = .invalid_url, .reason = error.InvalidFormat }, .expected = "is not a valid URL" },
        .{ .failure = .{ .step = .send, .reason = error.ConnectionRefused }, .expected = "could not send a request to 'https://example.test/page'" },
        .{ .failure = .{ .step = .receive, .reason = error.ConnectionClosed }, .expected = "no response from 'https://example.test/page'" },
        .{ .failure = .{ .step = .body, .reason = error.UnexpectedEndOfStream }, .expected = "could not read the response" },
        .{ .failure = .{ .step = .compression, .reason = error.UnsupportedCompressionMethod }, .expected = "compression this client cannot read" },
        .{ .failure = .{ .step = .timed_out, .reason = error.Timeout }, .expected = "did not answer within 180s" },
    };
    for (cases) |case| {
        const result = try case.failure.result(a, request);
        defer result.deinit(a);
        try std.testing.expect(result.is_error);
        try std.testing.expect(std.mem.indexOf(u8, result.output, case.expected) != null);
        try std.testing.expectEqual(case.failure.step == .timed_out, result.timed_out);
    }
}

test "a status line prefers the phrase the server sent" {
    const a = std.testing.allocator;
    const sent = try formatStatusLine(a, .not_found, "Gone Fishing");
    defer a.free(sent);
    try std.testing.expectEqualStrings("404 Gone Fishing", sent);

    const known = try formatStatusLine(a, .not_found, "");
    defer a.free(known);
    try std.testing.expectEqualStrings("404 Not Found", known);
}

/// `reference` resolved against `base`, the way a link on a page or a redirect
/// names an address: whole already when it has a scheme, taken from the base's
/// origin when it starts with `/`, and joined to the base's directory when it
/// is relative. Null for a reference nobody could follow — a script, a mail
/// address, an anchor of the page it was found on.
pub fn join(allocator: std.mem.Allocator, base: []const u8, reference: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, reference, " \t\r\n");
    if (trimmed.len == 0) return null;
    const unreadable = [_][]const u8{ "javascript:", "mailto:", "tel:", "data:", "#" };
    for (unreadable) |prefix| {
        if (std.ascii.startsWithIgnoreCase(trimmed, prefix)) return null;
    }
    if (std.ascii.startsWithIgnoreCase(trimmed, "http://") or std.ascii.startsWithIgnoreCase(trimmed, "https://")) {
        return try allocator.dupe(u8, trimmed);
    }

    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return try allocator.dupe(u8, trimmed);
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfScalarPos(u8, base, authority_start, '/') orelse base.len;
    if (std.mem.startsWith(u8, trimmed, "//")) {
        return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ base[0..scheme_end], trimmed });
    }
    // Everything a root-relative or relative address is joined to: the page's
    // own origin, and the directory it was read from.
    const origin = base[0..authority_end];
    if (std.mem.startsWith(u8, trimmed, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ origin, trimmed });
    }
    const directory_end = if (std.mem.lastIndexOfScalar(u8, base, '/')) |slash| @max(slash, authority_end) else authority_end;
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base[0..directory_end], trimmed });
}

/// `template` with every `{placeholder}` replaced by `value`, or null when the
/// template does not name the placeholder at all.
pub fn fill(
    allocator: std.mem.Allocator,
    template: []const u8,
    placeholder: []const u8,
    value: []const u8,
) !?[]u8 {
    if (std.mem.indexOf(u8, template, placeholder) == null) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var rest = template;
    while (std.mem.indexOf(u8, rest, placeholder)) |at| {
        try out.appendSlice(allocator, rest[0..at]);
        try out.appendSlice(allocator, value);
        rest = rest[at + placeholder.len ..];
    }
    try out.appendSlice(allocator, rest);
    return try out.toOwnedSlice(allocator);
}

/// Where a configured fetch service is asked for a URL: the service's own
/// template with `{url}` filled in, or the URL appended to its path, which is
/// how the reader services are addressed.
pub fn fetchEndpoint(allocator: std.mem.Allocator, template: []const u8, url: []const u8) ![]u8 {
    if (try fill(allocator, template, "{url}", url)) |filled| return filled;
    if (std.mem.endsWith(u8, template, "/")) return std.fmt.allocPrint(allocator, "{s}{s}", .{ template, url });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ template, url });
}

/// The header a configured service is asked with: the key as a bearer token,
/// which is how a reader or a search service takes one.
pub fn bearer(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
}

/// `text` written so that it can stand in a URL: everything but the unreserved
/// characters is escaped.
pub fn percentEncode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const digits = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |c| {
        const plain = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
        if (plain) {
            try out.append(allocator, c);
            continue;
        }
        try out.append(allocator, '%');
        try out.append(allocator, digits[c >> 4]);
        try out.append(allocator, digits[c & 0x0f]);
    }
    return out.toOwnedSlice(allocator);
}

/// The text a percent-escaped URL component stands for.
pub fn percentDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(allocator, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "an address is resolved against the page it was found on" {
    const a = std.testing.allocator;
    const base = "https://example.test/guide/page.html";
    const cases = [_]struct { reference: []const u8, expected: ?[]const u8 }{
        .{ .reference = "https://other.test/x", .expected = "https://other.test/x" },
        .{ .reference = "//cdn.test/y", .expected = "https://cdn.test/y" },
        .{ .reference = "/root", .expected = "https://example.test/root" },
        .{ .reference = "next.html", .expected = "https://example.test/guide/next.html" },
        .{ .reference = "  ", .expected = null },
        .{ .reference = "mailto:hi@example.test", .expected = null },
        .{ .reference = "#section", .expected = null },
        .{ .reference = "javascript:void(0)", .expected = null },
    };
    for (cases) |case| {
        const joined = try join(a, base, case.reference);
        defer if (joined) |value| a.free(value);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, joined.?);
        } else {
            try std.testing.expect(joined == null);
        }
    }
}

test "a placeholder is filled in, and its absence is answered with null" {
    const a = std.testing.allocator;
    const filled = (try fill(a, "https://search.test/?q={query}&n={query}", "{query}", "zig")).?;
    defer a.free(filled);
    try std.testing.expectEqualStrings("https://search.test/?q=zig&n=zig", filled);
    try std.testing.expect((try fill(a, "https://search.test/?q=x", "{query}", "zig")) == null);
}

test "a fetch endpoint takes the URL in its template or after its path" {
    const a = std.testing.allocator;
    const templated = try fetchEndpoint(a, "https://reader.test/?target={url}", "https://example.test/a?b=1");
    defer a.free(templated);
    try std.testing.expectEqualStrings("https://reader.test/?target=https://example.test/a?b=1", templated);

    const appended = try fetchEndpoint(a, "https://reader.test/", "https://example.test/a");
    defer a.free(appended);
    try std.testing.expectEqualStrings("https://reader.test/https://example.test/a", appended);
}

test "a URL component is escaped and read back" {
    const a = std.testing.allocator;
    const encoded = try percentEncode(a, "zig lang & co/测试?");
    defer a.free(encoded);
    try std.testing.expectEqualStrings("zig%20lang%20%26%20co%2F%E6%B5%8B%E8%AF%95%3F", encoded);
    const decoded = try percentDecode(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings("zig lang & co/测试?", decoded);
    // What is not an escape is left alone.
    const plain = try percentDecode(a, "100% sure%2");
    defer a.free(plain);
    try std.testing.expectEqualStrings("100% sure%2", plain);
}
