//! The `web_fetch` tool: one page, read as text.
//!
//! A page is fetched and handed over as the markdown a reader would have copied
//! out of it — `html.zig` does that reading. When a fetch service is configured
//! (`WEB_FETCH_URL`, and `WEB_FETCH_KEY` for the services that want one), the
//! page is asked for through that service instead and its answer is what comes
//! back, unchanged: a reader service already returns the text it was asked for.
//!
//! A body that is not text is refused: this tool reads pages, and a download is
//! `bash` with `curl`.
const std = @import("std");
const html = @import("html.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const web = @import("web.zig");

const ToolResult = result_mod.ToolResult;

/// The web_fetch tool: one page, read as text.
pub const spec: tool.Tool = .{
    .name = "web_fetch",
    .description = "Fetch a web page and return its readable text as markdown. Use it to read a page, not to call an API.",
    .parameters_json =
    \\{"type":"object","properties":{"url":{"type":"string","description":"The full URL, including the scheme"}},"required":["url"]}
    ,
    .label = "web_fetch…",
    .run = run,
};

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    const url = parseArguments(ctx.allocator, arguments) catch |err| return switch (err) {
        // A call written for the tool this one replaced is answered with what
        // became of that argument, rather than being read as one that asked for
        // a page and nothing else.
        error.SaveToRemoved => ctx.refuse("Error: web_fetch has no 'save_to' argument. It returns a page's text; keep a file with bash and curl instead."),
        else => ctx.refuseFmt(
            "Error: web_fetch arguments are unusable ({s}); it needs a 'url'",
            .{@errorName(err)},
        ),
    };
    defer ctx.allocator.free(url);

    // A configured service answers in the page's place, and takes the page's
    // address as part of its own.
    var endpoint: ?[]u8 = null;
    defer if (endpoint) |value| ctx.allocator.free(value);
    var authorization: ?[]u8 = null;
    defer if (authorization) |value| ctx.allocator.free(value);
    var headers: [1]std.http.Header = undefined;
    var header_count: usize = 0;
    if (ctx.web.fetch_url) |service| {
        endpoint = try web.fetchEndpoint(ctx.allocator, service, url);
        if (ctx.web.fetch_key) |key| {
            authorization = try web.bearer(ctx.allocator, key);
            headers[0] = .{ .name = "authorization", .value = authorization.? };
            header_count = 1;
        }
    }

    const reply = try web.get(ctx.io, ctx.allocator, .{
        .url = endpoint orelse url,
        .headers = headers[0..header_count],
    });
    var response = switch (reply) {
        .failure => |failure| return failure.result(ctx.allocator, .{ .url = url }),
        .response => |response| response,
    };
    defer response.deinit();

    // What comes back from a configured service is the text it was asked to
    // produce; a page fetched here has to be read first.
    const text = if (endpoint != null)
        try ctx.allocator.dupe(u8, response.body)
    else
        (try readableText(ctx.allocator, response)) orelse "";
    // A successful result owns this text; the branches that build another one
    // release it themselves.
    errdefer ctx.allocator.free(text);

    if (!response.ok()) {
        const line = try response.statusLine(ctx.allocator);
        defer ctx.allocator.free(line);
        const output = try std.fmt.allocPrint(ctx.allocator, "Error: {s}\n{s}", .{ line, text });
        ctx.allocator.free(text);
        return .{ .output = output, .is_error = true };
    }

    if (endpoint == null and text.len == 0 and response.body.len > 0) {
        const refused = try ctx.refuseFmt(
            "Error: '{s}' answered with {s} of {d} bytes, which is not text; web_fetch reads pages. Fetch a download with bash and curl.",
            .{
                url,
                if (response.content_type.len > 0) response.content_type else "a body",
                response.body.len,
            },
        );
        ctx.allocator.free(text);
        return refused;
    }

    if (!response.truncated) return .{ .output = text, .is_error = false };

    const output = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}\n[the response was longer than one page of text may carry; the rest was not read]",
        .{text},
    );
    ctx.allocator.free(text);
    return .{ .output = output, .is_error = false };
}

/// The text of a response, when it has one: an HTML page is read as markdown,
/// any other text is handed over as it was written. Null for a body that is not
/// text at all.
fn readableText(allocator: std.mem.Allocator, response: web.Response) !?[]u8 {
    if (isHtml(response.content_type, response.body)) {
        // A link is resolved against the address the page really came from,
        // which after a redirect is not the one that was asked for.
        return try html.toText(allocator, response.body, .{ .base_url = response.url });
    }
    if (isText(response.content_type)) return try allocator.dupe(u8, response.body);
    return null;
}

fn isHtml(content_type: []const u8, body: []const u8) bool {
    if (std.mem.eql(u8, content_type, "text/html") or std.mem.eql(u8, content_type, "application/xhtml+xml")) return true;
    if (content_type.len > 0) return false;
    // A server that names no type still sent something, and a document that
    // opens with a tag is read as one.
    const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
    return trimmed.len > 0 and trimmed[0] == '<';
}

fn isText(content_type: []const u8) bool {
    if (content_type.len == 0) return true;
    if (std.mem.startsWith(u8, content_type, "text/")) return true;
    const texts = [_][]const u8{
        "application/json",         "application/xml",    "application/javascript",
        "application/x-javascript", "application/x-yaml", "application/yaml",
        "application/x-ndjson",     "application/sql",    "application/graphql",
    };
    for (texts) |mime| {
        if (std.mem.eql(u8, content_type, mime)) return true;
    }
    return std.mem.endsWith(u8, content_type, "+json") or std.mem.endsWith(u8, content_type, "+xml");
}

/// The one argument a call carries, owned by the caller.
fn parseArguments(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;

    if (parsed.value.object.get("save_to") != null) return error.SaveToRemoved;

    const url_value = parsed.value.object.get("url") orelse return error.MissingUrl;
    if (url_value != .string or url_value.string.len == 0) return error.MissingUrl;
    return try allocator.dupe(u8, url_value.string);
}

test "parse web_fetch arguments" {
    const a = std.testing.allocator;
    const url = try parseArguments(a, "{\"url\":\"https://example.test/page\"}");
    defer a.free(url);
    try std.testing.expectEqualStrings("https://example.test/page", url);

    // The argument this tool used to take is named as gone rather than read as
    // one that asked for a page.
    try std.testing.expectError(error.SaveToRemoved, parseArguments(
        a,
        "{\"url\":\"https://example.test/a\",\"save_to\":\"out/a\"}",
    ));

    try std.testing.expectError(error.MissingUrl, parseArguments(a, "{}"));
    try std.testing.expectError(error.MissingUrl, parseArguments(a, "{\"url\":\"\"}"));
    try std.testing.expectError(error.MissingUrl, parseArguments(a, "{\"url\":7}"));
    try std.testing.expectError(error.InvalidArguments, parseArguments(a, "[]"));
}

test "a page is read as text and anything else is not" {
    try std.testing.expect(isHtml("text/html", ""));
    try std.testing.expect(isHtml("application/xhtml+xml", ""));
    try std.testing.expect(isHtml("", "  <!DOCTYPE html>"));
    try std.testing.expect(!isHtml("", "plain words"));
    try std.testing.expect(!isHtml("application/json", "<html>"));

    try std.testing.expect(isText(""));
    try std.testing.expect(isText("text/plain"));
    try std.testing.expect(isText("application/json"));
    try std.testing.expect(isText("application/ld+json"));
    try std.testing.expect(!isText("image/png"));
    try std.testing.expect(!isText("application/octet-stream"));
}
