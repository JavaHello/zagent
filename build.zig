const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zagent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run zagent");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const integration_step = b.step("test-integration", "Run CLI integration tests (Python 3 required)");
    var previous: *std.Build.Step = b.getInstallStep();
    for ([_][]const u8{
        "tests/workspace_integration.py",
        "tests/streaming_integration.py",
        "tests/execution_integration.py",
        "tests/completion_integration.py",
        "tests/responses_failure_integration.py",
        "tests/menu_integration.py",
        "tests/popup_integration.py",
        "tests/runtime_integration.py",
        "tests/interrupt_integration.py",
        "tests/session_integration.py",
    }) |script| {
        const command = b.addSystemCommand(&.{"python3"});
        command.addFileArg(b.path(script));
        command.step.dependOn(previous);
        previous = &command.step;
    }
    integration_step.dependOn(previous);
}
