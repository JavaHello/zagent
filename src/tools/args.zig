const std = @import("std");

pub fn optionalUnsigned(value: ?std.json.Value, minimum: usize) !?usize {
    const field = value orelse return null;
    if (field != .integer) return error.InvalidArguments;
    const number = std.math.cast(usize, field.integer) orelse return error.InvalidArguments;
    if (number < minimum) return error.InvalidArguments;
    return number;
}

/// A boolean argument that may be absent, in which case it is false. Anything
/// that is not a JSON boolean is refused rather than guessed at.
pub fn optionalBool(value: ?std.json.Value) !bool {
    const field = value orelse return false;
    return switch (field) {
        .bool => |flag| flag,
        else => error.InvalidArguments,
    };
}

/// A string argument that may be absent. An empty string counts as absent, so a
/// model that sends `"body": ""` gets a request with no body rather than one
/// with a zero-length body.
pub fn optionalString(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const field = value orelse return null;
    if (field != .string) return error.InvalidArguments;
    if (field.string.len == 0) return null;
    return try allocator.dupe(u8, field.string);
}

pub fn searchPath(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const path = (try optionalString(allocator, value)) orelse return allocator.dupe(u8, ".");
    if (std.mem.startsWith(u8, path, "-")) {
        defer allocator.free(path);
        return std.fmt.allocPrint(allocator, "./{s}", .{path});
    }
    return path;
}
