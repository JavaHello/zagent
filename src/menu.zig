const std = @import("std");

// ANSI colour codes
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";

/// One choice offered to the user. Whoever holds the `Options` owns the slices.
pub const Option = struct {
    label: []const u8,
    /// Empty when the model described nothing.
    description: []const u8,
    recommended: bool,

    pub fn deinit(self: Option, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.description);
    }
};

/// A parsed list of choices, owning its backing slice.
pub const Options = struct {
    items: []Option,

    pub fn none() Options {
        return .{ .items = &.{} };
    }

    pub fn deinit(self: Options, allocator: std.mem.Allocator) void {
        for (self.items) |option| option.deinit(allocator);
        if (self.items.len > 0) allocator.free(self.items);
    }
};

/// The parsed arguments of one ask_user call.
pub const Question = struct {
    text: []const u8,
    options: Options,

    pub fn deinit(self: Question, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.options.deinit(allocator);
    }
};

/// What the user did at a menu.
pub const Answer = union(enum) {
    /// Index into the offered options.
    option: usize,
    /// The user's own words, borrowed from the line that was read.
    custom: []const u8,
    /// Nothing to go on: Enter with no recommendation to fall back on.
    skip,
};

/// Parse the `arguments` string of an ask_user tool call. Everything the model
/// can get wrong — unparseable JSON, a missing question, no usable options —
/// comes back as `InvalidQuestion`, so callers have one case to report.
pub fn parseAskUser(allocator: std.mem.Allocator, arguments_json: []const u8) !Question {
    return parseAskUserInner(allocator, arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidQuestion,
    };
}

fn parseAskUserInner(allocator: std.mem.Allocator, arguments_json: []const u8) !Question {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidQuestion;
    const question_val = parsed.value.object.get("question") orelse return error.InvalidQuestion;
    if (question_val != .string) return error.InvalidQuestion;
    const options_val = parsed.value.object.get("options") orelse return error.InvalidQuestion;

    const options = try parseOptions(allocator, options_val);
    errdefer options.deinit(allocator);

    return .{
        .text = try allocator.dupe(u8, question_val.string),
        .options = options,
    };
}

/// Parse an `options` array. A bare string counts as a label with no
/// description, because models drift into `["a","b"]` often enough that
/// rejecting it would cost a whole extra round trip.
pub fn parseOptions(allocator: std.mem.Allocator, value: std.json.Value) !Options {
    if (value != .array) return error.InvalidOptions;

    var items: std.ArrayList(Option) = .empty;
    errdefer {
        for (items.items) |option| option.deinit(allocator);
        items.deinit(allocator);
    }

    for (value.array.items) |entry| {
        // A malformed element is skipped rather than failing the whole call,
        // the way the response parser skips unreadable tool calls.
        const option = (try buildOption(allocator, entry)) orelse continue;
        errdefer option.deinit(allocator);
        try items.append(allocator, option);
    }

    if (items.items.len == 0) return error.InvalidOptions;

    return .{ .items = try items.toOwnedSlice(allocator) };
}

fn buildOption(allocator: std.mem.Allocator, value: std.json.Value) !?Option {
    var label: []const u8 = undefined;
    var description: []const u8 = "";
    var recommended = false;

    switch (value) {
        .string => |text| label = text,
        .object => |obj| {
            const label_val = obj.get("label") orelse return null;
            if (label_val != .string) return null;
            label = label_val.string;
            if (obj.get("description")) |description_val| {
                if (description_val == .string) description = description_val.string;
            }
            if (obj.get("recommended")) |recommended_val| {
                if (recommended_val == .bool) recommended = recommended_val.bool;
            }
        },
        else => return null,
    }

    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    return .{
        .label = owned_label,
        .description = try allocator.dupe(u8, description),
        .recommended = recommended,
    };
}

pub fn recommendedIndex(options: []const Option) ?usize {
    for (options, 0..) |option, i| {
        if (option.recommended) return i;
    }
    return null;
}

/// Write the numbered menu. Only the first option marked recommended is
/// flagged, so a model that marks several cannot produce a contradictory list.
pub fn writeMenu(w: *std.Io.Writer, question: []const u8, options: []const Option) !void {
    const recommended = recommendedIndex(options);

    try w.writeByte('\n');
    try w.print("  {s}\n", .{question});
    for (options, 0..) |option, i| {
        try w.print("    {d}) {s}", .{ i + 1, option.label });
        if (option.description.len > 0) {
            try w.print("  " ++ DIM ++ "{s}" ++ RESET, .{option.description});
        }
        if (recommended != null and recommended.? == i) {
            try w.writeAll(" " ++ BOLD ++ "(recommended)" ++ RESET);
        }
        try w.writeByte('\n');
    }
}

/// Interpret one line typed at a menu. An empty answer takes the recommended
/// option; a number or the option's own label picks by position; anything else
/// is handed back as the user's own words.
pub fn parseAnswer(raw: []const u8, options: []const Option, recommended: ?usize) Answer {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0) return if (recommended) |i| .{ .option = i } else .skip;

    // Accept "2", "2)" and "2." — the numbering is what the menu shows.
    const digits = std.mem.trimEnd(u8, line, ").");
    if (std.fmt.parseInt(usize, digits, 10)) |number| {
        if (number >= 1 and number <= options.len) return .{ .option = number - 1 };
    } else |_| {}

    for (options, 0..) |option, i| {
        if (std.ascii.eqlIgnoreCase(line, option.label)) return .{ .option = i };
    }

    return .{ .custom = line };
}

/// One line describing the outcome, for the model to read. Owned by the caller.
pub fn describeAnswer(allocator: std.mem.Allocator, answer: Answer, options: []const Option) ![]u8 {
    return switch (answer) {
        .option => |i| blk: {
            const option = options[i];
            const separator = if (option.description.len > 0) " — " else "";
            if (option.recommended) {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "User selected the recommended option: {s}{s}{s}",
                    .{ option.label, separator, option.description },
                );
            }
            break :blk try std.fmt.allocPrint(
                allocator,
                "User selected: {s}{s}{s}",
                .{ option.label, separator, option.description },
            );
        },
        .custom => |text| std.fmt.allocPrint(
            allocator,
            "The user did not pick one of the options and answered: {s}",
            .{text},
        ),
        .skip => allocator.dupe(
            u8,
            "The user pressed Enter without choosing, and no option was marked recommended. Decide yourself and continue.",
        ),
    };
}

const test_options = [_]Option{
    .{ .label = "Add tests", .description = "Covers the new branch.", .recommended = true },
    .{ .label = "Skip tests", .description = "", .recommended = false },
};

test "parse ask_user arguments" {
    const allocator = std.testing.allocator;
    const question = try parseAskUser(allocator,
        \\{"question":"How should I test this?","options":[{"label":"Add tests","description":"Covers the new branch.","recommended":true},{"label":"Skip tests"}]}
    );
    defer question.deinit(allocator);

    try std.testing.expectEqualStrings("How should I test this?", question.text);
    try std.testing.expectEqual(@as(usize, 2), question.options.items.len);
    try std.testing.expectEqualStrings("Add tests", question.options.items[0].label);
    try std.testing.expectEqualStrings("Covers the new branch.", question.options.items[0].description);
    try std.testing.expect(question.options.items[0].recommended);
    try std.testing.expectEqualStrings("", question.options.items[1].description);
    try std.testing.expect(!question.options.items[1].recommended);
}

test "parse options accepts bare strings and skips malformed entries" {
    const allocator = std.testing.allocator;
    const options = try parseAskUser(allocator,
        \\{"question":"Which?","options":["alpha",{"label":"beta"},42]}
    );
    defer options.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), options.options.items.len);
    try std.testing.expectEqualStrings("alpha", options.options.items[0].label);
    try std.testing.expectEqualStrings("beta", options.options.items[1].label);
}

test "ask_user arguments without options are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidQuestion, parseAskUser(allocator, "{\"question\":\"Which?\"}"));
    try std.testing.expectError(error.InvalidQuestion, parseAskUser(allocator, "{\"question\":\"Which?\",\"options\":[]}"));
    try std.testing.expectError(error.InvalidQuestion, parseAskUser(allocator, "not json"));
}

test "a numbered answer picks that option" {
    try std.testing.expectEqual(Answer{ .option = 1 }, parseAnswer("2", &test_options, 0));
    try std.testing.expectEqual(Answer{ .option = 0 }, parseAnswer(" 1) ", &test_options, null));
    try std.testing.expectEqual(Answer{ .option = 0 }, parseAnswer("1.", &test_options, null));
}

test "an empty answer takes the recommendation" {
    try std.testing.expectEqual(Answer{ .option = 0 }, parseAnswer("\n", &test_options, 0));
    // With nothing marked, Enter leaves the decision to the model.
    try std.testing.expectEqual(Answer.skip, parseAnswer("", &test_options, null));
}

test "an answer may repeat an option label" {
    try std.testing.expectEqual(Answer{ .option = 1 }, parseAnswer("skip TESTS", &test_options, 0));
}

test "anything else is the user's own words" {
    try std.testing.expectEqualStrings("do neither", parseAnswer("do neither", &test_options, 0).custom);
    try std.testing.expectEqualStrings("9", parseAnswer("9", &test_options, 0).custom);
}

test "the menu marks only the first recommended option" {
    const allocator = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const options = [_]Option{
        .{ .label = "A", .description = "first", .recommended = true },
        .{ .label = "B", .description = "", .recommended = true },
    };
    try writeMenu(&aw.writer, "Which one?", &options);

    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "Which one?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1) A") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2) B") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "(recommended)"));
}

test "the description names the recommendation" {
    const allocator = std.testing.allocator;

    const chosen = try describeAnswer(allocator, .{ .option = 0 }, &test_options);
    defer allocator.free(chosen);
    try std.testing.expectEqualStrings(
        "User selected the recommended option: Add tests — Covers the new branch.",
        chosen,
    );

    const other = try describeAnswer(allocator, .{ .option = 1 }, &test_options);
    defer allocator.free(other);
    try std.testing.expectEqualStrings("User selected: Skip tests", other);

    const custom = try describeAnswer(allocator, .{ .custom = "neither" }, &test_options);
    defer allocator.free(custom);
    try std.testing.expectEqualStrings("The user did not pick one of the options and answered: neither", custom);
}
