const std = @import("std");
const Config = @import("config.zig").Config;
const Agent = @import("agent.zig").Agent;
const provider = @import("provider.zig");
const history = @import("history.zig");
const commands = @import("commands.zig");
const mcp = @import("mcp.zig");
const banner = @import("banner.zig");
const term = @import("term.zig");
const text = @import("text.zig");
const Screen = @import("screen.zig").Screen;
const Linenoise = @import("editor/main.zig").Linenoise;

const sgr = @import("style.zig");
const RESET = sgr.RESET;
const BOLD = sgr.BOLD;
const DIM = sgr.DIM;
const RED = sgr.RED;
const GREEN = sgr.GREEN;
const YELLOW = sgr.YELLOW;

const HELP =
    \\Commands:
    \\  /help        Show this help message
    \\  /clear       Clear conversation history
    \\  /new         Create a new session and empty the scratch directory
    \\  /session     Show the current session ID and resume command
    \\  /memory      List saved memories
    \\  /remember <text>  Save a note to memory
    \\  /forget <n|all>   Remove a saved note
    \\  /model       Show current model
    \\  /status      Show token usage and account quota
    \\  /mcp         List the MCP servers and their tools
    \\  /quit, /exit Exit zagent
    \\  /, @, $      Command / project file / reserved candidates
    \\  ↑/↓          Select candidate; Tab/Enter inserts; Esc closes
    \\  Wheel/PageUp/Down  Scroll output history
    \\  While running: commands remain available; typed text adjusts the task
    \\  Questions   The menu owns the keyboard; Esc or Ctrl+D dismisses it
    \\  Own answer  Esc in the free-text row goes back to the options
    \\  Esc          Stop current task and discard input typed while it ran
    \\  Ctrl+Z       Suspend; resume with fg
    \\  Ctrl+D       Exit zagent
    \\
;

// Prompt passed to linenoise. Colour codes are fine here because
// the editor's width() implementation correctly ignores ANSI SGR sequences.
// The arrow is the whole prompt: the word it used to carry said nothing that
// the colour and the position do not.
const PROMPT = BOLD ++ GREEN ++ "\xe2\x9d\xaf" ++ RESET ++ " ";

/// Process arguments are borrowed from the OS (or from an iterator's internal
/// buffer), so copy the ones we keep around for the lifetime of `main`.
fn collectArgs(allocator: std.mem.Allocator, args: std.process.Args) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }

    var iter = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iter.deinit();
    while (iter.next()) |arg| {
        try list.append(allocator, try allocator.dupe(u8, arg));
    }
    return list;
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
}

/// Recall the prompts typed in earlier runs and hand back the file to save
/// them to, or null when they cannot be kept: no home directory to put them
/// in, or no terminal whose history would be worth keeping. Lines read from a
/// pipe are not the user's own history, so a non-interactive stdin is left
/// alone.
fn openHistory(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    ln: *Linenoise,
) !?[]u8 {
    if (!ln.is_tty) return null;

    const path = (try history.statePath(allocator, env)) orelse return null;
    errdefer allocator.free(path);

    if (!history.load(io, ln, path)) {
        allocator.free(path);
        return null;
    }
    return path;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var args = try collectArgs(allocator, init.minimal.args);
    defer {
        freeArgs(allocator, args.items);
        args.deinit(allocator);
    }

    if (args.items.len == 4 and std.mem.eql(u8, args.items[1], "--tool-worker")) {
        const result = @import("tool_worker.zig").execute(io, allocator, env, args.items[2], args.items[3]) catch |err| tools_error: {
            break :tools_error @import("tools.zig").ToolResult{
                .content = try std.fmt.allocPrint(allocator, "Tool failed: {s}", .{@errorName(err)}),
                .is_error = true,
                .timed_out = err == error.Timeout,
            };
        };
        defer result.deinit(allocator);
        const encoded = try std.json.Stringify.valueAlloc(allocator, result, .{});
        defer allocator.free(encoded);
        try std.Io.File.stdout().writeStreamingAll(io, encoded);
        return;
    }

    if (args.items.len == 2 and (std.mem.eql(u8, args.items[1], "--help") or std.mem.eql(u8, args.items[1], "-h"))) {
        try std.Io.File.stdout().writeStreamingAll(io, "Usage: zagent [query ...]\n" ++
            "With no query, start an interactive conversation.\n\n" ++
            "  --help, -h          Show this help\n" ++
            "  --version           Show version\n" ++
            "  --resume <id>       Resume a saved session in this workspace\n" ++
            "  login / logout      Sign in with ChatGPT / remove local credentials\n" ++
            "  models              List models for the selected provider\n\n" ++
            "AI_PROVIDER=deepseek  Use DEEPSEEK_API_KEY\n" ++
            "AI_URL / AI_MODEL / AI_KEY override provider settings.\n" ++
            "AI_MEMORY_FILE        Store memory in another file\n" ++
            "Tools and local MCP servers run on the host with inherited environment and network access.\n" ++
            "Build with Zig 0.17.0.\n");
        return;
    }
    if (args.items.len == 2 and std.mem.eql(u8, args.items[1], "--version")) {
        try std.Io.File.stdout().writeStreamingAll(io, "zagent 0.1.0 (Zig 0.17)\n");
        return;
    }

    if (args.items.len == 2 and (std.mem.eql(u8, args.items[1], "login") or std.mem.eql(u8, args.items[1], "logout"))) {
        const auth = @import("codex_auth.zig");
        const auth_path = try auth.path(allocator, env);
        defer allocator.free(auth_path);
        if (std.mem.eql(u8, args.items[1], "login")) {
            try auth.login(allocator, io, auth_path);
        } else {
            try auth.logout(io, auth_path);
        }
        return;
    }

    // Trust must precede state loading, API requests and local MCP startup.
    // Administrative commands do not operate in the current workspace.
    if (!(args.items.len == 2 and std.mem.eql(u8, args.items[1], "models"))) {
        const workspace = @import("workspace.zig");
        if (!try workspace.isTrusted(allocator, io, env)) {
            const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
            defer allocator.free(canonical);
            const stderr = std.Io.File.stderr();
            if (!(std.Io.File.stdin().isTty(io) catch false) or !(stderr.isTty(io) catch false)) {
                try stderr.writeStreamingAll(io, "Not trusted. Run interactively to approve this directory first.\n");
                std.process.exit(1);
            }
            try printToStderr(allocator, io, "\nTrust this directory?\n  {s}\nTrusted directories allow tool execution and local MCP servers.\n", .{canonical});
            const menu = @import("menu.zig");
            const options = [_]menu.Option{
                .{ .label = "Don't trust and exit", .description = "", .recommended = false },
                .{ .label = "Trust and continue", .description = "", .recommended = false },
            };
            const answer = try menu.selectOnly(allocator, io, "Choose an action", &options);
            const trusted = switch (answer) {
                .option => |index| index == 1,
                .custom, .cancel => false,
            };
            if (!trusted) {
                try std.Io.File.stderr().writeStreamingAll(io, "Not trusted. Exiting.\n");
                std.process.exit(1);
            }
            try workspace.trust(allocator, io, env);
        }
    }

    const config = Config.load(allocator, io, env) catch |err| switch (err) {
        error.UnknownProvider => {
            const valid = try std.mem.join(allocator, ", ", provider.Provider.names());
            defer allocator.free(valid);
            const msg = try std.fmt.allocPrint(
                allocator,
                RED ++ "Error: unknown AI_PROVIDER." ++ RESET ++
                    "\n  Valid values: {s}\n" ++
                    "  To use another endpoint, unset AI_PROVIDER and set AI_URL and AI_MODEL instead.\n",
                .{valid},
            );
            defer allocator.free(msg);
            std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            // Exiting directly rather than returning keeps Zig from printing a
            // stack trace underneath an error that is already fully explained.
            std.process.exit(1);
        },
        else => return err,
    };
    defer config.deinit();

    if (args.items.len == 2 and std.mem.eql(u8, args.items[1], "models")) {
        var client = @import("openai.zig").Client.init(allocator, io, config);
        defer client.deinit();
        const models = try client.listModels();
        defer allocator.free(models);
        try std.Io.File.stdout().writeStreamingAll(io, models);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    }

    var query_start: usize = 1;
    var resume_id: ?[]const u8 = null;
    if (args.items.len > 1 and std.mem.eql(u8, args.items[1], "--resume")) {
        if (args.items.len < 3) {
            try std.Io.File.stderr().writeStreamingAll(io, "Usage: zagent --resume <session-id> [query ...]\n");
            std.process.exit(1);
        }
        resume_id = args.items[2];
        query_start = 3;
    }

    // The terminal is created here rather than inside the REPL so that the
    // ask_user menu also works in single-query mode.
    var ln = Linenoise.init(allocator, io, env);
    defer ln.deinit();
    // Show command, file, and reserved-extension candidates as the user types.
    ln.completions_callback = commands.complete;
    ln.popup_callback = @import("completion.zig").candidates;

    const history_path = try openHistory(allocator, io, env, &ln);
    defer if (history_path) |path| allocator.free(path);

    // The MCP servers are started before the first question, because the tools
    // they bring are part of what the question is asked with.
    var problems: std.ArrayList([]u8) = .empty;
    defer {
        for (problems.items) |problem| allocator.free(problem);
        problems.deinit(allocator);
    }
    const stderr = std.Io.File.stderr();
    // What came of the servers is collected rather than printed: the
    // interactive session takes the terminal over and starts on a blank
    // screen, so a line written now would be erased before it could be read.
    // It is drawn under the wordmark instead. Only the per-server "starting"
    // progress stays live, because that is what the wait looks like.
    var report: std.Io.Writer.Allocating = .init(allocator);
    defer report.deinit();
    var watcher = McpProgress{ .io = io, .allocator = allocator };
    var registry = mcp.Registry.connect(allocator, io, env, &problems, .{
        .context = &watcher,
        .started = McpProgress.started,
    }) catch |err| failed: {
        try report.writer.print(YELLOW ++ "  ⚠ mcp: no servers were read: {s}\n" ++ RESET, .{@errorName(err)});
        break :failed mcp.Registry.empty(allocator, io);
    };
    // Declared before the agent, because the agent borrows it and the defers
    // run in reverse: the agent has to be gone before this one is freed.
    defer registry.deinit();
    for (problems.items) |problem| {
        try report.writer.print(YELLOW ++ "  ⚠ {s}\n" ++ RESET, .{problem});
    }
    try registry.writeStartup(&report.writer);

    var agent = try Agent.init(allocator, io, config, &ln, env, &registry);
    defer agent.deinit();

    agent.startSession(resume_id) catch |err| {
        try printToStderr(allocator, io, "Cannot open session: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    if (args.items.len > query_start) {
        // No wordmark and no screen in this mode, so the report goes out here,
        // to stderr: stdout belongs to the answer, and `zagent "..." > notes.md`
        // stays clean.
        if (report.written().len > 0) {
            try stderr.writeStreamingAll(io, report.written());
            try stderr.writeStreamingAll(io, "\n");
        }
        if (agent.session_id) |id| {
            try printToStderr(allocator, io, "Session: {s} (resume: zagent --resume {s})\n", .{ id, id });
        }
        // Single-query mode: join remaining args as the query
        const query = try std.mem.join(allocator, " ", args.items[query_start..]);
        defer allocator.free(query);
        try agent.processQuery(query);
    } else {
        // Interactive REPL mode
        try runRepl(allocator, io, env, &agent, config, &ln, history_path, &registry, report.written());
        if (agent.session_id) |id| {
            try printToStderr(allocator, io, "Resume session: zagent --resume {s}\n", .{id});
        }
    }
}

fn runRepl(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    agent: *Agent,
    config: Config,
    ln: *Linenoise,
    history_path: ?[]const u8,
    registry: *const mcp.Registry,
    mcp_report: []const u8,
) !void {
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    // The interactive session owns the whole terminal: the conversation fills
    // it and the prompt sits at the bottom. A piped or `TERM=dumb` run keeps
    // the old inline layout, where the output is what the consumer reads.
    var screen = Screen.init(allocator, io, ln.is_tty and ln.term_supported and
        (stdout.isTty(io) catch false));
    if (env.get("TMUX")) |value| {
        if (value.len > 0) screen.tmux_env = env;
    }
    agent.attachScreen(if (screen.isActive()) &screen else null);
    defer agent.attachScreen(null);
    try screen.enter();
    defer screen.deinit();
    var runtime = @import("runtime.zig").Runtime{ .agent = agent, .screen = &screen };
    if (screen.isActive()) {
        screen.buffered = true;
        agent.form_context = &runtime;
        agent.form_callback = @import("runtime.zig").Runtime.presentForm;
        ln.tick_callback = tickRuntime;
        ln.scroll_callback = scrollRuntime;
        ln.mouse_callback = mouseRuntime;
        ln.interrupt_callback = interruptRuntime;
        ln.handoff_callback = questionRuntime;
    }

    ln.multiline_mode = true;
    ln.bottom_anchor = screen.isActive();
    ln.layout_callback = layoutScreen;
    ln.layout_context = &runtime;
    // The editor must not keep pointing at a screen that is about to go away.
    defer {
        runtime.deinit();
        ln.bottom_anchor = false;
        ln.layout_callback = null;
        ln.layout_context = null;
        ln.tick_callback = null;
        ln.scroll_callback = null;
        ln.mouse_callback = null;
        ln.interrupt_callback = null;
        ln.handoff_callback = null;
        agent.form_callback = null;
        agent.form_context = null;
    }
    // Fullscreen keeps its own blank prompt row at the bottom, so the
    // animation must not draw a second prompt above it.
    agent.progress_prompt = if (ln.is_tty and !screen.isActive()) PROMPT else null;

    {
        // The wordmark is drawn through an allocating writer because a
        // truecolour one costs a few kilobytes of escape sequences. Colour is
        // for a terminal only: piped to a file it would be noise.
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try banner.write(&aw.writer, .{
            .mode = banner.detect(env, ln.term_supported and (stdout.isTty(io) catch false)),
            .columns = if (screen.isActive()) screen.cols else term.columns(stdout),
        });
        // The startup report belongs to the header, and the terminal was taken
        // over after the servers were started: this is where it can be read.
        if (mcp_report.len > 0) try aw.writer.writeAll(mcp_report);
        try aw.writer.writeByte('\n');
        try writeOut(&screen, stdout, io, aw.written());
    }
    {
        // The label is dim and the model name is not, so the eye lands on the
        // value rather than on the word "Model".
        const model_line = if (config.provider) |selected|
            try std.fmt.allocPrint(allocator, DIM ++ "  Model  " ++ RESET ++ "{s}" ++ DIM ++ " · {s}\n" ++ RESET, .{ config.model, @tagName(selected) })
        else
            try std.fmt.allocPrint(allocator, DIM ++ "  Model  " ++ RESET ++ "{s}\n", .{config.model});
        defer allocator.free(model_line);
        try writeOut(&screen, stdout, io, model_line);
    }
    if (agent.session_id) |id| {
        const message = try std.fmt.allocPrint(allocator, "  Session  {s}\n  Resume   zagent --resume {s}\n", .{ id, id });
        defer allocator.free(message);
        try writeOut(&screen, stdout, io, message);
    }
    try writeOut(&screen, stdout, io, DIM ++ "  Enter to send, Alt+Enter or Ctrl+J for newline, Ctrl+Z to suspend, Ctrl+D to exit. /help for commands.\n\n" ++ RESET);

    if (config.api_key.len == 0 and config.provider != .codex) {
        // Name the variable that actually applies, so a provider user is not
        // told to export a key for some other service.
        const key_var = if (config.provider) |selected| selected.spec().api_key_env else "OPENAI_API_KEY";
        const msg = try std.fmt.allocPrint(
            allocator,
            YELLOW ++ "Warning: {s} is not set.\n  export {s}=your-key\n\n" ++ RESET,
            .{ key_var, key_var },
        );
        defer allocator.free(msg);
        try writeOut(&screen, stderr, io, msg);
    }

    // The API history was loaded before the terminal existed. Seed the screen's
    // conversation log now so scrolling and redraws retain the restored turns.
    try agent.replayHistory();

    while (true) {
        // linenoise handles raw-mode input, Unicode width, and multi-byte
        // character deletion correctly (including Chinese/CJK characters).
        // Returns null on EOF (Ctrl+D); error.CtrlC on Ctrl+C, error.Suspend on
        // Ctrl+Z. The rows the prompt needs are reserved before every read: the
        // conversation is drawn above them, never under them.
        try screen.prepareInput();
        const maybe_line = ln.linenoise(PROMPT) catch |err| switch (err) {
            error.CtrlC => null,
            error.Handoff => {
                // A question is waiting. The editor has parked the line it was
                // editing, so the menu can have the keyboard and the prompt
                // rows: the question is asked where the input box was.
                try screen.endInput();
                try runtime.serveQuestions();
                continue;
            },
            error.Suspend => {
                // Hand the terminal back, stop, and come back to the same
                // line: the editor hands the typed text over in
                // `pending_input`, so the retry opens on it.
                try screen.suspendProcess();
                continue;
            },
            else => return err,
        };
        try screen.endInput();
        const raw_line = maybe_line orelse {
            try writeOut(&screen, stdout, io, "\n");
            break;
        };
        defer allocator.free(raw_line);

        const line = std.mem.trim(u8, raw_line, " \t\r\n");

        if (line.len == 0) continue;

        // The editor's rows are cleared once the line is read; the question
        // still belongs in the record, with the prompt it was typed after. An
        // inline run keeps the prompt line on screen already.
        if (screen.isActive()) {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try aw.writer.writeAll(PROMPT);
            try text.writeSanitized(&aw.writer, line);
            try aw.writer.writeByte('\n');
            try screen.writeLog(aw.written());
        }

        // Add non-empty lines to history so the user can navigate with ↑/↓.
        // The file, when there is one, makes that outlive the process; it is
        // written before the query runs, so an interrupt part-way through an
        // answer cannot lose the question that asked for it.
        try ln.history.add(line);
        if (history_path) |path| history.save(io, ln, path);

        if (runtime.busy() and line[0] == '/' and
            !std.mem.eql(u8, line, "/status") and !std.mem.eql(u8, line, "/help") and
            !std.mem.eql(u8, line, "/model") and !std.mem.eql(u8, line, "/mcp") and !std.mem.eql(u8, line, "/session") and
            !std.mem.eql(u8, line, "/quit") and !std.mem.eql(u8, line, "/exit"))
        {
            try screen.writeLog("This command changes session state; retry after the current task finishes.\n");
            continue;
        }

        if (std.mem.eql(u8, line, "/quit") or std.mem.eql(u8, line, "/exit")) {
            try writeOut(&screen, stdout, io, DIM ++ "Goodbye!\n" ++ RESET);
            break;
        } else if (std.mem.eql(u8, line, "/help")) {
            try writeOut(&screen, stdout, io, HELP);
        } else if (std.mem.eql(u8, line, "/session")) {
            const message = try std.fmt.allocPrint(allocator, "Session: {s}\nResume: zagent --resume {s}\n", .{ agent.session_id.?, agent.session_id.? });
            defer allocator.free(message);
            try writeOut(&screen, stdout, io, message);
        } else if (std.mem.eql(u8, line, "/new")) {
            agent.startSession(null) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "Cannot create session: {s}\n", .{@errorName(err)});
                defer allocator.free(message);
                try writeOut(&screen, stderr, io, message);
                continue;
            };
            // The scratch directory belongs to the conversation being left
            // behind, not to the new one, so a new session starts from an empty
            // directory. The path itself stays: the system prompt names it.
            agent.scratch.reset() catch |err| {
                const message = try std.fmt.allocPrint(allocator, "Cannot clear scratch directory: {s}\n", .{@errorName(err)});
                defer allocator.free(message);
                try writeOut(&screen, stderr, io, message);
            };
            const message = try std.fmt.allocPrint(allocator, "New session: {s}\nResume: zagent --resume {s}\n", .{ agent.session_id.?, agent.session_id.? });
            defer allocator.free(message);
            try writeOut(&screen, stdout, io, message);
        } else if (std.mem.eql(u8, line, "/clear")) {
            agent.clearHistory();
            try writeOut(&screen, stdout, io, DIM ++ "Conversation history cleared.\n" ++ RESET);
        } else if (std.mem.eql(u8, line, "/memory")) {
            agent.listMemory() catch |err| try reportCommandError(allocator, &screen, io, "memory", err);
        } else if (std.mem.eql(u8, line, "/remember") or std.mem.startsWith(u8, line, "/remember ")) {
            const note = std.mem.trim(u8, line["/remember".len..], " \t");
            agent.rememberCommand(note) catch |err| try reportCommandError(allocator, &screen, io, "remember", err);
        } else if (std.mem.eql(u8, line, "/forget") or std.mem.startsWith(u8, line, "/forget ")) {
            const argument = std.mem.trim(u8, line["/forget".len..], " \t");
            agent.forgetCommand(argument) catch |err| try reportCommandError(allocator, &screen, io, "forget", err);
        } else if (std.mem.eql(u8, line, "/status")) {
            const counts = agent.client.tokenCounts();
            const msg = try std.fmt.allocPrint(allocator, "Model: {s}\nWorkspace: {s}\nScratch: {s}\nLast turn tokens (server usage or estimate): input {d}, output {d}\n", .{ config.model, agent.workspace, agent.scratch.path, counts.input, counts.output });
            defer allocator.free(msg);
            try writeOut(&screen, stdout, io, msg);
            var status_client = @import("openai.zig").Client.init(allocator, io, config);
            defer status_client.deinit();
            const quota = status_client.quotaStatus() catch |err| {
                try reportCommandError(allocator, &screen, io, "status: quota unavailable", err);
                continue;
            };
            defer allocator.free(quota);
            try writeOut(&screen, stdout, io, quota);
        } else if (std.mem.eql(u8, line, "/model")) {
            const msg = try std.fmt.allocPrint(allocator, "Model: {s}\n", .{config.model});
            defer allocator.free(msg);
            try writeOut(&screen, stdout, io, msg);
        } else if (std.mem.eql(u8, line, "/mcp")) {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try registry.writeStatus(&aw.writer);
            try writeOut(&screen, stdout, io, aw.written());
        } else if (screen.isActive()) {
            try runtime.submit(line);
        } else {
            agent.processQuery(line) catch |err| {
                const errmsg = try std.fmt.allocPrint(allocator, RED ++ "Error: {s}" ++ RESET ++ "\n", .{@errorName(err)});
                defer allocator.free(errmsg);
                try writeOut(&screen, stderr, io, errmsg);
            };
        }

        try writeOut(&screen, stdout, io, "\n");
    }
}

/// Send finished bytes to the conversation, or straight to `file` when the
/// session does not own the screen.
fn writeOut(screen: *Screen, file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    if (screen.isActive()) return screen.writeLog(bytes);
    try file.writeStreamingAll(io, bytes);
}

/// Report a slash-command failure without taking the REPL down with it.
fn reportCommandError(
    allocator: std.mem.Allocator,
    screen: *Screen,
    io: std.Io,
    command: []const u8,
    err: anyerror,
) !void {
    const message = try std.fmt.allocPrint(allocator, RED ++ "Error: {s}: {s}" ++ RESET ++ "\n", .{ command, @errorName(err) });
    defer allocator.free(message);
    try writeOut(screen, std.Io.File.stderr(), io, message);
}

/// The editor reports how many rows it needs at the bottom. Reserving them is
/// what repaints the conversation when the prompt grows.
fn layoutScreen(context: ?*anyopaque, rows: usize, repaint: bool) anyerror!void {
    const runtime: *@import("runtime.zig").Runtime = @ptrCast(@alignCast(context));
    runtime.screen.editor_frame = true;
    defer runtime.screen.editor_frame = false;
    try runtime.screen.reserveInput(rows, repaint);
}

fn tickRuntime(context: ?*anyopaque) anyerror!bool {
    const runtime: *@import("runtime.zig").Runtime = @ptrCast(@alignCast(context));
    return runtime.tick();
}

fn interruptRuntime(context: ?*anyopaque) anyerror!void {
    const runtime: *@import("runtime.zig").Runtime = @ptrCast(@alignCast(context));
    try runtime.interrupt();
}

fn questionRuntime(context: ?*anyopaque) anyerror!bool {
    return @import("runtime.zig").Runtime.questionPending(context);
}

fn mouseRuntime(context: ?*anyopaque, report: []const u8) anyerror!void {
    const rt: *@import("runtime.zig").Runtime = @ptrCast(@alignCast(context orelse return));
    try rt.screen.mouse(report);
}

fn scrollRuntime(context: ?*anyopaque, up: bool, page: bool) anyerror!void {
    const runtime: *@import("runtime.zig").Runtime = @ptrCast(@alignCast(context));
    try runtime.screen.scroll(up, page);
}

/// Says what is being waited for before each server is started. Written to
/// stderr, where the rest of the progress already goes.
const McpProgress = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    fn started(context: *anyopaque, name: []const u8) void {
        const self: *McpProgress = @ptrCast(@alignCast(context));
        const line = std.fmt.allocPrint(
            self.allocator,
            DIM ++ "  ⚙ mcp: starting \"{s}\"…\n" ++ RESET,
            .{name},
        ) catch return;
        defer self.allocator.free(line);
        std.Io.File.stderr().writeStreamingAll(self.io, line) catch {};
    }
};

fn printToStderr(
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try std.Io.File.stderr().writeStreamingAll(io, message);
}

// The other modules are only reachable from `main`, which a test build never
// analyzes, so their tests would otherwise be dropped from `zig build test`.
test {
    _ = @import("editor/main.zig");
    _ = @import("unicode_width/main.zig");
    _ = @import("agent.zig");
    _ = @import("status.zig");
    _ = @import("execution.zig");
    _ = @import("session.zig");
    _ = @import("tool_worker.zig");
    _ = @import("history.zig");
    _ = @import("tools.zig");
    _ = @import("diff.zig");
    _ = @import("openai.zig");
    _ = @import("config.zig");
    _ = @import("provider.zig");
    _ = @import("menu.zig");
    _ = @import("completion.zig");
    _ = @import("commands.zig");
    _ = @import("compact.zig");
    _ = @import("memory.zig");
    _ = @import("style.zig");
    _ = @import("term.zig");
    _ = @import("screen.zig");
    _ = @import("banner.zig");
    _ = @import("text.zig");
    _ = @import("render.zig");
    _ = @import("spinner.zig");
    _ = @import("mcp.zig");
    _ = @import("mcp_transport.zig");
}

test "config loads" {
    const allocator = std.testing.allocator;
    // An empty map has no HOME, so no config file is read and the developer's
    // own environment cannot leak into the test.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const config = try Config.load(allocator, std.testing.io, &env);
    defer config.deinit();
    try std.testing.expect(config.max_tokens > 0);
}
