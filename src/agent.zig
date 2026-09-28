const std = @import("std");
const openai = @import("openai.zig");
const tools = @import("tools.zig");
const menu = @import("menu.zig");
const verifier = @import("verifier.zig");
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
    \\Guidelines:
    \\- Be concise and direct in your responses.
    \\- Use the shell tool to run commands, install packages, or perform system operations.
    \\- Use read_file / write_file for file operations.
    \\- Use list_dir to explore directories.
    \\- Chain multiple tool calls to accomplish complex tasks step by step.
    \\- Always explain what you are doing when using tools.
    \\- If an operation fails, analyze the error and try a different approach, but stop after 3-5 failed attempts and explain what went wrong.
    \\- If a task seems impossible with available tools (e.g. requires a web browser, authentication, or blocked services), report this to the user instead of retrying endlessly.
    \\- Do not repeat the same tool call with the same parameters.
    \\- When the request is ambiguous, or when a decision only the user can make is blocking you, call ask_user with two to four concrete options and mark the one you recommend. Ask only when the answer changes what you do next; decide routine details yourself.
    \\- After every turn that used tools, an automatic completion check reviews your work. If it reports unfinished work, act on it instead of restating your answer.
;

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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config, linenoise: *Linenoise) !Agent {
        var history: std.ArrayList(Message) = .empty;
        errdefer history.deinit(allocator);

        const system_content = try allocator.dupe(u8, SYSTEM_PROMPT);
        errdefer allocator.free(system_content);
        try history.append(allocator, .{
            .role = "system",
            .content = system_content,
            .reasoning_content = null,
            .tool_calls = null,
            .tool_call_id = null,
        });

        return .{
            .allocator = allocator,
            .io = io,
            .client = openai.Client.init(allocator, io, config),
            .history = history,
            .max_iterations = config.max_iterations,
            .max_verifications = config.max_verifications,
            .linenoise = linenoise,
        };
    }

    pub fn deinit(self: *Agent) void {
        for (self.history.items) |msg| msg.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.client.deinit();
    }

    /// Clear conversation history (keeps the system prompt).
    pub fn clearHistory(self: *Agent) void {
        for (self.history.items[1..]) |msg| msg.deinit(self.allocator);
        self.history.shrinkRetainingCapacity(1);
    }

    /// Process a single user query: work on it until the model answers and the
    /// completion check agrees that the request is done.
    pub fn processQuery(self: *Agent, query: []const u8) !void {
        try self.appendUserMessage(query);
        // The judge is shown only what this turn produced, so remember where
        // the request it is checking starts.
        const turn_start = self.history.items.len;

        var verifications: u32 = 0;
        var worked = false;

        while (true) {
            const turn = try self.runToolLoop();
            if (!turn.completed) return;
            // Counted across the whole query, not per round: a round that only
            // claims the work is finished still has to pass the check.
            worked = worked or turn.tool_calls > 0;
            // A query that never touched a tool is a conversation, not a task.
            if (!worked) return;
            if (self.max_verifications == 0) return;

            if (verifications == self.max_verifications) {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ⟳ completion check budget ({d}) spent; ending the turn unchecked\n" ++ RESET, .{self.max_verifications});
                return;
            }
            verifications += 1;

            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  ⟳ checking completion…\n" ++ RESET, .{});

            const verdict = (try self.judgeTurn(turn_start)) orelse return;
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
            const response = self.client.chat(self.history.items) catch |err| {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, RED ++ "Error: failed to call API: {s}\n" ++ RESET, .{@errorName(err)});
                return err;
            };
            defer response.deinit(self.allocator);

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
                // DeepSeek requires the assistant turn to be replayed as it was
                // received, so keep any content alongside the tool calls.
                const owned_content = if (response.content) |value| try self.allocator.dupe(u8, value) else null;
                errdefer if (owned_content) |value| self.allocator.free(value);
                const owned_reasoning = if (response.reasoning_content) |value| try self.allocator.dupe(u8, value) else null;
                errdefer if (owned_reasoning) |value| self.allocator.free(value);

                try self.history.append(self.allocator, .{
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
                turn.tool_calls += tool_calls.len;
                // Continue: call API again with tool results
            } else {
                // Final answer
                if (response.content) |content| {
                    const stdout = std.Io.File.stdout();
                    try stdout.writeStreamingAll(self.io, "\n" ++ BOLD ++ CYAN ++ "Assistant" ++ RESET ++ "\n");
                    try stdout.writeStreamingAll(self.io, content);
                    try stdout.writeStreamingAll(self.io, "\n");

                    const owned_content = try self.allocator.dupe(u8, content);
                    errdefer self.allocator.free(owned_content);
                    const owned_reasoning = if (response.reasoning_content) |value| try self.allocator.dupe(u8, value) else null;
                    errdefer if (owned_reasoning) |value| self.allocator.free(value);

                    try self.history.append(self.allocator, .{
                        .role = "assistant",
                        .content = owned_content,
                        .reasoning_content = owned_reasoning,
                        .tool_calls = null,
                        .tool_call_id = null,
                    });
                }
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

        const response = self.client.chatWithoutTools(&messages) catch |err| {
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
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try menu.writeMenu(&aw.writer, question, options);
        try std.Io.File.stdout().writeStreamingAll(self.io, aw.written());

        const recommended = menu.recommendedIndex(options);

        if (!self.linenoise.is_tty or !self.linenoise.term_supported) {
            // Nothing to read a choice from. Taking the recommendation keeps a
            // piped or single-query run moving instead of stalling it.
            if (recommended) |index| {
                try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  no terminal to read an answer from; taking the recommended option\n" ++ RESET, .{});
                return try menu.describeAnswer(self.allocator, .{ .option = index }, options);
            }
            try printFmt(std.Io.File.stderr(), self.io, self.allocator, DIM ++ "  no terminal to read an answer from\n" ++ RESET, .{});
            return null;
        }

        const hint = if (recommended) |index|
            try std.fmt.allocPrint(self.allocator, "  Enter takes option {d}; type a number, or your own answer.\n", .{index + 1})
        else
            try self.allocator.dupe(u8, "  Type the number of your choice.\n");
        defer self.allocator.free(hint);
        try printFmt(std.Io.File.stdout(), self.io, self.allocator, DIM ++ "{s}" ++ RESET, .{hint});

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

        return try menu.describeAnswer(self.allocator, menu.parseAnswer(line, options, recommended), options);
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

    /// Append a user-role message, taking a copy of `text`.
    fn appendUserMessage(self: *Agent, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.history.append(self.allocator, .{
            .role = "user",
            .content = owned,
            .reasoning_content = null,
            .tool_calls = null,
            .tool_call_id = null,
        });
    }

    fn executeTool(self: *Agent, call: ToolCallData) !tools.ToolResult {
        try printFmt(std.Io.File.stderr(), self.io, self.allocator, YELLOW ++ "  ⚙ {s}" ++ RESET ++ " {s}\n", .{ call.name, call.arguments });

        const result: tools.ToolResult = blk: {
            if (std.mem.eql(u8, call.name, "shell")) {
                const command = openai.extractStringArg(self.allocator, call.arguments, "command") catch {
                    break :blk .{
                        .content = try self.allocator.dupe(u8, "Error: missing 'command' argument"),
                        .is_error = true,
                    };
                };
                defer self.allocator.free(command);
                break :blk try tools.executeShell(self.io, self.allocator, command);
            } else if (std.mem.eql(u8, call.name, "read_file")) {
                const path = openai.extractStringArg(self.allocator, call.arguments, "path") catch {
                    break :blk .{
                        .content = try self.allocator.dupe(u8, "Error: missing 'path' argument"),
                        .is_error = true,
                    };
                };
                defer self.allocator.free(path);
                break :blk try tools.readFile(self.io, self.allocator, path);
            } else if (std.mem.eql(u8, call.name, "write_file")) {
                const path = openai.extractStringArg(self.allocator, call.arguments, "path") catch {
                    break :blk .{
                        .content = try self.allocator.dupe(u8, "Error: missing 'path' argument"),
                        .is_error = true,
                    };
                };
                defer self.allocator.free(path);
                const content = openai.extractStringArg(self.allocator, call.arguments, "content") catch {
                    break :blk .{
                        .content = try self.allocator.dupe(u8, "Error: missing 'content' argument"),
                        .is_error = true,
                    };
                };
                defer self.allocator.free(content);
                break :blk try tools.writeFile(self.io, self.allocator, path, content);
            } else if (std.mem.eql(u8, call.name, "list_dir")) {
                const path = openai.extractStringArg(self.allocator, call.arguments, "path") catch {
                    break :blk .{
                        .content = try self.allocator.dupe(u8, "Error: missing 'path' argument"),
                        .is_error = true,
                    };
                };
                defer self.allocator.free(path);
                break :blk try tools.listDir(self.io, self.allocator, path);
            } else if (std.mem.eql(u8, call.name, "ask_user")) {
                break :blk try self.askUser(call.arguments);
            } else {
                break :blk .{
                    .content = try std.fmt.allocPrint(self.allocator, "Unknown tool: {s}", .{call.name}),
                    .is_error = true,
                };
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
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try file.writeStreamingAll(io, text);
}
