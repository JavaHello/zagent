const std = @import("std");
const openai = @import("openai.zig");
const tools = @import("tools.zig");
const diff = @import("diff.zig");
const text = @import("text.zig");
const menu = @import("menu.zig");
const verifier = @import("verifier.zig");
const compact = @import("compact.zig");
const memory_mod = @import("memory.zig");
const mcp = @import("mcp.zig");
const render = @import("render.zig");
const term = @import("term.zig");
const spinner = @import("spinner.zig");
const Screen = @import("screen.zig").Screen;
const ScreenLogWriter = @import("screen.zig").LogWriter;
const Config = @import("config.zig").Config;
const Linenoise = @import("editor/main.zig").Linenoise;

const Message = openai.Message;
const ToolCallData = openai.ToolCallData;

// ANSI colour codes
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const CYAN = "\x1b[36m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";

/// Longest transcript the completion judge is shown.
const summary_max_bytes = 8000;

/// How many times one reply may be continued after the output limit cut it
/// short. Each continuation buys another full budget of text, so a handful is
/// enough for any answer a person will read; the cap stops a model that never
/// reaches a stopping point from spending the iteration budget on one turn.
const max_continuations: usize = 8;

/// How often a reply that produced no text at all is re-asked with a request to
/// work in smaller steps. Repeating the same oversized request is rarely
/// useful, so this is deliberately smaller than `max_continuations`.
const max_empty_continuations: usize = 2;

/// What to tell the model when the token limit cut its reply short. With part
/// of the text in hand the job is to carry on from it; without any, the only
/// way forward is a smaller step.
const continue_prompt =
    "Your previous reply was cut off by the model's output token limit. Continue exactly where it stopped, without repeating anything you already wrote, and keep the rest concise.";

const restart_prompt =
    "Your previous attempt was cut off by the model's output token limit before it delivered a usable reply. Try again in smaller steps: split large files into chunks and keep the response concise.";

// Prompt for the choice menu. Colour codes are fine here because linenoize's
// width() implementation correctly ignores ANSI SGR sequences.
const CHOICE_PROMPT = BOLD ++ YELLOW ++ "choice" ++ RESET ++ " \xe2\x9d\xaf ";

const SYSTEM_PROMPT =
    \\You are zagent, a powerful command-line AI assistant built with Zig.
    \\You can help users with any task by using the provided tools.
    \\
    \\Ordinary tools run directly in the current working directory with the host environment and network access. Commands detected as dangerous (privilege escalation, system or network configuration changes, system-path writes) run in a sandbox with no host fallback. AI_TOOL_NETWORK=1 enables network access only for sandboxed tools and local MCP servers. Detection is heuristic, not a security boundary; do not assume arbitrary scripts are isolated.
    \\Guidelines:
    \\- Be concise and direct in your responses.
    \\- Before executing a new user task, briefly explain the goal and practical approach if no initial plan has already been provided. Do not repeat a plan already present in the conversation.
    \\- Use the shell tool to run commands, install packages, or perform system operations.
    \\- Use http_request for URLs and APIs instead of shelling out to curl, and its save_to argument when downloading a file.
    \\- Use read_file to read a file. Use edit_file for an exact unique text replacement, or apply_patch for a unified diff with enough context to place it. Do not write a whole file back through write_file to change part of it, and do not edit files through the shell.
    \\- Use write_file only for a file that does not exist yet, or when the entire contents are being replaced. A file that does not exist can also be created with apply_patch and a '--- /dev/null' header.
    \\- Use list_dir to explore directories.
    \\- Use grep to search file contents, and find to locate files by name, instead of shelling out: they use ripgrep and fd where those are installed.
    \\- Chain multiple tool calls to accomplish complex tasks step by step.
    \\- Always explain what you are doing when using tools.
    \\- If an operation fails, analyze the error and try a different approach, but stop after 3-5 failed attempts and explain what went wrong.
    \\- If a task seems impossible with available tools (e.g. requires a web browser, authentication, or blocked services), report this to the user instead of retrying endlessly.
    \\- Do not repeat the same tool call with the same parameters.
    \\- When you learn something durable — a user preference, a project fact, a decision, or a constraint — call remember with a short, self-contained note. Do not save transient details, secrets, or anything the user asked you to forget.
    \\- When the conversation grows long, earlier messages may be replaced by a summary. Treat that summary as part of the conversation, and keep your own replies concise so it stays useful.
    \\- When the request is ambiguous, or when a decision only the user can make is blocking you, call ask_user with two to four concrete options and mark the one you recommend. Ask only when the answer changes what you do next; decide routine details yourself.
    \\- After every turn that used tools, an automatic completion check reviews your work. If it reports unfinished work, act on it instead of restating your answer.
;

/// The system prompt as the model is given it: the constant above, plus what
/// the MCP servers contribute — a sentence naming their tools, when there are
/// any, and whatever each server says about using it.
fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    registry: *const mcp.Registry,
    memory_section: ?[]const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    try aw.writer.writeAll(SYSTEM_PROMPT);
    if (registry.functionJson().len > 0) {
        try aw.writer.writeAll(
            "\n- Tools whose name starts with mcp__ come from an MCP server that is connected;" ++
                " call one exactly as you would any other tool.\n",
        );

        if (try registry.instructions(allocator)) |notes| {
            defer allocator.free(notes);
            try aw.writer.writeAll(notes);
            try aw.writer.writeByte('\n');
        }
    }
    if (memory_section) |section| {
        try aw.writer.writeByte('\n');
        try aw.writer.writeAll(section);
        try aw.writer.writeByte('\n');
    }

    return aw.toOwnedSlice();
}

pub const Agent = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: openai.Client,
    history: std.ArrayList(Message),
    max_iterations: u32,
    /// How many completion checks one user query may cost.
    max_verifications: u32,
    /// The terminal ask_user and the choice menus read from.
    linenoise: *Linenoise,
    /// Which search programs the machine has. Decided once, in `init`, for the
    /// same reason as `render_markdown`: a search should not have to ask the
    /// filesystem a question whose answer cannot change while the agent runs.
    search: tools.SearchBackends,
    tool_network: bool,
    tool_env: *const std.process.Environ.Map,
    session_path: ?[]u8,
    /// Durable notes loaded at startup and updated by the remember tool.
    memory: memory_mod.Memory,
    /// Estimated token budget; 0 disables automatic compaction.
    compact_threshold: u32,
    /// Newest messages kept verbatim across a compaction.
    compact_keep: u32,
    /// Ask the model after each turn whether anything should be remembered.
    memory_auto: bool,
    /// Whether to render the model's markdown for a terminal. Decided once, in
    /// `init`, so the answer path never has to ask the operating system.
    render_markdown: bool,
    /// Whether the progress line for a wait may be animated. Decided once, in
    /// `init`, next to `render_markdown` and by the same test — a terminal that
    /// cannot do line editing is no place for a carriage return and an erase,
    /// and neither is one where stdout is a file or a pager: the animation
    /// takes a line of the terminal, and it must be the only writer to it.
    animate_progress: bool,
    terminal_title: term.Title,
    current_task: []const u8 = "",
    query_started: ?std.Io.Timestamp = null,
    progress_prompt: ?[]const u8 = null,
    /// Where the conversation is drawn when the interactive session owns the
    /// screen. Null for a single query: answers then go straight to stdout, so
    /// `zagent "q" > notes.md` stays clean.
    screen: ?*Screen = null,
    /// The MCP servers and the tools they brought. Borrowed rather than owned:
    /// whoever started the agent outlives it, and the agent only reads this and
    /// calls through it.
    mcp_registry: *mcp.Registry,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        linenoise: *Linenoise,
        env: *const std.process.Environ.Map,
        mcp_registry: *mcp.Registry,
    ) !Agent {
        var history: std.ArrayList(Message) = .empty;
        errdefer history.deinit(allocator);

        var memory = if (config.memory)
            try memory_mod.Memory.init(allocator, io, env)
        else
            try memory_mod.Memory.initWithPath(allocator, io, null);
        errdefer memory.deinit();
        const memory_section = try memory.promptSection(allocator, memory_mod.prompt_budget);
        defer if (memory_section) |section| allocator.free(section);

        const system_content = try buildSystemPrompt(allocator, mcp_registry, memory_section);
        errdefer allocator.free(system_content);
        try history.append(allocator, .{
            .role = "system",
            .content = system_content,
            .reasoning_content = null,
            .tool_calls = null,
            .tool_call_id = null,
        });

        const session_path = if (env.get("AI_SESSION_FILE")) |path| if (path.len > 0) try allocator.dupe(u8, path) else null else null;
        errdefer if (session_path) |path| allocator.free(path);
        if (session_path) |path| {
            var loaded = try @import("session.zig").load(io, allocator, path);
            defer loaded.deinit(allocator);
            errdefer for (loaded.items) |message| message.deinit(allocator);
            try history.appendSlice(allocator, loaded.items);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .client = openai.Client.init(allocator, io, config),
            .history = history,
            .max_iterations = config.max_iterations,
            .max_verifications = config.max_verifications,
            .linenoise = linenoise,
            .search = tools.detectSearchBackends(io, env),
            .tool_env = env,
            .session_path = session_path,
            .memory = memory,
            .compact_threshold = config.compact_threshold,
            .compact_keep = config.compact_keep,
            .memory_auto = config.memory and config.memory_auto,
            .tool_network = if (env.get("AI_TOOL_NETWORK")) |v| std.mem.eql(u8, v, "1") else false,
            // The check is on stdout rather than on `linenoise.is_tty`, which
            // describes stdin: `zagent "q" < file` with a terminal on stdout
            // should still render, and `zagent "q" | less` must not.
            .render_markdown = config.markdown and
                linenoise.term_supported and
                (std.Io.File.stdout().isTty(io) catch false),
            // stderr as well as stdout, unlike the renderer: the animation is
            // written to stderr, and a run whose stdout is a file or a pager is
            // one where the terminal belongs to something else.
            .animate_progress = linenoise.term_supported and
                (std.Io.File.stdout().isTty(io) catch false) and
                (std.Io.File.stderr().isTty(io) catch false),
            .mcp_registry = mcp_registry,
            .terminal_title = term.Title.init(io, linenoise.term_supported),
        };
    }

    pub fn deinit(self: *Agent) void {
        self.terminal_title.deinit();
        for (self.history.items) |msg| msg.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.client.deinit();
        self.memory.deinit();
        if (self.session_path) |path| self.allocator.free(path);
    }

    /// Draw the conversation on `screen` instead of on the files the progress
    /// lines normally use.
    pub fn attachScreen(self: *Agent, screen: ?*Screen) void {
        self.screen = screen;
    }

    /// One status or answer line: into the conversation when a screen owns it,
    /// and to `file` otherwise. The file still matters for a redirected run,
    /// where stdout belongs to another program and stderr carries progress.
    fn emit(self: *Agent, file: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
        if (self.screen) |screen| {
            if (screen.isActive()) {
                const message = try std.fmt.allocPrint(self.allocator, fmt, args);
                defer self.allocator.free(message);
                return screen.writeLog(message);
            }
        }
        try printFmt(file, self.io, self.allocator, fmt, args);
    }

    /// Clear conversation history (keeps the system prompt).
    pub fn clearHistory(self: *Agent) void {
        for (self.history.items[1..]) |msg| msg.deinit(self.allocator);
        self.history.shrinkRetainingCapacity(1);
        self.checkpoint() catch {};
    }

    fn checkpoint(self: *Agent) !void {
        if (self.session_path) |path| try @import("session.zig").save(self.io, self.allocator, path, self.history.items[1..]);
    }

    /// Rebuild the system prompt so notes saved during this session are part
    /// of every later request.
    fn refreshSystemPrompt(self: *Agent) !void {
        const section = try self.memory.promptSection(self.allocator, memory_mod.prompt_budget);
        defer if (section) |value| self.allocator.free(value);
        const content = try buildSystemPrompt(self.allocator, self.mcp_registry, section);
        errdefer self.allocator.free(content);

        const previous = self.history.items[0].content;
        self.history.items[0].content = content;
        if (previous) |value| self.allocator.free(value);
    }

    /// Fold the messages before a safe cut into one summary. Returns false
    /// when there is nothing safe to compact or the model could not produce a
    /// summary; in both cases the history is left as it was, because losing
    /// the conversation is worse than exceeding the budget by one turn.
    fn compactHistory(self: *Agent, turn_start: ?*usize) !bool {
        const cut = compact.findCut(self.history.items, self.compact_keep) orelse return false;
        const before = compact.estimateTokens(self.history.items);

        const summary = self.summarizeRange(1, cut) catch |err| {
            if (self.client.takeHttpError()) |message| {
                defer self.allocator.free(message);
                try self.emit(std.Io.File.stderr(), RED ++ "  ✗ {s}\n" ++ RESET, .{message});
            }
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ context compaction skipped: {s}\n" ++ RESET, .{@errorName(err)});
            return false;
        };
        defer self.allocator.free(summary);

        const shift = compact.install(self.allocator, &self.history, cut, summary) catch |err| {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ context compaction skipped: {s}\n" ++ RESET, .{@errorName(err)});
            return false;
        };
        if (turn_start) |index| {
            if (index.* >= cut) {
                index.* -= shift;
            } else {
                // The turn began in the part that was summarized; the first
                // kept message is the nearest point the verifier can use.
                index.* = @min(index.*, 2);
            }
        }
        self.checkpoint() catch {};

        const after = compact.estimateTokens(self.history.items);
        try self.emit(std.Io.File.stderr(), DIM ++ "  ⟳ compacted {d} earlier messages (~{d} tokens freed)\n" ++ RESET, .{ cut - 2, before -| after });
        return true;
    }

    /// Compact when the estimated conversation has crossed the budget.
    fn compactIfNeeded(self: *Agent, turn_start: ?*usize) !bool {
        if (self.compact_threshold == 0) return false;
        if (!compact.needsCompaction(self.history.items, self.compact_threshold)) return false;
        return self.compactHistory(turn_start);
    }

    /// Summarize `[from, to)` in bounded chunks, carrying the summary so far
    /// into each request. Returns an owned summary.
    fn summarizeRange(self: *Agent, from: usize, to: usize) ![]u8 {
        var running: ?[]u8 = null;
        errdefer if (running) |value| self.allocator.free(value);

        var start = from;
        while (start < to) {
            var end = start;
            var weight: usize = 0;
            while (end < to) {
                const next = compact.messageWeight(self.history.items[end]);
                if (end > start and weight + next > compact.max_chunk_bytes) break;
                weight += next;
                end += 1;
            }
            if (end == start) end = start + 1;

            const segment = try compact.renderTranscript(self.allocator, self.history.items, start, end);
            defer self.allocator.free(segment);
            const messages = try compact.buildSummaryMessages(self.allocator, running, segment);
            defer compact.freeSummaryMessages(self.allocator, messages);

            const response = try self.client.respondWithoutTools(messages);
            defer response.deinit(self.allocator);
            if (!std.mem.eql(u8, response.finish_reason, "stop")) return error.SummaryTruncated;
            const content = response.content orelse return error.EmptySummary;
            const next = try compact.sanitizeSummary(self.allocator, content);
            if (running) |old| self.allocator.free(old);
            running = next;
            start = end;
        }
        return running orelse error.EmptySummary;
    }

    /// `/compact`: summarize the older part of the conversation now, whether
    /// or not the budget has been reached.
    pub fn compactCommand(self: *Agent) !void {
        if (compact.findCut(self.history.items, self.compact_keep) == null) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  nothing to compact yet\n" ++ RESET, .{});
            return;
        }
        _ = try self.compactHistory(null);
    }

    /// `/memory`: list what is saved, newest last.
    pub fn listMemory(self: *Agent) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try self.memory.writeList(&aw.writer);
        try self.writeLogOrStdout(aw.written());
    }

    /// `/remember <text>`: save a note by hand, as the model's remember tool
    /// does, and make it part of this session's system prompt.
    pub fn rememberCommand(self: *Agent, note: []const u8) !void {
        if (!self.memory.enabled) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  memory is disabled\n" ++ RESET, .{});
            return;
        }
        if (note.len == 0) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  usage: /remember <text>\n" ++ RESET, .{});
            return;
        }

        const added = self.memory.add(note) catch |err| {
            try self.emit(std.Io.File.stderr(), RED ++ "  ✗ could not remember: {s}\n" ++ RESET, .{@errorName(err)});
            return;
        };
        if (!added) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  already remembered\n" ++ RESET, .{});
            return;
        }
        self.memory.save() catch |err| {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ memory could not be saved: {s}\n" ++ RESET, .{@errorName(err)});
            return;
        };
        self.refreshSystemPrompt() catch {};
        try self.emit(std.Io.File.stderr(), DIM ++ "  ✓ remembered: {s}\n" ++ RESET, .{note});
    }

    /// `/forget <n|all>`: drop one numbered note, or every note.
    pub fn forgetCommand(self: *Agent, argument: []const u8) !void {
        if (!self.memory.enabled) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  memory is disabled\n" ++ RESET, .{});
            return;
        }
        const arg = std.mem.trim(u8, argument, " \t");
        if (arg.len == 0) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  usage: /forget <number> | /forget all\n" ++ RESET, .{});
            return;
        }
        if (std.ascii.eqlIgnoreCase(arg, "all")) {
            self.memory.clear();
            self.memory.save() catch |err| {
                try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ memory could not be saved: {s}\n" ++ RESET, .{@errorName(err)});
                return;
            };
            self.refreshSystemPrompt() catch {};
            try self.emit(std.Io.File.stderr(), DIM ++ "  all memories forgotten\n" ++ RESET, .{});
            return;
        }
        const number = std.fmt.parseInt(usize, arg, 10) catch {
            try self.emit(std.Io.File.stderr(), DIM ++ "  usage: /forget <number> | /forget all\n" ++ RESET, .{});
            return;
        };
        if (number == 0 or !self.memory.remove(number - 1)) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  no memory number {d} (see /memory)\n" ++ RESET, .{number});
            return;
        }
        self.memory.save() catch |err| {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ memory could not be saved: {s}\n" ++ RESET, .{@errorName(err)});
            return;
        };
        self.refreshSystemPrompt() catch {};
        try self.emit(std.Io.File.stderr(), DIM ++ "  ✓ forgot memory {d}\n" ++ RESET, .{number});
    }

    /// The remember tool: save one durable note and tell the model whether it
    /// was new.
    fn rememberTool(self: *Agent, arguments: []const u8) !tools.ToolResult {
        if (!self.memory.enabled) {
            return .{
                .content = try self.allocator.dupe(u8, "Memory is disabled (AI_MEMORY=0)."),
                .is_error = true,
            };
        }
        const note = openai.extractStringArg(self.allocator, arguments, "text") catch {
            return .{
                .content = try self.allocator.dupe(u8, "Error: remember needs a non-empty 'text' string"),
                .is_error = true,
            };
        };
        defer self.allocator.free(note);

        const added = self.memory.add(note) catch |err| switch (err) {
            error.EmptyMemory => return .{
                .content = try self.allocator.dupe(u8, "Error: remember needs a non-empty 'text' string"),
                .is_error = true,
            },
            else => return err,
        };
        if (!added) {
            return .{
                .content = try std.fmt.allocPrint(self.allocator, "Already in memory: {s}", .{note}),
                .is_error = false,
            };
        }

        self.memory.save() catch |err| {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ memory could not be saved: {s}\n" ++ RESET, .{@errorName(err)});
        };
        self.refreshSystemPrompt() catch {};
        return .{
            .content = try std.fmt.allocPrint(self.allocator, "Saved to memory: {s}", .{note}),
            .is_error = false,
        };
    }

    /// After a turn, ask the model whether anything durable emerged. This is
    /// deliberately conservative, and does nothing when memory is off.
    fn extractMemories(self: *Agent, query: []const u8) !void {
        if (!self.memory_auto or !self.memory.enabled) return;
        if (self.history.items.len <= 1) return;

        const window = 12;
        const from = if (self.history.items.len > window) self.history.items.len - window else 1;
        const transcript = try compact.renderTranscript(self.allocator, self.history.items, from, self.history.items.len);
        defer self.allocator.free(transcript);
        const known = try self.memory.promptSection(self.allocator, memory_mod.prompt_budget);
        defer if (known) |value| self.allocator.free(value);

        const messages = try memory_mod.buildExtractMessages(self.allocator, query, transcript, known);
        defer memory_mod.freeExtractMessages(self.allocator, messages);

        self.terminal_title.update("checking memory…", self.current_task);
        defer self.terminal_title.update("ready", self.current_task);
        var spin = spinner.Spinner.start(self.io, std.Io.File.stderr(), "checking memory…", self.progressOptions());
        defer spin.stop();
        const response = self.client.respondWithoutTools(messages) catch {
            // Optional work: drop the stored HTTP detail rather than letting a
            // later, unrelated failure report it as its own.
            if (self.client.takeHttpError()) |message| self.allocator.free(message);
            return;
        };
        defer response.deinit(self.allocator);
        if (!std.mem.eql(u8, response.finish_reason, "stop")) return;
        const content = response.content orelse return;

        var extracted = memory_mod.parseExtraction(self.allocator, content);
        defer extracted.deinit();
        if (extracted.notes.items.len == 0) return;

        var added: usize = 0;
        for (extracted.notes.items) |note| {
            if (self.memory.add(note) catch false) added += 1;
        }
        if (added == 0) return;

        self.memory.save() catch |err| {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ memory could not be saved: {s}\n" ++ RESET, .{@errorName(err)});
            return;
        };
        self.refreshSystemPrompt() catch {};
        try self.emit(std.Io.File.stderr(), DIM ++ "  ✧ remembered {d} note{s}\n" ++ RESET, .{ added, if (added == 1) "" else "s" });
    }

    /// Process a single user query: work on it until the model answers and the
    /// completion check agrees that the request is done.
    pub fn processQuery(self: *Agent, query: []const u8) !void {
        self.query_started = std.Io.Timestamp.now(self.io, .awake);
        defer self.query_started = null;
        self.client.resetTokenCounters();
        // Never use raw user input as a terminal title, even while planning.
        self.current_task = "";
        defer self.current_task = "";
        self.terminal_title.update("planning…", "");
        var task_title: ?[]u8 = null;
        defer if (task_title) |title| self.allocator.free(title);
        self.processQueryInner(query, &task_title) catch |err| {
            self.terminal_title.update("error", self.current_task);
            return err;
        };
        self.terminal_title.update("ready", self.current_task);
        const elapsed_ms = self.query_started.?.untilNow(self.io, .awake).toMilliseconds();
        const counts = self.client.tokenCounts();
        try self.emit(std.Io.File.stderr(), DIM ++ "  Worked for {d}.{d}s · in {d} · out {d} tokens\n" ++ RESET, .{
            @divTrunc(elapsed_ms, 1000),
            @divTrunc(@mod(elapsed_ms, 1000), 100),
            counts.input,
            counts.output,
        });
        // The extraction is a small extra request, so it runs after the
        // user's own stats and never turns a finished answer into an error.
        self.extractMemories(query) catch {};
    }

    fn progressOptions(self: *Agent) spinner.Options {
        return .{
            .enabled = self.animate_progress,
            .started = self.query_started,
            .prompt = self.progress_prompt,
            .first_frame_delay_ms = 0,
            .in_tokens = &self.client.input_tokens,
            .out_tokens = &self.client.output_tokens,
        };
    }

    /// A separate tool-free request establishes intent before any execution.
    /// Keep its public approach in history so the execution request can use it.
    fn planTask(self: *Agent) !?[]u8 {
        var messages: std.ArrayList(Message) = .empty;
        defer messages.deinit(self.allocator);
        try messages.appendSlice(self.allocator, self.history.items);
        try messages.append(self.allocator, .{
            .role = "developer",
            .reasoning_content = null,
            .tool_calls = null,
            .tool_call_id = null,
            .content = "Before executing the latest user request, identify the goal and a brief practical approach using conversation context. Do not execute or claim work is done. Return only JSON: {\"title\":\"a concise task summary in the user's language, fewer than 80 Unicode characters, not a copy of the input\",\"approach\":\"one brief sentence explaining what you will do and how, in the user's language\"}.",
        });
        var spin = spinner.Spinner.start(self.io, std.Io.File.stderr(), "planning…", self.progressOptions());
        const response = self.client.respondWithoutTools(messages.items) catch {
            spin.stop();
            if (self.client.takeHttpError()) |detail| self.allocator.free(detail);
            return null;
        };
        spin.stop();
        defer response.deinit(self.allocator);
        if (!std.mem.eql(u8, response.finish_reason, "stop")) return null;
        const content = response.content orelse return null;
        const parsed = std.json.parseFromSlice(struct { title: []const u8, approach: []const u8 }, self.allocator, content, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        const title = std.mem.trim(u8, parsed.value.title, " \t\r\n");
        const approach = std.mem.trim(u8, parsed.value.approach, " \t\r\n");
        if (title.len == 0 or approach.len == 0) return null;
        const owned = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned);
        try self.emit(std.Io.File.stdout(), "{s}\n\n", .{approach});
        try self.appendAssistantText(approach);
        return owned;
    }

    fn processQueryInner(self: *Agent, query: []const u8, task_title: *?[]u8) !void {
        try self.appendUserMessage(query);
        try self.checkpoint();
        // A conversation that has grown past the budget is compacted before
        // the request that would otherwise carry all of it.
        _ = self.compactIfNeeded(null) catch false;
        task_title.* = try self.planTask();
        self.current_task = task_title.* orelse "Task";
        self.terminal_title.update("thinking…", self.current_task);
        // The judge is shown only what this turn produced, so remember where
        // the request it is checking starts. Compaction during the turn moves
        // this index down; `runToolLoop` updates it.
        var turn_start = self.history.items.len;

        var verifications: u32 = 0;
        var worked = false;

        while (true) {
            const turn = try self.runToolLoop(&turn_start);
            if (!turn.completed) return error.IterationLimitReached;
            // Counted across the whole query, not per round: a round that only
            // claims the work is finished still has to pass the check.
            worked = worked or turn.tool_calls > 0;
            // A query that never touched a tool is a conversation, not a task.
            if (!worked) return;
            if (self.max_verifications == 0) return;

            // A check that fails to produce a verdict — the request errored,
            // the reply was truncated, or it was not JSON — says nothing about
            // the work, so it is asked again while budget remains. The answer
            // is already printed and the turn is over; throwing it away over
            // one unusable reply is the worst of both outcomes. Each attempt
            // spends a check, so a judge that can never be read is still
            // bounded.
            var judged: ?verifier.Verdict = null;
            while (judged == null and verifications < self.max_verifications) {
                verifications += 1;
                // The check announces itself from inside `judgeAnimated`, where
                // it can be animated for as long as the judge is thinking.
                judged = try self.judgeTurn(query, turn_start);
            }
            const verdict = judged orelse {
                try self.emit(std.Io.File.stderr(), DIM ++ "  ✗ no usable completion verdict in {d} checks; the answer above stands unverified\n" ++ RESET, .{verifications});
                return error.CompletionUnverified;
            };
            defer verdict.deinit(self.allocator);

            if (verdict.complete) {
                try self.emit(std.Io.File.stderr(), DIM ++ "  ✓ completion check passed\n" ++ RESET, .{});
                return;
            }

            try self.emit(std.Io.File.stderr(), YELLOW ++ "  ↻ not done: {s}\n" ++ RESET, .{verdict.reason});

            // Do not start another round that cannot be checked. In particular,
            // the last rejection used to trigger more tools and print a new
            // answer, only to fail unconditionally at the top of this loop.
            if (verifications == self.max_verifications) {
                try self.emit(std.Io.File.stderr(), DIM ++ "  ⟳ completion check budget ({d}) spent; task remains unverified\n" ++ RESET, .{self.max_verifications});
                if (verdict.next_step) |step| {
                    try self.emit(std.Io.File.stderr(), "  Next step: {s}\n", .{step});
                }
                try self.emit(std.Io.File.stderr(), "  Continue with the next step in a new query, or increase AI_MAX_VERIFICATIONS for tasks needing more repair rounds.\n", .{});
                return error.CompletionUnverified;
            }

            // The judge can hand the open question back as a menu of its own
            // making, for the turns the model never got around to asking about.
            if (verdict.options.items.len > 0) {
                const question = verdict.question orelse "How should I proceed?";
                const answer = (try self.askChoice(question, verdict.options.items)) orelse {
                    try self.emit(std.Io.File.stderr(), DIM ++ "  stopped without an answer\n" ++ RESET, .{});
                    return;
                };
                defer self.allocator.free(answer);
                try self.emit(std.Io.File.stderr(), DIM ++ "  → {s}\n" ++ RESET, .{answer});
                try self.appendUserMessage(answer);
            } else {
                const follow_up = try verifier.buildFollowUp(self.allocator, verdict);
                defer self.allocator.free(follow_up);
                try self.appendUserMessage(follow_up);
            }
        }
    }

    /// Send the conversation and wait, with the progress line animated for the
    /// length of the wait.
    ///
    /// The spinner lives in these helpers rather than in the loop that calls
    /// them: a `defer` in the loop body would still be in force while the tool
    /// results are printed, and the next frame of the animation would erase
    /// what was just printed. Here it ends before the caller writes a byte.
    fn chatAnimated(self: *Agent, messages: []const Message, stream: *AnswerStream) !openai.ApiResponse {
        self.terminal_title.update("thinking…", self.current_task);
        var spin = spinner.Spinner.start(self.io, std.Io.File.stderr(), "thinking…", self.progressOptions());
        defer spin.stop();
        // The streamer stops the animation as soon as the first text arrives,
        // so the answer and the spinner never fight over the same line.
        stream.spin = &spin;
        defer stream.spin = null;
        return self.client.respondStreaming(messages, self.mcp_registry.functionJson(), stream.sink()) catch |err| {
            spin.stop();
            try self.reportHttpError();
            return err;
        };
    }

    /// Ask the completion judge, animated the same way. Without a terminal to
    /// animate, the plain line it replaces is printed instead, so a redirected
    /// run still records that the check happened.
    fn judgeAnimated(self: *Agent, messages: []const Message) !openai.ApiResponse {
        self.terminal_title.update("checking completion…", self.current_task);
        var spin = spinner.Spinner.start(self.io, std.Io.File.stderr(), "checking completion…", self.progressOptions());
        if (!spin.animating()) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⟳ checking completion…\n" ++ RESET, .{});
        }
        defer spin.stop();
        return self.client.respondWithoutTools(messages) catch |err| {
            spin.stop();
            try self.reportHttpError();
            return err;
        };
    }

    /// Report what the server said about a request that failed. The client
    /// keeps it instead of printing it, so that it can be said here — after
    /// the animation has given the line back.
    fn reportHttpError(self: *Agent) !void {
        const message = self.client.takeHttpError() orelse return;
        defer self.allocator.free(message);
        try self.emit(std.Io.File.stderr(), RED ++ "  ✗ {s}\n" ++ RESET, .{message});
    }

    const Turn = struct {
        /// How many tool calls the model made before its final answer.
        tool_calls: usize,
        /// False when the iteration budget ran out before an answer.
        completed: bool,
    };

    /// Run the tool-call loop until the model answers or the iteration budget
    /// runs out. The answer is printed and kept in the history.
    fn runToolLoop(self: *Agent, turn_start: ?*usize) !Turn {
        // Tests drive the loop directly, without a query around it; give them
        // a boundary of their own rather than making the caller invent one.
        var local_turn_start = self.history.items.len;
        const start = turn_start orelse &local_turn_start;
        var turn: Turn = .{ .tool_calls = 0, .completed = false };
        var iteration: usize = 0;
        // Text from replies that the token limit cut short. It is held back
        // until the answer is complete, so the pieces print as the one reply
        // they were meant to be instead of several half-rendered documents.
        var carried: std.ArrayList(u8) = .empty;
        defer carried.deinit(self.allocator);
        // The answer streams into this for as long as the loop runs, so a
        // reply cut short by the token limit keeps painting one document and
        // tool-call commentary is shown as the model writes it.
        const stream = try AnswerStream.init(self);
        defer stream.deinit();
        var continuations: usize = 0;
        var empty_continuations: usize = 0;
        // Where this turn's continuation fragments start in the history. When
        // the turn settles they are folded into the answer, or dropped if the
        // reply turned into a tool call, so no transport scaffolding is kept.
        var continuation_start: ?usize = null;

        while (iteration < self.max_iterations) : (iteration += 1) {
            // Tool output can grow the conversation inside one turn. Compact
            // between iterations, but never while a cut-off reply is still
            // being carried: its fragments and the index that folds them are
            // not safe to move until the continuation settles.
            if (continuation_start == null) {
                _ = self.compactIfNeeded(start) catch false;
            }
            const response = self.chatAnimated(self.history.items, stream) catch |err| {
                // Do not leave a continuation prompt as the last message for
                // the next request to answer.
                self.settleContinuations(&continuation_start, carried.items, null) catch {};
                stream.flushPending() catch {};
                try self.emit(std.Io.File.stderr(), RED ++ "Error: failed to call API: {s}\n" ++ RESET, .{@errorName(err)});
                return err;
            };
            defer response.deinit(self.allocator);

            if (std.mem.eql(u8, response.finish_reason, "length")) {
                // The client already retried with a larger budget where its
                // cap allowed it. What is left is to keep the text that was
                // produced and ask for the rest, rather than lose the turn.
                if (response.content) |partial| {
                    if (continuations >= max_continuations) {
                        try self.reportTruncation(stream, &continuation_start, carried.items, partial, response.reasoning_content);
                        return error.ResponseTruncated;
                    }
                    continuations += 1;
                    if (continuation_start == null) continuation_start = self.history.items.len;
                    try carried.appendSlice(self.allocator, partial);
                    try self.appendAssistantFragment(partial, response.reasoning_content);
                    try self.emit(std.Io.File.stderr(), DIM ++ "  … reply cut off by the output limit; continuing where it stopped\n" ++ RESET, .{});
                    try self.appendUserMessage(continue_prompt);
                    continue;
                }
                if (empty_continuations >= max_empty_continuations) {
                    try self.reportTruncation(stream, &continuation_start, carried.items, "", response.reasoning_content);
                    return error.ResponseTruncated;
                }
                empty_continuations += 1;
                if (continuation_start == null) continuation_start = self.history.items.len;
                try self.emit(std.Io.File.stderr(), DIM ++ "  … reply cut off before any text; asking for a smaller step\n" ++ RESET, .{});
                try self.appendUserMessage(if (carried.items.len > 0) continue_prompt else restart_prompt);
                continue;
            }
            if (std.mem.eql(u8, response.finish_reason, "tool_calls")) {
                const tool_calls = response.tool_calls orelse {
                    self.settleContinuations(&continuation_start, carried.items, null) catch {};
                    try self.emit(std.Io.File.stderr(), RED ++ "Error: finish_reason=tool_calls but no tool_calls\n" ++ RESET, .{});
                    return error.InvalidResponse;
                };

                // A partial reply that led to a tool call is not the answer;
                // drop its fragments before the call joins the conversation.
                try self.settleContinuations(&continuation_start, "", null);
                carried.clearRetainingCapacity();
                // Any commentary the model streamed before the call is shown;
                // finish its last line so the tool announcement starts fresh.
                stream.flushPending() catch {};

                // Clone tool calls so the assistant message can own them
                const owned_calls = try cloneToolCalls(self.allocator, tool_calls);
                errdefer {
                    for (owned_calls) |c| c.deinit(self.allocator);
                    self.allocator.free(owned_calls);
                }
                // Keep exact Responses output items alongside the UI summary.
                // This retains reasoning and function call IDs for stateless replay.
                const owned_content = if (response.content) |value| try self.allocator.dupe(u8, value) else null;
                errdefer if (owned_content) |value| self.allocator.free(value);
                const owned_reasoning = if (response.reasoning_content) |value| try self.allocator.dupe(u8, value) else null;
                errdefer if (owned_reasoning) |value| self.allocator.free(value);

                const owned_items = if (response.response_items) |value| try self.allocator.dupe(u8, value) else null;
                errdefer if (owned_items) |value| self.allocator.free(value);
                try self.history.append(self.allocator, .{
                    .response_items = owned_items,
                    .role = "assistant",
                    .content = owned_content,
                    .reasoning_content = owned_reasoning,
                    .tool_calls = owned_calls,
                    .tool_call_id = null,
                });

                for (tool_calls) |call| {
                    const result = self.executeTool(call) catch |err| blk: {
                        const error_content = try std.fmt.allocPrint(
                            self.allocator,
                            "Tool execution error for {s}: {s}",
                            .{ call.name, @errorName(err) },
                        );
                        break :blk tools.ToolResult{
                            .content = error_content,
                            .is_error = true,
                        };
                    };
                    defer result.deinit(self.allocator);

                    const result_content = try self.allocator.dupe(u8, result.content);
                    errdefer self.allocator.free(result_content);
                    const call_id = try self.allocator.dupe(u8, call.id);
                    errdefer self.allocator.free(call_id);

                    try self.history.append(self.allocator, .{
                        .role = "tool",
                        .content = result_content,
                        .reasoning_content = null,
                        .tool_calls = null,
                        .tool_call_id = call_id,
                    });
                }
                try self.checkpoint();
                turn.tool_calls += tool_calls.len;
                // Continue: call API again with tool results
            } else {
                // Final answer
                if (response.content) |content| {
                    // Earlier pieces of this reply are already in the history;
                    // print them together so markdown sees one document.
                    var combined: ?[]u8 = null;
                    defer if (combined) |buffered| self.allocator.free(buffered);
                    const printed = if (carried.items.len > 0) blk: {
                        combined = try std.mem.concat(self.allocator, u8, &.{ carried.items, content });
                        break :blk combined.?;
                    } else content;
                    if (stream.started) {
                        // The answer was already painted as it streamed; all
                        // that is left is the pending line, table and trailer.
                        try stream.finish();
                    } else {
                        // No stream reached the caller (a test transport, say):
                        // render the whole answer at once as before.
                        try self.answerHeader();
                        try self.writeAnswer(printed);
                        try self.answerTrailer();
                    }

                    if (continuation_start != null) {
                        // Fold the pieces and prompts into the one reply they
                        // make up; incomplete items are never replayed.
                        try self.settleContinuations(&continuation_start, printed, response.reasoning_content);
                    } else {
                        const owned_content = try self.allocator.dupe(u8, content);
                        errdefer self.allocator.free(owned_content);
                        const owned_reasoning = if (response.reasoning_content) |value| try self.allocator.dupe(u8, value) else null;
                        errdefer if (owned_reasoning) |value| self.allocator.free(value);

                        const owned_items = if (response.response_items) |value| try self.allocator.dupe(u8, value) else null;
                        errdefer if (owned_items) |value| self.allocator.free(value);
                        try self.history.append(self.allocator, .{
                            .response_items = owned_items,
                            .role = "assistant",
                            .content = owned_content,
                            .reasoning_content = owned_reasoning,
                            .tool_calls = null,
                            .tool_call_id = null,
                        });
                    }
                }
                try self.checkpoint();
                turn.completed = true;
                break;
            }
        }

        if (iteration == self.max_iterations) {
            // Keep whatever the cut-off replies had produced, but not the
            // prompts that asked for it.
            try self.settleContinuations(&continuation_start, carried.items, null);
            stream.flushPending() catch {};
            try self.emit(std.Io.File.stderr(), RED ++ "Error: reached maximum tool call iterations ({d})\n" ++ RESET, .{self.max_iterations});
        }

        return turn;
    }

    /// Ask the judge whether the turn that started at `turn_start` finished the
    /// user's request. Returns null when the judge could not be consulted or
    /// its reply could not be read: an unjudgeable turn keeps the answer it
    /// already printed rather than looping on a check that cannot pass.
    fn judgeTurn(self: *Agent, request: []const u8, turn_start: usize) !?verifier.Verdict {
        const summary = try verifier.summarize(self.allocator, self.history.items[turn_start..], summary_max_bytes);
        defer self.allocator.free(summary);
        const prompt = try verifier.buildPrompt(self.allocator, request, summary);
        defer self.allocator.free(prompt);

        // The request only serialises these, so borrowed content is enough.
        const messages = [_]Message{
            .{ .role = "system", .content = verifier.SYSTEM_PROMPT, .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
            .{ .role = "user", .content = prompt, .reasoning_content = null, .tool_calls = null, .tool_call_id = null },
        };

        const response = self.judgeAnimated(&messages) catch |err| {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ completion check skipped: {s}\n" ++ RESET, .{@errorName(err)});
            return null;
        };
        defer response.deinit(self.allocator);

        // A verdict cut off by the token limit cannot be trusted, even when
        // the fragment happens to parse: the outer loop asks again.
        if (std.mem.eql(u8, response.finish_reason, "length")) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ completion check skipped: the reply was truncated\n" ++ RESET, .{});
            return null;
        }

        const content = response.content orelse {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ completion check skipped: the reply was empty\n" ++ RESET, .{});
            return null;
        };

        return verifier.parseVerdict(self.allocator, content) catch |err| {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ⚠ completion check skipped: {s}\n" ++ RESET, .{@errorName(err)});
            return null;
        };
    }

    /// Show the offered options and return one line describing what the user
    /// chose. Returns null when the question was dismissed and the model has
    /// to decide on its own.
    fn askChoice(self: *Agent, question: []const u8, options: []const menu.Option) !?[]u8 {
        self.terminal_title.update("waiting for input", self.current_task);
        const recommended = menu.recommendedIndex(options);

        if (!self.linenoise.is_tty or !self.linenoise.term_supported or
            !(std.Io.File.stderr().isTty(self.io) catch false))
        {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            try menu.writeMenu(&aw.writer, question, options);
            try self.writeLogOrStdout(aw.written());
            // Nothing to read a choice from. Taking the recommendation keeps a
            // piped or single-query run moving instead of stalling it.
            if (recommended) |index| {
                try self.emit(std.Io.File.stderr(), DIM ++ "  no terminal to read an answer from; taking the recommended option\n" ++ RESET, .{});
                return try menu.describeAnswer(self.allocator, .{ .option = index }, options);
            }
            try self.emit(std.Io.File.stderr(), DIM ++ "  no terminal to read an answer from\n" ++ RESET, .{});
            return null;
        }

        const selected = try menu.select(self.allocator, self.io, question, options) orelse return null;
        if (selected < options.len) {
            return try menu.describeAnswer(self.allocator, .{ .option = selected }, options);
        }

        // A menu answer is free text, not a slash command, so completion and
        // hints are switched off for this read and restored afterwards.
        const saved_completions = self.linenoise.completions_callback;
        const saved_hints = self.linenoise.hints_callback;
        const saved_popup = self.linenoise.popup_callback;
        self.linenoise.completions_callback = null;
        self.linenoise.hints_callback = null;
        self.linenoise.popup_callback = null;
        defer {
            self.linenoise.completions_callback = saved_completions;
            self.linenoise.hints_callback = saved_hints;
            self.linenoise.popup_callback = saved_popup;
        }

        var raw_line: ?[]const u8 = null;
        while (true) {
            if (self.screen) |screen| try screen.prepareInput();
            raw_line = self.linenoise.linenoise(CHOICE_PROMPT) catch |err| switch (err) {
                error.CtrlC => {
                    if (self.screen) |screen| try screen.endInput();
                    return null;
                },
                error.Suspend => {
                    // The custom-answer read is a normal line edit; suspension
                    // gives the terminal back and resumes on the same text.
                    if (self.screen) |screen| {
                        try screen.suspendProcess();
                    } else {
                        @import("screen.zig").stopProcess();
                    }
                    continue;
                },
                else => return err,
            };
            if (self.screen) |screen| try screen.endInput();
            break;
        }
        const line = raw_line orelse {
            // End of input: fall back to the recommendation, if any.
            if (recommended) |index| return try menu.describeAnswer(self.allocator, .{ .option = index }, options);
            return null;
        };
        defer self.allocator.free(line);

        // The question is part of the record even though the editor's rows are
        // cleared once the answer is read.
        if (self.screen) |screen| {
            const echo = try std.fmt.allocPrint(self.allocator, "{s}{s}\n", .{ CHOICE_PROMPT, line });
            defer self.allocator.free(echo);
            try screen.writeLog(echo);
        }

        const answer = std.mem.trim(u8, line, " \t\r\n");
        if (answer.len == 0) return null;
        return try menu.describeAnswer(self.allocator, .{ .custom = answer }, options);
    }

    /// The ask_user tool: put the model's question to the user and hand the
    /// answer back as the tool result.
    fn askUser(self: *Agent, arguments: []const u8) !tools.ToolResult {
        const question = menu.parseAskUser(self.allocator, arguments) catch {
            return .{
                .content = try self.allocator.dupe(u8, "Error: ask_user needs a 'question' and a non-empty 'options' array"),
                .is_error = true,
            };
        };
        defer question.deinit(self.allocator);

        if (try self.askChoice(question.text, question.options.items)) |answer| {
            return .{ .content = answer, .is_error = false };
        }

        return .{
            .content = try self.allocator.dupe(u8, "The question was dismissed without an answer. If you can, decide yourself; otherwise explain what you need and stop."),
            .is_error = true,
        };
    }

    /// Append a user-role message, taking a copy of `message`.
    fn appendUserMessage(self: *Agent, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned);
        try self.history.append(self.allocator, .{
            .role = "user",
            .content = owned,
            .reasoning_content = null,
            .tool_calls = null,
            .tool_call_id = null,
        });
    }

    /// Keep a partial reply in the history, without reasoning, so the next
    /// request can continue it. Incomplete output must not be replayed.
    fn appendAssistantText(self: *Agent, partial: []const u8) !void {
        try self.appendAssistantFragment(partial, null);
    }

    /// Keep an assistant reply fragment in the history, with its chain-of-
    /// thought text when known. Thinking mode requires the reasoning to be
    /// passed back on later tool-carrying turns, even when the reply that
    /// followed it was cut short.
    fn appendAssistantFragment(self: *Agent, partial: []const u8, reasoning: ?[]const u8) !void {
        const owned = try self.allocator.dupe(u8, partial);
        errdefer self.allocator.free(owned);
        const owned_reasoning = if (reasoning) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_reasoning) |value| self.allocator.free(value);
        try self.history.append(self.allocator, .{
            .role = "assistant",
            .content = owned,
            .reasoning_content = owned_reasoning,
            .tool_calls = null,
            .tool_call_id = null,
        });
    }

    /// Remove the partial replies and prompts a continuation left in the
    /// history, keeping their text as one assistant message when there is any.
    /// A turn that ends in a tool call or an error must not leave the model's
    /// transport scaffolding behind for the next request to read.
    fn settleContinuations(self: *Agent, start: *?usize, keep: []const u8, reasoning: ?[]const u8) !void {
        const index = start.* orelse return;
        while (self.history.items.len > index) {
            const message = self.history.items[self.history.items.len - 1];
            self.history.items.len -= 1;
            message.deinit(self.allocator);
        }
        start.* = null;
        if (keep.len > 0) try self.appendAssistantFragment(keep, reasoning);
    }

    /// Give up on a reply the token limit keeps cutting short. What was
    /// produced before is still worth printing: losing it would be worse than
    /// the error that ends the turn.
    fn reportTruncation(self: *Agent, stream: *AnswerStream, start: *?usize, carried: []const u8, partial: []const u8, reasoning: ?[]const u8) !void {
        const answer = try std.mem.concat(self.allocator, u8, &.{ carried, partial });
        defer self.allocator.free(answer);
        try self.settleContinuations(start, answer, reasoning);
        if (answer.len > 0) {
            if (stream.started) {
                try stream.finish();
            } else {
                try self.answerHeader();
                try self.writeAnswer(answer);
                try self.answerTrailer();
            }
        }
        try self.emit(std.Io.File.stderr(), RED ++ "Error: model output still exceeds the token budget after automatic retries and continuations; split the task into smaller steps, or raise AI_MAX_TOKENS if the endpoint accepts more than DeepSeek's 8192.\n" ++ RESET, .{});
    }

    /// Announce a tool call on the line above whatever it prints.
    ///
    /// Most tools are one line of name and arguments. `apply_patch` is the
    /// exception: its argument is the diff itself, and a JSON-escaped diff tells
    /// nobody anything — so it is drawn instead, line by line, in the colours
    /// the change would be read in.
    fn announceToolCall(self: *Agent, call: ToolCallData) !void {
        // Written through a fixed buffer rather than built up in memory first:
        // a patch is read as it is drawn, and a long one never has to be held
        // whole to be shown.
        var buf: [4096]u8 = undefined;

        if (self.screen) |screen| {
            if (screen.isActive()) {
                var log_writer = screen.logWriter(&buf);
                try self.writeToolCall(&log_writer.writer, call);
                return log_writer.writer.flush();
            }
        }

        var file_writer = std.Io.File.stderr().writerStreaming(self.io, &buf);
        try self.writeToolCall(&file_writer.interface, call);
        try file_writer.interface.flush();
    }

    fn writeToolCall(self: *Agent, w: *std.Io.Writer, call: ToolCallData) !void {
        if (!std.mem.eql(u8, call.name, "apply_patch")) {
            try w.writeAll(YELLOW ++ "  ⚙ ");
            // A tool name and its arguments are model output like any other, so
            // they are sanitised like any other: a call carrying an escape
            // sequence gets to be read, not to repaint the line it is on.
            try text.writeSanitized(w, call.name);
            try w.writeAll(RESET ++ " ");
            try text.writeSanitized(w, call.arguments);
            try w.writeByte('\n');
            return;
        }

        const patch_text = openai.extractStringArg(self.allocator, call.arguments, "patch") catch {
            // Nothing to draw. What the model actually sent still goes up, so
            // the call is visible; the dispatch reports what was wrong with it.
            try w.writeAll(YELLOW ++ "  ⚙ apply_patch" ++ RESET ++ " ");
            try text.writeSanitized(w, call.arguments);
            try w.writeByte('\n');
            return;
        };
        defer self.allocator.free(patch_text);

        try w.writeAll(YELLOW ++ "  ⚙ apply_patch\n" ++ RESET);
        try diff.render(w, patch_text);
    }

    fn executeTool(self: *Agent, call: ToolCallData) !tools.ToolResult {
        self.terminal_title.update(call.name, self.current_task);
        try self.announceToolCall(call);

        const result: tools.ToolResult = blk: {
            // A tool can run for minutes, so the wait gets the same animation
            // the model calls do. The `defer` covers the dispatch and nothing
            // else: below this block the result is previewed, and that has to
            // land on a line the animation has already given back.
            // A tool from an MCP server has a label too, built when the tool
            // was listed: it names the server the call is going to, and it is
            // this process's own string rather than one a server wrote.
            const label = tools.progressLabel(call.name) orelse self.mcp_registry.progressLabel(call.name);
            var spin = if (label) |caption|
                spinner.Spinner.start(self.io, std.Io.File.stderr(), caption, self.progressOptions())
            else
                spinner.Spinner.disabled(self.io);
            defer spin.stop();

            if (std.mem.eql(u8, call.name, "remember")) {
                break :blk try self.rememberTool(call.arguments);
            } else if (std.mem.eql(u8, call.name, "ask_user")) {
                break :blk try self.askUser(call.arguments);
            } else if (std.mem.startsWith(u8, call.name, mcp.tool_prefix)) {
                // A tool of a connected MCP server: the registry knows which
                // server it belongs to and what the server calls it.
                break :blk try self.mcp_registry.call(self.allocator, call.name, call.arguments);
            } else {
                break :blk try @import("execution.zig").execute(self.io, self.allocator, self.tool_env, self.tool_network, call.name, call.arguments);
            }
        };

        // Print a brief preview of the result
        const preview_len = @min(result.content.len, 200);
        const truncated = result.content.len > preview_len;
        if (result.is_error) {
            try self.emit(std.Io.File.stderr(), RED ++ "  ✗ {s}\n" ++ RESET, .{result.content});
        } else if (truncated) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ✓ {s}...\n" ++ RESET, .{result.content[0..preview_len]});
        } else {
            try self.emit(std.Io.File.stderr(), DIM ++ "  ✓ {s}\n" ++ RESET, .{result.content});
        }

        return result;
    }

    /// Print the model's answer: rendered for a terminal, raw otherwise.
    ///
    /// The raw path matters as much as the rendered one. When stdout is a pipe
    /// or a file the consumer is another program, and markdown is both the most
    /// faithful representation and the one that loses nothing — stripping
    /// markers would quietly cost a `| tee answer.md` user their structure.
    fn writeAnswer(self: *Agent, content: []const u8) !void {
        const stdout = std.Io.File.stdout();
        if (!self.render_markdown) return self.writeLogOrStdout(content);

        // A fixed buffer rather than `Writer.Allocating`: for a long answer the
        // latter would hold the entire styled document in memory before
        // printing a byte of it. This buffer is the renderer's only memory,
        // whatever the size of the document.
        var buf: [8192]u8 = undefined;

        if (self.screen) |screen| {
            if (screen.isActive()) {
                var log_writer = screen.logWriter(&buf);
                try render.render(&log_writer.writer, content, .{
                    .width = term.usableWidth(term.columns(stdout)),
                });
                return log_writer.writer.flush();
            }
        }

        var file_writer = stdout.writerStreaming(self.io, &buf);

        try render.render(&file_writer.interface, content, .{
            .width = term.usableWidth(term.columns(stdout)),
        });
        try file_writer.interface.flush();
    }

    /// Send finished bytes to the conversation, or to stdout when the
    /// interactive screen is not in use.
    fn writeLogOrStdout(self: *Agent, bytes: []const u8) !void {
        if (self.screen) |screen| {
            if (screen.isActive()) return screen.writeLog(bytes);
        }
        return std.Io.File.stdout().writeStreamingAll(self.io, bytes);
    }

    fn answerHeader(self: *Agent) !void {
        if (self.screen) |screen| {
            if (screen.isActive()) return screen.writeLog("\n" ++ BOLD ++ CYAN ++ "Assistant" ++ RESET ++ "\n");
        }
        const stdout = std.Io.File.stdout();
        if (stdout.isTty(self.io) catch false) {
            try stdout.writeStreamingAll(self.io, "\n" ++ BOLD ++ CYAN ++ "Assistant" ++ RESET ++ "\n");
        }
    }

    fn answerTrailer(self: *Agent) !void {
        try self.writeLogOrStdout("\n");
    }
};

/// Paints the answer as it streams from the model. The markdown renderer is
/// fed one complete line at a time, so bold, fences, lists and tables render
/// as they are written instead of appearing all at once when the request ends.
///
/// The struct is heap-allocated because the renderer holds a pointer to the
/// writer that lives inside this struct; a copy would invalidate it.
const AnswerStream = struct {
    agent: *Agent,
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,
    buf: [8192]u8 = undefined,
    log_writer: ?ScreenLogWriter = null,
    file_writer: ?std.Io.File.Writer = null,
    renderer: ?render.Renderer = null,
    /// Set once the first text delta has been shown, which is when the
    /// "Assistant" header is printed and the spinner is given its line back.
    started: bool = false,
    finished: bool = false,
    /// The spinner animating the wait for this turn. Stopped on the first
    /// delta so it does not draw over the answer.
    spin: ?*spinner.Spinner = null,

    fn init(agent: *Agent) !*AnswerStream {
        const allocator = agent.allocator;
        const self = try allocator.create(AnswerStream);
        self.* = .{ .agent = agent, .allocator = allocator };
        errdefer self.deinit();

        if (agent.render_markdown) {
            const width = term.usableWidth(term.columns(std.Io.File.stdout()));
            if (agent.screen) |screen| {
                if (screen.isActive()) {
                    self.log_writer = screen.logWriter(&self.buf);
                    self.renderer = render.Renderer.init(&self.log_writer.?.writer, .{ .width = width });
                }
            }
            if (self.renderer == null) {
                self.file_writer = std.Io.File.stdout().writerStreaming(agent.io, &self.buf);
                self.renderer = render.Renderer.init(&self.file_writer.?.interface, .{ .width = width });
            }
        }
        return self;
    }

    fn deinit(self: *AnswerStream) void {
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn sink(self: *AnswerStream) openai.StreamSink {
        return .{ .context = self, .onText = onText };
    }

    fn onText(context: *anyopaque, delta: []const u8) void {
        const self: *AnswerStream = @ptrCast(@alignCast(context));
        self.feed(delta) catch {};
    }

    fn feed(self: *AnswerStream, delta: []const u8) !void {
        if (delta.len == 0) return;
        if (!self.started) {
            self.started = true;
            // The spinner owns the terminal's line until the first text is
            // ready; stop it before anything else is written.
            if (self.spin) |spin| spin.stop();
            try self.agent.answerHeader();
        }
        try self.pending.appendSlice(self.allocator, delta);
        try self.drainLines();
    }

    fn drainLines(self: *AnswerStream) !void {
        while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
            const line = self.pending.items[0..nl];
            try self.emitLine(line);
            const rest = self.pending.items[nl + 1 ..];
            std.mem.copyForwards(u8, self.pending.items[0..rest.len], rest);
            self.pending.shrinkRetainingCapacity(rest.len);
        }
    }

    fn emitLine(self: *AnswerStream, line: []const u8) !void {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (self.renderer) |*r| {
            try r.feedLine(trimmed);
            // Push the line to the terminal now rather than waiting for the
            // writer's buffer to fill; that is what makes the answer stream.
            try r.flushWriter();
        } else {
            try self.agent.writeLogOrStdout(trimmed);
            try self.agent.writeLogOrStdout("\n");
        }
    }

    /// Emit the partial line still waiting for a newline, if there is one.
    /// Called when a turn ends without a final answer so its last line does
    /// not run into what is printed next.
    fn flushPending(self: *AnswerStream) !void {
        if (self.pending.items.len == 0) return;
        try self.emitLine(self.pending.items);
        self.pending.clearRetainingCapacity();
    }

    /// End the answer: flush any partial line and buffered table, then the
    /// trailing blank line. Idempotent, so the defers in callers are safe.
    fn finish(self: *AnswerStream) !void {
        if (self.finished) return;
        self.finished = true;
        if (self.renderer == null and self.pending.items.len > 0) {
            try self.agent.writeLogOrStdout(self.pending.items);
            self.pending.clearRetainingCapacity();
        } else {
            try self.flushPending();
        }
        if (self.renderer) |*r| try r.finish();
        if (self.started) try self.agent.answerTrailer();
    }
};

fn cloneToolCalls(allocator: std.mem.Allocator, calls: []const ToolCallData) ![]ToolCallData {
    const result = try allocator.alloc(ToolCallData, calls.len);
    var i: usize = 0;
    errdefer {
        for (result[0..i]) |c| c.deinit(allocator);
        allocator.free(result);
    }
    for (calls, 0..) |call, j| {
        result[j] = .{
            .id = try allocator.dupe(u8, call.id),
            .name = try allocator.dupe(u8, call.name),
            .arguments = try allocator.dupe(u8, call.arguments),
        };
        i = j + 1;
    }
    return result;
}

fn printFmt(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try file.writeStreamingAll(io, message);
}

/// A standalone agent for tests. The line editor and MCP registry live beside
/// it because the agent only borrows them, and the whole harness is
/// heap-allocated so their addresses stay valid while it runs.
const TestHarness = struct {
    env: std.process.Environ.Map,
    config: Config,
    linenoise: Linenoise,
    registry: mcp.Registry,
    agent: Agent,

    fn init(allocator: std.mem.Allocator, io: std.Io) !*TestHarness {
        const self = try allocator.create(TestHarness);
        errdefer allocator.destroy(self);

        self.env = .init(allocator);
        errdefer self.env.deinit();
        try self.env.put("AI_URL", "http://127.0.0.1:1/v1");
        try self.env.put("AI_MODEL", "test-model");
        try self.env.put("AI_KEY", "test-key");
        // Never read or write the developer's real memory file from a test.
        try self.env.put("AI_MEMORY", "0");

        self.config = try Config.load(allocator, io, &self.env);
        errdefer self.config.deinit();

        self.linenoise = Linenoise.init(allocator, io, &self.env);
        errdefer self.linenoise.deinit();

        self.registry = mcp.Registry.empty(allocator, io);
        errdefer self.registry.deinit();

        self.agent = try Agent.init(allocator, io, self.config, &self.linenoise, &self.env, &self.registry);
        return self;
    }

    fn deinit(self: *TestHarness, allocator: std.mem.Allocator) void {
        self.agent.deinit();
        self.registry.deinit();
        self.linenoise.deinit();
        self.config.deinit();
        self.env.deinit();
        allocator.destroy(self);
    }
};

/// Scripted Responses bodies for `openai.Client`, so the loop can be driven
/// without a socket. It records the budget of every request it is given.
const MockTransport = struct {
    replies: []const []const u8,
    cursor: usize = 0,
    budgets: std.ArrayList(u32) = .empty,
    requests: std.ArrayList([]u8) = .empty,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: []const u8) anyerror![]u8 {
        const self: *MockTransport = @ptrCast(@alignCast(context));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
        defer parsed.deinit();
        const budget = parsed.value.object.get("max_output_tokens") orelse return error.InvalidRequest;
        try self.budgets.append(allocator, @intCast(budget.integer));

        const owned = try allocator.dupe(u8, request);
        errdefer allocator.free(owned);
        try self.requests.append(allocator, owned);

        if (self.cursor >= self.replies.len) return error.NoScriptedReply;
        const reply = self.replies[self.cursor];
        self.cursor += 1;
        return allocator.dupe(u8, reply);
    }

    fn deinit(self: *MockTransport, allocator: std.mem.Allocator) void {
        for (self.requests.items) |request| allocator.free(request);
        self.requests.deinit(allocator);
        self.budgets.deinit(allocator);
    }
};

const truncated_text =
    "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"incomplete\",\"content\":[{\"type\":\"output_text\",\"text\":\"Half an \"}]}]}";

const truncated_call =
    "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[{\"type\":\"function_call\"}]}";

const completed_answer =
    "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer.\"}]}]}";

const completed_split =
    "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Split into chunks.\"}]}]}";

/// Send fd 1 and 2 to /dev/null for the length of a test. The Zig test runner
/// uses stdout as its protocol channel, and `runToolLoop` writes answers and
/// progress directly to the process's standard files.
const Silence = struct {
    saved_out: std.Io.File,
    saved_err: std.Io.File,
    null_file: std.Io.File,

    fn init(io: std.Io) !Silence {
        const null_file = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .write_only });
        errdefer null_file.close(io);
        const saved_out = std.Io.File{ .handle = try duplicateFd(std.posix.STDOUT_FILENO), .flags = .{ .nonblocking = false } };
        errdefer saved_out.close(io);
        const saved_err = std.Io.File{ .handle = try duplicateFd(std.posix.STDERR_FILENO), .flags = .{ .nonblocking = false } };
        errdefer saved_err.close(io);
        try redirectFd(null_file.handle, std.posix.STDOUT_FILENO);
        errdefer redirectFd(saved_out.handle, std.posix.STDOUT_FILENO) catch {};
        try redirectFd(null_file.handle, std.posix.STDERR_FILENO);
        return .{ .saved_out = saved_out, .saved_err = saved_err, .null_file = null_file };
    }

    fn deinit(self: *Silence, io: std.Io) void {
        redirectFd(self.saved_out.handle, std.posix.STDOUT_FILENO) catch {};
        redirectFd(self.saved_err.handle, std.posix.STDERR_FILENO) catch {};
        self.saved_out.close(io);
        self.saved_err.close(io);
        self.null_file.close(io);
    }
};

fn duplicateFd(fd: std.posix.fd_t) !std.posix.fd_t {
    const result = std.posix.system.dup(fd);
    if (std.posix.errno(result) != .SUCCESS) return error.DuplicateFdFailed;
    return @intCast(result);
}

fn redirectFd(from: std.posix.fd_t, to: std.posix.fd_t) !void {
    if (std.posix.errno(std.posix.system.dup2(from, to)) != .SUCCESS) return error.RedirectFdFailed;
}

test "planning generates a title before execution and keeps only the public approach" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);
    const reply =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"{\\\"title\\\":\\\"修复终端标题\\\",\\\"approach\\\":\\\"先定位标题逻辑，再修改并测试。\\\"}\"}]}]}";
    var mock: MockTransport = .{ .replies = &.{reply} };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("不要把这段原文直接放到标题上");
    const title = (try harness.agent.planTask()).?;
    defer allocator.free(title);
    try std.testing.expectEqualStrings("修复终端标题", title);
    try std.testing.expectEqualStrings("先定位标题逻辑，再修改并测试。", harness.agent.history.items[2].content.?);
    try std.testing.expectEqual(@as(usize, 1), mock.requests.items.len);
    const request = try std.json.parseFromSlice(std.json.Value, allocator, mock.requests.items[0], .{});
    defer request.deinit();
    try std.testing.expect(request.value.object.get("tools") == null);
}

test "unusable planning responses do not become titles or history" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);
    var mock: MockTransport = .{ .replies = &.{ completed_answer, truncated_text } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("Raw input must not be a title");
    const before = harness.agent.history.items.len;
    try std.testing.expect((try harness.agent.planTask()) == null);
    try std.testing.expect((try harness.agent.planTask()) == null);
    try std.testing.expectEqual(before, harness.agent.history.items.len);
}

test "compaction replaces old turns with a summary and keeps the recent ones" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    harness.agent.compact_keep = 2;

    try harness.agent.appendUserMessage("one");
    try harness.agent.appendAssistantText("answer one");
    try harness.agent.appendUserMessage("two");
    try harness.agent.appendAssistantText("answer two");
    try harness.agent.appendUserMessage("three");
    try harness.agent.appendAssistantText("answer three");
    try harness.agent.appendUserMessage("four");
    try harness.agent.appendAssistantText("answer four");

    var mock: MockTransport = .{ .replies = &.{completed_answer} };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };

    {
        var quiet = try Silence.init(std.testing.io);
        defer quiet.deinit(std.testing.io);
        try harness.agent.compactCommand();
    }

    // system, summary, then the newest turn verbatim.
    try std.testing.expectEqual(@as(usize, 4), harness.agent.history.items.len);
    try std.testing.expectEqualStrings("system", harness.agent.history.items[0].role);
    const summary = harness.agent.history.items[1].content.?;
    try std.testing.expect(std.mem.indexOf(u8, summary, "Earlier conversation summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "answer.") != null);
    try std.testing.expectEqualStrings("four", harness.agent.history.items[2].content.?);
    try std.testing.expectEqualStrings("answer four", harness.agent.history.items[3].content.?);
}

test "a truncated reply is continued and kept as one message" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);

    var mock: MockTransport = .{ .replies = &.{ truncated_text, completed_answer } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };

    const turn = try blk: {
        var quiet = try Silence.init(std.testing.io);
        defer quiet.deinit(std.testing.io);
        try harness.agent.appendUserMessage("Do the task");
        break :blk harness.agent.runToolLoop(null);
    };

    try std.testing.expect(turn.completed);
    // The default budget is already on the growth cap, so truncation is
    // answered by a continuation rather than by a larger request.
    try std.testing.expectEqualSlices(u32, &[_]u32{ 8192, 8192 }, mock.budgets.items);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "Continue exactly where it stopped") != null);
    // The partial reply and the prompt that asked for the rest are folded
    // into one assistant message; no scaffolding is left in the history.
    try std.testing.expectEqual(@as(usize, 3), harness.agent.history.items.len);
    const answer = harness.agent.history.items[2];
    try std.testing.expectEqualStrings("assistant", answer.role);
    try std.testing.expectEqualStrings("Half an answer.", answer.content.?);
    try std.testing.expect(answer.response_items == null);
}

test "a truncated tool call is retried in smaller steps without a dangling prompt" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);

    var mock: MockTransport = .{ .replies = &.{ truncated_call, completed_split } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };

    const turn = try blk: {
        var quiet = try Silence.init(std.testing.io);
        defer quiet.deinit(std.testing.io);
        try harness.agent.appendUserMessage("Do the task");
        break :blk harness.agent.runToolLoop(null);
    };

    try std.testing.expect(turn.completed);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 8192, 8192 }, mock.budgets.items);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "Try again in smaller steps") != null);
    try std.testing.expectEqual(@as(usize, 3), harness.agent.history.items.len);
    try std.testing.expectEqualStrings("Split into chunks.", harness.agent.history.items[2].content.?);
}

test "a reply that never stops truncating is given up on and still kept" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);

    // One initial reply plus `max_continuations` continuations, all cut off.
    var replies: [max_continuations + 1][]const u8 = undefined;
    for (&replies) |*reply| reply.* = truncated_text;
    var mock: MockTransport = .{ .replies = &replies };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };

    const outcome = blk: {
        var quiet = try Silence.init(std.testing.io);
        defer quiet.deinit(std.testing.io);
        try harness.agent.appendUserMessage("Do the task");
        break :blk harness.agent.runToolLoop(null);
    };
    try std.testing.expectError(error.ResponseTruncated, outcome);

    try std.testing.expectEqual(max_continuations + 1, mock.budgets.items.len);
    // The fragments become one assistant answer, and the prompts that asked
    // for them are gone, so the next request sees a proper conversation.
    try std.testing.expectEqual(@as(usize, 3), harness.agent.history.items.len);
    const answer = harness.agent.history.items[2].content.?;
    try std.testing.expectEqual(@as(usize, (max_continuations + 1) * "Half an ".len), answer.len);
    for (0..max_continuations + 1) |index| {
        try std.testing.expectEqualStrings("Half an ", answer[index * "Half an ".len ..][0.."Half an ".len]);
    }
}
