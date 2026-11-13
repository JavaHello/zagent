//! The `web_search` tool: what the web says about a query, as a list of titles,
//! addresses and snippets.
//!
//! Where the results come from is configuration. With `WEB_SEARCH_URL` set (and
//! `WEB_SEARCH_KEY` when the service wants one) the query is put to that
//! endpoint, and its answer is read: JSON is read for its results, an HTML
//! results page is parsed, and anything else is handed over as the service
//! wrote it. With nothing configured the query goes to DuckDuckGo's own results
//! page, which takes no key and is the one source that works out of the box.
const std = @import("std");
const args_mod = @import("args.zig");
const html = @import("html.zig");
const result_mod = @import("result.zig");
const tool = @import("tool.zig");
const web = @import("web.zig");

const ToolResult = result_mod.ToolResult;

/// The web_search tool: one query, its results.
pub const spec: tool.Tool = .{
    .name = "web_search",
    .description = "Search the web and return the title, URL and snippet of each result. Use it to find pages; read one with web_fetch.",
    .parameters_json =
    \\{"type":"object","properties":{"query":{"type":"string","description":"What to search for"},"limit":{"type":"integer","description":"How many results to return, 1-20; defaults to 8","minimum":1,"maximum":20}},"required":["query"]}
    ,
    .label = "web_search…",
    .run = run,
};

/// How many results a call gets when it does not say.
const default_limit: usize = 8;

/// The most results one call may ask for.
const max_limit: usize = 20;

/// Where a search without a configured service goes. DuckDuckGo's HTML page
/// answers without a key, which is what makes it the fallback rather than the
/// first choice.
const duckduckgo_endpoint = "https://html.duckduckgo.com/html/?q=";

/// What the fallback asks with. DuckDuckGo answers a browser's user agent with
/// a page that needs JavaScript to show a result, and answers a text browser
/// with the results themselves — which is what this client can read.
const text_browser_user_agent = "Lynx/2.8.9rel.1 libwww-FM/2.14 SSL-MM/1.4.1";

fn run(ctx: tool.Context, arguments: []const u8) !ToolResult {
    const request = parseArguments(ctx.allocator, arguments) catch |err| return ctx.refuseFmt(
        "Error: web_search arguments are unusable ({s}); it needs a 'query' and a 'limit' between 1 and {d}",
        .{ @errorName(err), max_limit },
    );
    defer request.deinit(ctx.allocator);

    const limit = @min(request.limit orelse default_limit, max_limit);
    if (ctx.web.search_url) |service| return configured(ctx, service, request.query, limit);
    return duckduckgo(ctx, request.query, limit);
}

/// Put the query to the configured endpoint and read what it answers.
fn configured(ctx: tool.Context, service: []const u8, query: []const u8, limit: usize) !ToolResult {
    const encoded = try web.percentEncode(ctx.allocator, query);
    defer ctx.allocator.free(encoded);
    const limit_text = try std.fmt.allocPrint(ctx.allocator, "{d}", .{limit});
    defer ctx.allocator.free(limit_text);
    const url = try endpointUrl(ctx.allocator, service, encoded, limit_text);
    defer ctx.allocator.free(url);

    var authorization: ?[]u8 = null;
    defer if (authorization) |value| ctx.allocator.free(value);
    var headers: [2]std.http.Header = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "accept", .value = "application/json, text/html;q=0.9, text/plain;q=0.5" };
    header_count += 1;
    if (ctx.web.search_key) |key| {
        authorization = try web.bearer(ctx.allocator, key);
        headers[header_count] = .{ .name = "authorization", .value = authorization.? };
        header_count += 1;
    }

    const reply = try web.get(ctx.io, ctx.allocator, .{ .url = url, .headers = headers[0..header_count] });
    var response = switch (reply) {
        .failure => |failure| return failure.result(ctx.allocator, .{ .url = url }),
        .response => |response| response,
    };
    defer response.deinit();

    if (!response.ok()) {
        const line = try response.statusLine(ctx.allocator);
        defer ctx.allocator.free(line);
        return .{
            .output = try std.fmt.allocPrint(ctx.allocator, "Error: '{s}' answered {s}:\n{s}", .{ url, line, response.body }),
            .is_error = true,
        };
    }

    // A service may answer with results, with a results page, or with text of
    // its own; each is handed over the way it was written.
    if (try jsonResults(ctx.allocator, response.body, query, limit)) |output| return .{ .output = output, .is_error = false };
    if (try htmlResults(ctx.allocator, response.body, query, limit)) |output| return .{ .output = output, .is_error = false };
    return .{ .output = try ctx.allocator.dupe(u8, response.body), .is_error = false };
}

/// Put the query to DuckDuckGo's results page. There is no key and no setting:
/// this is what happens when nothing else is configured.
fn duckduckgo(ctx: tool.Context, query: []const u8, limit: usize) !ToolResult {
    const encoded = try web.percentEncode(ctx.allocator, query);
    defer ctx.allocator.free(encoded);
    const url = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ duckduckgo_endpoint, encoded });
    defer ctx.allocator.free(url);

    const reply = try web.get(ctx.io, ctx.allocator, .{
        .url = url,
        .headers = &.{
            .{ .name = "user-agent", .value = text_browser_user_agent },
            .{ .name = "accept", .value = "text/html,application/xhtml+xml" },
        },
    });
    var response = switch (reply) {
        .failure => |failure| return failure.result(ctx.allocator, .{ .url = url }),
        .response => |response| response,
    };
    defer response.deinit();

    if (response.ok()) {
        if (try htmlResults(ctx.allocator, response.body, query, limit)) |output| return .{ .output = output, .is_error = false };
    }

    const line = try response.statusLine(ctx.allocator);
    defer ctx.allocator.free(line);
    return ctx.refuseFmt(
        "Error: DuckDuckGo returned no results ({s}). Set WEB_SEARCH_URL, and WEB_SEARCH_KEY when the service takes one, to search through an endpoint instead.",
        .{line},
    );
}

/// Where a configured service is asked: its own template with `{query}` and
/// `{limit}` filled in, or the query added to its query string when the
/// template does not say where it goes.
fn endpointUrl(
    allocator: std.mem.Allocator,
    template: []const u8,
    encoded_query: []const u8,
    limit: []const u8,
) ![]u8 {
    var url: []u8 = if (try web.fill(allocator, template, "{query}", encoded_query)) |filled|
        filled
    else blk: {
        const separator: u8 = if (std.mem.indexOfScalar(u8, template, '?') != null) '&' else '?';
        break :blk try std.fmt.allocPrint(allocator, "{s}{c}q={s}", .{ template, separator, encoded_query });
    };
    if (try web.fill(allocator, url, "{limit}", limit)) |filled| {
        allocator.free(url);
        url = filled;
    }
    return url;
}

/// One search result.
const Hit = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    snippet: []const u8 = "",
};

/// Write the results the way the model reads them: a numbered list, each entry
/// naming what it is, where it is and what it says.
fn render(allocator: std.mem.Allocator, hits: []const Hit, query: []const u8) ![]u8 {
    if (hits.len == 0) return std.fmt.allocPrint(allocator, "No results for '{s}'.", .{query});

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (hits, 0..) |hit, index| {
        const title = if (hit.title.len > 0) hit.title else hit.url;
        if (index > 0) try out.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "{d}. {s}\n   {s}", .{ index + 1, title, hit.url });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
        const snippet = std.mem.trim(u8, hit.snippet, " \t\r\n");
        if (snippet.len > 0) {
            // A snippet is one line of the list whatever its source wrapped it
            // in: its own line breaks folded into spaces, its words as they are.
            const folded = try fold(allocator, snippet);
            defer allocator.free(folded);
            if (folded.len > 0) {
                const quoted = try std.fmt.allocPrint(allocator, "\n   {s}", .{folded});
                defer allocator.free(quoted);
                try out.appendSlice(allocator, quoted);
            }
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// One line of text: the whitespace runs in it, its line breaks included,
/// folded into single spaces.
fn fold(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var space = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) try out.append(allocator, ' ');
        space = false;
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// Read an HTML results page — DuckDuckGo's own, or a service that answers with
/// one. Null when the page holds no results of that shape.
fn htmlResults(
    allocator: std.mem.Allocator,
    page: []const u8,
    query: []const u8,
    limit: usize,
) !?[]u8 {
    var links = try collectLinks(allocator, page);
    defer links.deinit(allocator);

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(allocator);
    defer for (hits.items) |hit| {
        allocator.free(hit.title);
        allocator.free(hit.url);
        allocator.free(hit.snippet);
    };

    for (links.items, 0..) |link, index| {
        if (hits.items.len >= limit) break;
        const until = if (index + 1 < links.items.len) links.items[index + 1].start else page.len;
        // The entry is added before its parts are made, so that the list owns
        // whatever was built if a later allocation fails.
        try hits.append(allocator, .{});
        const hit = &hits.items[hits.items.len - 1];
        hit.title = try html.fragment(allocator, page[link.tag_end..link.content_end]);
        const href = html.attribute(page[link.start..link.tag_end], "href") orelse "";
        const decoded = try html.decodeEntities(allocator, href);
        defer allocator.free(decoded);
        hit.url = try unwrap(allocator, decoded);
        hit.snippet = if (snippetOf(page, link.next, until)) |text|
            try html.fragment(allocator, text)
        else
            try allocator.dupe(u8, "");
    }

    if (hits.items.len == 0) return null;
    return try render(allocator, hits.items, query);
}

/// One result link: where its tag starts, where its text starts and ends, and
/// where the page carries on after it.
const Link = struct {
    start: usize,
    tag_end: usize,
    content_end: usize,
    next: usize,
};

fn collectLinks(allocator: std.mem.Allocator, page: []const u8) !std.ArrayList(Link) {
    var links: std.ArrayList(Link) = .empty;
    errdefer links.deinit(allocator);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, page, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, page, lt, '>') orelse break;
        const raw = page[lt .. gt + 1];
        const parsed = html.tag(raw);
        if (!parsed.closing and (html.hasClass(raw, "result__a") or html.hasClass(raw, "result-link"))) {
            const close = html.findClose(page, gt + 1, parsed.name) orelse break;
            try links.append(allocator, .{
                .start = lt,
                .tag_end = gt + 1,
                .content_end = close.content_end,
                .next = close.next,
            });
            i = close.next;
            continue;
        }
        i = gt + 1;
    }
    return links;
}

/// The snippet that belongs to a result: the next element marked as one, before
/// the result that follows it.
fn snippetOf(page: []const u8, from: usize, until: usize) ?[]const u8 {
    var i = from;
    while (i < until) {
        const lt = std.mem.indexOfScalarPos(u8, page, i, '<') orelse return null;
        if (lt >= until) return null;
        const gt = std.mem.indexOfScalarPos(u8, page, lt, '>') orelse return null;
        const raw = page[lt .. gt + 1];
        const parsed = html.tag(raw);
        if (!parsed.closing and (html.hasClass(raw, "result__snippet") or html.hasClass(raw, "result-snippet"))) {
            const close = html.findClose(page, gt + 1, parsed.name) orelse return null;
            return page[gt + 1 .. @min(close.content_end, until)];
        }
        i = gt + 1;
    }
    return null;
}

/// The address a result points at. DuckDuckGo wraps every result in a redirect
/// of its own; the address inside it is what a reader would follow.
fn unwrap(allocator: std.mem.Allocator, href: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, href, "uddg=")) |at| {
        const value = href[at + "uddg=".len ..];
        const end = std.mem.indexOfScalar(u8, value, '&') orelse value.len;
        return try web.percentDecode(allocator, value[0..end]);
    }
    if (std.mem.startsWith(u8, href, "//")) return std.fmt.allocPrint(allocator, "https:{s}", .{href});
    return try allocator.dupe(u8, href);
}

/// A body a service answered with, read for the results in it. Null when the
/// body is not JSON or holds none that can be recognised.
fn jsonResults(
    allocator: std.mem.Allocator,
    body: []const u8,
    query: []const u8,
    limit: usize,
) !?[]u8 {
    const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(allocator);
    try collectHits(allocator, parsed.value, &hits, limit, 0);
    if (hits.items.len == 0) return null;
    return try render(allocator, hits.items, query);
}

/// Find the results in a JSON answer without being told the shape of it: the
/// first array of objects that name an address, wherever the service put it.
fn collectHits(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    hits: *std.ArrayList(Hit),
    limit: usize,
    depth: usize,
) !void {
    if (hits.items.len >= limit or depth > 6) return;
    switch (value) {
        .array => |array| {
            for (array.items) |item| {
                if (hits.items.len >= limit) return;
                if (hitOf(item)) |hit| {
                    try hits.append(allocator, hit);
                    continue;
                }
                try collectHits(allocator, item, hits, limit, depth + 1);
            }
        },
        .object => |object| {
            if (hitOf(value)) |hit| {
                try hits.append(allocator, hit);
                return;
            }
            var entries = object.iterator();
            while (entries.next()) |entry| {
                if (hits.items.len >= limit) return;
                try collectHits(allocator, entry.value_ptr.*, hits, limit, depth + 1);
            }
        },
        else => {},
    }
}

/// One object read as a result, or null when it names no address it could be.
fn hitOf(value: std.json.Value) ?Hit {
    if (value != .object) return null;
    const object = value.object;
    const url = stringField(object, &.{ "url", "link", "href" }) orelse return null;
    if (url.len == 0) return null;
    return .{
        .title = stringField(object, &.{ "title", "name", "heading" }) orelse "",
        .url = url,
        .snippet = stringField(object, &.{ "content", "description", "snippet", "text", "summary", "body" }) orelse "",
    };
}

fn stringField(object: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = object.get(name) orelse continue;
        if (value == .string and value.string.len > 0) return value.string;
    }
    return null;
}

const Arguments = struct {
    query: []const u8,
    limit: ?usize = null,

    fn deinit(self: Arguments, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
    }
};

fn parseArguments(allocator: std.mem.Allocator, arguments_json: []const u8) !Arguments {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const arguments = parsed.value.object;

    const query_value = arguments.get("query") orelse return error.MissingQuery;
    if (query_value != .string or query_value.string.len == 0) return error.MissingQuery;
    const query = try allocator.dupe(u8, query_value.string);
    errdefer allocator.free(query);

    const limit = try args_mod.optionalUnsigned(arguments.get("limit"), 1);
    return .{ .query = query, .limit = limit };
}

test "parse web_search arguments" {
    const a = std.testing.allocator;
    const simple = try parseArguments(a, "{\"query\":\"zig\"}");
    defer simple.deinit(a);
    try std.testing.expectEqualStrings("zig", simple.query);
    try std.testing.expect(simple.limit == null);

    const counted = try parseArguments(a, "{\"query\":\"zig\",\"limit\":3}");
    defer counted.deinit(a);
    try std.testing.expectEqual(@as(?usize, 3), counted.limit);

    try std.testing.expectError(error.MissingQuery, parseArguments(a, "{}"));
    try std.testing.expectError(error.MissingQuery, parseArguments(a, "{\"query\":\"\"}"));
    try std.testing.expectError(error.InvalidArguments, parseArguments(a, "[]"));
    try std.testing.expectError(error.InvalidArguments, parseArguments(a, "{\"query\":\"zig\",\"limit\":0}"));
    try std.testing.expectError(error.InvalidArguments, parseArguments(a, "{\"query\":\"zig\",\"limit\":\"3\"}"));
}

test "a results page is read into a numbered list" {
    const a = std.testing.allocator;
    const page =
        \\<div class="result results_links">
        \\  <h2><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2F&amp;rut=x">Zig Programming &amp; Language</a></h2>
        \\  <a class="result__snippet" href="https://ziglang.org/">A <b>general-purpose</b> language.</a>
        \\</div>
        \\<div class="result results_links">
        \\  <h2><a rel="nofollow" class="result__a" href="https://zig.dev/docs">Docs</a></h2>
        \\  <a class="result__snippet" href="https://zig.dev/docs">The documentation.</a>
        \\</div>
    ;
    const output = (try htmlResults(a, page, "zig", 8)).?;
    defer a.free(output);
    try std.testing.expectEqualStrings(
        \\1. Zig Programming & Language
        \\   https://ziglang.org/
        \\   A general-purpose language.
        \\
        \\2. Docs
        \\   https://zig.dev/docs
        \\   The documentation.
        \\
    , output);
}

test "a results page in the lite shape is read too" {
    const a = std.testing.allocator;
    const page =
        \\<table><tr><td><a rel="nofollow" href="https://example.test/a" class='result-link'>First</a></td></tr>
        \\<tr><td class='result-snippet'>What the first one says.</td></tr></table>
    ;
    const output = (try htmlResults(a, page, "first", 8)).?;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "1. First") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://example.test/a") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "What the first one says.") != null);
}

test "a page with no results of that shape is not one" {
    const a = std.testing.allocator;
    try std.testing.expect((try htmlResults(a, "<html><body>nothing here</body></html>", "zig", 8)) == null);
}

test "results are read out of JSON whatever the service calls its fields" {
    const a = std.testing.allocator;
    const body =
        \\{"query":"zig","results":[
        \\  {"title":"Zig","url":"https://ziglang.org/","content":"A language."},
        \\  {"name":"Docs","link":"https://zig.dev/","description":"How to."}
        \\]}
    ;
    const output = (try jsonResults(a, body, "zig", 8)).?;
    defer a.free(output);
    try std.testing.expectEqualStrings(
        \\1. Zig
        \\   https://ziglang.org/
        \\   A language.
        \\
        \\2. Docs
        \\   https://zig.dev/
        \\   How to.
        \\
    , output);
}

test "a snippet keeps text that only looks like markup" {
    const a = std.testing.allocator;
    const body = "{\"results\":[{\"title\":\"HTML\",\"url\":\"https://a.test\",\"content\":\"Use <div> and\\n<b> together\"}]}";
    const output = (try jsonResults(a, body, "html", 8)).?;
    defer a.free(output);
    try std.testing.expectEqualStrings(
        "1. HTML\n   https://a.test\n   Use <div> and <b> together\n",
        output,
    );
}

test "a JSON answer without results is handed over rather than read" {
    const a = std.testing.allocator;
    try std.testing.expect((try jsonResults(a, "{\"status\":\"ok\"}", "zig", 8)) == null);
    try std.testing.expect((try jsonResults(a, "not json", "zig", 8)) == null);
}

test "the results stop at the limit" {
    const a = std.testing.allocator;
    const body =
        \\{"results":[{"title":"a","url":"https://a.test"},{"title":"b","url":"https://b.test"},{"title":"c","url":"https://c.test"}]}
    ;
    const output = (try jsonResults(a, body, "q", 2)).?;
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://b.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "https://c.test") == null);
}

test "a configured endpoint takes the query where its template says, or in its query string" {
    const a = std.testing.allocator;
    const templated = try endpointUrl(a, "https://search.test/api?q={query}&n={limit}", "zig", "5");
    defer a.free(templated);
    try std.testing.expectEqualStrings("https://search.test/api?q=zig&n=5", templated);

    const appended = try endpointUrl(a, "https://search.test/api", "zig", "5");
    defer a.free(appended);
    try std.testing.expectEqualStrings("https://search.test/api?q=zig", appended);

    const with_query = try endpointUrl(a, "https://search.test/api?engine=web", "zig", "5");
    defer a.free(with_query);
    try std.testing.expectEqualStrings("https://search.test/api?engine=web&q=zig", with_query);
}

test "a DuckDuckGo redirect is opened, and the address inside it kept" {
    const a = std.testing.allocator;
    const opened = try unwrap(a, "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.test%2Fa%3Fb%3D1&rut=abc");
    defer a.free(opened);
    try std.testing.expectEqualStrings("https://example.test/a?b=1", opened);

    const direct = try unwrap(a, "https://example.test/b");
    defer a.free(direct);
    try std.testing.expectEqualStrings("https://example.test/b", direct);
}
