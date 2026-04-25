const std = @import("std");
const openai = @import("openai.zig");
const tools = @import("tools.zig");
const Config = @import("config.zig").Config;

const Message = openai.Message;
const ToolCallData = openai.ToolCallData;

// ANSI colour codes
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const CYAN = "\x1b[36m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";

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
    \\- If an operation fails, analyze the error and try a different approach.
;

pub const Agent = struct {
    allocator: std.mem.Allocator,
    client: openai.Client,
    history: std.ArrayList(Message),

    pub fn init(allocator: std.mem.Allocator, config: Config) !Agent {
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
            .client = openai.Client.init(allocator, config),
            .history = history,
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

    /// Process a single user query through the agent loop.
    pub fn processQuery(self: *Agent, query: []const u8) !void {
        const user_content = try self.allocator.dupe(u8, query);
        errdefer self.allocator.free(user_content);
        try self.history.append(self.allocator, .{
            .role = "user",
            .content = user_content,
            .reasoning_content = null,
            .tool_calls = null,
            .tool_call_id = null,
        });

        var iteration: usize = 0;
        const max_iterations = 200;

        while (iteration < max_iterations) : (iteration += 1) {
            const response = self.client.chat(self.history.items) catch |err| {
                try printFmt(std.fs.File.stderr(), self.allocator, RED ++ "Error: failed to call API: {s}\n" ++ RESET, .{@errorName(err)});
                return err;
            };
            defer response.deinit(self.allocator);

            if (std.mem.eql(u8, response.finish_reason, "tool_calls")) {
                const tool_calls = response.tool_calls orelse {
                    try printFmt(std.fs.File.stderr(), self.allocator, RED ++ "Error: finish_reason=tool_calls but no tool_calls\n" ++ RESET, .{});
                    return error.InvalidResponse;
                };

                // Clone tool calls so the assistant message can own them
                const owned_calls = try cloneToolCalls(self.allocator, tool_calls);
                errdefer {
                    for (owned_calls) |c| c.deinit(self.allocator);
                    self.allocator.free(owned_calls);
                }
                try self.history.append(self.allocator, .{
                    .role = "assistant",
                    .content = null,
                    .reasoning_content = if (response.reasoning_content) |value| try self.allocator.dupe(u8, value) else null,
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
                // Continue: call API again with tool results
            } else {
                // Final answer
                if (response.content) |content| {
                    try std.fs.File.stdout().writeAll("\n" ++ BOLD ++ CYAN ++ "Assistant" ++ RESET ++ "\n");
                    try std.fs.File.stdout().writeAll(content);
                    try std.fs.File.stdout().writeAll("\n");

                    const owned_content = try self.allocator.dupe(u8, content);
                    errdefer self.allocator.free(owned_content);
                    try self.history.append(self.allocator, .{
                        .role = "assistant",
                        .content = owned_content,
                        .reasoning_content = if (response.reasoning_content) |value| try self.allocator.dupe(u8, value) else null,
                        .tool_calls = null,
                        .tool_call_id = null,
                    });
                }
                break;
            }
        }

        if (iteration == max_iterations) {
            try printFmt(std.fs.File.stderr(), self.allocator, RED ++ "Error: reached maximum tool call iterations ({d})\n" ++ RESET, .{max_iterations});
        }
    }

    fn executeTool(self: *Agent, call: ToolCallData) !tools.ToolResult {
        try printFmt(std.fs.File.stderr(), self.allocator, YELLOW ++ "  ⚙ {s}" ++ RESET ++ " {s}\n", .{ call.name, call.arguments });

        const result: tools.ToolResult = blk: {
            if (std.mem.eql(u8, call.name, "shell")) {
                const command = openai.extractStringArg(self.allocator, call.arguments, "command") catch {
                    break :blk .{
                        .content = try self.allocator.dupe(u8, "Error: missing 'command' argument"),
                        .is_error = true,
                    };
                };
                defer self.allocator.free(command);
                break :blk try tools.executeShell(self.allocator, command);
            } else if (std.mem.eql(u8, call.name, "read_file")) {
                const path = openai.extractStringArg(self.allocator, call.arguments, "path") catch {
                    break :blk .{
                        .content = try self.allocator.dupe(u8, "Error: missing 'path' argument"),
                        .is_error = true,
                    };
                };
                defer self.allocator.free(path);
                break :blk try tools.readFile(self.allocator, path);
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
                break :blk try tools.writeFile(self.allocator, path, content);
            } else if (std.mem.eql(u8, call.name, "list_dir")) {
                const path = openai.extractStringArg(self.allocator, call.arguments, "path") catch {
                    break :blk .{
                        .content = try self.allocator.dupe(u8, "Error: missing 'path' argument"),
                        .is_error = true,
                    };
                };
                defer self.allocator.free(path);
                break :blk try tools.listDir(self.allocator, path);
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
            try printFmt(std.fs.File.stderr(), self.allocator, RED ++ "  ✗ {s}\n" ++ RESET, .{result.content});
        } else if (truncated) {
            try printFmt(std.fs.File.stderr(), self.allocator, DIM ++ "  ✓ {s}...\n" ++ RESET, .{result.content[0..preview_len]});
        } else {
            try printFmt(std.fs.File.stderr(), self.allocator, DIM ++ "  ✓ {s}\n" ++ RESET, .{result.content});
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

fn printFmt(file: std.fs.File, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try file.writeAll(text);
}
