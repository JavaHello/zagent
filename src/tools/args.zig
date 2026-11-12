const std = @import("std");

/// A required string argument, owned by the caller. Absent, null or a
/// non-string value is refused rather than guessed at; the tool that asked for
/// it turns the error into the message it gives the model.
pub fn requiredString(allocator: std.mem.Allocator, arguments: []const u8, field: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;
    const value = parsed.value.object.get(field) orelse return error.MissingField;
    if (value != .string) return error.InvalidFieldType;
    return allocator.dupe(u8, value.string);
}

/// Whether the call names `field` at all. Arguments that do not parse are not
/// this check's business: the tool's own parser reports them.
pub fn hasField(allocator: std.mem.Allocator, arguments: []const u8, field: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return parsed.value.object.get(field) != null;
}

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
