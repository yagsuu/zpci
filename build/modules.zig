const std = @import("std");

const Build = std.Build;
const Module = Build.Module;
const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = Build.ResolvedTarget;

const ModuleImport = struct { []const u8, *Module };

pub const Modules = struct {
    pci: *Module,
    bar: *Module,
    capabilities: *Module,
    config: *Module,
    core: *Module,
    header: *Module,
    interrupts: *Module,
    memory: *Module,
    resources: *Module,
    topology: *Module,
    testing: *Module,

    pub fn init(
        b: *Build,
        target: ResolvedTarget,
        optimize: OptimizeMode,
    ) Modules {
        const stdx = b.dependency("zstdx", .{
            .target = target,
            .optimize = optimize,
        }).module("stdx");

        const modules: Modules = .{
            .pci = b.addModule("pci", .{
                .root_source_file = b.path("src/pci.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .bar = b.createModule(.{
                .root_source_file = b.path("src/bar.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .capabilities = addModule(b, "capabilities", target, optimize),
            .config = addModule(b, "config", target, optimize),
            .core = addModule(b, "core", target, optimize),
            .header = addModule(b, "header", target, optimize),
            .interrupts = addModule(b, "interrupts", target, optimize),
            .memory = addModule(b, "memory", target, optimize),
            .resources = addModule(b, "resources", target, optimize),
            .topology = addModule(b, "topology", target, optimize),
            .testing = addModule(b, "testing", target, optimize),
        };

        addImports(modules.pci, &.{
            .{ "bar", modules.bar },
            .{ "capabilities", modules.capabilities },
            .{ "config", modules.config },
            .{ "core", modules.core },
            .{ "header", modules.header },
            .{ "interrupts", modules.interrupts },
            .{ "memory", modules.memory },
            .{ "resources", modules.resources },
            .{ "topology", modules.topology },
            .{ "testing", modules.testing },
        });

        addImports(modules.core, &.{
            .{ "stdx", stdx },
        });

        addImports(modules.config, &.{
            .{ "stdx", stdx },
            .{ "core", modules.core },
        });

        addImports(modules.header, &.{
            .{ "config", modules.config },
            .{ "core", modules.core },
            .{ "testing", modules.testing },
            .{ "stdx", stdx },
        });

        addImports(modules.bar, &.{
            .{ "stdx", stdx },
            .{ "config", modules.config },
            .{ "core", modules.core },
            .{ "header", modules.header },
        });

        addImports(modules.capabilities, &.{
            .{ "stdx", stdx },
            .{ "config", modules.config },
            .{ "core", modules.core },
            .{ "testing", modules.testing },
        });

        addImports(modules.interrupts, &.{
            .{ "config", modules.config },
            .{ "core", modules.core },
            .{ "capabilities", modules.capabilities },
            .{ "memory", modules.memory },
        });

        addImports(modules.resources, &.{
            .{ "stdx", stdx },
            .{ "bar", modules.bar },
            .{ "config", modules.config },
            .{ "core", modules.core },
            .{ "header", modules.header },
            .{ "testing", modules.testing },
        });

        addImports(modules.topology, &.{
            .{ "stdx", stdx },
            .{ "capabilities", modules.capabilities },
            .{ "config", modules.config },
            .{ "core", modules.core },
            .{ "header", modules.header },
        });

        addImports(modules.testing, &.{
            .{ "config", modules.config },
            .{ "core", modules.core },
            .{ "memory", modules.memory },
        });

        return modules;
    }
};

fn addImports(module: *Module, imports: []const ModuleImport) void {
    for (imports) |entry| {
        module.addImport(entry[0], entry[1]);
    }
}

fn addModule(
    b: *Build,
    name: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
) *Module {
    return b.createModule(.{
        .root_source_file = b.path(b.fmt("src/{s}/module.zig", .{name})),
        .target = target,
        .optimize = optimize,
    });
}
