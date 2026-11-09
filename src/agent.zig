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
    \\Tools run in a sandbox. Only the current workspace is writable; host home and credentials are hidden. Network access is disabled unless AI_TOOL_NETWORK=1.
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
                judged = try self.judgeTurn(turn_start);
            }
            const verdict = judged orelse {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ✗ no usable completion verdict in {d} checks; the answer above stands unverified\n" ++ RESET, .{verifications});
                return error.CompletionUnverified;
            };
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
        // Text from replies that the token limit cut short. It is held back
        // until the answer is complete, so the pieces print as the one reply
        // they were meant to be instead of several half-rendered documents.
        var carried: std.ArrayList(u8) = .empty;
        defer carried.deinit(self.allocator);
        var continuations: usize = 0;
        var empty_continuations: usize = 0;
        // Where this turn's continuation fragments start in the history. When
        // the turn settles they are folded into the answer, or dropped if the
        // reply turned into a tool call, so no transport scaffolding is kept.
        var continuation_start: ?usize = null;

        while (iteration < self.max_iterations) : (iteration += 1) {
            const response = self.chatAnimated(self.history.items) catch |err| {
                // Do not leave a continuation prompt as the last message for
                // the next request to answer.
                self.settleContinuations(&continuation_start, carried.items) catch {};
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "Error: failed to call API: {s}\n" ++ RESET, .{@errorName(err)});
                return err;
            };
            defer response.deinit(self.allocator);

            if (std.mem.eql(u8, response.finish_reason, "length")) {
                // The client already retried with a larger budget where its
                // cap allowed it. What is left is to keep the text that was
                // produced and ask for the rest, rather than lose the turn.
                if (response.content) |partial| {
                    if (continuations >= max_continuations) {
                        try self.reportTruncation(&continuation_start, carried.items, partial);
                        return error.ResponseTruncated;
                    }
                    continuations += 1;
                    if (continuation_start == null) continuation_start = self.history.items.len;
                    try carried.appendSlice(self.allocator, partial);
                    try self.appendAssistantText(partial);
                    try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  … reply cut off by the output limit; continuing where it stopped\n" ++ RESET, .{});
                    try self.appendUserMessage(continue_prompt);
                    continue;
                }
                if (empty_continuations >= max_empty_continuations) {
                    try self.reportTruncation(&continuation_start, carried.items, "");
                    return error.ResponseTruncated;
                }
                empty_continuations += 1;
                if (continuation_start == null) continuation_start = self.history.items.len;
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  … reply cut off before any text; asking for a smaller step\n" ++ RESET, .{});
                try self.appendUserMessage(if (carried.items.len > 0) continue_prompt else restart_prompt);
                continue;
            }
            if (std.mem.eql(u8, response.finish_reason, "tool_calls")) {
                const tool_calls = response.tool_calls orelse {
                    self.settleContinuations(&continuation_start, carried.items) catch {};
                    try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "Error: finish_reason=tool_calls but no tool_calls\n" ++ RESET, .{});
                    return error.InvalidResponse;
                };

                // A partial reply that led to a tool call is not the answer;
                // drop its fragments before the call joins the conversation.
                try self.settleContinuations(&continuation_start, "");
                carried.clearRetainingCapacity();

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
                    const stdout = std.Io.File.stdout();
                    if (stdout.isTty(self.io) catch false) try stdout.writeStreamingAll(self.io, "\n" ++ BOLD ++ CYAN ++ "Assistant" ++ RESET ++ "\n");
                    try self.writeAnswer(printed);
                    try stdout.writeStreamingAll(self.io, "\n");

                    if (continuation_start != null) {
                        // Fold the pieces and prompts into the one reply they
                        // make up; incomplete items are never replayed.
                        try self.settleContinuations(&continuation_start, printed);
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
            try self.settleContinuations(&continuation_start, carried.items);
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

        // A verdict cut off by the token limit cannot be trusted, even when
        // the fragment happens to parse: the outer loop asks again.
        if (std.mem.eql(u8, response.finish_reason, "length")) {
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ⚠ completion check skipped: the reply was truncated\n" ++ RESET, .{});
            return null;
        }

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

    /// Keep a partial reply in the history, without response items, so the
    /// next request can continue it. Incomplete output must not be replayed.
    fn appendAssistantText(self: *Agent, partial: []const u8) !void {
        const owned = try self.allocator.dupe(u8, partial);
        errdefer self.allocator.free(owned);
        try self.history.append(self.allocator, .{
            .role = "assistant",
            .content = owned,
            .reasoning_content = null,
            .tool_calls = null,
            .tool_call_id = null,
        });
    }

    /// Remove the partial replies and prompts a continuation left in the
    /// history, keeping their text as one assistant message when there is any.
    /// A turn that ends in a tool call or an error must not leave the model's
    /// transport scaffolding behind for the next request to read.
    fn settleContinuations(self: *Agent, start: *?usize, keep: []const u8) !void {
        const index = start.* orelse return;
        while (self.history.items.len > index) {
            const message = self.history.items[self.history.items.len - 1];
            self.history.items.len -= 1;
            message.deinit(self.allocator);
        }
        start.* = null;
        if (keep.len > 0) try self.appendAssistantText(keep);
    }

    /// Give up on a reply the token limit keeps cutting short. What was
    /// produced before is still worth printing: losing it would be worse than
    /// the error that ends the turn.
    fn reportTruncation(self: *Agent, start: *?usize, carried: []const u8, partial: []const u8) !void {
        const answer = try std.mem.concat(self.allocator, u8, &.{ carried, partial });
        defer self.allocator.free(answer);
        try self.settleContinuations(start, answer);
        if (answer.len > 0) {
            const stdout = std.Io.File.stdout();
            if (stdout.isTty(self.io) catch false) try stdout.writeStreamingAll(self.io, "\n" ++ BOLD ++ CYAN ++ "Assistant" ++ RESET ++ "\n");
            try self.writeAnswer(answer);
            try stdout.writeStreamingAll(self.io, "\n");
        }
        try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "Error: model output still exceeds the token budget after automatic retries and continuations; split the task into smaller steps, or raise AI_MAX_TOKENS if the endpoint accepts more than DeepSeek's 8192.\n" ++ RESET, .{});
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
        break :blk harness.agent.runToolLoop();
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
        break :blk harness.agent.runToolLoop();
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
