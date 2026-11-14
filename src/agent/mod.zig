const std = @import("std");
const openai = @import("../model/openai.zig");
const trace_mod = @import("../debug/trace.zig");
const tools = @import("../tools/mod.zig");
const sanitize = @import("../util/terminal/sanitize.zig");
const menu = @import("../ui/menu.zig");
const memory_mod = @import("../state/memory.zig");
const plan_mod = @import("../state/plan.zig");
const mcp = @import("../mcp/mod.zig");
const scratch_mod = @import("../state/scratch.zig");
const sysinfo = @import("../host/sysinfo.zig");
const render = @import("../ui/render.zig");
const layout = @import("../ui/layout.zig");
const term = @import("../ui/term.zig");
const spinner = @import("../ui/spinner.zig");
const Screen = @import("../ui/screen.zig").Screen;
const ScreenLogWriter = @import("../ui/screen.zig").LogWriter;
const Config = @import("../model/config.zig").Config;
const Linenoise = @import("../editor/linenoise.zig").Linenoise;

const Message = openai.Message;
const ToolCallData = openai.ToolCallData;

// ANSI colour codes
const sgr = @import("../ui/style.zig");
const RESET = sgr.RESET;
const BOLD = sgr.BOLD;
const DIM = sgr.DIM;
const CYAN = sgr.CYAN;
const GREEN = sgr.GREEN;
const YELLOW = sgr.YELLOW;
const RED = sgr.RED;

// The instructions a run starts with, and the limits around them, live in
// prompt.zig; the loop below uses them by their own names.
const agent_prompt = @import("prompt.zig");
const subagent = @import("subagent.zig");
const max_continuations = agent_prompt.max_continuations;
const max_empty_continuations = agent_prompt.max_empty_continuations;
const continue_prompt = agent_prompt.continue_prompt;
const restart_prompt = agent_prompt.restart_prompt;
const steering_note = agent_prompt.steering_note;
const CHOICE_PROMPT = agent_prompt.CHOICE_PROMPT;
const error_preview_max = agent_prompt.error_preview_max;
const self_check_prompt = agent_prompt.self_check_prompt;
const deadline_prompt = agent_prompt.deadline_prompt;
const subagent_deadline_grace_seconds = agent_prompt.subagent_deadline_grace_seconds;
/// How long the waiting caller sleeps between looks at its own clocks. The
/// same order as the supervisor's own poll: these are status checks, not work.
const subagent_poll_ms: i64 = 100;
const main_omitted = agent_prompt.main_omitted;
const buildSystemPrompt = agent_prompt.buildSystemPrompt;
const buildSubagentPrompt = agent_prompt.buildSubagentPrompt;
const subagent_omitted = agent_prompt.subagent_omitted;

/// The lines a terminal sees of one tool result: the status on the first line
/// under the call — `✓`, `✗`, and how the call ended where the result says
/// so — then the result on the line after it, at the column where that status
/// line's own text would have started. A result that printed nothing is its
/// status line, not a status and a blank line beneath it.
fn writeResultPreview(w: *std.Io.Writer, body: []const u8, status: tools.ToolResult) std.Io.Writer.Error!void {
    try w.writeAll(if (status.is_error) RED ++ layout.indent ++ "✗" else DIM ++ layout.indent ++ "✓");
    // The way the call ended belongs on the status line, next to the glyph that
    // already says whether it succeeded: a timeout, a killed program and a
    // failed one all read as `✗`, and how it ended is the part nobody can guess.
    if (status.timed_out) {
        try w.writeAll(" timed out");
    } else if (status.exit_code) |code| {
        try w.print(" exit {d}", .{code});
    } else if (status.termination) |termination| {
        try w.print(" {s}", .{termination});
    }
    if (body.len > 0) {
        try w.writeByte('\n');
        try layout.writeBlock(w, body, layout.after_glyph, layout.after_glyph);
    }
    try w.writeAll("\n" ++ RESET);
}

pub const Agent = struct {
    interrupted: std.atomic.Value(bool) = .init(false),
    allocator: std.mem.Allocator,
    io: std.Io,
    client: openai.Client,
    history: std.ArrayList(Message),
    /// The terminal ask_user and the choice menus read from.
    linenoise: *Linenoise,
    form_context: ?*anyopaque = null,
    /// Who puts a form of questions to the user. The full-screen runtime owns
    /// the keyboard, so it presents the form instead of the terminal below.
    form_callback: ?*const fn (?*anyopaque, []menu.Slot) anyerror!menu.Replies = null,
    /// Which search programs the machine has. Decided once, in `init`, for the
    /// same reason as `render_markdown`: a search should not have to ask the
    /// filesystem a question whose answer cannot change while the agent runs.
    search: tools.SearchBackends,
    tool_env: *const std.process.Environ.Map,
    session_path: ?[]u8,
    session_id: ?[]u8 = null,
    child_record: ?@import("../state/session.zig").Child = null,
    /// The working directory commands run in, named in the system prompt.
    workspace: [:0]u8,
    /// What machine this run is on: the OS and its version, the kernel, the
    /// architecture, the CPUs and the memory, read once in `init` and named in
    /// the system prompt. A sub-agent inherits it from the agent that called
    /// it, which works on the same machine.
    host: sysinfo.Info,
    /// The private scratch directory this run owns, named in the system prompt.
    /// Created once, at startup, so concurrent agents never share one path and
    /// the model never has to ask for a place to work. Not a sandbox, and not
    /// durable: a new session empties it and the process removes it on exit.
    scratch: scratch_mod.Scratch,
    /// Durable notes loaded at startup and updated by the memory_save tool.
    memory: memory_mod.Memory,
    /// The checklist of the work in progress. It lives in memory, is changed by
    /// the plan tool and `/plan`, and is saved with the session rather than in
    /// a file of its own. Named in the system prompt, which is rebuilt whenever
    /// it changes rather than fixed at startup.
    plan: plan_mod.Plan,
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
    /// The settings this agent was built from, borrowed: the agent that owns
    /// them outlives every agent started from it. A sub-agent starts from the
    /// same provider, model and key as the one that called it.
    config: *const Config,
    /// Whether this agent is the one on the terminal, or one a tool call
    /// started. A sub-agent has no terminal or plan; durable parents give it a child session.
    role: Role = .main,
    /// The agent that started this one. Its interrupt flag is checked too, so
    /// Esc stops the whole tree rather than the outer turn alone.
    parent: ?*Agent = null,
    /// Where a sub-agent's answer is collected instead of printed. Null for the
    /// agent on the terminal, which has a user to answer.
    capture: ?*std.ArrayList(u8) = null,
    /// Where the report of this turn starts in `capture`. The commentary that
    /// precedes a round of tool calls is not part of it: only the reply that
    /// stands on the finished work is.
    capture_mark: usize = 0,
    /// What this sub-agent shares with its caller: the self-check it is asked
    /// for, the deadline it must meet. Null for the agent on the terminal, which
    /// has nobody to check in with.
    supervisor: ?*subagent.Supervisor = null,
    /// The sub-agents this agent started and has not closed. A run that has
    /// reported back is paused, not finished: it stays here until the model
    /// resumes or stops it, and `deinit` closes whatever is left over.
    runs: std.ArrayList(*Run) = .empty,
    run_counter: usize = 0,
    /// The task the model last announced, named in the terminal title. It is
    /// kept across turns on purpose: a follow-up that announces no task of its
    /// own still belongs to the work the title names, and dropping it at the
    /// next prompt would leave the title with nothing to show.
    current_task: []const u8 = "",
    query_started: ?std.Io.Timestamp = null,
    progress_prompt: ?[]const u8 = null,
    /// The terminal's part in the tool call being answered. It is filled in by
    /// the dispatch hooks below, which is where the host UI's work for a call
    /// happens, and read back by whoever previews the result.
    tool_ui: ToolUi,
    /// Lines the user typed while this task was running. They are not a new
    /// task: the worker drains them at its next request boundary and sends
    /// them to the model inside the work in progress. The terminal thread
    /// appends and the worker swaps the whole list out, so the mutex only
    /// ever guards that hand-over.
    inbox: std.ArrayList([]u8) = .empty,
    inbox_mutex: std.Io.Mutex = .init,
    /// Where the conversation is drawn when the interactive session owns the
    /// screen. Null for a single query: answers then go straight to stdout, so
    /// `zagent "q" > notes.md` stays clean.
    screen: ?*Screen = null,
    /// What the model is thinking while it thinks it. The reasoning is shown in
    /// a panel above the prompt; only its duration stays in the status bar.
    thinking: Thinking = .{},
    /// The MCP servers and the tools they brought. Borrowed rather than owned:
    /// whoever started the agent outlives it, and the agent only reads this and
    /// calls through it.
    mcp_registry: *mcp.Registry,
    /// Where a `--debug` run records what this agent did. Null otherwise, and
    /// borrowed when set: the run that opened the trace outlives the agent and
    /// renders the report from it.
    trace: ?*trace_mod.Recorder = null,
    /// Who this agent is in the record. The agent on the terminal is "main";
    /// each sub-agent is named after the run that started it.
    trace_agent: []const u8 = "main",
    /// The name above when this agent had to make one, freed with it.
    trace_agent_owned: ?[]u8 = null,
    /// Which request of the turn is in flight, numbered from one.
    trace_iteration: usize = 0,

    pub const Role = enum {
        /// The agent a person talks to: it owns the terminal, the session and
        /// the plan.
        main,
        /// An agent a tool call started for one task. It reports back through
        /// its caller instead of printing, with a child session when the parent is durable.
        subagent,
    };

    const InitOptions = struct {
        role: Role = .main,
        /// The agent that starts this one, for a sub-agent. It lends the
        /// working directory, the search programs and the interrupt flag, and
        /// it must outlive the agent it starts.
        parent: ?*Agent = null,
        /// Where a sub-agent's answer goes.
        capture: ?*std.ArrayList(u8) = null,
        /// What this child shares with its caller. The run that starts the
        /// child owns it and outlives the child.
        supervisor: ?*subagent.Supervisor = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: *const Config,
        linenoise: *Linenoise,
        env: *const std.process.Environ.Map,
        mcp_registry: *mcp.Registry,
    ) !Agent {
        return initWith(allocator, io, config, linenoise, env, mcp_registry, .{});
    }

    fn initWith(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: *const Config,
        linenoise: *Linenoise,
        env: *const std.process.Environ.Map,
        mcp_registry: *mcp.Registry,
        options: InitOptions,
    ) !Agent {
        var history: std.ArrayList(Message) = .empty;
        errdefer history.deinit(allocator);

        var memory = try memory_mod.Memory.init(allocator, io, env);
        errdefer memory.deinit();

        // An empty plan: this process has no session yet, and whichever one
        // `startSession` opens brings its own checklist with it.
        var plan = plan_mod.Plan.init(allocator);
        errdefer plan.deinit();

        // A sub-agent works on the same machine as the agent that called it, so
        // it is told about the same search programs rather than looking again.
        const parent = options.parent;
        const search = if (parent) |p| p.search else tools.detectSearchBackends(io, env);
        var client = openai.Client.init(allocator, io, config.*);
        client.search = search;
        // Each role is described by the few tools it does not get: the caller
        // has no report to hand in, and a sub-agent has neither the call that
        // started it nor the one that stops it.
        client.builtin_omit = switch (options.role) {
            .main => &main_omitted,
            .subagent => &subagent_omitted,
        };
        // A test transport is the one thing a sub-agent inherits that is not
        // settings: the loop is driven without a socket, so the requests the
        // sub-agent makes are scripted by the same test.
        if (parent) |p| client.transport = p.client.transport;
        // A debug run writes the whole tree into one file: a sub-agent records
        // into the trace its caller holds, under its own name.
        if (parent) |p| client.trace = p.client.trace;
        const workspace: [:0]u8 = if (parent) |p|
            try allocator.dupeSentinel(u8, p.workspace, 0)
        else
            try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(workspace);
        // The machine, read once: like the search programs above, its answer
        // cannot change while the process runs, and a sub-agent works on the
        // same one, so it inherits the parent's facts instead of asking again.
        var host = if (parent) |p| try p.host.clone(allocator) else try sysinfo.Info.read(allocator, io);
        errdefer host.deinit(allocator);
        var scratch = try scratch_mod.Scratch.init(io, allocator, env);
        errdefer scratch.deinit(allocator);
        const system_content = switch (options.role) {
            .main => try buildSystemPrompt(allocator, mcp_registry, memory.enabled, search, &host, workspace, scratch.path),
            .subagent => try buildSubagentPrompt(allocator, mcp_registry, memory.enabled, search, &host, workspace, scratch.path),
        };
        errdefer allocator.free(system_content);
        try history.append(allocator, .{
            .role = "system",
            .content = system_content,
            .reasoning_content = null,
            .tool_calls = null,
            .tool_call_id = null,
        });

        // Only the agent a person talks to has a terminal to write on, a
        // session to record, and a plan of its own. A sub-agent reports back
        // through the tool result and leaves all three to its caller.
        const interactive = options.role == .main;
        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .history = history,
            .linenoise = linenoise,
            .search = search,
            .tool_env = env,
            .host = host,
            .tool_ui = .{ .spinner = spinner.Spinner.disabled(io), .label = .init(allocator) },
            .session_path = null,
            .workspace = workspace,
            .scratch = scratch,
            .memory = memory,
            .plan = plan,
            .config = config,
            .role = options.role,
            .parent = options.parent,
            .capture = options.capture,
            .supervisor = options.supervisor,
            // The check is on stdout rather than on `linenoise.is_tty`, which
            // describes stdin: `zagent "q" < file` with a terminal on stdout
            // should still render, and `zagent "q" | less` must not.
            .render_markdown = interactive and linenoise.term_supported and
                (std.Io.File.stdout().isTty(io) catch false),
            // stderr as well as stdout, unlike the renderer: the animation is
            // written to stderr, and a run whose stdout is a file or a pager is
            // one where the terminal belongs to something else.
            .animate_progress = interactive and linenoise.term_supported and
                (std.Io.File.stdout().isTty(io) catch false) and
                (std.Io.File.stderr().isTty(io) catch false),
            .mcp_registry = mcp_registry,
            .trace = if (parent) |p| p.trace else null,
            .terminal_title = term.Title.init(io, interactive and linenoise.term_supported),
        };
    }

    pub fn deinit(self: *Agent) void {
        // A sub-agent still running would keep its task alive for the life of
        // the process: the caller that was watching it is gone.
        // Whatever is still open is closed here, before anything it borrows.
        self.closeRuns();
        self.tool_ui.spinner.stop();
        self.tool_ui.label.deinit();
        self.runs.deinit(self.allocator);
        if (self.current_task.len > 0) self.allocator.free(self.current_task);
        if (self.trace_agent_owned) |label| self.allocator.free(label);
        for (self.inbox.items) |line| self.allocator.free(line);
        self.inbox.deinit(self.allocator);
        self.host.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.allocator.free(self.workspace);
        self.terminal_title.deinit();
        for (self.history.items) |msg| msg.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.client.deinit();
        self.memory.deinit();
        self.plan.deinit();
        if (self.session_path) |path| self.allocator.free(path);
        if (self.session_id) |id| self.allocator.free(id);
    }

    /// Draw the conversation on `screen` instead of on the files the progress
    /// lines normally use.
    pub fn attachScreen(self: *Agent, screen: ?*Screen) void {
        self.screen = screen;
    }

    /// Record this agent's steps from here on. Called once the session exists,
    /// because the trace is named after it, and by `/debug` when a run that
    /// started without one turns tracing on mid-session.
    pub fn attachTrace(self: *Agent, trace: ?*trace_mod.Recorder) void {
        self.trace = trace;
        self.client.trace = trace;
        self.client.trace_ctx = self.traceCtx();
        const opened = trace orelse return;
        // Only the agent on the terminal describes the run: a sub-agent's
        // events are steps inside it, not another run.
        if (self.role != .main) return;
        opened.run(.{
            .session = self.session_id orelse "",
            .workspace = self.workspace,
            .scratch = self.scratch.path,
            .model = self.config.model,
            .provider = if (self.config.provider) |selected| selected.name() else "",
            .base_url = self.config.base_url,
            .max_tokens = self.config.max_tokens,
        });
    }

    /// Which agent and which request a step belongs to, as the trace records it.
    fn traceCtx(self: *Agent) trace_mod.Ctx {
        return .{ .agent = self.trace_agent, .iteration = self.trace_iteration };
    }

    /// One status or answer line: into the conversation when a screen owns it,
    /// and to `file` otherwise. The file still matters for a redirected run,
    /// where stdout belongs to another program and stderr carries progress.
    fn emit(self: *Agent, file: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
        if (self.capture) |_| {
            // A sub-agent has no terminal. Text meant for the conversation is
            // kept for its report; its progress is nobody's business but its
            // own, and the caller prints a line for the call already.
            if (file.handle != std.Io.File.stdout().handle) return;
            const message = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(message);
            return self.writeLogOrStdout(message);
        }
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
        // The ids of the runs this conversation started do not survive it. A
        // paused child would sit there until the process ended, unreachable
        // from a conversation that no longer names it.
        self.closeRuns();
        for (self.history.items[1..]) |msg| msg.deinit(self.allocator);
        self.history.shrinkRetainingCapacity(1);
        self.checkpoint() catch {};
    }

    /// Switch only after the new snapshot has been created or fully validated.
    pub fn startSession(self: *Agent, resume_id: ?[]const u8) !void {
        const session = @import("../state/session.zig");
        const id = if (resume_id) |value| try self.allocator.dupe(u8, value) else try session.newId(self.io, self.allocator);
        errdefer self.allocator.free(id);
        try session.validateId(id);
        const relative = try std.fmt.allocPrint(self.allocator, "sessions/{s}.json", .{id});
        defer self.allocator.free(relative);
        const path = try @import("../state/workspace.zig").filePath(self.allocator, self.io, self.tool_env, relative);
        errdefer self.allocator.free(path);
        var loaded: session.Loaded = undefined;
        if (resume_id != null) {
            try std.Io.Dir.cwd().access(self.io, path, .{});
            loaded = try session.load(self.io, self.allocator, path);
        } else {
            // A new session starts without a plan: the checklist belongs to
            // the session the work was done in, not to this process.
            loaded = .{ .messages = .empty, .plan = plan_mod.Plan.init(self.allocator) };
            session.save(self.io, self.allocator, path, &.{}, &loaded.plan) catch |err| {
                loaded.deinit(self.allocator);
                return err;
            };
        }
        defer loaded.deinit(self.allocator);
        try self.history.ensureTotalCapacity(self.allocator, loaded.messages.items.len + 1);
        self.closeRuns();
        // The system prompt names this process's working and scratch
        // directories, so switching sessions replaces the messages only.
        for (self.history.items[1..]) |message| message.deinit(self.allocator);
        self.history.shrinkRetainingCapacity(1);
        self.history.appendSliceAssumeCapacity(loaded.messages.items);
        loaded.messages.clearRetainingCapacity();
        // The plan of the session just opened replaces this process's; the old
        // one goes into `loaded` and is freed with it.
        std.mem.swap(plan_mod.Plan, &self.plan, &loaded.plan);
        if (self.session_path) |old| self.allocator.free(old);
        if (self.session_id) |old| self.allocator.free(old);
        self.session_path = path;
        self.session_id = id;
        self.client.resetTokenCounters();
        // Another session is another piece of work: the task the old one
        // announced says nothing about this one.
        self.forgetTask();
    }

    /// Drop the title's task label, leaving the activity to speak for itself.
    fn forgetTask(self: *Agent) void {
        if (self.current_task.len > 0) self.allocator.free(self.current_task);
        self.current_task = "";
        self.terminal_title.update("ready", "");
    }

    /// Restore the visible conversation from the saved messages, without
    /// dispatching tools or changing the model history/checkpoint.
    pub fn replayHistory(self: *Agent) !void {
        if (self.history.items.len <= 1) return;
        try self.emit(std.Io.File.stdout(), DIM ++ "  ── Restored session history ──\n" ++ RESET, .{});
        for (self.history.items[1..]) |message| {
            if (std.mem.eql(u8, message.role, "user")) {
                if (message.content) |content| {
                    var aw: std.Io.Writer.Allocating = .init(self.allocator);
                    defer aw.deinit();
                    try aw.writer.writeAll("\n" ++ BOLD ++ GREEN ++ "❯" ++ RESET ++ " ");
                    try sanitize.writeSanitized(&aw.writer, content);
                    try aw.writer.writeByte('\n');
                    try self.writeLogOrStdout(aw.written());
                }
            } else if (std.mem.eql(u8, message.role, "assistant")) {
                if (message.content) |content| {
                    if (content.len > 0) {
                        try self.answerHeader();
                        try self.writeAnswer(content);
                        try self.answerTrailer();
                    }
                }
                if (message.tool_calls) |calls| {
                    for (calls) |call| try self.announceToolCall(call.name, call.arguments);
                }
            } else if (std.mem.eql(u8, message.role, "tool")) {
                if (message.tool_result) |result| {
                    try self.previewToolResult(result.output, result, false);
                }
            }
        }
        try self.emit(std.Io.File.stdout(), DIM ++ "  ── End of restored history ──\n\n" ++ RESET, .{});
    }

    fn checkpoint(self: *Agent) !void {
        if (self.session_path) |path| try @import("../state/session.zig").saveChild(self.io, self.allocator, path, self.history.items[1..], &self.plan, self.child_record);
    }

    /// `/memory`: list what is saved, newest last.
    pub fn listMemory(self: *Agent) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try self.memory.writeList(&aw.writer);
        try self.writeBlock(aw.written());
    }

    /// `/remember <text>`: save a note by hand, as the model's memory_save tool
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
        try self.emit(std.Io.File.stderr(), DIM ++ "  ✓ forgot memory {d}\n" ++ RESET, .{number});
    }

    /// `/plan`: show the checklist, or `/plan clear` to drop it.
    pub fn planCommand(self: *Agent, argument: []const u8) !void {
        const arg = std.mem.trim(u8, argument, " \t");
        if (arg.len == 0) {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            try self.plan.writeChecklist(&aw.writer);
            return self.writeBlock(aw.written());
        }
        if (!std.ascii.eqlIgnoreCase(arg, "clear")) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  usage: /plan [clear]\n" ++ RESET, .{});
            return;
        }
        if (self.plan.steps.items.len == 0) {
            try self.emit(std.Io.File.stderr(), DIM ++ "  no plan to clear\n" ++ RESET, .{});
            return;
        }
        self.plan.clear();
        // The session snapshot is where the plan lives once this process is
        // gone, so a cleared plan is saved before the command reports success.
        self.checkpoint() catch |err| {
            try self.emit(std.Io.File.stderr(), RED ++ "  ✗ plan cleared, but the session was not saved: {s}\n" ++ RESET, .{@errorName(err)});
            return;
        };
        try self.emit(std.Io.File.stderr(), DIM ++ "  ✓ plan cleared\n" ++ RESET, .{});
    }

    /// Settle unanswered calls after an interrupted query.
    /// Called only after the worker has joined. Preserve completed tool results
    /// and explicitly settle any calls that cancellation left unanswered.
    pub fn finishInterruption(self: *Agent) !void {
        var index = self.history.items.len;
        while (index > 0) {
            index -= 1;
            const calls = self.history.items[index].tool_calls orelse continue;
            for (calls) |call| {
                var answered = false;
                for (self.history.items[index + 1 ..]) |message| {
                    if (message.tool_call_id) |id| {
                        if (std.mem.eql(u8, id, call.id)) answered = true;
                    }
                }
                if (answered) continue;
                const content = try self.allocator.dupe(u8, "Task interrupted by user. Execution may have partially completed; inspect actual state before retrying.");
                errdefer self.allocator.free(content);
                const id = try self.allocator.dupe(u8, call.id);
                errdefer self.allocator.free(id);
                try self.history.append(self.allocator, .{
                    .role = "tool",
                    .content = null,
                    .tool_result = .{ .output = content, .is_error = true },
                    .tool_call_id = id,
                    .reasoning_content = null,
                    .tool_calls = null,
                });
            }
            break;
        }
        // The work was stopped, so nothing of it stays on the screen waiting
        // out the panel's delay.
        self.thinking.close(self);
        self.terminal_title.update("ready", self.current_task);
        try self.checkpoint();
    }

    fn checkInterrupted(self: *Agent) !void {
        if (self.interrupted.load(.acquire)) return error.Canceled;
        // Esc belongs to the whole tree: the user stopped the work, not the
        // outer turn alone, and a sub-agent that kept going would edit files
        // after a task was called off.
        if (self.parent) |parent| {
            if (parent.interrupted.load(.acquire)) return error.Canceled;
        }
    }

    /// Hand a line the user typed during a running task to that task. The
    /// worker sends it with its next request, so the instruction reaches the
    /// model now instead of queueing behind the answer it belongs to.
    pub fn steer(self: *Agent, line: []const u8) !void {
        const owned = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(owned);
        // Appended under the lock so a drain cannot miss the allocation.
        self.inbox_mutex.lockUncancelable(self.io);
        defer self.inbox_mutex.unlock(self.io);
        try self.inbox.append(self.allocator, owned);
    }

    /// Move the lines typed during the task into `into`, for a caller with no
    /// request left to send them with. Ownership of the lines passes over.
    pub fn takeSteering(self: *Agent, into: *std.ArrayList([]u8)) !void {
        var lines = self.claimInbox();
        defer lines.deinit(self.allocator);
        var moved: usize = 0;
        errdefer for (lines.items[moved..]) |line| self.allocator.free(line);
        for (lines.items) |line| {
            try into.append(self.allocator, line);
            moved += 1;
        }
    }

    /// Throw away guidance no request will carry: Esc drops it with the task.
    pub fn clearSteering(self: *Agent) void {
        var lines = self.claimInbox();
        defer lines.deinit(self.allocator);
        for (lines.items) |line| self.allocator.free(line);
    }

    /// Take the whole inbox, leaving an empty one behind. The list that comes
    /// back is the caller's to free.
    fn claimInbox(self: *Agent) std.ArrayList([]u8) {
        self.inbox_mutex.lockUncancelable(self.io);
        defer self.inbox_mutex.unlock(self.io);
        const lines = self.inbox;
        self.inbox = .empty;
        return lines;
    }

    /// Put what the user typed during the task into the conversation, so the
    /// next request carries it. Returns false when nothing arrived.
    ///
    /// Holding it back until a request boundary is the point: a request in
    /// flight cannot take new input, and a line that cut it short would throw
    /// away work the user asked for. The answer that is already streaming
    /// finishes, and the guidance redirects the request after it.
    fn injectSteering(self: *Agent) !bool {
        var lines = self.claimInbox();
        defer {
            for (lines.items) |line| self.allocator.free(line);
            lines.deinit(self.allocator);
        }
        if (lines.items.len == 0) return false;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try aw.writer.writeAll(steering_note);
        try aw.writer.writeAll("\n\n");
        for (lines.items, 0..) |line, index| {
            if (index > 0) try aw.writer.writeByte('\n');
            try sanitize.writeSanitized(&aw.writer, line);
        }

        try self.appendUserMessage(aw.written());
        try self.emit(std.Io.File.stderr(), DIM ++ "  ↳ guidance from the terminal added to this task\n" ++ RESET, .{});
        if (self.trace) |trace| trace.note(self.traceCtx(), "info", "guidance typed while the task ran was added to this request");
        try self.checkpoint();
        return true;
    }

    pub fn processQuery(self: *Agent, query: []const u8) !void {
        self.query_started = std.Io.Timestamp.now(self.io, .awake);
        defer self.query_started = null;
        self.client.resetTokenCounters();
        if (self.screen) |screen| screen.clearThinkingSummary();
        // Raw user input is never a terminal title, and the task last
        // announced stays until the model announces a new one: the title
        // describes the work in progress, not the line that started it.
        self.terminal_title.update("thinking…", self.current_task);
        self.processQueryInner(query) catch |err| {
            self.terminal_title.update("error", self.current_task);
            return err;
        };
        self.terminal_title.update("ready", self.current_task);
        const elapsed_ms = self.query_started.?.untilNow(self.io, .awake).toMilliseconds();
        const counts = self.client.tokenCounts();
        try self.emit(std.Io.File.stderr(), DIM ++ "  Worked for {d}.{d}s · in {d} (cached {d}, {s}; cache reports {d}/{d}) · out {d} (reasoning {d}) · total {d} tokens · usage {d}/{d} calls\n" ++ RESET, .{
            @divTrunc(elapsed_ms, 1000),
            @divTrunc(@mod(elapsed_ms, 1000), 100),
            counts.input,
            counts.cached,
            if (counts.cache_usage_reports == 0) "unknown" else if (counts.cache_usage_reports < counts.requests) "partial" else "reported",
            counts.cache_usage_reports,
            counts.requests,
            counts.output,
            counts.reasoning,
            counts.total,
            counts.usage_reports,
            counts.requests,
        });
        try self.checkInterrupted();
        // The final answer settles the turn; its text is not a status protocol.
        try self.emit(std.Io.File.stderr(), BOLD ++ GREEN ++ "  ✓ Turn finished" ++ RESET ++ "\n", .{});
    }

    fn progressOptions(self: *Agent) spinner.Options {
        return .{
            .enabled = self.animate_progress,
            .screen = if (self.form_callback != null) self.screen else null,
            .started = self.query_started,
            .prompt = self.progress_prompt,
            .first_frame_delay_ms = 0,
            .in_tokens = &self.client.input_tokens,
            .out_tokens = &self.client.output_tokens,
        };
    }

    /// Start one sub-agent and the task that runs it. The run owns the child,
    /// what the two sides share, and the buffer the child answers into; the
    /// caller of `subagent` only ever holds it by its id.
    ///
    /// `title` is the summary the terminal names the run with, and may be
    /// empty: a run without one is named by its task on the lines that would
    /// have shown it.
    pub fn startRun(self: *Agent, task: []const u8, context: []const u8, title: []const u8, self_check_seconds: u32) !*Run {
        return self.createRun(task, context, title, self_check_seconds, null);
    }

    pub fn restoreRun(self: *Agent, id: []const u8, self_check_seconds: u32) !*Run {
        if (id.len < 2 or id[0] != 's') return error.InvalidSessionId;
        _ = try std.fmt.parseInt(usize, id[1..], 10);
        return self.createRun("", "", "", self_check_seconds, id);
    }

    fn createRun(self: *Agent, task: []const u8, context: []const u8, title: []const u8, self_check_seconds: u32, restore_id: ?[]const u8) !*Run {
        const session = @import("../state/session.zig");
        const run = try self.allocator.create(Run);
        errdefer self.allocator.destroy(run);
        // Reserve ids against durable children, including completed ones.
        while (true) {
            self.run_counter += 1;
            const parent_path = self.session_path orelse break;
            const candidate = try std.fmt.allocPrint(self.allocator, "{s}.s{d}.json", .{ parent_path, self.run_counter });
            defer self.allocator.free(candidate);
            std.Io.Dir.cwd().access(self.io, candidate, .{}) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
        }
        const id = if (restore_id) |value| try self.allocator.dupe(u8, value) else try std.fmt.allocPrint(self.allocator, "s{d}", .{self.run_counter});
        errdefer self.allocator.free(id);
        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(run.title);
        run.* = .{
            .id = id,
            .title = owned_title,
            .child = undefined,
            .supervisor = subagent.Supervisor.init(self.io, self.allocator),
            .started = std.Io.Timestamp.now(self.io, .awake),
        };
        errdefer run.supervisor.deinit();

        const child = try self.allocator.create(Agent);
        errdefer self.allocator.destroy(child);
        child.* = try Agent.initWith(self.allocator, self.io, self.config, self.linenoise, self.tool_env, self.mcp_registry, .{
            .role = .subagent,
            .parent = self,
            .capture = &run.capture,
            .supervisor = &run.supervisor,
        });
        errdefer child.deinit();
        // Named in the record after the run the caller watches: two sub-agents
        // interleave their steps in one trace, and the name is how a reader
        // tells which one a request belongs to. Only a debug run pays for it.
        if (child.trace != null) {
            child.trace_agent_owned = try std.fmt.allocPrint(self.allocator, "subagent {s}", .{run.id});
            child.trace_agent = child.trace_agent_owned.?;
        }
        run.child = child;
        if (self.session_path) |parent_path| {
            child.session_path = try std.fmt.allocPrint(self.allocator, "{s}.{s}.json", .{ parent_path, id });
            child.child_record = .{ .parent = self.session_id orelse "", .id = id, .title = run.title };
        }
        var continuation: []const u8 = task;
        if (restore_id != null) {
            const path = child.session_path orelse return error.NoSession;
            try std.Io.Dir.cwd().access(self.io, path, .{});
            var loaded = try session.load(self.io, self.allocator, path);
            defer loaded.deinit(self.allocator);
            const record = loaded.child orelse return error.InvalidSessionId;
            continuation = switch (record.status) {
                .completed => "The caller explicitly requested continuation of this completed task. Continue from saved history; do not repeat already completed work unless needed for the follow-up.",
                .failed => "The caller requested continuation of this failed task. Review the saved failure and history before proceeding. Unconfirmed tool outcomes are unknown; inspect before retrying side effects.",
                .running, .interrupted => "The process restarted: this task was interrupted. Continue from saved history. Unconfirmed tool outcomes are unknown; inspect before retrying any side effects.",
            };
            if (!std.mem.eql(u8, record.parent, self.session_id orelse "") or !std.mem.eql(u8, record.id, id)) return error.InvalidSessionId;
            const restored_title = try self.allocator.dupe(u8, record.title);
            self.allocator.free(run.title);
            run.title = restored_title;
            child.child_record.?.title = run.title;
            try child.history.appendSlice(self.allocator, loaded.messages.items);
            loaded.messages.clearRetainingCapacity();
        }
        // The two ways a run stops for a reason other than its caller's
        // deadline: this process asking for the task to stop, and the child
        // itself being told to.
        run.supervisor.canceled = &child.interrupted;
        run.supervisor.caller_canceled = &self.interrupted;

        var prompt: std.ArrayList(u8) = .empty;
        errdefer prompt.deinit(self.allocator);
        try prompt.appendSlice(self.allocator, continuation);
        if (context.len > 0) {
            try prompt.appendSlice(self.allocator, "\n\nWhat the agent that asked you already knows:\n");
            try prompt.appendSlice(self.allocator, context);
        }

        const owned_prompt = try prompt.toOwnedSlice(self.allocator);
        // Taken out of the list above, so it owns itself until the task does.
        errdefer self.allocator.free(owned_prompt);
        // A self-check of zero means the child's first boundary: asking before
        // the task starts is what makes that the first request rather than
        // whichever one the child happens to reach next.
        if (self_check_seconds == 0) run.supervisor.requestProgress();
        // In the list before the task starts: once the child is running, only
        // `closeRun` may free what it is using, and a failure below must not
        // leave a live task pointing at freed memory.
        try self.runs.append(self.allocator, run);
        run.future = self.io.concurrent(childTurn, .{ child, &run.supervisor, owned_prompt }) catch |err| {
            _ = self.runs.pop();
            return err;
        };
        return run;
    }

    /// Watch the run until it ends, on the two clocks its caller set, and make
    /// its final report the tool result.
    ///
    /// Every `self_check_seconds` the child is asked for a self-check, and what
    /// it answers is printed on the terminal: the model that started the run
    /// reads none of it, which is what makes the whole call one wait. At
    /// `deadline_seconds` the child is told to stop working and write its final
    /// report; the grace after that is for that report, not for more work, and
    /// a child that misses it is stopped where it stands.
    ///
    /// A command that is already running is never cut short, because a report
    /// that claims a check it did not finish is worse than a report that
    /// arrives late.
    pub fn waitRun(self: *Agent, run: *Run, self_check_seconds: u32, deadline_seconds: u32) anyerror!tools.ToolResult {
        const interval_ms: i64 = @as(i64, @intCast(self_check_seconds)) * std.time.ms_per_s;
        const deadline_at = inMs(run.started, @as(i64, @intCast(deadline_seconds)) * std.time.ms_per_s);
        var check_at = inMs(run.started, interval_ms);
        // Set once the deadline has been passed on to the child: the run is over
        // from there, and `cut_at` is when the report it was asked for is given
        // up on.
        var deadline_sent = false;
        var cut_at: ?std.Io.Timestamp = null;
        while (true) {
            const wake = run.supervisor.wait(nextWake(check_at, deadline_at, cut_at)) catch |err| {
                // Esc while the caller was waiting: nobody owns the child any
                // more, and a child that kept going would edit files after a
                // task was called off.
                self.abortRun(run);
                return err;
            };
            switch (wake) {
                .progress => |report| {
                    defer self.allocator.free(report);
                    try self.showSelfCheck(run, report);
                    // A self-check the caller asked to be due at once is asked
                    // for at once: with an interval of zero the child is
                    // checked at its next boundary, and waiting for the next
                    // look at the clock would make that the one after it.
                    if (interval_ms == 0) run.supervisor.requestProgress();
                    check_at = inMsNow(self.io, @max(interval_ms, subagent_poll_ms));
                },
                .done => return self.finishRun(run, if (deadline_sent)
                    "Sub-agent reached its deadline and stopped. Its final report — what is done and what is left undone. Verify it before marking a plan step done:"
                else
                    "Sub-agent report — verify it before marking a plan step done:"),
                .failed => |failure| return self.failRun(run, failure),
                .timeout => {
                    const now = std.Io.Timestamp.now(self.io, .awake);
                    if (cut_at) |cut| {
                        // The deadline stands until the run ends: a child that
                        // answered it with more work instead of its report is
                        // told again at the boundary after that.
                        run.supervisor.setDeadline();
                        if (cut.untilNow(self.io, .awake).nanoseconds >= 0) return self.cutRun(run);
                        continue;
                    }
                    if (deadline_at.untilNow(self.io, .awake).nanoseconds >= 0) {
                        deadline_sent = true;
                        run.supervisor.setDeadline();
                        cut_at = inMs(now, @as(i64, subagent_deadline_grace_seconds) * std.time.ms_per_s);
                        continue;
                    }
                    if (check_at.untilNow(self.io, .awake).nanoseconds >= 0) {
                        // Asked for once: a request the child has not reached a
                        // boundary for yet is the one it will see, and asking
                        // again on every poll would only set the same flag.
                        if (!run.supervisor.progressPending()) run.supervisor.requestProgress();
                        check_at = inMsNow(self.io, @max(interval_ms, subagent_poll_ms));
                    }
                },
            }
        }
    }

    /// Show a sub-agent's self-check on the terminal.
    ///
    /// It is the caller's line and the caller's terminal: the child's own
    /// output is captured, so this is the only place its progress is read. The
    /// animation the call owns is given the line back for it and taken again
    /// afterwards, because a frame drawn over the report would erase it.
    fn showSelfCheck(self: *Agent, run: *Run, report: []const u8) !void {
        self.tool_ui.spinner.stop();
        defer self.resumeCallProgress();
        const elapsed_s = @divTrunc(run.started.untilNow(self.io, .awake).toMilliseconds(), std.time.ms_per_s);
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        try line.writer.print("  ⇢ self-check, {d}m {d}s in · ", .{
            @divTrunc(elapsed_s, std.time.s_per_min),
            @mod(elapsed_s, std.time.s_per_min),
        });
        try writeRunTag(&line.writer, run);
        // The run carries on by itself: the report is the user's to read, and
        // stopping it is theirs too, so the line says how.
        try line.writer.writeAll(" · carrying on, Esc stops it\n");
        try sanitize.writeSanitized(&line.writer, report);
        try line.writer.writeAll("\n");
        try self.emit(std.Io.File.stderr(), CYAN ++ "{s}" ++ RESET, .{line.written()});
    }

    /// Read the answer a run ended on and close it. `heading` says how the run
    /// got there, because a run that was cut by its deadline and one that
    /// finished on its own read differently to whoever has to verify the work.
    fn finishRun(self: *Agent, run: *Run, heading: []const u8) anyerror!tools.ToolResult {
        // The report is the reply that stands on the finished work: the
        // commentary of earlier rounds stays in the capture before the mark.
        const start = @min(run.child.capture_mark, run.capture.items.len);
        const answer = std.mem.trim(u8, run.capture.items[start..], " \t\r\n");
        defer self.closeRun(run);
        if (answer.len == 0) {
            return .{
                .output = try self.allocator.dupe(u8, "The sub-agent finished without a report. Inspect the working directory for what it did."),
                .is_error = true,
            };
        }
        return .{
            .output = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ heading, answer }),
            .is_error = false,
        };
    }

    /// A run that ended in an error. Whatever it changed is still on disk, and
    /// the caller is told to look rather than to assume nothing happened.
    fn failRun(self: *Agent, run: *Run, failure: anyerror) anyerror!tools.ToolResult {
        defer self.closeRun(run);
        return .{
            .output = try std.fmt.allocPrint(self.allocator, "The sub-agent stopped: {s}. Whatever it changed is on disk; inspect it before retrying.", .{subagentFailure(failure)}),
            .is_error = true,
        };
    }

    /// A run that would not write its final report after the deadline: stop it
    /// where it stands and read back what it wrote.
    ///
    /// The report is taken before the child is freed, and it is the honest one
    /// — the last thing the child said, with the deadline named as the reason
    /// the work stops there rather than the child claiming it was finished.
    fn cutRun(self: *Agent, run: *Run) anyerror!tools.ToolResult {
        const start = @min(run.child.capture_mark, run.capture.items.len);
        const said = std.mem.trim(u8, run.capture.items[start..], " \t\r\n");
        const answer = try self.allocator.dupe(u8, said);
        defer self.allocator.free(answer);
        self.abortRun(run);
        if (answer.len == 0) return .{
            .output = try self.allocator.dupe(u8, "The sub-agent passed its deadline and was stopped without a word. Inspect the working directory for what it did."),
            .is_error = true,
        };
        return .{
            .output = try std.fmt.allocPrint(self.allocator, "The sub-agent passed its deadline and was stopped mid-work. This is the last thing it said, not a finished report — what it left undone is unknown until you look:\n{s}", .{answer}),
            .is_error = false,
        };
    }

    /// Close every run this agent still holds. Not while a turn is running:
    /// the task doing that work owns the list, and it closes what it started
    /// when it is done with it.
    fn closeRuns(self: *Agent) void {
        if (self.query_started != null) return;
        while (self.runs.items.len > 0) self.abortRun(self.runs.items[self.runs.items.len - 1]);
    }

    pub fn findRun(self: *Agent, id: []const u8) ?*Run {
        for (self.runs.items) |run| {
            if (std.mem.eql(u8, run.id, id)) return run;
        }
        return null;
    }

    /// Close a run whose child has finished: take its tokens into this
    /// session's totals, free the child, and forget the run. The task is
    /// awaited first, so nothing reads the child after it is freed.
    fn closeRun(self: *Agent, run: *Run) void {
        if (run.future) |*future| _ = future.await(self.io);
        // The sub-agent's requests were part of what this query cost, so their
        // tokens are counted where the user reads the totals.
        self.client.absorbUsage(&run.child.client);
        run.child.deinit();
        self.allocator.destroy(run.child);
        run.capture.deinit(self.allocator);
        run.supervisor.deinit();
        self.allocator.free(run.id);
        self.allocator.free(run.title);
        for (self.runs.items, 0..) |candidate, index| {
            if (candidate == run) {
                _ = self.runs.swapRemove(index);
                break;
            }
        }
        self.allocator.destroy(run);
    }

    /// Close a run that is still going: tell the child to stop, which it sees
    /// at its next request boundary, and wait for it to be gone. A command that
    /// is already running is not cut: there is no way to end it that does not
    /// also lose what it printed.
    fn abortRun(self: *Agent, run: *Run) void {
        run.child.interrupted.store(true, .release);
        self.closeRun(run);
    }

    /// Take what the run's clocks asked for at a request boundary: a
    /// self-check, or the deadline that ends the work. Both arrive as a message
    /// in the conversation, the way a line the user typed does, and both are
    /// answered inside the work in progress rather than after it.
    fn applySupervision(self: *Agent) !void {
        const supervisor = self.supervisor orelse return;
        const due = supervisor.takeDue();
        if (!due.any()) return;
        // The deadline outranks a self-check asked for before it: one of them
        // asks for a status line, the other is the end of the work.
        if (due.deadline) {
            try self.appendUserMessage(deadline_prompt);
            try self.emit(std.Io.File.stderr(), DIM ++ "  ↳ the deadline passed: the final report\n" ++ RESET, .{});
            if (self.trace) |trace| trace.note(self.traceCtx(), "info", "the deadline passed: the final report");
        } else {
            try self.appendUserMessage(self_check_prompt);
            try self.emit(std.Io.File.stderr(), DIM ++ "  ↳ a self-check: report progress and carry on\n" ++ RESET, .{});
            if (self.trace) |trace| trace.note(self.traceCtx(), "info", "a self-check: report progress and carry on");
        }
        try self.checkpoint();
    }

    fn processQueryInner(self: *Agent, query: []const u8) !void {
        try self.appendUserMessage(query);
        if (self.trace) |trace| trace.query(self.traceCtx(), query);
        try self.checkpoint();
        self.terminal_title.update("thinking…", self.current_task);

        try self.checkInterrupted();
        try self.runToolLoop();
    }

    /// Send the conversation and wait, with the progress line animated for the
    /// length of the wait.
    ///
    /// The spinner lives in these helpers rather than in the loop that calls
    /// them: a `defer` in the loop body would still be in force while the tool
    /// results are printed, and the next frame of the animation would erase
    /// what was just printed. Here it ends before the caller writes a byte.
    fn chatAnimated(self: *Agent, messages: []const Message, stream: *AnswerStream) !openai.ApiResponse {
        try self.checkInterrupted();
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

    /// Report what the server said about a request that failed. The client
    /// keeps it instead of printing it, so that it can be said here — after
    /// the animation has given the line back.
    fn reportHttpError(self: *Agent) !void {
        const message = self.client.takeHttpError() orelse return;
        defer self.allocator.free(message);
        try self.emit(std.Io.File.stderr(), RED ++ "  ✗ {s}\n" ++ RESET, .{message});
    }

    /// Run the tool-call loop until the model answers. Nothing counts the
    /// requests: a turn ends when the model stops asking for tools, and a turn
    /// that never gets there is ended by its caller's interrupt. The answer is
    /// printed and kept in the history.
    fn runToolLoop(self: *Agent) !void {
        // However the turn ends — an answer, a tool call, a failure, Esc — the
        // reasoning panel closes here and its duration stays in the status bar.
        defer self.thinking.close(self);
        var made: usize = 0;
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

        // The requests are numbered for the record, not capped: what ends this
        // loop is the model's answer or the caller's interrupt.
        while (true) : (iteration += 1) {
            // Requests are numbered from one in the record, so "request #2"
            // means the second one of this turn, whichever agent made it.
            self.trace_iteration = iteration + 1;
            self.client.trace_ctx = self.traceCtx();
            try self.checkInterrupted();
            // A line typed while the last request was running goes out with
            // this one: it belongs to the task in progress. A continuation
            // chain is the exception — its fragments are folded or dropped
            // when it settles, and the guidance would go with them, so it
            // waits for the first boundary that is not part of a chain.
            if (continuation_start == null) {
                stream.flushPending() catch {};
                _ = try self.injectSteering();
                try self.applySupervision();
            }
            var response = self.chatAnimated(self.history.items, stream) catch |err| {
                // Do not leave a continuation prompt as the last message for
                // the next request to answer.
                self.settleContinuations(&continuation_start, carried.items, null) catch {};
                stream.flushPending() catch {};
                // The reasoning stops where the request did, before the line
                // that says it failed.
                self.thinking.close(self);
                try self.emit(std.Io.File.stderr(), RED ++ "Error: failed to call API: {s}\n" ++ RESET, .{@errorName(err)});
                return err;
            };
            defer response.deinit(self.allocator);
            // A response that asks for a tool has no answer text to fold the
            // panel in front of, and the call line must not be written under
            // reasoning that has already finished.
            self.thinking.close(self);

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
                    if (self.trace) |trace| trace.note(self.traceCtx(), "warn", "the reply was cut off by the output limit; the model was asked to continue");
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
                if (self.trace) |trace| trace.note(self.traceCtx(), "warn", "the reply was cut off before any text; the model was asked for a smaller step");
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
                {
                    const owned_calls = try cloneToolCalls(self.allocator, tool_calls);
                    // Keep exact Responses output items alongside the UI summary.
                    // This retains reasoning and function call IDs for stateless replay.
                    // The response's own fields are handed over rather than
                    // copied; only the tool calls are cloned, because the loop
                    // below keeps using them. Everything given to the history,
                    // the clone included, is released again if the append fails.
                    try self.appendOwnedMessage(.{
                        .response_items = takeOwnedSlice(&response.response_items),
                        .role = "assistant",
                        .content = takeOwnedSlice(&response.content),
                        .reasoning_content = takeOwnedSlice(&response.reasoning_content),
                        .tool_calls = owned_calls,
                        .tool_call_id = null,
                    });
                }

                // Every question a call asks is put to the user by the tool
                // itself, in one form, so the loop just runs the calls.
                if (self.child_record != null) try self.checkpoint();
                for (tool_calls) |call| {
                    try self.checkInterrupted();
                    // The call is recorded before it runs, so a call that
                    // never returns is still in the record with its arguments.
                    if (self.trace) |trace| trace.toolCall(self.traceCtx(), call.name, call.id, call.arguments);
                    const tool_started = std.Io.Timestamp.now(self.io, .awake);
                    const result = self.executeTool(call) catch |err| blk: {
                        if (self.interrupted.load(.acquire)) return error.Canceled;
                        const error_content = try std.fmt.allocPrint(
                            self.allocator,
                            "Tool execution error for {s}: {s}",
                            .{ call.name, @errorName(err) },
                        );
                        break :blk tools.ToolResult{
                            .output = error_content,
                            .is_error = true,
                            .timed_out = err == error.Timeout,
                        };
                    };
                    // The result as the model reads it, so the record holds
                    // what the model was handed — down to a repeated page the
                    // read tool answered with a marker.
                    if (self.trace) |trace| trace.toolResult(self.traceCtx(), call.name, call.id, result.output, .{
                        .is_error = result.is_error,
                        .exit_code = result.exit_code,
                        .timed_out = result.timed_out,
                        .termination = result.termination,
                        .ccr_id = if (result.ccr_id) |*id| id else null,
                        .ms = tool_started.untilNow(self.io, .awake).toMilliseconds(),
                    });
                    defer result.deinit(self.allocator);

                    const result_content = try self.allocator.dupe(u8, result.output);
                    errdefer self.allocator.free(result_content);
                    const call_id = try self.allocator.dupe(u8, call.id);
                    errdefer self.allocator.free(call_id);

                    try self.history.append(self.allocator, .{
                        .role = "tool",
                        .content = null,
                        .reasoning_content = null,
                        .tool_calls = null,
                        .tool_call_id = call_id,
                        .tool_result = .{
                            .output = result_content,
                            .is_error = result.is_error,
                            .exit_code = result.exit_code,
                            .timed_out = result.timed_out,
                            .termination = result.termination,
                            .ccr_id = result.ccr_id,
                        },
                    });
                    if (self.child_record != null) try self.checkpoint();
                }
                // A sub-agent's report is the reply that stands on its finished
                // work, not the commentary it wrote before asking for tools:
                // the next round starts the text the caller reads back.
                if (self.capture) |sink| self.capture_mark = sink.items.len;
                try self.checkpoint();
                made += tool_calls.len;
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
                        // What was just printed becomes the history's message
                        // without a second copy: the folded text when the reply
                        // was assembled from fragments, and otherwise the
                        // response's own buffer. Taking a field out leaves the
                        // response unable to free it, so exactly one owner
                        // remains; a failed append hands them back.
                        const owned_content = combined orelse takeOwnedSlice(&response.content).?;
                        combined = null;
                        try self.appendOwnedMessage(.{
                            .response_items = takeOwnedSlice(&response.response_items),
                            .role = "assistant",
                            .content = owned_content,
                            .reasoning_content = takeOwnedSlice(&response.reasoning_content),
                            .tool_calls = null,
                            .tool_call_id = null,
                        });
                    }
                }
                try self.checkpoint();
                // A line typed while the answer was being written is part of
                // this task too. Keep the turn open so the request after the
                // answer acts on it, rather than handing it to a new task.
                if (try self.injectSteering()) {
                    stream.reopen();
                    continue;
                }
                break;
            }
        }

        if (self.trace) |trace| trace.turn(self.traceCtx(), .{
            .tool_calls = made,
            .ms = if (self.query_started) |started| started.untilNow(self.io, .awake).toMilliseconds() else 0,
        });
    }

    /// Put one form of questions to the user and take its answers. A single
    /// question arrives here as a form of one, so both behave the same way.
    ///
    /// Returns one reply per question, in the order they were asked. A question
    /// the user dismissed comes back dismissed, and the model decides for
    /// itself what to do next.
    pub fn askForm(self: *Agent, slots: []menu.Slot) !menu.Replies {
        self.terminal_title.update("waiting for input", self.current_task);
        if (self.form_callback) |present| return present(self.form_context, slots);

        if (!self.linenoise.is_tty or !self.linenoise.term_supported or
            !(std.Io.File.stderr().isTty(self.io) catch false))
        {
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            var recommended: usize = 0;
            for (slots) |*slot| {
                try menu.writeMenu(&aw.writer, slot.text, slot.options);
                // Nothing to read a choice from. Taking the recommendation
                // keeps a piped or single-query run moving instead of stalling
                // it.
                const index = menu.recommendedIndex(slot.options) orelse continue;
                slot.selected = index;
                slot.answered = true;
                recommended += 1;
            }
            try self.writeLogOrStdout(aw.written());
            const hint = if (recommended > 0)
                DIM ++ "  no terminal to read an answer from; taking the recommended option\n" ++ RESET
            else
                DIM ++ "  no terminal to read an answer from\n" ++ RESET;
            try self.emit(std.Io.File.stderr(), "{s}", .{hint});
            return menu.repliesFrom(self.allocator, slots);
        }

        const replies = try menu.resolve(self.allocator, slots, .{
            .context = self,
            .present = presentOnTerminal,
            .read = readOnTerminal,
        });
        if (replies.canceled) {
            // Esc at the questions is a stop here too: nothing is answered, and
            // the run ends the way it does when the screen owns the form. The
            // replies still go back, so the tool has a result to record.
            self.interrupted.store(true, .release);
            try self.emit(std.Io.File.stderr(), YELLOW ++ "  Task interrupted (Esc). The questions were cancelled and no answer was sent.\n" ++ RESET, .{});
        }
        return replies;
    }

    /// Draw a form on the terminal, which owns the keyboard in this mode.
    fn presentOnTerminal(context: *anyopaque, slots: []menu.Slot, focus: ?usize) anyerror!menu.Outcome {
        const self: *Agent = @ptrCast(@alignCast(context));
        return menu.form(self.allocator, self.io, slots, true, true, focus);
    }

    /// Read the free text a free-text row asks for, on that same terminal.
    fn readOnTerminal(context: *anyopaque) anyerror!menu.Line {
        const self: *Agent = @ptrCast(@alignCast(context));
        return self.readChoiceLine();
    }

    /// Read the free text the "type your own answer" row asks for. Owned by the
    /// caller, trimmed, and never empty: an empty line is no answer at all.
    pub fn readChoiceLine(self: *Agent) !menu.Line {
        // A menu answer is free text, not a slash command, so completion and
        // hints are switched off for this read and restored afterwards.
        const saved_completions = self.linenoise.completions_callback;
        const saved_hints = self.linenoise.hints_callback;
        const saved_popup = self.linenoise.popup_callback;
        const saved_question = self.linenoise.question_input;
        self.linenoise.completions_callback = null;
        self.linenoise.hints_callback = null;
        self.linenoise.popup_callback = null;
        self.linenoise.question_input = true;
        defer {
            self.linenoise.completions_callback = saved_completions;
            self.linenoise.hints_callback = saved_hints;
            self.linenoise.popup_callback = saved_popup;
            self.linenoise.question_input = saved_question;
        }

        var raw_line: ?[]const u8 = null;
        while (true) {
            if (self.screen) |screen| try screen.prepareInput();
            raw_line = self.linenoise.linenoise(CHOICE_PROMPT) catch |err| switch (err) {
                // Esc is the way back to the options, not the end of the read.
                error.Escaped => {
                    if (self.screen) |screen| try screen.endInput();
                    return .back;
                },
                error.Suspend => {
                    // The custom-answer read is a normal line edit; suspension
                    // gives the terminal back and resumes on the same text.
                    if (self.screen) |screen| {
                        try screen.suspendProcess();
                    } else {
                        @import("../ui/screen.zig").stopProcess();
                    }
                    continue;
                },
                else => return err,
            };
            if (self.screen) |screen| try screen.endInput();
            break;
        }
        const line = raw_line orelse return .none;
        defer self.allocator.free(line);

        // The answer is part of the record even though the editor's rows are
        // cleared once it is read.
        if (self.screen) |screen| {
            const echo = try std.fmt.allocPrint(self.allocator, "{s}{s}\n", .{ CHOICE_PROMPT, line });
            defer self.allocator.free(echo);
            try screen.writeLog(echo);
        }

        const answer = std.mem.trim(u8, line, " \t\r\n");
        if (answer.len == 0) return .none;
        return .{ .answer = try self.allocator.dupe(u8, answer) };
    }

    /// Give the history a message whose fields are already owned. The history
    /// is the only owner afterwards, so a failed append — the only operation
    /// that can fail here — releases the fields again.
    fn appendOwnedMessage(self: *Agent, message: Message) !void {
        self.history.append(self.allocator, message) catch |err| {
            message.deinit(self.allocator);
            return err;
        };
    }

    /// Take a response field out of the response so the history can own it
    /// instead of copying it. The response no longer frees what is taken.
    fn takeOwnedSlice(field: *?[]const u8) ?[]const u8 {
        const value = field.* orelse return null;
        field.* = null;
        return value;
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
    /// Most tools are one line of name and arguments, and the arguments are
    /// named rather than serialised: `summary.zig` is what turns a call's JSON
    /// into the words beside the tool's name, and a tool that has nothing to say
    /// about an argument keeps that argument out of the line rather than putting
    /// it there as it arrived. `apply_patch` and `edit` are the block-shaped
    /// exceptions: their arguments are the diff itself, and a JSON-escaped diff
    /// tells nobody anything — so it is drawn instead, line by line, in the
    /// colours the change would be read in.
    fn announceToolCall(self: *Agent, name: []const u8, arguments: []const u8) !void {
        if (self.capture != null) {
            const parent = self.parent orelse return;
            parent.tool_ui.spinner.stop();
            defer parent.resumeCallProgress();
            var line: std.Io.Writer.Allocating = .init(self.allocator);
            defer line.deinit();
            try line.writer.writeAll("\x1b[35m  ⇢ ");
            try sanitize.writeSanitized(&line.writer, if (self.child_record) |record| record.id else "subagent");
            try line.writer.writeAll(RESET ++ "\n");
            try self.writeToolCall(&line.writer, name, arguments);
            return parent.emit(std.Io.File.stderr(), "{s}", .{line.written()});
        }
        // Written through a fixed buffer rather than built up in memory first:
        // a patch is read as it is drawn, and a long one never has to be held
        // whole to be shown.
        var buf: [4096]u8 = undefined;

        if (self.screen) |screen| {
            if (screen.isActive()) {
                var log_writer = screen.logWriter(&buf);
                try self.writeToolCall(&log_writer.writer, name, arguments);
                return log_writer.writer.flush();
            }
        }

        var file_writer = std.Io.File.stderr().writerStreaming(self.io, &buf);
        try self.writeToolCall(&file_writer.interface, name, arguments);
        try file_writer.interface.flush();
    }

    fn writeToolCall(self: *Agent, w: *std.Io.Writer, name: []const u8, arguments: []const u8) !void {
        const summary = @import("../tools/summary.zig");
        const spec = @import("../tools/dispatch.zig").presentation(name);
        var preview: std.Io.Writer.Allocating = .init(self.allocator);
        defer preview.deinit();
        const ctx: tools.Context = .{ .io = self.io, .allocator = self.allocator, .agent = self };
        const summarized = if (spec) |s| if (s.summary) |write| try write(ctx, &preview.writer, arguments) else false else false;
        const block = summarized and spec.?.summary_block;
        try w.writeAll(if (self.role == .subagent) "\x1b[35m  ⚙ " else if (spec != null and spec.?.delegated) CYAN ++ "  ⇢ " else YELLOW ++ "  ⚙ ");
        try w.writeAll(BOLD);
        try sanitize.writeSanitized(w, name);
        try w.writeAll(RESET);
        if (block) {
            try w.writeByte('\n');
            try w.writeAll(preview.written());
            return;
        }
        // A call no spec here describes — an MCP tool's, whose arguments arrive
        // in a shape this program does not know — is still named rather than
        // dumped. Only arguments that are not an object at all, or a tool whose
        // own preview failed, keep the JSON they arrived as.
        const text = if (summarized) preview.written() else named: {
            preview.clearRetainingCapacity();
            const named = try summary.writeObject(&preview.writer, self.allocator, arguments);
            break :named if (named) preview.written() else arguments;
        };
        // The name is what a reader scans a turn for; the arguments are its
        // detail, so they are drawn dim beside it.
        try w.writeAll(" " ++ DIM);
        try summary.writeFitted(w, text, self.callLineRoom(name));
        try w.writeAll(RESET ++ "\n");
    }

    /// Columns a call's arguments may take: what the terminal has left on the
    /// line after the margin, the glyph and the tool's name.
    ///
    /// A run whose stderr is not a terminal is writing to a pipe or a file,
    /// where the line is content rather than layout — the margin is not drawn
    /// there either — so nothing is cut and the whole summary is kept. On a
    /// terminal one call is one line: a shell command carrying a loop is worth
    /// reading, but not at the price of hiding the calls after it behind its
    /// wrapping.
    fn callLineRoom(self: *Agent, name: []const u8) usize {
        const stderr = std.Io.File.stderr();
        if (!(stderr.isTty(self.io) catch false)) return std.math.maxInt(usize);
        const width = term.usableWidth(term.columns(stderr));
        // `  ⚙ ` is the margin and the glyph, two columns each; then the name
        // and the space that separates it from its arguments.
        return width -| (layout.columns + 2 + term.width(name) + 1);
    }

    /// The terminal's part in one tool call, where the call starts: the call is
    /// named in the title, announced on the terminal, and the line the
    /// animation draws while it runs belongs to this call alone. Dispatch runs
    /// this before the tool sees its arguments, so a call that a tool refuses
    /// is still shown to the user.
    fn beforeToolCall(ctx: tools.Context, name: []const u8, arguments: []const u8) !?tools.ToolResult {
        const self = ctx.agent orelse return null;
        self.terminal_title.update(name, self.current_task);
        try self.announceToolCall(name, arguments);
        // Started last: nothing after it may fail, because the after hook is
        // what gives the line back and an error here would skip that hook.
        try self.startCallProgress(name, arguments);
        return null;
    }

    /// Give the line the call owned back, then let the cache that may stand in
    /// for the result have it. This runs before the result is previewed, so the
    /// preview lands on a cleared line whatever the call did.
    fn afterToolCall(ctx: tools.Context, name: []const u8, arguments: []const u8, outcome: anyerror!tools.ToolResult) !tools.ToolResult {
        if (ctx.agent) |self| self.tool_ui.spinner.stop();
        // A sub-agent's report is not something to cache: it is the one thing
        // the caller reads back from a run, and swapping it for a preview plus
        // an id would hide exactly the text it has to verify. Everything else
        // is cached as usual — including what a sub-agent runs on its own side,
        // which is cached in that child's scratch directory, read back by the
        // child through `ccr_retrieve`, and deleted with the child.
        if (std.mem.eql(u8, name, "subagent")) return outcome;
        return @import("../tools/ccr.zig").cacheOversizedOutput(ctx, name, arguments, outcome);
    }

    /// Start the animation for the call in progress, if the tool has a label
    /// and this run has a terminal to animate on. A tool can run for minutes,
    /// so the wait gets the same line the model calls do.
    fn startCallProgress(self: *Agent, name: []const u8, arguments: []const u8) !void {
        const label = try self.callProgressLabel(name, arguments, &self.tool_ui.label);
        var options = self.progressOptions();
        // A sub-agent works out of sight, so its line is coloured like its
        // call: the user can tell a second agent at work from the main model
        // thinking, without reading the words.
        if (@import("../tools/dispatch.zig").presentation(name)) |spec| {
            if (spec.delegated) options.style = CYAN;
        }
        self.tool_ui.spinner = if (label) |caption|
            spinner.Spinner.start(self.io, std.Io.File.stderr(), caption, options)
        else
            spinner.Spinner.disabled(self.io);
    }

    /// Take the call's line again after something else wrote to the terminal.
    /// The label is the one `startCallProgress` built for this call and nothing
    /// has rebuilt it since, so the caption is still the same caption.
    fn resumeCallProgress(self: *Agent) void {
        const caption = self.tool_ui.label.written();
        if (caption.len == 0) return;
        var options = self.progressOptions();
        options.style = CYAN;
        self.tool_ui.spinner = spinner.Spinner.start(self.io, std.Io.File.stderr(), caption, options);
    }

    /// The endpoints the web tools ask, as this session's configuration
    /// resolved them: a tool with none of its own keeps its built-in behaviour.
    fn webEndpoints(self: *const Agent) tools.WebConfig {
        return .{
            .search_url = self.config.web_search_url,
            .search_key = self.config.web_search_key,
            .fetch_url = self.config.web_fetch_url,
            .fetch_key = self.config.web_fetch_key,
        };
    }

    /// Run one tool call. Everything the user sees of the call — its line in
    /// the title, its announcement, the animation while it runs, and the
    /// preview of what it returned — happens here and in the hooks this
    /// dispatch is given; the tools themselves know nothing of the terminal.
    fn executeTool(self: *Agent, call: ToolCallData) !tools.ToolResult {
        const cache_dir = try tools.ccrDirPath(self.allocator, self.scratch.path);
        defer self.allocator.free(cache_dir);
        const ctx: tools.Context = .{
            .io = self.io,
            .allocator = self.allocator,
            .env = self.tool_env,
            .cache_dir = cache_dir,
            .hooks = .{ .before = beforeToolCall, .after = afterToolCall },
            .agent = self,
            .web = self.webEndpoints(),
        };
        // Dispatch applies the shared size limit after execution hooks. The UI
        // only previews the result the tool returned, guarded as it prints.
        const result = try tools.execute(ctx, call.name, call.arguments);
        errdefer result.deinit(self.allocator);
        const presentation = @import("../tools/dispatch.zig").presentation(call.name);
        try self.previewToolResult(result.output, result, if (presentation) |spec| spec.delegated else false);
        return result;
    }

    /// The progress line's label for a tool call, or null for a tool that must
    /// not have one. Most tools name themselves; a sub-agent names the run it
    /// works on — its title when it has one, otherwise the task it was handed
    /// or the run it is resuming — because it works with no output of its own
    /// on screen and this line is the only sign of what it is doing.
    ///
    /// `buf` is where a built label lives. It must outlive the animation, so
    /// the caller owns it and frees it after the spinner has stopped.
    fn callProgressLabel(self: *Agent, name: []const u8, arguments: []const u8, buf: *std.Io.Writer.Allocating) !?[]const u8 {
        if (@import("../tools/dispatch.zig").presentation(name)) |spec| {
            if (spec.progress) |write| {
                var raw: std.Io.Writer.Allocating = .init(self.allocator);
                defer raw.deinit();
                const label = try write(.{ .io = self.io, .allocator = self.allocator, .agent = self }, &raw, arguments) orelse return null;
                buf.clearRetainingCapacity();
                try sanitize.writeSanitized(&buf.writer, label);
                return buf.written();
            }
        }
        return tools.progressLabel(name) orelse self.mcp_registry.progressLabel(name);
    }

    /// Use the same result preview for live execution and restored messages.
    ///
    /// The status is the whole of the first line under the call — `✓` or `✗`
    /// and, when the result has one, the exit code, the signal or the timeout —
    /// and the result begins on the line after it. So the first line of every
    /// result reads the same way whatever the tool printed: a one-line `read`
    /// and a failed `bash` are told apart at the glyph, at the margin, before
    /// any of their text is read. The text under it is the tool's own, whole
    /// and unchanged: a tool reports how it ended beside its text, not inside
    /// it, so there is nothing here to leave out.
    fn previewToolResult(self: *Agent, content: []const u8, status: tools.ToolResult, delegated: bool) !void {
        if (self.capture != null) {
            const parent = self.parent orelse return;
            parent.tool_ui.spinner.stop();
            defer parent.resumeCallProgress();
            return parent.previewToolResult(content, status, delegated);
        }
        // An error is shown whole, because its message is the point of it — but
        // a result cut at the size limit is large even as an error, so even
        // that one keeps to a readable share of the terminal.
        const preview_len = if (delegated)
            content.len
        else if (status.is_error)
            @min(content.len, error_preview_max)
        else
            @min(content.len, 200);
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();
        try sanitize.writeSanitized(&body.writer, content[0..preview_len]);
        if (content.len > preview_len) try body.writer.writeAll("...");
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        if (delegated and self.render_markdown) {
            try writeResultPreview(&aw.writer, "", status);
            try render.render(&aw.writer, body.written(), .{
                .width = term.usableWidth(term.columns(std.Io.File.stderr())),
                .indent = layout.after_glyph.len,
            });
        } else {
            try writeResultPreview(&aw.writer, body.written(), status);
        }
        try self.emit(std.Io.File.stderr(), "{s}", .{aw.written()});
    }

    /// Print the model's answer: rendered for a terminal, raw otherwise.
    ///
    /// The raw path matters as much as the rendered one. When stdout is a pipe
    /// or a file the consumer is another program, and markdown is both the most
    /// faithful representation and the one that loses nothing — stripping
    /// markers would quietly cost a `| tee answer.md` user their structure.
    pub fn writeAnswer(self: *Agent, content: []const u8) !void {
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
                    .indent = layout.columns,
                });
                return log_writer.writer.flush();
            }
        }

        var file_writer = stdout.writerStreaming(self.io, &buf);

        try render.render(&file_writer.interface, content, .{
            .width = term.usableWidth(term.columns(stdout)),
            .indent = layout.columns,
        });
        try file_writer.interface.flush();
    }

    /// Write a finished block to the conversation at its left margin: a
    /// command's own listing is shown against the same left edge as the answer
    /// above the prompt. A pipe or a file is handed the block as it is, because
    /// what reads it there cannot see a margin and did not ask for one.
    fn writeBlock(self: *Agent, block: []const u8) !void {
        if (!self.onTerminal()) return self.writeLogOrStdout(block);
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try layout.write(&aw.writer, block);
        return self.writeLogOrStdout(aw.written());
    }

    /// Whether what is written is read by a person on a terminal rather than by
    /// another program. It is the one condition under which the conversation
    /// takes a left margin.
    fn onTerminal(self: *Agent) bool {
        if (self.capture != null) return false;
        if (self.screen) |screen| {
            if (screen.isActive()) return true;
        }
        return std.Io.File.stdout().isTty(self.io) catch false;
    }

    /// Send finished bytes to the conversation, or to stdout when the
    /// interactive screen is not in use.
    fn writeLogOrStdout(self: *Agent, bytes: []const u8) !void {
        // A sub-agent's answer is collected rather than printed: it reaches
        // the caller as the tool result, not as text on a terminal it does
        // not own.
        if (self.capture) |sink| return sink.appendSlice(self.allocator, bytes);
        if (self.screen) |screen| {
            if (screen.isActive()) return screen.writeLog(bytes);
        }
        return std.Io.File.stdout().writeStreamingAll(self.io, bytes);
    }

    /// The line the answer opens with, at the same margin as everything else
    /// the conversation shows: the header is what the text under it lines up
    /// with, so it carries the margin rather than the renderer alone.
    fn answerHeader(self: *Agent) !void {
        if (self.capture != null) return;
        const header = "\n" ++ layout.indent ++ BOLD ++ CYAN ++ "Assistant" ++ RESET ++ "\n";
        if (self.screen) |screen| {
            if (screen.isActive()) return screen.writeLog(header);
        }
        const stdout = std.Io.File.stdout();
        if (stdout.isTty(self.io) catch false) {
            try stdout.writeStreamingAll(self.io, header);
        }
    }

    fn answerTrailer(self: *Agent) !void {
        if (self.capture != null) return;
        try self.writeLogOrStdout("\n");
    }
};

/// The chain of thought while the model produces it.
///
/// The reasoning is not part of the answer and is never kept: it is shown in a
/// panel the full-screen layout holds open above the prompt, and when the panel
/// closes only the status bar keeps the duration. No reasoning buffer here
/// outlives the request it belongs to.
///
/// The panel outlives the start of the answer by a few seconds, so the last
/// row of reasoning can be read while the answer is written; the screen times
/// that close, and every other close here is immediate.
///
/// A run with no screen, and a sub-agent, have none of this: the deltas are
/// dropped, because there is no panel to scroll them in and printing them would
/// put narration where the answer belongs.
const Thinking = struct {
    /// Set when the first delta of this thought arrived. Cleared when the panel
    /// was handed to the screen to close, which is not necessarily closed yet.
    /// Null also means "nothing to close".
    started: ?std.Io.Timestamp = null,

    fn feed(self: *Thinking, agent: *Agent, delta: []const u8) void {
        if (delta.len == 0) return;
        const screen = agent.screen orelse return;
        if (agent.capture != null or !screen.isActive()) return;
        if (self.started == null) self.started = std.Io.Timestamp.now(agent.io, .awake);
        screen.publishThinking(delta);
    }

    /// The answer has begun: ask the screen to keep the panel for a moment and
    /// then close it, saying how long the model thought. The last rows of
    /// reasoning are what led to the answer, and they are read while the first
    /// of it is written.
    ///
    /// The close is the screen's to perform because this thread is busy
    /// streaming; once it is asked for, this turn has nothing left to say about
    /// the panel.
    fn deferClose(self: *Thinking, agent: *Agent) void {
        const started = self.started orelse return;
        self.started = null;
        const screen = agent.screen orelse return;
        if (!screen.isActive()) return;
        var buf: [96]u8 = undefined;
        const line = thoughtLine(started, agent, &buf) orelse return;
        screen.scheduleThinkingClose(line);
    }

    /// Close the panel at once, whatever was asked for earlier: before a call
    /// line or an error that must not be written under it, at the end of the
    /// turn, and when the user stops the work. Nothing of a finished turn sits
    /// on the screen waiting for a delay that no longer means anything.
    fn close(self: *Thinking, agent: *Agent) void {
        const started = self.started orelse {
            // The screen may still be holding the panel open after the answer.
            if (agent.screen) |screen| {
                if (screen.isActive()) screen.hideThinking();
            }
            return;
        };
        self.started = null;
        closeNow(started, agent);
    }

    fn closeNow(started: std.Io.Timestamp, agent: *Agent) void {
        const screen = agent.screen orelse return;
        if (!screen.isActive()) return;
        var buf: [96]u8 = undefined;
        const line = thoughtLine(started, agent, &buf) orelse return;
        screen.scheduleThinkingClose(line);
        screen.hideThinking();
    }
};

/// Compact duration for the status bar, without terminal styling or newlines.
fn thoughtLine(started: std.Io.Timestamp, agent: *Agent, buf: []u8) ?[]const u8 {
    const elapsed_ms = started.untilNow(agent.io, .awake).toMilliseconds();
    if (elapsed_ms >= 10 * std.time.ms_per_s) {
        return std.fmt.bufPrint(buf, "✻ Thought for {d}s", .{
            @divTrunc(elapsed_ms, std.time.ms_per_s),
        }) catch null;
    }
    return std.fmt.bufPrint(buf, "✻ Thought for {d}.{d}s", .{
        @divTrunc(elapsed_ms, std.time.ms_per_s),
        @divTrunc(@mod(elapsed_ms, std.time.ms_per_s), 100),
    }) catch null;
}

/// The host UI's state for the tool call being answered.
///
/// The animation is started in the context's before hook and stopped in its
/// after hook, so it has to outlive both; the label the animation reads from
/// is built for the call and has to outlive the animation. Both live here, on
/// the agent whose terminal it is.
const ToolUi = struct {
    /// The line the running call owns. Disabled when nothing was started: a
    /// tool with no progress label, or a run with no terminal to animate on.
    spinner: spinner.Spinner,
    /// Where the label the animation borrows is built, reused from call to
    /// call so a long run does not allocate one per call.
    label: std.Io.Writer.Allocating,
};

/// One sub-agent this agent started: the child, what the two share, and the
/// task running it.
///
/// Heap-allocated and owned by the `runs` list of the caller, because the run
/// outlives the call that started it: the child holds pointers into this struct
/// (its capture sink and its supervisor), and a self-check that arrives while
/// the caller is waiting has to have somewhere to land.
const Run = struct {
    /// The id the model names to resume this run.
    id: []u8,
    /// The summary the terminal shows while the run works, empty when the
    /// caller gave none. Kept here rather than read back out of the arguments,
    /// because a resume names only the id: the lines that report on a run the
    /// caller did not just start still have to say which run they mean.
    title: []u8,
    child: *Agent,
    supervisor: subagent.Supervisor,
    /// Where the child's answers are collected instead of printed. Owned here
    /// rather than by the tool call, for the same reason as the rest.
    capture: std.ArrayList(u8) = .empty,
    /// The task the child runs in. Null only between `create` and `concurrent`.
    future: ?std.Io.Future(void) = null,
    /// When the task was handed over, for the report's "Ns in".
    started: std.Io.Timestamp,
};

/// The task a sub-agent runs: its one turn, with its end recorded where the
/// caller is waiting for it.
fn childTurn(child: *Agent, supervisor: *subagent.Supervisor, prompt: []u8) void {
    defer child.allocator.free(prompt);
    child.processQuery(prompt) catch |err| {
        if (child.child_record) |*record| record.status = if (err == error.Canceled) .interrupted else .failed;
        child.checkpoint() catch |checkpoint_err| {
            supervisor.finish(checkpoint_err);
            return;
        };
        supervisor.finish(err);
        return;
    };
    if (child.child_record) |*record| record.status = .completed;
    child.checkpoint() catch |err| {
        if (child.child_record) |*record| record.status = .failed;
        supervisor.finish(err);
        return;
    };
    supervisor.finish(null);
}

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
    /// The renderer borrows table rows until the table is flushed. Keep those
    /// lines separate from `pending`, which is compacted after every newline.
    retained_lines: std.ArrayList([]u8) = .empty,
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
                    self.renderer = render.Renderer.init(&self.log_writer.?.writer, .{
                        .width = width,
                        .indent = layout.columns,
                    });
                }
            }
            if (self.renderer == null) {
                self.file_writer = std.Io.File.stdout().writerStreaming(agent.io, &self.buf);
                self.renderer = render.Renderer.init(&self.file_writer.?.interface, .{
                    .width = width,
                    .indent = layout.columns,
                });
            }
        }
        return self;
    }

    fn clearRetainedLines(self: *AnswerStream) void {
        for (self.retained_lines.items) |line| self.allocator.free(line);
        self.retained_lines.clearRetainingCapacity();
    }

    fn deinit(self: *AnswerStream) void {
        self.clearRetainedLines();
        self.retained_lines.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn sink(self: *AnswerStream) openai.StreamSink {
        return .{ .context = self, .onText = onText, .onReasoning = onReasoning };
    }

    fn onText(context: *anyopaque, delta: []const u8) void {
        const self: *AnswerStream = @ptrCast(@alignCast(context));
        self.feed(delta) catch {};
    }

    fn onReasoning(context: *anyopaque, delta: []const u8) void {
        const self: *AnswerStream = @ptrCast(@alignCast(context));
        self.agent.thinking.feed(self.agent, delta);
    }

    fn feed(self: *AnswerStream, delta: []const u8) !void {
        if (delta.len == 0) return;
        if (!self.started) {
            self.started = true;
            // The spinner owns the terminal's line until the first text is
            // ready; stop it before anything else is written.
            if (self.spin) |spin| spin.stop();
            // The answer begins where the reasoning ends. The panel is given
            // its delay rather than folded away at once, so the row that led
            // here can still be read; its line is written when it closes.
            self.agent.thinking.deferClose(self.agent);
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
            const owned = try self.allocator.dupe(u8, trimmed);
            self.retained_lines.append(self.allocator, owned) catch |err| {
                self.allocator.free(owned);
                return err;
            };
            try r.feedLine(owned);
            if (r.table.count == 0) self.clearRetainedLines();
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
        self.clearRetainedLines();
        if (self.started) try self.agent.answerTrailer();
    }

    /// Reopen the stream for another reply in the same turn. The next text
    /// paints its own header and trailer, because a task that took fresh
    /// guidance is answering a different question than the one before it.
    fn reopen(self: *AnswerStream) void {
        self.finished = false;
        self.started = false;
    }
};

test "streamed table rows survive pending buffer compaction and reallocation" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const stream = try allocator.create(AnswerStream);
    stream.* = .{
        .agent = undefined, // emitLine's renderer path does not use the agent.
        .allocator = allocator,
        .renderer = render.Renderer.init(&output.writer, .{ .styled = false }),
    };
    defer stream.deinit();

    const chunks = [_][]const u8{
        "| Name | Value |\n| --- |",
        " --- |\n| alpha | one |\n",
        "| beta | two |\n",
        "\nordinary text\n",
        "not a table | still prose\n",
    };
    var document: std.ArrayList(u8) = .empty;
    defer document.deinit(allocator);
    for (chunks) |chunk| {
        try document.appendSlice(allocator, chunk);
        try stream.pending.appendSlice(allocator, chunk);
        try stream.drainLines();
        // Force the source allocation to be freed, even for small chunks.
        const fresh = try allocator.dupe(u8, stream.pending.items);
        stream.pending.deinit(allocator);
        stream.pending = .empty;
        defer allocator.free(fresh);
        try stream.pending.appendSlice(allocator, fresh);
    }
    try stream.finish();
    try std.testing.expectEqual(@as(usize, 0), stream.retained_lines.items.len);

    var expected: std.Io.Writer.Allocating = .init(allocator);
    defer expected.deinit();
    try render.render(&expected.writer, document.items, .{ .styled = false });
    try std.testing.expectEqualStrings(expected.written(), output.written());
}

fn cloneToolCalls(allocator: std.mem.Allocator, calls: []const ToolCallData) ![]ToolCallData {
    const result = try allocator.alloc(ToolCallData, calls.len);
    var i: usize = 0;
    errdefer {
        for (result[0..i]) |c| c.deinit(allocator);
        allocator.free(result);
    }
    for (calls, 0..) |call, j| {
        // Each field is owned as soon as it exists: a failure half way through
        // one call must not strand the fields already copied for it.
        const id = try allocator.dupe(u8, call.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, call.name);
        errdefer allocator.free(name);
        const arguments = try allocator.dupe(u8, call.arguments);
        result[j] = .{ .id = id, .name = name, .arguments = arguments };
        i = j + 1;
    }
    return result;
}

fn checkCloneToolCallsFailures(allocator: std.mem.Allocator) !void {
    const calls = [_]ToolCallData{
        .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a.zig\"}" },
        .{ .id = "call_2", .name = "shell", .arguments = "{\"command\":\"ls\"}" },
    };
    const clone = try cloneToolCalls(allocator, &calls);
    defer {
        for (clone) |call| call.deinit(allocator);
        allocator.free(clone);
    }
    try std.testing.expectEqual(@as(usize, 2), clone.len);
    try std.testing.expectEqualStrings("shell", clone[1].name);
}

test "cloning tool calls releases a half copied call when an allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkCloneToolCallsFailures, .{});
}

fn printFmt(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try file.writeStreamingAll(io, message);
}

/// Why a sub-agent stopped, in words a reader of the caller's conversation can
/// use: the bounds it runs under have names of their own only here.
fn subagentFailure(err: anyerror) []const u8 {
    if (err == error.Canceled) return "the task was interrupted";
    return @errorName(err);
}

/// The id of a run, and the title it was started with when it has one: how a
/// line about a run names it, so a caller reading one of two reports can tell
/// which run it is reading.
fn writeRunTag(w: *std.Io.Writer, run: *const Run) !void {
    try w.writeAll(run.id);
    if (run.title.len == 0) return;
    try w.writeAll(" \"");
    // The title was checked for control characters when the run started, so it
    // is one line already.
    try w.writeAll(run.title);
    try w.writeByte('"');
}

/// A moment `ms` milliseconds after `from`, on the clock the waits use.
fn inMs(from: std.Io.Timestamp, ms: i64) std.Io.Timestamp {
    return std.Io.Timestamp.addDuration(from, .fromMilliseconds(ms));
}

/// The same, counted from now.
fn inMsNow(io: std.Io, ms: i64) std.Io.Timestamp {
    return inMs(std.Io.Timestamp.now(io, .awake), ms);
}

/// The first of the caller's moments: the next self-check, the deadline, or the
/// end of the grace it gave the child for its final report.
fn nextWake(check_at: std.Io.Timestamp, deadline_at: std.Io.Timestamp, cut_at: ?std.Io.Timestamp) std.Io.Timestamp {
    var next = check_at;
    if (std.Io.Timestamp.compare(deadline_at, .lt, next)) next = deadline_at;
    if (cut_at) |cut| {
        if (std.Io.Timestamp.compare(cut, .lt, next)) next = cut;
    }
    return next;
}

test "subagent tool actions use a distinct color without changing arguments" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    harness.agent.role = .subagent;
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    try harness.agent.writeToolCall(&line.writer, "read", "{\"path\":\"example.zig\"}");
    try std.testing.expect(std.mem.startsWith(u8, line.written(), "\x1b[35m  ⚙ " ++ BOLD ++ "read" ++ RESET ++ " " ++ DIM ++ "example.zig"));
    try std.testing.expect(std.mem.indexOf(u8, line.written(), "example.zig") != null);
}

/// A standalone agent with a hermetic environment for tests. The line editor
/// and MCP registry live beside it because the agent only borrows them.
const TestHarness = struct {
    /// The agent creates its scratch directory at startup; `TMPDIR` points
    /// here so that directory is removed with the test instead of littering
    /// the host's temporary folder.
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    config: Config,
    linenoise: Linenoise,
    registry: mcp.Registry,
    agent: Agent,

    fn init(allocator: std.mem.Allocator, io: std.Io) !*TestHarness {
        const self = try allocator.create(TestHarness);
        errdefer allocator.destroy(self);

        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const scratch_root = try self.tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(scratch_root);

        self.env = .init(allocator);
        errdefer self.env.deinit();
        try self.env.put("TMPDIR", scratch_root);
        try self.env.put("AI_URL", "http://127.0.0.1:1/v1");
        try self.env.put("AI_MODEL", "test-model");
        try self.env.put("AI_KEY", "test-key");
        // No home/state directory: tests never resolve the developer's memory.
        // Tests that need memory install their own storage explicitly.

        self.config = try Config.load(allocator, io, &self.env);
        errdefer self.config.deinit();

        self.linenoise = Linenoise.init(allocator, io, &self.env);
        errdefer self.linenoise.deinit();

        self.registry = mcp.Registry.empty(allocator, io);
        errdefer self.registry.deinit();

        self.agent = try Agent.init(allocator, io, &self.config, &self.linenoise, &self.env, &self.registry);
        return self;
    }

    fn deinit(self: *TestHarness, allocator: std.mem.Allocator) void {
        self.agent.deinit();
        self.registry.deinit();
        self.linenoise.deinit();
        self.config.deinit();
        self.env.deinit();
        self.tmp.cleanup();
        allocator.destroy(self);
    }
};

/// Scripted Responses bodies for `openai.Client`, so the loop can be driven
/// without a socket. It records the budget of every request it is given.
const MockTransport = struct {
    replies: []const []const u8,
    cursor: usize = 0,
    /// Set to act like a user typing during the run: `steer_line` is handed to
    /// the agent just before the reply to request `steer_at` is produced.
    agent: ?*Agent = null,
    steer_at: usize = 0,
    steer_line: []const u8 = "",
    budgets: std.ArrayList(u32) = .empty,
    requests: std.ArrayList([]u8) = .empty,

    fn send(context: *anyopaque, allocator: std.mem.Allocator, request: []const u8) anyerror![]u8 {
        const self: *MockTransport = @ptrCast(@alignCast(context));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
        defer parsed.deinit();
        const budget = parsed.value.object.get("max_output_tokens") orelse return error.InvalidRequest;
        try self.budgets.append(allocator, @intCast(budget.integer));

        const owned = try allocator.dupe(u8, request);
        // Recorded before any later failure: the request did go out, and a
        // caller that dies of `NoScriptedReply` still wants to read it.
        self.requests.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };

        if (self.agent) |agent| {
            if (self.steer_at == self.cursor) try agent.steer(self.steer_line);
        }
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

test "main model announces the task through a built-in call without planning requests" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);
    const reply =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"task\",\"name\":\"announce_task\",\"arguments\":\"{\\\"title\\\":\\\"修复终端标题\\\",\\\"description\\\":\\\"先定位标题逻辑，再修改并测试。\\\"}\"}]}";
    var mock: MockTransport = .{ .replies = &.{ reply, completed_answer } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("不要把这段原文直接放到标题上");
    try harness.agent.runToolLoop();
    try std.testing.expectEqualStrings("修复终端标题", harness.agent.current_task);
    try std.testing.expectEqual(@as(usize, 2), mock.requests.items.len);
    for (mock.requests.items) |body| {
        const request = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer request.deinit();
        try std.testing.expect(request.value.object.get("tools") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "先定位标题逻辑") != null);
}

test "a follow-up that announces no task keeps the one in the title" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);

    const announced = try @import("../tools/announce_task.zig").execute(&harness.agent, "{\"title\":\"修复终端标题\",\"description\":\"先定位标题逻辑。\"}");
    announced.deinit(allocator);
    try std.testing.expectEqualStrings("修复终端标题", harness.agent.current_task);

    // The next line is answered without a task of its own: the title must not
    // fall back to the application name alone between the two turns.
    var mock: MockTransport = .{ .replies = &.{completed_answer} };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.processQuery("继续");
    try std.testing.expectEqualStrings("修复终端标题", harness.agent.current_task);

    // A new announcement replaces it: the title follows the latest task.
    const replaced = try @import("../tools/announce_task.zig").execute(&harness.agent, "{\"title\":\"别的任务\",\"description\":\"换一件事。\"}");
    replaced.deinit(allocator);
    try std.testing.expectEqualStrings("别的任务", harness.agent.current_task);
}

test "a self-check is kept in the child's record and the run goes on" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const harness = try TestHarness.init(a, io);
    defer harness.deinit(a);
    var silence = try Silence.init(io);
    defer silence.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    harness.agent.session_path = try std.fs.path.join(a, &.{ directory, "parent.json" });
    harness.agent.session_id = try a.dupe(u8, "parent");
    const progress = "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"done\",\"name\":\"ls\",\"arguments\":\"{}\"},{\"type\":\"function_call\",\"call_id\":\"rep\",\"name\":\"report\",\"arguments\":\"{\\\"summary\\\":\\\"saved halfway report\\\"}\"},{\"type\":\"function_call\",\"call_id\":\"pending\",\"name\":\"ls\",\"arguments\":\"{}\"}]}";
    var mock: MockTransport = .{ .replies = &.{ progress, completed_answer } };
    defer mock.deinit(a);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    // A self-check of zero asks at the child's first boundary, so the report is
    // answered in the middle of the batch and the work after it runs anyway.
    const run = try harness.agent.startRun("work", "", "", 0);
    const child_path = try a.dupe(u8, run.child.session_path.?);
    defer a.free(child_path);
    const report = try harness.agent.waitRun(run, 0, 3_600);
    defer report.deinit(a);
    // The caller reads the last reply, not the self-check printed on its way.
    try std.testing.expect(std.mem.indexOf(u8, report.output, "answer.") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.output, "saved halfway report") == null);
    // The child's own record keeps the self-check it answered, and the call
    // after it: a report finishes nothing.
    var loaded = try @import("../state/session.zig").load(io, a, child_path);
    defer loaded.deinit(a);
    const messages = loaded.messages.items;
    var reported = false;
    var worked_on = false;
    for (messages) |message| {
        if (std.mem.eql(u8, message.tool_call_id orelse "", "rep")) {
            reported = true;
            try std.testing.expect(std.mem.indexOf(u8, message.tool_result.?.output, "printed on the caller's terminal") != null);
        }
        if (std.mem.eql(u8, message.tool_call_id orelse "", "pending")) worked_on = true;
    }
    try std.testing.expect(reported and worked_on);
    var asked = false;
    for (messages) |message| {
        for (message.tool_calls orelse &.{}) |call| {
            if (std.mem.eql(u8, call.name, "report")) {
                asked = true;
                try std.testing.expect(std.mem.indexOf(u8, call.arguments, "saved halfway report") != null);
            }
        }
    }
    try std.testing.expect(asked);
}

test "durable child can be reconstructed under its old id without replaying tools" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const harness = try TestHarness.init(a, io);
    defer harness.deinit(a);
    var silence = try Silence.init(io);
    defer silence.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    harness.agent.session_path = try std.fs.path.join(a, &.{ directory, "parent.json" });
    harness.agent.session_id = try a.dupe(u8, "parent");
    var mock: MockTransport = .{ .replies = &.{ completed_answer, completed_answer, completed_answer } };
    defer mock.deinit(a);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    const first = try harness.agent.startRun("original task", "original context", "title", 60);
    const first_result = try harness.agent.waitRun(first, 60, 3_600);
    defer first_result.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), harness.agent.runs.items.len);
    harness.agent.run_counter = 0;
    const restored = try harness.agent.restoreRun("s1", 60);
    try std.testing.expectEqualStrings("s1", restored.id);
    try std.testing.expectEqualStrings("title", restored.title);
    const restored_result = try harness.agent.waitRun(restored, 60, 3_600);
    defer restored_result.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "original context") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "explicitly requested continuation of this completed task") != null);
    const next = try harness.agent.startRun("new task", "", "", 60);
    try std.testing.expect(!std.mem.eql(u8, next.id, "s1"));
    const next_result = try harness.agent.waitRun(next, 60, 3_600);
    defer next_result.deinit(a);
}

test "a subagent runs its own turn and reports back" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);

    const call =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"sub\",\"name\":\"subagent\",\"arguments\":\"{\\\"task\\\":\\\"count the tests\\\"}\"}]}";
    var mock: MockTransport = .{ .replies = &.{ call, completed_answer, completed_answer } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("delegate the counting");

    try harness.agent.runToolLoop();
    // One request per agent: the parent asks, the sub-agent answers, the parent
    // answers with that report in hand.
    try std.testing.expectEqual(@as(usize, 3), mock.requests.items.len);

    // The sub-agent is a conversation of its own: its own prompt, none of the
    // parent's messages, and none of the tools that belong to the terminal.
    const child = mock.requests.items[1];
    try std.testing.expect(std.mem.indexOf(u8, child, "You are a sub-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "delegate the counting") == null);
    for ([_][]const u8{ "\"ask_user\"", "\"announce_task\"", "\"subagent\"", "\"plan\"", "\"memory_save\"" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, child, name) == null);
    }

    // The parent reads back one report, not the sub-agent's transcript.
    const parent = mock.requests.items[2];
    try std.testing.expect(std.mem.indexOf(u8, parent, "Sub-agent report") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "answer.") != null);
}

test "a sub-agent's own results are cached and its report never is" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const harness = try TestHarness.init(a, io);
    defer harness.deinit(a);
    var silence = try Silence.init(io);
    defer silence.deinit(io);

    const dir = try tools.ccrDirPath(a, harness.agent.scratch.path);
    defer a.free(dir);
    const ctx: tools.Context = .{
        .io = io,
        .allocator = a,
        .env = harness.agent.tool_env,
        .cache_dir = dir,
        .agent = &harness.agent,
    };
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (0..1200) |_| try text.writer.writeAll("payload line\n");
    const long = text.written();
    try std.testing.expect(long.len > tools.max_output_bytes);

    // The report is the one text the caller verifies the work from: it reaches
    // the caller whole, at any size, with no preview and no cache id.
    const report = try Agent.afterToolCall(ctx, "subagent", "{}", .{ .output = try a.dupe(u8, long), .is_error = false });
    defer report.deinit(a);
    try std.testing.expectEqualStrings(long, report.output);
    try std.testing.expect(report.ccr_id == null and !report.is_error);

    // What the sub-agent runs itself goes through the cache like any other
    // agent's result: it is kept in the child's own scratch directory, and the
    // preview names the entry the child reads back with `ccr_retrieve`.
    harness.agent.role = .subagent;
    defer harness.agent.role = .main;
    const own = try Agent.afterToolCall(ctx, "read", "{}", .{ .output = try a.dupe(u8, long), .is_error = false });
    defer own.deinit(a);
    try std.testing.expect(own.ccr_id != null and !own.is_error);
    try std.testing.expect(own.output.len < long.len);
    const marker = std.mem.indexOf(u8, own.output, "[ccr ") orelse return error.MissingCacheId;
    try std.testing.expect(std.mem.indexOf(u8, own.output[marker..], "ccr_retrieve") != null);

    // The entry holds the whole result, so the child can page through it.
    const id = own.output[marker + "[ccr ".len ..][0..@import("../tools/ccr.zig").id_len];
    const path = try std.fmt.allocPrint(a, "{s}/{s}.log", .{ dir, id });
    defer a.free(path);
    const cached = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(long.len + 1));
    defer a.free(cached);
    try std.testing.expectEqualStrings(long, cached);
}

test "a self-check asks the child for a report and the caller waits for the end" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);

    // A self-check of zero is the child's first boundary, so the order of these
    // replies is the order of the run itself: start, self-check, report, the
    // child's final answer, the caller's answer.
    const start =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"sub\",\"name\":\"subagent\",\"arguments\":\"{\\\"task\\\":\\\"split the files\\\",\\\"self_check_seconds\\\":0}\"}]}";
    const progress =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"rep\",\"name\":\"report\",\"arguments\":\"{\\\"summary\\\":\\\"two of four files split\\\"}\"}]}";
    var mock: MockTransport = .{ .replies = &.{ start, progress, completed_answer, completed_answer } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("split the source tree");

    try harness.agent.runToolLoop();
    try std.testing.expectEqual(@as(usize, 4), mock.requests.items.len);

    // The child's first request carries the self-check as a line of its
    // conversation, the way a line the user typed would.
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "check-in interval has passed") != null);
    // The report comes back as permission to carry on, not as a question: the
    // child's answer to it is the next request it makes.
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[2], "two of four files split") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[2], "printed on the caller's terminal") != null);
    // The caller never sees the self-check. What it reads back is the final
    // report, once, when the run ends.
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[3], "Sub-agent report") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[3], "two of four files split") == null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[3], "answer.") != null);
}

test "a self-check answered instead of reported ends the run" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);

    // The self-check asks for a report or an answer, and the child that means
    // to stop answers: the run ends on that reply, as if it had finished, and
    // the caller reads it back. Only three requests are made — the child never
    // reaches another boundary.
    const start =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"sub\",\"name\":\"subagent\",\"arguments\":\"{\\\"task\\\":\\\"split the files\\\",\\\"self_check_seconds\\\":0}\"}]}";
    const stopped =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Stopping here: two of four files split, the rest blocked on a missing schema.\"}]}]}";
    var mock: MockTransport = .{ .replies = &.{ start, stopped, completed_answer } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("split the source tree");

    try harness.agent.runToolLoop();
    try std.testing.expectEqual(@as(usize, 3), mock.requests.items.len);
    // The prompt the child was given at the boundary names the stop it took.
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "check-in interval has passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "answer with your final report now, and the run ends there") != null);
    // The answer it stopped on is the caller's report, not the self-check.
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[2], "Sub-agent report") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[2], "the rest blocked on a missing schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[2], "check-in interval has passed") == null);
}

test "a self-check of zero asks again at every boundary" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);

    const start =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"sub\",\"name\":\"subagent\",\"arguments\":\"{\\\"task\\\":\\\"split the files\\\",\\\"self_check_seconds\\\":0}\"}]}";
    const first_report =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"rep1\",\"name\":\"report\",\"arguments\":\"{\\\"summary\\\":\\\"two of four files split\\\"}\"}]}";
    const second_report =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"rep2\",\"name\":\"report\",\"arguments\":\"{\\\"summary\\\":\\\"three of four files split\\\"}\"}]}";
    var mock: MockTransport = .{ .replies = &.{ start, first_report, second_report, completed_answer, completed_answer } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("split the source tree");

    try harness.agent.runToolLoop();
    // Two boundaries, two self-checks, and the same single wait for the caller.
    try std.testing.expectEqual(@as(usize, 5), mock.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "check-in interval has passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[2], "two of four files split") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[2], "check-in interval has passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[3], "three of four files split") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[4], "Sub-agent report") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[4], "answer.") != null);
}

test "the report tool belongs to the child and the clocks are checked" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    const ctx: tools.Context = .{
        .io = std.testing.io,
        .allocator = allocator,
        .agent = &harness.agent,
    };

    // A caller has nobody to report to: the self-check is the child's, and a
    // report from the agent on the terminal would only reach its own history.
    const reported = try tools.execute(ctx, "report", "{\"summary\":\"halfway\"}");
    defer reported.deinit(allocator);
    try std.testing.expect(reported.is_error);
    try std.testing.expect(std.mem.indexOf(u8, reported.output, "belongs to a sub-agent") != null);

    // A clock no run could keep is refused before the run starts.
    const checked = try tools.execute(ctx, "subagent", "{\"task\":\"anything\",\"self_check_seconds\":4000}");
    defer checked.deinit(allocator);
    try std.testing.expect(checked.is_error);
    try std.testing.expect(std.mem.indexOf(u8, checked.output, "self_check_seconds") != null);
    const undated = try tools.execute(ctx, "subagent", "{\"task\":\"anything\",\"deadline_seconds\":0}");
    defer undated.deinit(allocator);
    try std.testing.expect(undated.is_error);
    try std.testing.expect(std.mem.indexOf(u8, undated.output, "deadline_seconds") != null);
}

test "unified tools receive the owning agent through Context" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    const ctx: tools.Context = .{
        .io = std.testing.io,
        .allocator = allocator,
        .agent = &harness.agent,
    };
    const started = try tools.execute(ctx, "subagent", "{\"task\":\"anything\",\"self_check_seconds\":4000}");
    defer started.deinit(allocator);
    try std.testing.expect(started.is_error);
    try std.testing.expect(std.mem.indexOf(u8, started.output, "self_check_seconds") != null);

    // A saved run that was never started here is named as missing, and the
    // caller reads back why rather than a new run being started in its place.
    const resumed = try tools.execute(ctx, "subagent", "{\"id\":\"s9\"}");
    defer resumed.deinit(allocator);
    try std.testing.expect(resumed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, resumed.output, "could not restore sub-agent") != null);

    const plan = try tools.execute(ctx, "plan", "{}");
    defer plan.deinit(allocator);
    try std.testing.expect(!plan.is_error);
}

test "the sub-agent's progress line names its task and keeps to one line" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);

    var label: std.Io.Writer.Allocating = .init(allocator);
    defer label.deinit();

    // The task is model output: its newlines are flattened and its escape
    // sequences dropped, because the line is read on a terminal.
    try std.testing.expectEqualStrings(
        "subagent · count the tests…",
        (try harness.agent.callProgressLabel("subagent", "{\"task\":\"count \\u001b[31mthe tests\\u001b[0m\\nquietly\"}", &label)).?,
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, label.written(), 0x1b) == null);

    // A call whose title names the run shows the title, not the task behind
    // it: the title is the summary the caller chose for this line.
    const titled = "{\"task\":\"count every test in the source tree\\\\nand report\",\"title\":\"count the tests\"}";
    try std.testing.expectEqualStrings("subagent · count the tests", (try harness.agent.callProgressLabel("subagent", titled, &label)).?);
    var line: std.Io.Writer.Allocating = .init(allocator);
    defer line.deinit();
    try harness.agent.writeToolCall(&line.writer, "subagent", titled);
    try std.testing.expect(std.mem.indexOf(u8, line.written(), "⇢ " ++ BOLD ++ "subagent") != null);
    try std.testing.expect(std.mem.indexOf(u8, line.written(), "count the tests") != null);
    try std.testing.expect(std.mem.indexOf(u8, line.written(), "every test") == null);

    // A call with no task yet still says who is at work, and a tool that is
    // not a sub-agent keeps its own label.
    try std.testing.expectEqualStrings("subagent…", (try harness.agent.callProgressLabel("subagent", "{}", &label)).?);
    try std.testing.expectEqualStrings("bash…", (try harness.agent.callProgressLabel("bash", "{}", &label)).?);
    // A tool whose wait asks the user a question gets no line at all.
    try std.testing.expectEqual(@as(?[]const u8, null), try harness.agent.callProgressLabel("ask_user", "{}", &label));

    // A call that names a run already going shows that run's title, so the
    // second call on the same run reads as the same work.
    const run = try harness.agent.startRun("anything", "", "split the files", 3_600);
    try std.testing.expectEqualStrings("subagent · split the files", (try harness.agent.callProgressLabel("subagent", "{\"id\":\"s1\"}", &label)).?);
    // The run was started only to be named, so it is stopped here: nothing
    // waits on it, and the harness closes whatever is left at deinit.
    harness.agent.abortRun(run);
}

test "a title that cannot be one line is refused before a run starts" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    const ctx: tools.Context = .{
        .io = std.testing.io,
        .allocator = allocator,
        .agent = &harness.agent,
    };

    // A title of eighty characters is one too many and a line break inside one
    // would end the line early: both are refused, and neither starts a run.
    var too_long: [80]u8 = undefined;
    @memset(&too_long, 'a');
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("{{\"task\":\"anything\",\"title\":\"{s}\"}}", .{too_long});
    const long = try tools.execute(ctx, "subagent", aw.written());
    defer long.deinit(allocator);
    try std.testing.expect(long.is_error);
    try std.testing.expect(std.mem.indexOf(u8, long.output, "title") != null);

    const broken = try tools.execute(ctx, "subagent", "{\"task\":\"anything\",\"title\":\"one\\ntwo\"}");
    defer broken.deinit(allocator);
    try std.testing.expect(broken.is_error);
    try std.testing.expect(std.mem.indexOf(u8, broken.output, "one line") != null);
    try std.testing.expectEqual(@as(usize, 0), harness.agent.runs.items.len);
}

test "a subagent cannot start another one" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);

    const outer =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"outer\",\"name\":\"subagent\",\"arguments\":\"{\\\"task\\\":\\\"outer task\\\"}\"}]}";
    const inner =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"inner\",\"name\":\"subagent\",\"arguments\":\"{\\\"task\\\":\\\"inner task\\\"}\"}]}";
    var mock: MockTransport = .{ .replies = &.{ outer, inner, completed_answer, completed_answer } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("delegate twice");

    try harness.agent.runToolLoop();
    try std.testing.expectEqual(@as(usize, 4), mock.requests.items.len);
    // The refusal reaches the sub-agent as a tool result, so it finishes its own
    // task instead of starting a third agent.
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[2], "cannot start another sub-agent") != null);
}

test "a line typed while the task runs joins the next request instead of a new turn" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);
    var silence = try Silence.init(std.testing.io);
    defer silence.deinit(std.testing.io);
    // A tool call, then the answer. The user types while the call is answered,
    // which is the window a long tool or a slow request opens.
    const call =
        "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"task\",\"name\":\"announce_task\",\"arguments\":\"{\\\"title\\\":\\\"调整任务\\\",\\\"description\\\":\\\"先看实现。\\\"}\"}]}";
    var mock: MockTransport = .{
        .replies = &.{ call, completed_split },
        .agent = &harness.agent,
        .steer_at = 0,
        .steer_line = "also update the docs",
    };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };
    try harness.agent.appendUserMessage("Do the task");
    try harness.agent.runToolLoop();

    // One task, not two: the reply that follows the tool result is the only
    // answer, and it was asked for with the line the user typed.
    try std.testing.expectEqual(@as(usize, 2), mock.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[0], "also update the docs") == null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "function_call_output") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "also update the docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.requests.items[1], "guidance for the work in progress") != null);

    // The guidance is part of the conversation now, ahead of the answer.
    try std.testing.expectEqual(@as(usize, 6), harness.agent.history.items.len);
    const guidance = harness.agent.history.items[4];
    try std.testing.expectEqualStrings("user", guidance.role);
    try std.testing.expect(std.mem.indexOf(u8, guidance.content.?, "also update the docs") != null);
    try std.testing.expectEqualStrings("assistant", harness.agent.history.items[5].role);
    // Nothing is left waiting in the inbox once the turn settled.
    try std.testing.expectEqual(@as(usize, 0), harness.agent.inbox.items.len);
}

test "every tool a sub-agent is denied exists in the default set" {
    // The deny list is names, so a rename in tools/schema.zig would silently
    // hand a sub-agent a tool it must not have. This is the guard: the openai
    // test checks that the names it is given are dropped, and this one checks
    // the names still exist to be dropped.
    const tool_schema = @import("../tools/schema.zig");
    for (subagent_omitted) |name| {
        var found = false;
        for (tool_schema.builtin) |tool| {
            if (std.mem.eql(u8, tool.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "every built-in tool the model is offered uses the unified dispatch" {
    const tool_schema = @import("../tools/schema.zig");
    const dispatch = @import("../tools/dispatch.zig");
    for (tool_schema.builtin) |definition| {
        var host = false;
        for (dispatch.all) |spec| {
            if (std.mem.eql(u8, definition.name, spec.name)) host = true;
        }
        try std.testing.expect(host);
    }
}

test "a truncated reply is continued and kept as one message" {
    const allocator = std.testing.allocator;
    const harness = try TestHarness.init(allocator, std.testing.io);
    defer harness.deinit(allocator);

    var mock: MockTransport = .{ .replies = &.{ truncated_text, completed_answer } };
    defer mock.deinit(allocator);
    harness.agent.client.transport = .{ .context = &mock, .send = MockTransport.send };

    try blk: {
        var quiet = try Silence.init(std.testing.io);
        defer quiet.deinit(std.testing.io);
        try harness.agent.appendUserMessage("Do the task");
        break :blk harness.agent.runToolLoop();
    };

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

    try blk: {
        var quiet = try Silence.init(std.testing.io);
        defer quiet.deinit(std.testing.io);
        try harness.agent.appendUserMessage("Do the task");
        break :blk harness.agent.runToolLoop();
    };

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
        break :blk harness.agent.runToolLoop();
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

test "a result's status is a line of its own, with the result under it" {
    const a = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    // The status line carries how the call ended, and nothing the tool printed
    // shares it; the lines after it start where that line's own text would
    // have — under the glyph, not at the margin the glyph sits on.
    try writeResultPreview(&aw.writer, "one\ntwo", .{ .is_error = false, .exit_code = 0 });
    try std.testing.expectEqualStrings(
        DIM ++ "  ✓ exit 0\n    one\n    two\n" ++ RESET,
        aw.written(),
    );
    aw.clearRetainingCapacity();
    try writeResultPreview(&aw.writer, "Error: no such file", .{ .is_error = true });
    try std.testing.expectEqualStrings(RED ++ "  ✗\n    Error: no such file\n" ++ RESET, aw.written());
    aw.clearRetainingCapacity();
    try writeResultPreview(&aw.writer, "Tool timed out after 5s.", .{
        .is_error = true,
        .timed_out = true,
    });
    try std.testing.expectEqualStrings(
        RED ++ "  ✗ timed out\n    Tool timed out after 5s.\n" ++ RESET,
        aw.written(),
    );
    // A result that printed nothing is the status line alone.
    aw.clearRetainingCapacity();
    try writeResultPreview(&aw.writer, "", .{ .is_error = false, .exit_code = 0 });
    try std.testing.expectEqualStrings(DIM ++ "  ✓ exit 0\n" ++ RESET, aw.written());
    // A program killed from outside says which signal did it: the status line
    // is the only place the ending is written, so it has to be able to say
    // everything the shell would have.
    aw.clearRetainingCapacity();
    try writeResultPreview(&aw.writer, tools.no_output, .{
        .is_error = true,
        .termination = "SIGTERM",
    });
    try std.testing.expectEqualStrings(
        RED ++ "  ✗ SIGTERM\n" ++ RESET,
        aw.written(),
    );
}
