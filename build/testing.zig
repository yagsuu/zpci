const std = @import("std");

const module = @import("modules.zig");

const Build = std.Build;
const Module = Build.Module;
const Modules = module.Modules;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;
const Step = Build.Step;

const Category = struct {
    name: []const u8,
    module: *Module,
};

const CompileFixture = struct {
    name: []const u8,
    message: []const u8,
};

pub fn addHostTests(
    b: *Build,
    modules: *const Modules,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    check: *Step,
) *Step {
    const stdx = b.dependency("zstdx", .{
        .target = target,
        .optimize = optimize,
    }).module("stdx");

    const host = b.step("test-host", "Run host-side tests");
    const categories = [_]Category{
        .{ .name = "core", .module = modules.core },
        .{ .name = "config", .module = modules.config },
        .{ .name = "header", .module = modules.header },
        .{ .name = "bar", .module = modules.bar },
        .{ .name = "capabilities", .module = modules.capabilities },
        .{ .name = "memory", .module = modules.memory },
        .{ .name = "resources", .module = modules.resources },
        .{ .name = "topology", .module = modules.topology },
        .{ .name = "testing", .module = modules.testing },
    };

    for (categories) |category| {
        const step = b.step(
            b.fmt("test-{s}", .{category.name}),
            b.fmt("Run {s} tests", .{category.name}),
        );

        host.dependOn(step);
        addSuite(b, step, check, category.module);
    }

    const integration = b.step("test-integration", "Run integration tests");
    host.dependOn(integration);

    const root = b.createModule(.{
        .root_source_file = b.path("test/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdx", .module = stdx },
            .{ .name = "pci", .module = modules.pci },
        },
    });

    addSuite(b, integration, check, root);
    return host;
}

pub fn addCompileFixtureTests(b: *Build, modules: *const Modules) *Step {
    const step = b.step("test-compile", "Run compile fixtures");

    for (fixtures) |fixture| {
        const root = b.createModule(.{
            .root_source_file = b.path(b.fmt("test/compile/{s}.zig", .{fixture.name})),
            .target = modules.pci.resolved_target.?,
            .optimize = modules.pci.optimize.?,
            .imports = &.{.{ .name = "pci", .module = modules.pci }},
        });
        const compile = b.addObject(.{ .name = fixture.name, .root_module = root });
        compile.step.name = b.fmt("compile fixture {s}", .{fixture.name});

        compile.expect_errors = .{ .contains = fixture.message };

        step.dependOn(&compile.step);
    }

    return step;
}

fn addSuite(b: *Build, category: *Step, check: *Step, root: *Module) void {
    const tests = b.addTest(.{ .root_module = root });
    const run = b.addRunArtifact(tests);
    check.dependOn(&tests.step);
    category.dependOn(&run.step);
}

const fixtures = [_]CompileFixture{
    .{ .name = "unsupported_offset", .message = "configuration offsets require u8, u16, or u32" },
    .{ .name = "relative_offset", .message = "configuration access requires an absolute Offset" },
    .{ .name = "absolute_offset", .message = "capability access requires a RelativeOffset" },
    .{ .name = "raw_offset", .message = "configuration access requires an absolute Offset" },
    .{ .name = "config_raw_offset", .message = "configuration access requires an absolute Offset" },
    .{ .name = "config_relative_offset", .message = "configuration access requires an absolute Offset" },
    .{ .name = "unaligned_offset", .message = "'UnalignedAccess'" },
};
