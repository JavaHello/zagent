const Build = @import("std").Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wcwidth = b.dependency("wcwidth", .{
        .target = target,
        .optimize = optimize,
    }).module("wcwidth");

    _ = b.addModule("linenoise", .{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{
                .name = "wcwidth",
                .module = wcwidth,
            },
        },
    });
}
