const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});

    const stdx_dep = b.dependency("zstdx", .{
        .target = host_target,
        .optimize = optimize,
    });
    const stdx = stdx_dep.module("stdx");

    const pci = b.addModule("pci", .{
        .root_source_file = b.path("src/pci.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "stdx", .module = stdx }},
    });

    const tests_root = b.createModule(.{
        .root_source_file = b.path("test/all.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdx", .module = stdx },
            .{ .name = "pci", .module = pci },
        },
    });
    const tests = b.addTest(.{ .root_module = tests_root });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run host-side tests");
    test_step.dependOn(&run_tests.step);
}
