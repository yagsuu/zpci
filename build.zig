const std = @import("std");

const module = @import("build/modules.zig");
const testing = @import("build/testing.zig");

const Build = std.Build;
const Modules = module.Modules;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const modules = Modules.init(b, target, optimize);

    const check = b.step("check", "Compile all host test suites");
    const host = testing.addHostTests(b, &modules, target, optimize, check);
    const compile = testing.addCompileFixtureTests(b, &modules);

    const tests = b.step("test", "Run all tests");
    tests.dependOn(host);
    tests.dependOn(compile);
}
