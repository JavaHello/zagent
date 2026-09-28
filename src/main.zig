const std = @import("std");
const Config = @import("config.zig").Config;
const Agent = @import("agent.zig").Agent;
const provider = @import("provider.zig");
const history = @import("history.zig");
const commands = @import("commands.zig");
const mcp = @import("mcp.zig");
const Linenoise = @import("linenoise").Linenoise;

// ANSI colour codes
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const MAGENTA = "\x1b[35m";
const YELLOW = "\x1b[33m";

const BANNER =
    \\
    \\   ███████╗ █████╗  ██████╗ ███████╗███╗   ██╗████████╗
    \\   ╚════██║██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝
    \\       ██╔╝███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║   
    \\      ██╔╝ ██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║   
    \\      ██║  ██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║   
    \\      ╚═╝  ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝   
    \\
;

const HELP =
    \\Commands:
    \\  /help        Show this help message
    \\  /clear       Clear conversation history
    \\  /new         Start a new conversation (same as /clear)
    \\  /model       Show current model
    \\  /mcp         List the MCP servers and their tools
    \\  /quit, /exit Exit zagent
    \\  Tab          Complete a /command (a description appears as you type)
    \\  Ctrl+D       Exit zagent
    \\
;

// Prompt passed to linenoise. Colour codes are fine here because
// linenoize's width() implementation correctly ignores ANSI SGR sequences.
const PROMPT = BOLD ++ GREEN ++ "you" ++ RESET ++ " \xe2\x9d\xaf ";

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

    // The terminal is created here rather than inside the REPL so that the
    // ask_user menu also works in single-query mode.
    var ln = Linenoise.init(allocator, io, env);
    defer ln.deinit();
    // Slash commands complete on Tab and are described by dim ghost text as
    // they are typed. The ask_user menu clears these around its own reads, so
    // an answer there is never treated as a command.
    ln.completions_callback = commands.complete;
    ln.hints_callback = commands.hint;

    const history_path = try openHistory(allocator, io, env, &ln);
    defer if (history_path) |path| allocator.free(path);

    // The MCP servers are started before the first question, because the tools
    // they bring are part of what the question is asked with. Everything about
    // them is written to stderr: stdout belongs to the answer, and
    // `zagent "..." > notes.md` must stay clean.
    var problems: std.ArrayList([]u8) = .empty;
    defer {
        for (problems.items) |problem| allocator.free(problem);
        problems.deinit(allocator);
    }
    const stderr = std.Io.File.stderr();
    var watcher = McpProgress{ .io = io, .allocator = allocator };
    var registry = mcp.Registry.connect(allocator, io, env, &problems, .{
        .context = &watcher,
        .started = McpProgress.started,
    }) catch |err| failed: {
        try printToStderr(allocator, io, YELLOW ++ "  ⚠ mcp: no servers were read: {s}\n" ++ RESET, .{@errorName(err)});
        break :failed mcp.Registry.empty(allocator, io);
    };
    // Declared before the agent, because the agent borrows it and the defers
    // run in reverse: the agent has to be gone before this one is freed.
    defer registry.deinit();
    {
        var buf: [4096]u8 = undefined;
        var file_writer = stderr.writerStreaming(io, &buf);
        for (problems.items) |problem| {
            try file_writer.interface.print(YELLOW ++ "  ⚠ {s}\n" ++ RESET, .{problem});
        }
        try registry.writeStartup(&file_writer.interface);
        try file_writer.interface.flush();
        if (registry.functionJson().len > 0) {
            try file_writer.interface.writeAll(DIM ++ "\n" ++ RESET);
            try file_writer.interface.flush();
        }
    }

    var agent = try Agent.init(allocator, io, config, &ln, env, &registry);
    defer agent.deinit();

    if (args.items.len > 1) {
        // Single-query mode: join remaining args as the query
        const query = try std.mem.join(allocator, " ", args.items[1..]);
        defer allocator.free(query);
        try agent.processQuery(query);
    } else {
        // Interactive REPL mode
        try runRepl(allocator, io, &agent, config, &ln, history_path, &registry);
    }
}

fn runRepl(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent: *Agent,
    config: Config,
    ln: *Linenoise,
    history_path: ?[]const u8,
    registry: *const mcp.Registry,
) !void {
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    try stdout.writeStreamingAll(io, MAGENTA ++ BOLD ++ BANNER ++ RESET);
    {
        const model_line = if (config.provider) |selected|
            try std.fmt.allocPrint(allocator, DIM ++ "  Model : {s}  ({s})\n" ++ RESET, .{ config.model, @tagName(selected) })
        else
            try std.fmt.allocPrint(allocator, DIM ++ "  Model : {s}\n" ++ RESET, .{config.model});
        defer allocator.free(model_line);
        try stdout.writeStreamingAll(io, model_line);
    }
    try stdout.writeStreamingAll(io, DIM ++ "  Type /help for commands, Ctrl+D to exit.\n\n" ++ RESET);

    if (config.api_key.len == 0) {
        // Name the variable that actually applies, so a provider user is not
        // told to export a key for some other service.
        const key_var = if (config.provider) |selected| selected.spec().api_key_env else "OPENAI_API_KEY";
        const msg = try std.fmt.allocPrint(
            allocator,
            YELLOW ++ "Warning: {s} is not set.\n  export {s}=your-key\n\n" ++ RESET,
            .{ key_var, key_var },
        );
        defer allocator.free(msg);
        try stderr.writeStreamingAll(io, msg);
    }

    while (true) {
        // linenoise handles raw-mode input, Unicode width, and multi-byte
        // character deletion correctly (including Chinese/CJK characters).
        // Returns null on EOF (Ctrl+D); error.CtrlC on Ctrl+C.
        const raw_line = (ln.linenoise(PROMPT) catch |err| switch (err) {
            error.CtrlC => {
                try stdout.writeStreamingAll(io, "\n");
                break;
            },
            else => return err,
        }) orelse {
            try stdout.writeStreamingAll(io, "\n");
            break;
        };
        defer allocator.free(raw_line);

        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0) continue;

        // Add non-empty lines to history so the user can navigate with ↑/↓.
        // The file, when there is one, makes that outlive the process; it is
        // written before the query runs, so an interrupt part-way through an
        // answer cannot lose the question that asked for it.
        try ln.history.add(line);
        if (history_path) |path| history.save(io, ln, path);

        if (std.mem.eql(u8, line, "/quit") or std.mem.eql(u8, line, "/exit")) {
            try stdout.writeStreamingAll(io, DIM ++ "Goodbye!\n" ++ RESET);
            break;
        } else if (std.mem.eql(u8, line, "/help")) {
            try stdout.writeStreamingAll(io, HELP);
        } else if (std.mem.eql(u8, line, "/clear") or std.mem.eql(u8, line, "/new")) {
            agent.clearHistory();
            try stdout.writeStreamingAll(io, DIM ++ "Conversation history cleared.\n" ++ RESET);
        } else if (std.mem.eql(u8, line, "/model")) {
            const msg = try std.fmt.allocPrint(allocator, "Model: {s}\n", .{config.model});
            defer allocator.free(msg);
            try stdout.writeStreamingAll(io, msg);
        } else if (std.mem.eql(u8, line, "/mcp")) {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try registry.writeStatus(&aw.writer);
            try stdout.writeStreamingAll(io, aw.written());
        } else {
            agent.processQuery(line) catch |err| {
                const errmsg = try std.fmt.allocPrint(allocator, "\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
                defer allocator.free(errmsg);
                try stderr.writeStreamingAll(io, errmsg);
            };
        }

        try stdout.writeStreamingAll(io, "\n");
    }
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
    _ = @import("agent.zig");
    _ = @import("history.zig");
    _ = @import("tools.zig");
    _ = @import("diff.zig");
    _ = @import("openai.zig");
    _ = @import("config.zig");
    _ = @import("provider.zig");
    _ = @import("menu.zig");
    _ = @import("commands.zig");
    _ = @import("verifier.zig");
    _ = @import("style.zig");
    _ = @import("term.zig");
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
