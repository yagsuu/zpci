//! Tests for docs/specs/resources/assignment.md.

const std = @import("std");

const pci = @import("pci");

const assignment = pci.resources.assignment;
const bar = pci.bar;
const config = pci.config;
const core = pci.core;

const Assignment = assignment.Assignment;
const Function = config.Function;
const Kind = assignment.Kind;
const Node = assignment.Node;
const Requirement = assignment.Requirement;
const RootWindows = assignment.RootWindows;
const Source = assignment.Source;
const TestConfigSpace = pci.testing.config.TestConfigSpace;

const function_window_size: usize = 0x1000;

test "unit: sizeBound sums all nodes while empty roots emit no assignments" {
    // Include an unreachable node so the sizing helper remains an upper bound, not a reachability walk.
    var fixture = FunctionFixture{};
    fixture.init(1);
    const function = fixture.function;
    const reqs0 = [_]Requirement{barRequirement(function, 0, .mmio32, 0x1000, 0x1000)};
    const reqs1 = [_]Requirement{
        barRequirement(function, 1, .io, 0x100, 0x100),
        barRequirement(function, 2, .mmio64, 0x2000, 0x2000),
    };
    const nodes = [_]Node{
        .{ .parent = null, .kind = .endpoint, .requirements = &reqs0 },
        .{ .parent = null, .kind = .endpoint, .requirements = &reqs1 },
    };
    const input = assignment.Input{
        .nodes = &nodes,
        .roots = &.{},
        .root_windows = .{},
    };
    var scratch: [3]Assignment = undefined;

    try std.testing.expectEqual(@as(usize, 3), assignment.sizeBound(&nodes));
    const plan = try assignment.intoScratch(input, &scratch);
    try std.testing.expectEqual(@as(usize, 0), plan.assignments.len);
}

test "unit: intoScratch allows more assignments than nodes" {
    // Build a valid plan whose assignment count exceeds the node-count bound.
    var fixture = FunctionFixture{};
    fixture.init(8);
    const function = fixture.function;
    const reqs = [_]Requirement{
        barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
        barRequirement(function, 1, .mmio32, 0x1000, 0x1000),
        barRequirement(function, 2, .mmio32, 0x1000, 0x1000),
        barRequirement(function, 3, .mmio32, 0x1000, 0x1000),
        barRequirement(function, 4, .mmio32, 0x1000, 0x1000),
        barRequirement(function, 5, .mmio32, 0x1000, 0x1000),
        romRequirement(function, 0x1000, 0x1000),
    };
    const node_count = assignment.max_nodes / reqs.len + 1;
    const assignment_count = node_count * reqs.len;
    const allocator = std.testing.allocator;
    const nodes = try allocator.alloc(Node, node_count);
    defer allocator.free(nodes);
    const roots = try allocator.alloc(assignment.NodeIndex, node_count);
    defer allocator.free(roots);
    const scratch = try allocator.alloc(Assignment, assignment_count);
    defer allocator.free(scratch);

    for (nodes, roots, 0..) |*node, *root, index| {
        node.* = .{ .parent = null, .kind = .endpoint, .requirements = &reqs };
        root.* = @intCast(index);
    }

    const plan = try assignment.intoScratch(.{
        .nodes = nodes,
        .roots = roots,
        .root_windows = .{ .mmio32 = .range(.mmio32, 0x8000_0000, assignment_count * 0x1000) },
    }, scratch);

    try std.testing.expect(assignment_count > assignment.max_nodes);
    try std.testing.expectEqual(assignment_count, plan.assignments.len);
}

test "unit: DFS preorder emits parent requirements before children in input order" {
    // Give each requirement a distinct BAR index so the emitted sequence identifies the visited node.
    var fixture = FunctionFixture{};
    fixture.init(2);
    const function = fixture.function;
    const root_reqs = [_]Requirement{bridgeWindowRequirement(function, .memory, .mmio32, 0x4000, 0x1000)};
    const child0_reqs = [_]Requirement{barRequirement(function, 0, .mmio32, 0x1000, 0x1000)};
    const child1_reqs = [_]Requirement{barRequirement(function, 1, .mmio32, 0x1000, 0x1000)};
    const nodes = [_]Node{
        .{ .parent = null, .kind = .bridge, .requirements = &root_reqs },
        .{ .parent = 0, .kind = .endpoint, .requirements = &child0_reqs },
        .{ .parent = 0, .kind = .endpoint, .requirements = &child1_reqs },
    };
    const input = assignment.Input{
        .nodes = &nodes,
        .roots = &.{0},
        .root_windows = .{ .mmio32 = .range(.mmio32, 0x8000_0000, 0x8000) },
    };
    var scratch: [3]Assignment = undefined;

    const plan = try assignment.intoScratch(input, &scratch);

    try std.testing.expectEqual(@as(usize, 3), plan.assignments.len);
    try expectBridgeWindow(plan.assignments[0], .memory);
    try expectBarIndex(plan.assignments[1], 0);
    try expectBarIndex(plan.assignments[2], 1);
    try std.testing.expectEqual(@as(u64, 0x8000_0000), plan.assignments[0].base);
    try std.testing.expectEqual(@as(u64, 0x8000_0000), plan.assignments[1].base);
    try std.testing.expectEqual(@as(u64, 0x8000_1000), plan.assignments[2].base);
}

test "unit: pool preference records natural pools" {
    // Run isolated one-requirement cases so each natural pool decision is directly observable.
    var fixture = FunctionFixture{};
    fixture.init(3);
    const function = fixture.function;
    const cases = [_]PlacementCase{
        .{
            .name = "io natural",
            .requirement = barRequirement(function, 0, .io, 0x10, 0x10),
            .windows = .{ .io = .range(.io, 0x1000, 0x100) },
            .pool = .io,
            .base = 0x1000,
        },
        .{
            .name = "mmio32 natural",
            .requirement = barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
            .windows = .{ .mmio32 = .range(.mmio32, 0x8000_0000, 0x2000) },
            .pool = .mmio32,
            .base = 0x8000_0000,
        },
        .{
            .name = "mmio32_pref natural",
            .requirement = barRequirement(function, 0, .mmio32_pref, 0x1000, 0x1000),
            .windows = .{ .mmio32_pref = .range(.mmio32_pref, 0x9000_0000, 0x2000) },
            .pool = .mmio32_pref,
            .base = 0x9000_0000,
        },
        .{
            .name = "mmio64 natural",
            .requirement = barRequirement(function, 0, .mmio64, 0x1000, 0x1000),
            .windows = .{ .mmio64 = .range(.mmio64, 0x1_0000_0000, 0x2000) },
            .pool = .mmio64,
            .base = 0x1_0000_0000,
        },
        .{
            .name = "mmio64_pref natural",
            .requirement = barRequirement(function, 0, .mmio64_pref, 0x1000, 0x1000),
            .windows = .{ .mmio64_pref = .range(.mmio64_pref, 0x2_0000_0000, 0x2000) },
            .pool = .mmio64_pref,
            .base = 0x2_0000_0000,
        },
    };

    try expectPlacements(&cases);
}

test "unit: pool preference records fallback pools" {
    // Run isolated one-requirement cases so each fallback decision is directly observable.
    var fixture = FunctionFixture{};
    fixture.init(3);
    const function = fixture.function;
    const cases = [_]PlacementCase{
        .{
            .name = "mmio32_pref fallback",
            .requirement = barRequirement(function, 0, .mmio32_pref, 0x1000, 0x1000),
            .windows = .{ .mmio32 = .range(.mmio32, 0xA000_0000, 0x2000) },
            .pool = .mmio32,
            .base = 0xA000_0000,
        },
        .{
            .name = "mmio64 fallback",
            .requirement = barRequirement(function, 0, .mmio64, 0x1000, 0x1000),
            .windows = .{ .mmio32 = .range(.mmio32, 0xB000_0000, 0x2000) },
            .pool = .mmio32,
            .base = 0xB000_0000,
        },
        .{
            .name = "mmio64_pref prefetchable 32-bit fallback",
            .requirement = barRequirement(function, 0, .mmio64_pref, 0x1000, 0x1000),
            .windows = .{ .mmio32_pref = .range(.mmio32_pref, 0xC000_0000, 0x2000) },
            .pool = .mmio32_pref,
            .base = 0xC000_0000,
        },
        .{
            .name = "mmio64_pref non-prefetchable 64-bit fallback",
            .requirement = barRequirement(function, 0, .mmio64_pref, 0x1000, 0x1000),
            .windows = .{ .mmio64 = .range(.mmio64, 0x3_0000_0000, 0x2000) },
            .pool = .mmio64,
            .base = 0x3_0000_0000,
        },
        .{
            .name = "mmio64_pref non-prefetchable 32-bit fallback",
            .requirement = barRequirement(function, 0, .mmio64_pref, 0x1000, 0x1000),
            .windows = .{ .mmio32 = .range(.mmio32, 0xD000_0000, 0x2000) },
            .pool = .mmio32,
            .base = 0xD000_0000,
        },
    };

    try expectPlacements(&cases);
}

test "unit: alignment sort preserves caller requirements and placements stay contained" {
    // Place larger alignments first from an unaligned window and verify the original borrowed slice order survives.
    var fixture = FunctionFixture{};
    fixture.init(4);
    const function = fixture.function;
    var reqs = [_]Requirement{
        barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
        barRequirement(function, 1, .mmio32, 0x1000, 0x10_0000),
        barRequirement(function, 2, .mmio32, 0x1000, 0x4000),
        barRequirement(function, 3, .mmio32, 0x1_0000, 0x1000),
        barRequirement(function, 4, .mmio32, 0x4000, 0x1000),
        barRequirement(function, 5, .mmio32, 0x2000, 0x2000),
    };
    const nodes = [_]Node{.{ .parent = null, .kind = .endpoint, .requirements = &reqs }};
    const window = assignment.Aperture.range(.mmio32, 0x8010_0001, 0x20_0000);
    const input = assignment.Input{
        .nodes = &nodes,
        .roots = &.{0},
        .root_windows = .{ .mmio32 = window },
    };
    var scratch: [6]Assignment = undefined;

    const plan = try assignment.intoScratch(input, &scratch);

    try expectBarIndex(plan.assignments[0], 1);
    try expectBarIndex(plan.assignments[1], 2);
    try expectBarIndex(plan.assignments[2], 5);
    try expectBarIndex(plan.assignments[3], 3);
    try expectBarIndex(plan.assignments[4], 4);
    try expectBarIndex(plan.assignments[5], 0);
    try std.testing.expectEqual(@as(u64, 0x8020_0000), plan.assignments[0].base);
    for (plan.assignments) |placed| {
        try std.testing.expectEqual(@as(u64, 0), placed.base % placed.requirement.alignment);
        try std.testing.expect(window.contains(placed.base, placed.requirement.size));
    }
    try expectBarIndexFromRequirement(reqs[0], 0);
    try expectBarIndexFromRequirement(reqs[1], 1);
    try expectBarIndexFromRequirement(reqs[2], 2);
}

test "unit: ResourceExhausted reports the first requirement whose chain has no room" {
    // Make the larger sorted requirement impossible while a later smaller request would fit if incorrectly skipped.
    var fixture = FunctionFixture{};
    fixture.init(5);
    const function = fixture.function;
    const reqs = [_]Requirement{
        barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
        barRequirement(function, 1, .mmio32, 0x3000, 0x4000),
    };
    const nodes = [_]Node{.{ .parent = null, .kind = .endpoint, .requirements = &reqs }};
    const input = assignment.Input{
        .nodes = &nodes,
        .roots = &.{0},
        .root_windows = .{ .mmio32 = .range(.mmio32, 0x8000_0000, 0x2000) },
    };
    var scratch: [2]Assignment = undefined;

    try std.testing.expectError(error.ResourceExhausted, assignment.intoScratch(input, &scratch));
}

test "unit: StorageExhausted is checked before scratch is modified" {
    // Provide one slot for two reachable requirements and check the sentinel assignment is untouched.
    var fixture = FunctionFixture{};
    fixture.init(6);
    const function = fixture.function;
    const reqs = [_]Requirement{
        barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
        barRequirement(function, 1, .mmio32, 0x1000, 0x1000),
    };
    const nodes = [_]Node{.{ .parent = null, .kind = .endpoint, .requirements = &reqs }};
    const input = assignment.Input{
        .nodes = &nodes,
        .roots = &.{0},
        .root_windows = .{ .mmio32 = .range(.mmio32, 0x8000_0000, 0x4000) },
    };
    const sentinel = Assignment{ .requirement = reqs[0], .pool = .io, .base = 0xDEAD_BEEF };
    var scratch = [_]Assignment{sentinel};

    try std.testing.expectError(error.StorageExhausted, assignment.intoScratch(input, &scratch));
    try std.testing.expectEqual(sentinel.pool, scratch[0].pool);
    try std.testing.expectEqual(sentinel.base, scratch[0].base);
    try expectBarIndexFromRequirement(scratch[0].requirement, 0);
}

test "unit: bridge sub-apertures come only from bridge-window assignments" {
    // Force a prefetchable bridge window to fall back to the parent MMIO32 pool.
    // Children still place by the bridge window's semantic kind.
    var fixture = FunctionFixture{};
    fixture.init(7);
    const function = fixture.function;
    const root_reqs = [_]Requirement{
        barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
        bridgeWindowRequirement(function, .io, .io, 0x1000, 0x1000),
        bridgeWindowRequirement(function, .prefetchable_memory, .mmio32_pref, 0x4000, 0x1000),
    };
    const io_child_reqs = [_]Requirement{barRequirement(function, 1, .io, 0x100, 0x100)};
    const pref_child_reqs = [_]Requirement{barRequirement(function, 2, .mmio32_pref, 0x1000, 0x1000)};
    const nodes = [_]Node{
        .{ .parent = null, .kind = .bridge, .requirements = &root_reqs },
        .{ .parent = 0, .kind = .endpoint, .requirements = &io_child_reqs },
        .{ .parent = 0, .kind = .endpoint, .requirements = &pref_child_reqs },
    };
    const input = assignment.Input{
        .nodes = &nodes,
        .roots = &.{0},
        .root_windows = .{
            .io = .range(.io, 0x1000, 0x3000),
            .mmio32 = .range(.mmio32, 0x8000_0000, 0x8000),
        },
    };
    var scratch: [5]Assignment = undefined;

    const plan = try assignment.intoScratch(input, &scratch);

    try std.testing.expectEqual(@as(usize, 5), plan.assignments.len);
    try std.testing.expectEqual(Kind.mmio32, plan.assignments[0].pool);
    try std.testing.expectEqual(Kind.mmio32, plan.assignments[1].pool);
    try std.testing.expectEqual(Kind.io, plan.assignments[2].pool);
    try std.testing.expectEqual(Kind.io, plan.assignments[3].pool);
    try std.testing.expectEqual(Kind.mmio32_pref, plan.assignments[4].pool);
    try expectBridgeWindow(plan.assignments[0], .prefetchable_memory);
    try expectBarIndex(plan.assignments[1], 0);
    try expectBridgeWindow(plan.assignments[2], .io);
    try expectBarIndex(plan.assignments[3], 1);
    try expectBarIndex(plan.assignments[4], 2);
    try std.testing.expectEqual(plan.assignments[0].base, plan.assignments[4].base);
    try std.testing.expectEqual(plan.assignments[2].base, plan.assignments[3].base);
}

const PlacementCase = struct {
    name: []const u8,
    requirement: Requirement,
    windows: RootWindows,
    pool: Kind,
    base: u64,
};

fn expectPlacements(cases: []const PlacementCase) !void {
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        const reqs = [_]Requirement{case.requirement};
        const nodes = [_]Node{.{ .parent = null, .kind = .endpoint, .requirements = &reqs }};
        const input = assignment.Input{ .nodes = &nodes, .roots = &.{0}, .root_windows = case.windows };
        var scratch: [1]Assignment = undefined;

        const plan = try assignment.intoScratch(input, &scratch);

        try std.testing.expectEqual(@as(usize, 1), plan.assignments.len);
        try std.testing.expectEqual(case.pool, plan.assignments[0].pool);
        try std.testing.expectEqual(case.base, plan.assignments[0].base);
    }
}

const FunctionFixture = struct {
    bytes: [function_window_size]u8 = @splat(0),
    backend: TestConfigSpace = undefined,
    function: Function = undefined,

    fn init(self: *FunctionFixture, comptime device: u5) void {
        self.bytes = @splat(0);
        const sbdf = core.Sbdf.of(0, 0, device, 0);
        self.backend = TestConfigSpace.initSingle(sbdf, &self.bytes);
        self.function = Function.unchecked(self.backend.configSpace(), sbdf);
    }
};

fn barRequirement(function: Function, index: usize, kind: Kind, size: u64, alignment: u64) Requirement {
    return .{
        .kind = kind,
        .size = size,
        .alignment = alignment,
        .source = .{ .endpoint_bar = bar.BarRef.init(function, index) },
    };
}

fn romRequirement(function: Function, size: u64, alignment: u64) Requirement {
    return .{
        .kind = .mmio32,
        .size = size,
        .alignment = alignment,
        .source = .{ .endpoint_expansion_rom = function },
    };
}

fn bridgeWindowRequirement(
    function: Function,
    window: Source.BridgeWindow,
    kind: Kind,
    size: u64,
    alignment: u64,
) Requirement {
    return .{
        .kind = kind,
        .size = size,
        .alignment = alignment,
        .source = .{ .bridge_window = .{ .function = function, .window = window } },
    };
}

fn expectBarIndex(placed: Assignment, index: usize) !void {
    try expectBarIndexFromRequirement(placed.requirement, index);
}

fn expectBarIndexFromRequirement(requirement: Requirement, index: usize) !void {
    switch (requirement.source) {
        .endpoint_bar => |source| try std.testing.expectEqual(index, source.index),
        else => return error.TestExpectedEqual,
    }
}

fn expectBridgeWindow(placed: Assignment, window: Source.BridgeWindow) !void {
    switch (placed.requirement.source) {
        .bridge_window => |source| try std.testing.expectEqual(window, source.window),
        else => return error.TestExpectedEqual,
    }
}
