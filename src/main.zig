const std = @import("std");
const Config = @import("config.zig").Config;
const Agent = @import("agent.zig").Agent;
const Linenoise = @import("linenoise").Linenoise;

// ANSI colour codes
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
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
    \\  /model       Show current model
    \\  /quit, /exit Exit zagent
    \\  Ctrl+D       Exit zagent
    \\
;

// Prompt passed to linenoise. Colour codes are fine here because
// linenoize's width() implementation correctly ignores ANSI SGR sequences.
const PROMPT = BOLD ++ GREEN ++ "you" ++ RESET ++ " \xe2\x9d\xaf ";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try Config.load(allocator);
    defer config.deinit();

    var agent = try Agent.init(allocator, config);
    defer agent.deinit();

    if (args.len > 1) {
        // Single-query mode: join remaining args as the query
        const query = try std.mem.join(allocator, " ", args[1..]);
        defer allocator.free(query);
        try agent.processQuery(query);
    } else {
        // Interactive REPL mode
        try runRepl(allocator, &agent, config);
    }
}

fn runRepl(allocator: std.mem.Allocator, agent: *Agent, config: Config) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    try stdout.writeAll(MAGENTA ++ BOLD ++ BANNER ++ RESET);
    {
        const msg = try std.fmt.allocPrint(allocator, DIM ++ "  Model : {s}\n" ++ RESET, .{config.model});
        defer allocator.free(msg);
        try stdout.writeAll(msg);
    }
    try stdout.writeAll(DIM ++ "  Type /help for commands, Ctrl+D to exit.\n\n" ++ RESET);

    if (config.api_key.len == 0) {
        try stderr.writeAll(YELLOW ++ "Warning: OPENAI_API_KEY is not set.\n  export OPENAI_API_KEY=your-key\n\n" ++ RESET);
    }

    var ln = Linenoise.init(allocator);
    defer ln.deinit();

    while (true) {
        // linenoise handles raw-mode input, Unicode width, and multi-byte
        // character deletion correctly (including Chinese/CJK characters).
        // Returns null on EOF (Ctrl+D); error.CtrlC on Ctrl+C.
        const raw_line = (ln.linenoise(PROMPT) catch |err| switch (err) {
            error.CtrlC => {
                try stdout.writeAll("\n");
                break;
            },
            else => return err,
        }) orelse {
            try stdout.writeAll("\n");
            break;
        };
        defer allocator.free(raw_line);

        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0) continue;

        // Add non-empty lines to history so the user can navigate with ↑/↓.
        try ln.history.add(line);

        if (std.mem.eql(u8, line, "/quit") or std.mem.eql(u8, line, "/exit")) {
            try stdout.writeAll(DIM ++ "Goodbye!\n" ++ RESET);
            break;
        } else if (std.mem.eql(u8, line, "/help")) {
            try stdout.writeAll(HELP);
        } else if (std.mem.eql(u8, line, "/clear")) {
            agent.clearHistory();
            try stdout.writeAll(DIM ++ "Conversation history cleared.\n" ++ RESET);
        } else if (std.mem.eql(u8, line, "/model")) {
            const msg = try std.fmt.allocPrint(allocator, "Model: {s}\n", .{config.model});
            defer allocator.free(msg);
            try stdout.writeAll(msg);
        } else {
            agent.processQuery(line) catch |err| {
                const errmsg = try std.fmt.allocPrint(allocator, "\x1b[31mError: {s}\x1b[0m\n", .{@errorName(err)});
                defer allocator.free(errmsg);
                try stderr.writeAll(errmsg);
            };
        }

        try stdout.writeAll("\n");
    }
}

test "config loads" {
    const config = try Config.load(std.testing.allocator);
    defer config.deinit();
    try std.testing.expect(config.max_tokens > 0);
}
