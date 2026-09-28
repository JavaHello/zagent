const std = @import("std");
const Config = @import("config.zig").Config;
const Agent = @import("agent.zig").Agent;
const provider = @import("provider.zig");
const history = @import("history.zig");
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
    \\  /quit, /exit Exit zagent
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

    const history_path = try openHistory(allocator, io, env, &ln);
    defer if (history_path) |path| allocator.free(path);

    var agent = try Agent.init(allocator, io, config, &ln, env);
    defer agent.deinit();

    if (args.items.len > 1) {
        // Single-query mode: join remaining args as the query
        const query = try std.mem.join(allocator, " ", args.items[1..]);
        defer allocator.free(query);
        try agent.processQuery(query);
    } else {
        // Interactive REPL mode
        try runRepl(allocator, io, &agent, config, &ln, history_path);
    }
}

fn runRepl(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent: *Agent,
    config: Config,
    ln: *Linenoise,
    history_path: ?[]const u8,
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
    _ = @import("verifier.zig");
    _ = @import("style.zig");
    _ = @import("term.zig");
    _ = @import("text.zig");
    _ = @import("render.zig");
    _ = @import("spinner.zig");
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
