const std = @import("std");
const openai = @import("openai.zig");
const tools = @import("tools.zig");
const diff = @import("diff.zig");
const text = @import("text.zig");
const menu = @import("menu.zig");
const verifier = @import("verifier.zig");
const mcp = @import("mcp.zig");
const render = @import("render.zig");
const term = @import("term.zig");
const spinner = @import("spinner.zig");
const Config = @import("config.zig").Config;
const Linenoise = @import("linenoise").Linenoise;

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

// Prompt for the choice menu. Colour codes are fine here because linenoize's
// width() implementation correctly ignores ANSI SGR sequences.
const CHOICE_PROMPT = BOLD ++ YELLOW ++ "choice" ++ RESET ++ " \xe2\x9d\xaf ";

const SYSTEM_PROMPT =
    \\You are zagent, a powerful command-line AI assistant built with Zig.
    \\You can help users with any task by using the provided tools.
    \\
    \\Tools run in a Linux sandbox. Only the current workspace is writable; host home and credentials are hidden. Network access is disabled unless AI_TOOL_NETWORK=1.
    \\Guidelines:
    \\- Be concise and direct in your responses.
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
    \\- When the request is ambiguous, or when a decision only the user can make is blocking you, call ask_user with two to four concrete options and mark the one you recommend. Ask only when the answer changes what you do next; decide routine details yourself.
    \\- After every turn that used tools, an automatic completion check reviews your work. If it reports unfinished work, act on it instead of restating your answer.
;

/// The system prompt as the model is given it: the constant above, plus what
/// the MCP servers contribute — a sentence naming their tools, when there are
/// any, and whatever each server says about using it.
fn buildSystemPrompt(allocator: std.mem.Allocator, registry: *const mcp.Registry) ![]u8 {
    if (registry.functionJson().len == 0) return allocator.dupe(u8, SYSTEM_PROMPT);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    try aw.writer.writeAll(SYSTEM_PROMPT);
    try aw.writer.writeAll(
        "\n- Tools whose name starts with mcp__ come from an MCP server that is connected;" ++
            " call one exactly as you would any other tool.\n",
    );

    if (try registry.instructions(allocator)) |notes| {
        defer allocator.free(notes);
        try aw.writer.writeAll(notes);
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
    session_path: ?[]u8,
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

        const system_content = try buildSystemPrompt(allocator, mcp_registry);
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
            .session_path = session_path,
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
        if (self.session_path) |path| self.allocator.free(path);
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

    /// Process a single user query: work on it until the model answers and the
    /// completion check agrees that the request is done.
    pub fn processQuery(self: *Agent, query: []const u8) !void {
        self.query_started = std.Io.Timestamp.now(self.io, .awake);
        defer self.query_started = null;
        self.current_task = query;
        defer self.current_task = "";
        self.terminal_title.update("thinking…", query);
        self.processQueryInner(query) catch |err| {
            self.terminal_title.update("error", query);
            return err;
        };
        self.terminal_title.update("ready", query);
        const elapsed_ms = self.query_started.?.untilNow(self.io, .awake).toMilliseconds();
        try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  Worked for {d}.{d}s\n" ++ RESET, .{
            @divTrunc(elapsed_ms, 1000), @divTrunc(@mod(elapsed_ms, 1000), 100),
        });
    }

    fn progressOptions(self: *Agent) spinner.Options {
        return .{
            .enabled = self.animate_progress,
            .started = self.query_started,
            .prompt = self.progress_prompt,
            .first_frame_delay_ms = 0,
        };
    }

    fn processQueryInner(self: *Agent, query: []const u8) !void {
        try self.appendUserMessage(query);
        try self.checkpoint();
        // The judge is shown only what this turn produced, so remember where
        // the request it is checking starts.
        const turn_start = self.history.items.len;

        var verifications: u32 = 0;
        var worked = false;

        while (true) {
            const turn = try self.runToolLoop();
            if (!turn.completed) return error.IterationLimitReached;
            // Counted across the whole query, not per round: a round that only
            // claims the work is finished still has to pass the check.
            worked = worked or turn.tool_calls > 0;
            // A query that never touched a tool is a conversation, not a task.
            if (!worked) return;
            if (self.max_verifications == 0) return;

            if (verifications == self.max_verifications) {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ⟳ completion check budget ({d}) spent; task remains unverified\n" ++ RESET, .{self.max_verifications});
                return error.CompletionUnverified;
            }
            verifications += 1;

            // The check announces itself from inside `judgeAnimated`, where it
            // can be animated for as long as the judge is thinking.
            const verdict = (try self.judgeTurn(turn_start)) orelse return error.CompletionUnverified;
            defer verdict.deinit(self.allocator);

            if (verdict.complete) {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ✓ completion check passed\n" ++ RESET, .{});
                return;
            }

            try printFmt(std.Io.File.stderr(), self.io, self.allocator, YELLOW ++ "  ↻ not done: {s}\n" ++ RESET, .{verdict.reason});

            // The judge can hand the open question back as a menu of its own
            // making, for the turns the model never got around to asking about.
            if (verdict.options.items.len > 0) {
                const question = verdict.question orelse "How should I proceed?";
                const answer = (try self.askChoice(question, verdict.options.items)) orelse {
                    try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  stopped without an answer\n" ++ RESET, .{});
                    return;
                };
                defer self.allocator.free(answer);
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  → {s}\n" ++ RESET, .{answer});
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
    fn chatAnimated(self: *Agent, messages: []const Message) !openai.ApiResponse {
        self.terminal_title.update("thinking…", self.current_task);
        var spin = spinner.Spinner.start(self.io, std.Io.File.stderr(), "thinking…", self.progressOptions());
        defer spin.stop();
        return self.client.respond(messages, self.mcp_registry.functionJson()) catch |err| {
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
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ⟳ checking completion…\n" ++ RESET, .{});
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
        try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "  ✗ {s}\n" ++ RESET, .{message});
    }

    const Turn = struct {
        /// How many tool calls the model made before its final answer.
        tool_calls: usize,
        /// False when the iteration budget ran out before an answer.
        completed: bool,
    };

    /// Run the tool-call loop until the model answers or the iteration budget
    /// runs out. The answer is printed and kept in the history.
    fn runToolLoop(self: *Agent) !Turn {
        var turn: Turn = .{ .tool_calls = 0, .completed = false };
        var iteration: usize = 0;

        while (iteration < self.max_iterations) : (iteration += 1) {
            const response = self.chatAnimated(self.history.items) catch |err| {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "Error: failed to call API: {s}\n" ++ RESET, .{@errorName(err)});
                return err;
            };
            defer response.deinit(self.allocator);

            if (std.mem.eql(u8, response.finish_reason, "length")) {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "Error: model output still exceeds the token budget after automatic retries; split the task into smaller steps, or raise AI_MAX_TOKENS if the endpoint accepts more than DeepSeek's 8192.\n" ++ RESET, .{});
                return error.ResponseTruncated;
            }
            if (std.mem.eql(u8, response.finish_reason, "tool_calls")) {
                const tool_calls = response.tool_calls orelse {
                    try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "Error: finish_reason=tool_calls but no tool_calls\n" ++ RESET, .{});
                    return error.InvalidResponse;
                };

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
                    const stdout = std.Io.File.stdout();
                    if (stdout.isTty(self.io) catch false) try stdout.writeStreamingAll(self.io, "\n" ++ BOLD ++ CYAN ++ "Assistant" ++ RESET ++ "\n");
                    try self.writeAnswer(content);
                    try stdout.writeStreamingAll(self.io, "\n");

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
                try self.checkpoint();
                turn.completed = true;
                break;
            }
        }

        if (iteration == self.max_iterations) {
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "Error: reached maximum tool call iterations ({d})\n" ++ RESET, .{self.max_iterations});
        }

        return turn;
    }

    /// Ask the judge whether the turn that started at `turn_start` finished the
    /// user's request. Returns null when the judge could not be consulted or
    /// its reply could not be read: an unjudgeable turn keeps the answer it
    /// already printed rather than looping on a check that cannot pass.
    fn judgeTurn(self: *Agent, turn_start: usize) !?verifier.Verdict {
        const request = self.history.items[turn_start - 1].content orelse "";
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
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ⚠ completion check skipped: {s}\n" ++ RESET, .{@errorName(err)});
            return null;
        };
        defer response.deinit(self.allocator);

        const content = response.content orelse {
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ⚠ completion check skipped: the reply was empty\n" ++ RESET, .{});
            return null;
        };

        return verifier.parseVerdict(self.allocator, content) catch |err| {
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ⚠ completion check skipped: {s}\n" ++ RESET, .{@errorName(err)});
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
            try std.Io.File.stdout().writeStreamingAll(self.io, aw.written());
            // Nothing to read a choice from. Taking the recommendation keeps a
            // piped or single-query run moving instead of stalling it.
            if (recommended) |index| {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  no terminal to read an answer from; taking the recommended option\n" ++ RESET, .{});
                return try menu.describeAnswer(self.allocator, .{ .option = index }, options);
            }
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  no terminal to read an answer from\n" ++ RESET, .{});
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

        const raw_line = self.linenoise.linenoise(CHOICE_PROMPT) catch |err| switch (err) {
            error.CtrlC => return null,
            else => return err,
        };

        const line = raw_line orelse {
            // End of input: fall back to the recommendation, if any.
            if (recommended) |index| return try menu.describeAnswer(self.allocator, .{ .option = index }, options);
            return null;
        };
        defer self.allocator.free(line);

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

    /// Announce a tool call on the line above whatever it prints.
    ///
    /// Most tools are one line of name and arguments. `apply_patch` is the
    /// exception: its argument is the diff itself, and a JSON-escaped diff tells
    /// nobody anything — so it is drawn instead, line by line, in the colours
    /// the change would be read in.
    fn announceToolCall(self: *Agent, call: ToolCallData) !void {
        const stderr = std.Io.File.stderr();

        // Written through a fixed buffer rather than built up in memory first:
        // a patch is read as it is drawn, and a long one never has to be held
        // whole to be shown.
        var buf: [4096]u8 = undefined;
        var file_writer = stderr.writerStreaming(self.io, &buf);
        const w = &file_writer.interface;

        if (!std.mem.eql(u8, call.name, "apply_patch")) {
            try w.writeAll(YELLOW ++ "  ⚙ ");
            // A tool name and its arguments are model output like any other, so
            // they are sanitised like any other: a call carrying an escape
            // sequence gets to be read, not to repaint the line it is on.
            try text.writeSanitized(w, call.name);
            try w.writeAll(RESET ++ " ");
            try text.writeSanitized(w, call.arguments);
            try w.writeByte('\n');
            return file_writer.interface.flush();
        }

        const patch_text = openai.extractStringArg(self.allocator, call.arguments, "patch") catch {
            // Nothing to draw. What the model actually sent still goes up, so
            // the call is visible; the dispatch reports what was wrong with it.
            try w.writeAll(YELLOW ++ "  ⚙ apply_patch" ++ RESET ++ " ");
            try text.writeSanitized(w, call.arguments);
            try w.writeByte('\n');
            return file_writer.interface.flush();
        };
        defer self.allocator.free(patch_text);

        try w.writeAll(YELLOW ++ "  ⚙ apply_patch\n" ++ RESET);
        try diff.render(w, patch_text);
        try file_writer.interface.flush();
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

            if (std.mem.eql(u8, call.name, "ask_user")) {
                break :blk try self.askUser(call.arguments);
            } else if (std.mem.startsWith(u8, call.name, mcp.tool_prefix)) {
                // A tool of a connected MCP server: the registry knows which
                // server it belongs to and what the server calls it.
                break :blk try self.mcp_registry.call(self.allocator, call.name, call.arguments);
            } else {
                break :blk try @import("sandbox.zig").execute(self.io, self.allocator, self.tool_network, call.name, call.arguments);
            }
        };

        // Print a brief preview of the result
        const preview_len = @min(result.content.len, 200);
        const truncated = result.content.len > preview_len;
        if (result.is_error) {
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "  ✗ {s}\n" ++ RESET, .{result.content});
        } else if (truncated) {
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ✓ {s}...\n" ++ RESET, .{result.content[0..preview_len]});
        } else {
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ✓ {s}\n" ++ RESET, .{result.content});
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
        if (!self.render_markdown) return stdout.writeStreamingAll(self.io, content);

        // A fixed buffer rather than `Writer.Allocating`: for a long answer the
        // latter would hold the entire styled document in memory before
        // printing a byte of it. This buffer is the renderer's only memory,
        // whatever the size of the document.
        var buf: [8192]u8 = undefined;
        var file_writer = stdout.writerStreaming(self.io, &buf);

        try render.render(&file_writer.interface, content, .{
            .width = term.usableWidth(term.columns(stdout)),
        });
        try file_writer.interface.flush();
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
