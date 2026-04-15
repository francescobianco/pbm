const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "pbm",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run pbm");
    run_step.dependOn(&run_cmd.step);

    const smoke_cmd = b.addSystemCommand(&.{ "bash", "test/smoke-fetch.sh" });
    smoke_cmd.step.dependOn(b.getInstallStep());

    const smoke_step = b.step("smoke", "Run fetch smoke test");
    smoke_step.dependOn(&smoke_cmd.step);
}
