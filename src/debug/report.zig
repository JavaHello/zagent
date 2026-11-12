//! The HTML report a debug trace is read through.
//!
//! One self-contained file: no network, no external stylesheet, no framework,
//! so a trace can be copied off the machine it came from and opened anywhere.
//! The events are read back from the JSON lines the run wrote, which is also
//! why `zagent --debug-report` can rebuild a report from a trace kept earlier.
//!
//! The page is a vertical flowchart — one node per step, in the order the run
//! took them — and every node opens onto the bytes behind it: the body that was
//! sent, the raw stream that came back, the arguments of a tool call and the
//! result it produced.
const std = @import("std");

/// How many characters of a payload a node shows before its details are opened.
const preview_chars: usize = 200;

pub fn render(allocator: std.mem.Allocator, jsonl: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var events: std.ArrayList(std.json.Value) = .empty;
    defer events.deinit(arena);
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // One bad line is one lost step, not a lost report: the run is read as
        // far as it was written.
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch continue;
        if (value != .object) continue;
        try events.append(arena, value);
    }

    var counts: Counts = .{};
    for (events.items) |event| counts.add(string(event, "event"));

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeHead(&out.writer, events.items, counts);
    try out.writer.writeAll("<ol class=\"flow\">\n");
    for (events.items) |event| try writeNode(&out.writer, arena, event);
    try out.writer.writeAll("</ol>\n</main>\n");
    try writeScript(&out.writer);
    try out.writer.writeAll("</body>\n</html>\n");
    return out.toOwnedSlice();
}

const Counts = struct {
    requests: usize = 0,
    responses: usize = 0,
    calls: usize = 0,
    results: usize = 0,
    failures: usize = 0,
    notes: usize = 0,

    fn add(self: *Counts, kind: []const u8) void {
        if (std.mem.eql(u8, kind, "request")) self.requests += 1;
        if (std.mem.eql(u8, kind, "response")) self.responses += 1;
        if (std.mem.eql(u8, kind, "tool_call")) self.calls += 1;
        if (std.mem.eql(u8, kind, "tool_result")) self.results += 1;
        if (std.mem.eql(u8, kind, "failure")) self.failures += 1;
        if (std.mem.eql(u8, kind, "note")) self.notes += 1;
    }
};

/// The page as a whole: what the run was, how much of it there is, and the
/// controls that move through it.
fn writeHead(w: *std.Io.Writer, events: []const std.json.Value, counts: Counts) !void {
    const run = if (events.len > 0 and std.mem.eql(u8, string(events[0], "event"), "run"))
        events[0]
    else
        std.json.Value{ .null = {} };
    const session = string(run, "session");

    try w.writeAll(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>zagent debug trace
        \\
    );
    if (session.len > 0) {
        try w.writeAll(" · ");
        try escaped(w, session);
    }
    try w.writeAll(
        \\</title>
        \\<style>
        \\
    );
    try w.writeAll(css);
    try w.writeAll(
        \\</style>
        \\</head>
        \\<body>
        \\<header>
        \\<div class="brand"><span class="mark">zagent</span><span class="tagline">debug trace</span></div>
        \\<div class="controls">
        \\<input id="q" type="search" placeholder="Filter steps…" autocomplete="off">
        \\<button type="button" data-expand="1">Expand all</button>
        \\<button type="button" data-expand="0">Collapse all</button>
        \\</div>
        \\</header>
        \\<main>
        \\
    );

    try writeRun(w, run);
    try writeFilters(w, counts, events.len);
}

/// What the run was: the session, the model, the directories, the limits.
fn writeRun(w: *std.Io.Writer, run: std.json.Value) !void {
    if (run != .object) return;
    try w.writeAll("<section class=\"run\">\n<dl>\n");
    try fact(w, "session", string(run, "session"));
    try fact(w, "model", string(run, "model"));
    try fact(w, "provider", string(run, "provider"));
    try fact(w, "endpoint", string(run, "base_url"));
    try fact(w, "workspace", string(run, "workspace"));
    try fact(w, "scratch", string(run, "scratch"));
    if (integer(run, "max_tokens")) |limit| try number(w, "output budget", limit, "");
    if (integer(run, "max_iterations")) |limit| try number(w, "iteration limit", limit, "");
    try w.writeAll("</dl>\n</section>\n");
}

fn fact(w: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try w.print("<div><dt>{s}</dt><dd>", .{label});
    try escaped(w, value);
    try w.writeAll("</dd></div>\n");
}

fn number(w: *std.Io.Writer, label: []const u8, value: i64, suffix: []const u8) !void {
    try w.print("<div><dt>{s}</dt><dd>{d}{s}</dd></div>\n", .{ label, value, suffix });
}

/// One chip per kind of step. They are toggles: a run with many tool calls is
/// read by turning the requests off for a moment.
fn writeFilters(w: *std.Io.Writer, counts: Counts, total: usize) !void {
    try w.writeAll("<div class=\"filters\">\n");
    try w.print("<button type=\"button\" class=\"chip on\" data-filter=\"all\">All <b>{d}</b></button>\n", .{total});
    try w.print("<button type=\"button\" class=\"chip on\" data-filter=\"request\">Requests <b>{d}</b></button>\n", .{counts.requests});
    try w.print("<button type=\"button\" class=\"chip on\" data-filter=\"response\">Responses <b>{d}</b></button>\n", .{counts.responses});
    try w.print("<button type=\"button\" class=\"chip on\" data-filter=\"tool\">Tool calls <b>{d}</b></button>\n", .{counts.calls});
    try w.print("<button type=\"button\" class=\"chip on\" data-filter=\"failure\">Failures <b>{d}</b></button>\n", .{counts.failures});
    try w.print("<button type=\"button\" class=\"chip on\" data-filter=\"note\">Notes <b>{d}</b></button>\n", .{counts.notes});
    try w.writeAll("</div>\n");
}

const Head = struct {
    label: []const u8,
    title: []const u8,
    meta: []const u8 = "",
    preview: []const u8 = "",
    open: bool = false,
    /// Whether the node has blocks to show. A step that is only a line — the
    /// run starting, a note, the end of a turn — has no details to open.
    detail: bool = true,
};

fn writeNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    const kind = string(event, "event");
    if (std.mem.eql(u8, kind, "run")) return writeRunNode(w, event);
    if (std.mem.eql(u8, kind, "query")) return writeQueryNode(w, arena, event);
    if (std.mem.eql(u8, kind, "request")) return writeRequestNode(w, arena, event);
    if (std.mem.eql(u8, kind, "response")) return writeResponseNode(w, arena, event);
    if (std.mem.eql(u8, kind, "tool_call")) return writeCallNode(w, arena, event);
    if (std.mem.eql(u8, kind, "tool_result")) return writeResultNode(w, arena, event);
    if (std.mem.eql(u8, kind, "failure")) return writeFailureNode(w, arena, event);
    if (std.mem.eql(u8, kind, "note")) return writeNoteNode(w, arena, event);
    if (std.mem.eql(u8, kind, "turn")) return writeTurnNode(w, arena, event);
    // A kind this version does not know: still a step of the run.
    return writeGenericNode(w, arena, event);
}

fn writeRunNode(w: *std.Io.Writer, event: std.json.Value) !void {
    try nodeStart(w, event, .{
        .label = "RUN",
        .title = "Run started",
        .meta = string(event, "model"),
        .detail = false,
    });
    try nodeEnd(w, false);
}

fn writeQueryNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    const text = string(event, "text");
    try nodeStart(w, event, .{
        .label = "QUERY",
        .title = "Task the user asked for",
        .meta = string(event, "agent"),
        .preview = preview(text),
        .open = true,
    });
    try block(w, arena, "Text", text, false);
    try nodeEnd(w, true);
}

fn writeRequestNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    const title = try std.fmt.allocPrint(arena, "Request #{d}", .{integer(event, "iter") orelse 0});
    var size_buffer: [32]u8 = undefined;
    const meta = try std.fmt.allocPrint(arena, "{s} · {s} · ~{d} tokens", .{
        string(event, "agent"),
        sizeText(&size_buffer, integer(event, "bytes") orelse 0),
        integer(event, "est_tokens") orelse 0,
    });
    try nodeStart(w, event, .{ .label = "REQUEST", .title = title, .meta = meta });
    try block(w, arena, "Endpoint", string(event, "url"), false);
    try block(w, arena, "Model", string(event, "model"), false);
    if (boolean(event, "body_truncated")) try hint(w, "The body was longer than the trace keeps; its opening is shown.");
    try block(w, arena, "Request body", string(event, "body"), true);
    try nodeEnd(w, true);
}

fn writeResponseNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    const title = try std.fmt.allocPrint(arena, "Response #{d}", .{integer(event, "iter") orelse 0});
    var meta_aw: std.Io.Writer.Allocating = .init(arena);
    const finish = string(event, "finish");
    try meta_aw.writer.print("finish={s} · {d} ms", .{
        if (finish.len > 0) finish else "(none)",
        integer(event, "ms") orelse 0,
    });
    if (integer(event, "in_tokens")) |input| {
        try meta_aw.writer.print(" · in {d} / out {d} tokens", .{ input, integer(event, "out_tokens") orelse 0 });
    } else {
        try meta_aw.writer.writeAll(" · usage not reported");
    }
    try nodeStart(w, event, .{
        .label = "RESPONSE",
        .title = title,
        .meta = meta_aw.written(),
        .preview = preview(string(event, "content")),
    });
    if (string(event, "reasoning").len > 0) try block(w, arena, "Reasoning", string(event, "reasoning"), false);
    try block(w, arena, "Answer text", string(event, "content"), false);
    if (field(event, "tool_calls")) |calls| {
        if (calls == .array and calls.array.items.len > 0) {
            const encoded = try std.json.Stringify.valueAlloc(arena, calls, .{ .whitespace = .indent_2 });
            try block(w, arena, "Tool calls the model asked for", encoded, false);
        }
    }
    if (boolean(event, "raw_truncated")) try hint(w, "The stream was longer than the trace keeps; its opening is shown.");
    try block(w, arena, "Raw stream from the API", string(event, "raw"), false);
    try nodeEnd(w, true);
}

fn writeCallNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    const title = try std.fmt.allocPrint(arena, "Call {s}", .{string(event, "name")});
    const meta = try std.fmt.allocPrint(arena, "{s} · id {s}", .{ string(event, "agent"), string(event, "call_id") });
    try nodeStart(w, event, .{
        .label = "TOOL CALL",
        .title = title,
        .meta = meta,
        .preview = preview(string(event, "args")),
    });
    try block(w, arena, "Arguments", string(event, "args"), true);
    try nodeEnd(w, true);
}

fn writeResultNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    const name = string(event, "name");
    const failed = boolean(event, "is_error");
    const title = try std.fmt.allocPrint(arena, "{s} result", .{name});

    var meta_aw: std.Io.Writer.Allocating = .init(arena);
    try meta_aw.writer.print("{s} · {d} ms", .{ string(event, "agent"), integer(event, "ms") orelse 0 });
    if (failed) try meta_aw.writer.writeAll(" · error");
    if (integer(event, "exit_code")) |code| try meta_aw.writer.print(" · exit {d}", .{code});
    if (boolean(event, "timed_out")) try meta_aw.writer.writeAll(" · timed out");

    try nodeStart(w, event, .{
        .label = if (failed) "TOOL ERROR" else "TOOL RESULT",
        .title = title,
        .meta = meta_aw.written(),
        .preview = preview(string(event, "content")),
        .open = failed,
    });
    if (boolean(event, "truncated")) try hint(w, "The tool cut this result down to its size limit before returning it.");
    if (boolean(event, "content_truncated")) try hint(w, "The result was longer than the trace keeps; its opening is shown.");
    try block(w, arena, "Output", string(event, "content"), false);
    try nodeEnd(w, true);
}

fn writeFailureNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    try nodeStart(w, event, .{
        .label = "FAILURE",
        .title = string(event, "message"),
        .meta = string(event, "agent"),
        .open = true,
    });
    if (boolean(event, "raw_truncated")) try hint(w, "What the server sent was longer than the trace keeps.");
    try block(w, arena, "What the server sent", string(event, "raw"), false);
    try nodeEnd(w, true);
}

fn writeNoteNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    _ = arena;
    const level = string(event, "level");
    try nodeStart(w, event, .{
        .label = "NOTE",
        .title = string(event, "text"),
        .meta = if (level.len > 0) level else "info",
        .detail = false,
    });
    try nodeEnd(w, false);
}

fn writeTurnNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    const completed = boolean(event, "completed");
    const meta = try std.fmt.allocPrint(arena, "{s} · {d} tool calls · {d} ms", .{
        string(event, "agent"),
        integer(event, "tool_calls") orelse 0,
        integer(event, "ms") orelse 0,
    });
    try nodeStart(w, event, .{
        .label = "TURN",
        .title = if (completed) "Turn finished" else "Turn stopped before an answer",
        .meta = meta,
        .open = !completed,
        .detail = false,
    });
    try nodeEnd(w, false);
}

fn writeGenericNode(w: *std.Io.Writer, arena: std.mem.Allocator, event: std.json.Value) !void {
    const encoded = try std.json.Stringify.valueAlloc(arena, event, .{ .whitespace = .indent_2 });
    try nodeStart(w, event, .{ .label = "STEP", .title = string(event, "event") });
    try block(w, arena, "Event", encoded, false);
    try nodeEnd(w, true);
}

/// The frame every node shares: the rail and its dot, the kind, the one line
/// that identifies the step, and the moment it happened.
fn nodeStart(w: *std.Io.Writer, event: std.json.Value, head: Head) !void {
    const kind = string(event, "event");
    const seq = integer(event, "seq") orelse 0;
    try w.print("<li class=\"node k-{s}\" data-kind=\"{s}\" id=\"e{d}\">\n", .{ kind, kind, seq });
    try w.writeAll("<div class=\"rail\"><span class=\"dot\"></span></div>\n<div class=\"card\">\n<div class=\"head\">\n");
    try w.print("<span class=\"kind\">{s}</span>\n<span class=\"title\">", .{head.label});
    try escaped(w, head.title);
    try w.writeAll("</span>\n");
    if (head.meta.len > 0) {
        try w.writeAll("<span class=\"meta\">");
        try escaped(w, head.meta);
        try w.writeAll("</span>\n");
    }
    try writeTime(w, event);
    try w.writeAll("</div>\n");
    if (head.preview.len > 0) {
        try w.writeAll("<div class=\"preview\">");
        try escaped(w, head.preview);
        try w.writeAll("</div>\n");
    }
    // `open` is written now: the details element wraps every block below.
    if (head.detail) {
        try w.writeAll(if (head.open) "<details open><summary>Details</summary>\n" else "<details><summary>Details</summary>\n");
    }
}

/// Close the node, and the details element `nodeStart` opened when it had one.
fn nodeEnd(w: *std.Io.Writer, detail: bool) !void {
    if (detail) try w.writeAll("</details>\n");
    try w.writeAll("</div>\n</li>\n");
}

// --- reading events --------------------------------------------------------

fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn string(value: std.json.Value, key: []const u8) []const u8 {
    const found = field(value, key) orelse return "";
    return switch (found) {
        .string => |text| text,
        else => "",
    };
}

fn integer(json: std.json.Value, key: []const u8) ?i64 {
    const found = field(json, key) orelse return null;
    return switch (found) {
        .integer => |value| value,
        .float => |value| @intFromFloat(value),
        else => null,
    };
}

fn boolean(value: std.json.Value, key: []const u8) bool {
    const found = field(value, key) orelse return false;
    return switch (found) {
        .bool => |flag| flag,
        else => false,
    };
}

// --- writing pieces of the page --------------------------------------------

/// The first line of a payload, short enough to sit under a node's title.
fn preview(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    var end: usize = 0;
    while (end < trimmed.len and end < preview_chars) : (end += 1) {
        if (trimmed[end] == '\n' or trimmed[end] == '\r') break;
    }
    // A preview must not end in the middle of a character.
    while (end > 0 and end < trimmed.len and (trimmed[end] & 0xc0) == 0x80) end -= 1;
    return trimmed[0..end];
}

fn sizeText(buffer: []u8, bytes: i64) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
    if (bytes < 1024 * 1024) {
        return std.fmt.bufPrint(buffer, "{d}.{d} KB", .{ @divTrunc(bytes, 1024), @divTrunc(@mod(bytes, 1024) * 10, 1024) }) catch "";
    }
    return std.fmt.bufPrint(buffer, "{d}.{d} MB", .{ @divTrunc(bytes, 1024 * 1024), @divTrunc(@mod(bytes, 1024 * 1024) * 10, 1024 * 1024) }) catch "";
}

/// When in the run the step happened, counted from the moment the trace was
/// opened. Wall-clock time is in the JSON line for anyone who needs it.
fn writeTime(w: *std.Io.Writer, event: std.json.Value) !void {
    const ms = integer(event, "t") orelse 0;
    try w.writeAll("<span class=\"time\">");
    if (ms < 1000) {
        try w.print("+{d} ms", .{ms});
    } else {
        try w.print("+{d}.{d:0>2}s", .{ @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 10) });
    }
    try w.writeAll("</span>\n");
}

/// HTML-safe text. The payloads are model output, file contents and command
/// output: they are data, and must never become markup. Quotes are left alone:
/// this is element content, never an attribute, and a JSON body reads better
/// when it looks like the JSON that was sent.
fn escaped(w: *std.Io.Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        const replacement: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (replacement) |entity| {
            if (index > start) try w.writeAll(text[start..index]);
            try w.writeAll(entity);
            start = index + 1;
        }
    }
    if (start < text.len) try w.writeAll(text[start..]);
}

/// A payload that is JSON is shown indented: a request body read as one line
/// says nothing about which message was sent.
fn jsonText(w: *std.Io.Writer, arena: std.mem.Allocator, text: []const u8) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        // Not JSON after all — a truncated body, a plain-text answer. Shown as
        // it is rather than dropped.
        return escaped(w, text);
    };
    var buffer: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(parsed, .{ .whitespace = .indent_2 }, &buffer.writer) catch return escaped(w, text);
    return escaped(w, buffer.written());
}

fn block(w: *std.Io.Writer, arena: std.mem.Allocator, title: []const u8, text: []const u8, as_json: bool) !void {
    if (text.len == 0) return;
    try w.print("<div class=\"block\"><h4>{s}</h4><pre>", .{title});
    if (as_json) try jsonText(w, arena, text) else try escaped(w, text);
    try w.writeAll("</pre></div>\n");
}

fn hint(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("<p class=\"hint\">");
    try escaped(w, text);
    try w.writeAll("</p>\n");
}

const css =
    \\:root{
    \\  color-scheme: dark;
    \\  --bg:#0d1117; --card:#161b22; --line:#30363d; --text:#e6edf3; --muted:#8b949e;
    \\  --request:#58a6ff; --response:#3fb950; --tool_call:#d29922; --tool_result:#39c5cf;
    \\  --failure:#f85149; --turn:#a371f7; --note:#8b949e; --query:#f778ba;
    \\}
    \\*{box-sizing:border-box}
    \\body{margin:0;background:var(--bg);color:var(--text);
    \\  font:14px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
    \\header{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:14px;
    \\  align-items:center;justify-content:space-between;padding:12px 20px;
    \\  background:rgba(13,17,23,.94);border-bottom:1px solid var(--line)}
    \\.brand{display:flex;align-items:baseline;gap:10px}
    \\.mark{font-weight:700;letter-spacing:.02em}
    \\.tagline{color:var(--muted);font-size:12px}
    \\.controls{display:flex;gap:8px;align-items:center}
    \\.controls input{background:#0b0f14;border:1px solid var(--line);border-radius:6px;
    \\  color:var(--text);padding:6px 9px;font-size:12px;min-width:200px}
    \\.controls button{background:#21262d;color:var(--text);border:1px solid var(--line);
    \\  border-radius:6px;padding:6px 10px;font-size:12px;cursor:pointer}
    \\.controls button:hover{border-color:#3d444d}
    \\main{padding-bottom:40px}
    \\.run{max-width:1100px;margin:16px 20px 0;padding:14px 16px;background:var(--card);
    \\  border:1px solid var(--line);border-radius:10px}
    \\.run dl{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));
    \\  gap:10px 18px;margin:0}
    \\.run dt{color:var(--muted);font-size:11px;letter-spacing:.06em;text-transform:uppercase}
    \\.run dd{margin:2px 0 0;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
    \\.filters{display:flex;flex-wrap:wrap;gap:8px;margin:14px 20px 4px;max-width:1100px}
    \\.chip{border:1px solid var(--line);background:#161b22;color:var(--muted);
    \\  border-radius:999px;padding:4px 10px;font-size:12px;cursor:pointer}
    \\.chip.on{color:var(--text);border-color:#3d444d;background:#21262d}
    \\.chip b{color:var(--text);font-weight:600}
    \\.flow{list-style:none;margin:0;padding:10px 20px 0;max-width:1100px}
    \\.node{position:relative;display:grid;grid-template-columns:28px 1fr;gap:10px;padding-bottom:14px}
    \\.node::before{content:"";position:absolute;left:13px;top:16px;bottom:-4px;width:2px;
    \\  background:var(--line)}
    \\.node:last-child::before{display:none}
    \\.node.hidden{display:none}
    \\.rail{display:flex;justify-content:center}
    \\.dot{width:12px;height:12px;margin-top:9px;border-radius:50%;background:var(--muted);
    \\  box-shadow:0 0 0 3px var(--bg)}
    \\.k-request .dot{background:var(--request)}
    \\.k-response .dot{background:var(--response)}
    \\.k-tool_call .dot{background:var(--tool_call)}
    \\.k-tool_result .dot{background:var(--tool_result)}
    \\.k-failure .dot{background:var(--failure)}
    \\.k-turn .dot{background:var(--turn)}
    \\.k-query .dot{background:var(--query)}
    \\.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 14px 12px}
    \\.k-failure .card{border-color:rgba(248,81,73,.5)}
    \\.k-tool_result .card{border-left:3px solid rgba(57,197,207,.55)}
    \\.k-tool_call .card{border-left:3px solid rgba(210,153,34,.55)}
    \\.head{display:flex;flex-wrap:wrap;gap:8px;align-items:baseline}
    \\.kind{font:600 10px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.09em;
    \\  padding:4px 6px;border-radius:5px;background:#21262d;color:var(--muted)}
    \\.k-request .kind{color:var(--request)}
    \\.k-response .kind{color:var(--response)}
    \\.k-tool_call .kind{color:var(--tool_call)}
    \\.k-tool_result .kind{color:var(--tool_result)}
    \\.k-failure .kind{color:var(--failure)}
    \\.k-turn .kind{color:var(--turn)}
    \\.k-query .kind{color:var(--query)}
    \\.title{font-weight:600}
    \\.meta{color:var(--muted);font-size:12px}
    \\.time{margin-left:auto;color:var(--muted);font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
    \\.preview{margin-top:6px;color:#c9d1d9;opacity:.85;word-break:break-word;
    \\  font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
    \\details{margin-top:8px}
    \\summary{cursor:pointer;color:var(--muted);font-size:12px;user-select:none}
    \\summary:hover{color:var(--text)}
    \\.block h4{margin:12px 0 5px;font-size:11px;letter-spacing:.05em;text-transform:uppercase;
    \\  color:var(--muted);font-weight:600}
    \\pre{margin:0;padding:10px;background:#0b0f14;border:1px solid var(--line);border-radius:8px;
    \\  overflow:auto;max-height:420px;font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace;
    \\  white-space:pre-wrap;word-break:break-word}
    \\.hint{margin:8px 0 0;color:var(--tool_call);font-size:12px}
    \\@media print{header,.filters,.controls{display:none}pre{max-height:none}}
    \\
;

const script =
    \\<script>
    \\(function(){
    \\  var nodes = Array.prototype.slice.call(document.querySelectorAll('.node'));
    \\  var chips = Array.prototype.slice.call(document.querySelectorAll('.chip'));
    \\  var query = document.getElementById('q');
    \\  var shown = {request:true,response:true,tool:true,failure:true,note:true,turn:true,query:true,run:true};
    \\  var only = false;
    \\  function group(kind){ return (kind === 'tool_call' || kind === 'tool_result') ? 'tool' : kind; }
    \\  function apply(){
    \\    var needle = (query.value || '').trim().toLowerCase();
    \\    nodes.forEach(function(node){
    \\      var visible = !only || shown[group(node.dataset.kind)];
    \\      if (visible && needle) visible = node.textContent.toLowerCase().indexOf(needle) !== -1;
    \\      node.classList.toggle('hidden', !visible);
    \\    });
    \\  }
    \\  chips.forEach(function(chip, index){
    \\    chip.addEventListener('click', function(){
    \\      if (index === 0) {
    \\        only = false;
    \\        chips.forEach(function(other){ other.classList.toggle('on', other === chip); });
    \\        Object.keys(shown).forEach(function(key){ shown[key] = true; });
    \\      } else {
    \\        only = true;
    \\        chips[0].classList.remove('on');
    \\        chip.classList.toggle('on');
    \\        shown[chip.dataset.filter] = chip.classList.contains('on');
    \\      }
    \\      apply();
    \\    });
    \\  });
    \\  if (query) query.addEventListener('input', apply);
    \\  Array.prototype.forEach.call(document.querySelectorAll('[data-expand]'), function(button){
    \\    button.addEventListener('click', function(){
    \\      var open = button.dataset.expand === '1';
    \\      Array.prototype.forEach.call(document.querySelectorAll('.node details'), function(details){
    \\        details.open = open;
    \\      });
    \\    });
    \\  });
    \\})();
    \\</script>
    \\
;

fn writeScript(w: *std.Io.Writer) !void {
    try w.writeAll(script);
}

/// Where the report for a trace lives: next to it, with the other suffix.
pub fn htmlPathFor(allocator: std.mem.Allocator, jsonl_path: []const u8) ![]u8 {
    const suffix = ".jsonl";
    const stem = if (std.mem.endsWith(u8, jsonl_path, suffix))
        jsonl_path[0 .. jsonl_path.len - suffix.len]
    else
        jsonl_path;
    return std.fmt.allocPrint(allocator, "{s}.html", .{stem});
}

/// Read a trace and write its report beside it.
pub fn writeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    jsonl_path: []const u8,
    html_path: []const u8,
) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, jsonl_path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(data);
    const html = try render(allocator, data);
    defer allocator.free(html);
    if (std.fs.path.dirname(html_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = try std.Io.Dir.cwd().createFile(io, html_path, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, html);
}

test "the report turns events into a flowchart that keeps their payloads" {
    const jsonl =
        \\{"event":"run","seq":0,"t":0,"session":"abc","model":"mock","workspace":"/w","base_url":"http://x/v1"}
        \\{"event":"query","seq":1,"t":1,"agent":"main","text":"say <hi>"}
        \\{"event":"request","seq":2,"t":2,"agent":"main","iter":1,"url":"http://x/v1/responses","model":"mock","est_tokens":12,"bytes":20,"body":"{\"model\":\"mock\",\"input\":[]}"}
        \\{"event":"response","seq":3,"t":30,"agent":"main","iter":1,"finish":"tool_calls","ms":28,"in_tokens":5,"out_tokens":2,"content":null,"tool_calls":[{"id":"c1","name":"bash","arguments":"{\"command\":\"echo hi\"}"}],"raw":"data: {\"type\":\"response.completed\"}"}
        \\{"event":"tool_call","seq":4,"t":31,"agent":"main","iter":1,"name":"bash","call_id":"c1","args":"{\"command\":\"echo hi\"}","args_bytes":20}
        \\{"event":"tool_result","seq":5,"t":40,"agent":"main","iter":1,"name":"bash","call_id":"c1","ms":9,"is_error":false,"exit_code":0,"content":"hi\n","bytes":3}
        \\{"event":"failure","seq":6,"t":41,"agent":"main","message":"ApiError","raw":"{\"error\":\"nope\"}"}
        \\{"event":"turn","seq":7,"t":42,"agent":"main","completed":true,"tool_calls":1,"ms":42}
    ;
    const html = try render(std.testing.allocator, jsonl);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.startsWith(u8, html, "<!doctype html>"));
    try std.testing.expect(std.mem.endsWith(u8, html, "</html>\n"));
    for ([_][]const u8{
        "k-request",
        "k-response",
        "k-tool_call",
        "k-tool_result",
        "k-failure",
        "k-turn",
        "id=\"e5\"",
        // A request body is shown indented, not as one line.
        "\"model\": \"mock\"",
        "finish=tool_calls",
        "ApiError",
        "Call bash",
        "bash result",
        "Turn finished",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, html, needle) != null) catch |err| {
            std.debug.print("missing {s} in report\n", .{needle});
            return err;
        };
    }
    // Model output is data, not markup.
    try std.testing.expect(std.mem.indexOf(u8, html, "say &lt;hi&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "say <hi>") == null);
}

test "a broken line or an unknown step does not lose the report" {
    const jsonl =
        "{\"event\":\"query\",\"seq\":0,\"text\":\"first\"}\n" ++
        "this is not json\n" ++
        "{\"event\":\"something_new\",\"seq\":1,\"detail\":\"kept\"}\n";
    const html = try render(std.testing.allocator, jsonl);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "something_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "kept") != null);
}

test "the report path sits next to its trace" {
    const allocator = std.testing.allocator;
    const html = try htmlPathFor(allocator, "/state/debug/abc-1.jsonl");
    defer allocator.free(html);
    try std.testing.expectEqualStrings("/state/debug/abc-1.html", html);
}
