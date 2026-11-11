//! Resource assignment.

const std = @import("std");
const stdx = @import("stdx");

const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;
const Range = stdx.ranges.Range(u64);

const Requirement = model.Requirement;
const Assignment = model.Assignment;
const Type = model.Type;
const Aperture = model.Aperture;
const Apertures = model.Apertures;

pub const NodeIndex = u16;
pub const max_nodes: usize = std.math.maxInt(NodeIndex);
pub const max_depth: u8 = 32;

const max_endpoint_requirements: usize = 7;
const max_bridge_requirements: usize = 5;
const max_node_requirements: usize = max_endpoint_requirements;

pub const Node = struct {
    parent: ?NodeIndex,
    type: Node.Type,
    requirements: []const Requirement,

    pub const Type = enum { endpoint, bridge };
};

pub const Args = struct {
    nodes: []const Node,
    roots: []const NodeIndex,
    apertures: Apertures,
};

pub const Error = AllocError || error{
    ResourceExhausted,
    StorageExhausted,
};

/// Returns allocator-owned assignments; function backends remain borrowed.
/// `StorageExhausted` denotes count overflow, not allocator exhaustion.
pub fn assign(allocator: Allocator, args: Args) Error![]Assignment {
    std.debug.assert(args.nodes.len <= max_nodes);
    assertApertureTypes(&args.apertures);
    assertArgsShape(args);

    const required = try countRequirements(args);
    const assignments = try allocator.alloc(Assignment, required);
    errdefer allocator.free(assignments);

    var context = Context{
        .args = args,
        .assignments = assignments,
        .out_len = 0,
        .frames = undefined,
        .depth = 0,
    };

    for (args.roots) |root| {
        std.debug.assert(root < args.nodes.len);
        std.debug.assert(args.nodes[root].parent == null);

        context.pushFrame(&args.apertures);
        try context.visit(root);
        context.popFrame();
    }

    std.debug.assert(context.out_len == required);
    return assignments;
}

const Context = struct {
    args: Args,
    assignments: []Assignment,
    out_len: usize,
    frames: [max_depth]Apertures,
    depth: usize,

    fn visit(self: *Context, index: NodeIndex) Error!void {
        std.debug.assert(index < self.args.nodes.len);
        const node = self.args.nodes[index];
        assertNodeRequirements(node);

        if (node.parent) |parent| {
            std.debug.assert(parent < index);
            std.debug.assert(self.args.nodes[parent].type == .bridge);
        }

        const start = self.out_len;
        var sorted: [max_node_requirements]Requirement = undefined;
        const requirements = sortedRequirements(node.requirements, &sorted);

        for (requirements) |requirement| {
            const assignment = try place(requirement, self.currentFrame());

            self.assignments[self.out_len] = assignment;
            self.out_len += 1;
        }

        if (node.type == .bridge) {
            const child_frame = childApertures(self.assignments[start..self.out_len]);
            self.pushFrame(&child_frame);

            for (self.args.nodes, 0..) |child, child_index| {
                if (child.parent == index) {
                    std.debug.assert(child_index <= max_nodes);
                    try self.visit(@intCast(child_index));
                }
            }

            self.popFrame();
        }
    }

    fn currentFrame(self: *Context) *Apertures {
        std.debug.assert(self.depth > 0);
        return &self.frames[self.depth - 1];
    }

    fn pushFrame(self: *Context, frame: *const Apertures) void {
        std.debug.assert(self.depth < max_depth);
        self.frames[self.depth] = frame.*;
        self.depth += 1;
    }

    fn popFrame(self: *Context) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }
};

fn childApertures(assignments: []const Assignment) Apertures {
    var child = Apertures{};
    for (assignments) |assignment| {
        switch (assignment.requirement.source) {
            .bridge => {
                const aperture = Aperture{
                    .type = assignment.requirement.type,
                    .bounds = Range.fromStartLen(assignment.base, assignment.requirement.size) catch unreachable,
                };
                switch (assignment.requirement.type) {
                    .io => child.io = aperture,
                    .mmio32 => child.mmio32 = aperture,
                    .mmio32_prefetch => child.mmio32_prefetch = aperture,
                    .mmio64 => unreachable,
                    .mmio64_prefetch => child.mmio64_prefetch = aperture,
                }
            },
            .bar, .rom => {},
        }
    }

    return child;
}

fn countRequirements(args: Args) Error!usize {
    var total: usize = 0;
    for (args.roots) |root| {
        std.debug.assert(root < args.nodes.len);
        std.debug.assert(args.nodes[root].parent == null);
        total = std.math.add(usize, total, try countSubtreeRequirements(args, root, 1)) catch return error.StorageExhausted;
    }

    return total;
}

fn countSubtreeRequirements(args: Args, index: NodeIndex, depth: usize) Error!usize {
    std.debug.assert(index < args.nodes.len);
    std.debug.assert(depth <= max_depth);

    const node = args.nodes[index];
    assertNodeRequirements(node);
    if (node.parent) |parent| {
        std.debug.assert(parent < index);
        std.debug.assert(args.nodes[parent].type == .bridge);
    }

    var total = node.requirements.len;
    if (node.type == .bridge) {
        for (args.nodes, 0..) |child, child_index| {
            if (child.parent == index) {
                std.debug.assert(child_index <= max_nodes);
                total = std.math.add(usize, total, try countSubtreeRequirements(args, @intCast(child_index), depth + 1)) catch return error.StorageExhausted;
            }
        }
    }

    return total;
}

fn assertApertureTypes(apertures: *const Apertures) void {
    std.debug.assert(apertures.io.type == .io);
    std.debug.assert(apertures.mmio32.type == .mmio32);
    std.debug.assert(apertures.mmio32_prefetch.type == .mmio32_prefetch);
    std.debug.assert(apertures.mmio64.type == .mmio64);
    std.debug.assert(apertures.mmio64_prefetch.type == .mmio64_prefetch);
}

fn assertArgsShape(args: Args) void {
    for (args.nodes, 0..) |node, index| {
        std.debug.assert(index <= max_nodes);
        assertNodeRequirements(node);
        if (node.parent) |parent| {
            std.debug.assert(parent < index);
            std.debug.assert(args.nodes[parent].type == .bridge);
        }
    }
}

fn assertNodeRequirements(node: Node) void {
    switch (node.type) {
        .endpoint => std.debug.assert(node.requirements.len <= max_endpoint_requirements),
        .bridge => std.debug.assert(node.requirements.len <= max_bridge_requirements),
    }
}

fn sortedRequirements(
    requirements: []const Requirement,
    buffer: *[max_node_requirements]Requirement,
) []const Requirement {
    std.debug.assert(requirements.len <= buffer.len);

    for (requirements, 0..) |requirement, index| {
        buffer[index] = requirement;
    }

    var sorted_len: usize = 1;
    while (sorted_len < requirements.len) : (sorted_len += 1) {
        const current = buffer[sorted_len];
        var insert = sorted_len;
        while (insert > 0 and requirementLess(current, buffer[insert - 1])) : (insert -= 1) {
            buffer[insert] = buffer[insert - 1];
        }

        buffer[insert] = current;
    }

    return buffer[0..requirements.len];
}

fn requirementLess(left: Requirement, right: Requirement) bool {
    if (left.alignment != right.alignment) {
        return left.alignment > right.alignment;
    }

    if (left.size != right.size) {
        return left.size > right.size;
    }

    return false;
}

fn assertRequirement(requirement: Requirement) void {
    std.debug.assert(requirement.size > 0);
    std.debug.assert(requirement.alignment > 0);
    std.debug.assert(std.math.isPowerOfTwo(requirement.alignment));
}

fn place(requirement: Requirement, frame: *Apertures) Error!Assignment {
    assertRequirement(requirement);

    return switch (requirement.type) {
        .io => placeInPools(requirement, frame, &.{.io}),
        .mmio32 => placeInPools(requirement, frame, &.{.mmio32}),
        .mmio32_prefetch => placeInPools(requirement, frame, &.{ .mmio32_prefetch, .mmio32 }),
        .mmio64 => placeInPools(requirement, frame, &.{ .mmio64, .mmio32 }),
        .mmio64_prefetch => placeInPools(requirement, frame, &.{ .mmio64_prefetch, .mmio32_prefetch, .mmio64, .mmio32 }),
    };
}

fn placeInPools(requirement: Requirement, frame: *Apertures, comptime pools: []const Type) Error!Assignment {
    for (pools) |pool| {
        std.debug.assert(requirement.type.eligiblePools().has(pool));
        if (tryPlaceInPool(requirement, pool, frame.getPtr(pool))) |assignment| {
            return assignment;
        }
    }

    return error.ResourceExhausted;
}

fn tryPlaceInPool(requirement: Requirement, pool: Type, aperture: *Aperture) ?Assignment {
    std.debug.assert(aperture.type == pool);

    const base = aperture.allocate(requirement.size, requirement.alignment) orelse return null;

    std.debug.assert(base % requirement.alignment == 0);
    std.debug.assert(requirement.type.eligiblePools().has(pool));

    return .{ .requirement = requirement, .pool = pool, .base = base };
}

comptime {
    std.debug.assert(@sizeOf(NodeIndex) == 2);
    std.debug.assert(max_nodes == 65_535);
    std.debug.assert(max_depth == 32);
}

pub const unit = struct {
    const bar = @import("bar");
    const config = @import("config");
    const core = @import("core");
    const support = @import("testing");

    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;

    const FixedBufferAllocator = std.heap.FixedBufferAllocator;
    const FailingAllocator = testing.FailingAllocator;

    const Function = config.Function;

    const WindowType = core.bridge.Type;
    const Sbdf = core.Sbdf;

    const BarRef = bar.Ref;

    const TestConfigSpace = support.config.TestConfigSpace;

    const PlacementCase = struct {
        name: []const u8,
        requirement: Requirement,
        apertures: Apertures,
        pool: Type,
        base: u64,
    };

    const FunctionFixture = struct {
        bytes: [pcie_window_size]u8 = @splat(0),
        backend: TestConfigSpace = undefined,
        function: Function = undefined,

        fn init(self: *FunctionFixture, device: u5) void {
            self.bytes = @splat(0);
            const sbdf = Sbdf.from(.from(0), 0, device, 0);
            self.backend = TestConfigSpace.fromSingle(sbdf, &self.bytes);
            self.function = Function.from(self.backend.config(), sbdf);
        }
    };

    test "empty roots emit no assignments" {
        var fixture = FunctionFixture{};
        fixture.init(1);
        const function = fixture.function;
        const reqs0 = [_]Requirement{barRequirement(function, 0, .mmio32, 0x1000, 0x1000)};
        const reqs1 = [_]Requirement{
            barRequirement(function, 1, .io, 0x100, 0x100),
            barRequirement(function, 2, .mmio64, 0x2000, 0x2000),
        };
        const nodes = [_]Node{
            .{ .parent = null, .type = .endpoint, .requirements = &reqs0 },
            .{ .parent = null, .type = .endpoint, .requirements = &reqs1 },
        };
        const args = Args{
            .nodes = &nodes,
            .roots = &.{},
            .apertures = .{},
        };

        const assignments = try assign(testing.allocator, args);
        defer testing.allocator.free(assignments);

        try testing.expectEqual(@as(usize, 0), assignments.len);
    }

    test "assign allows more assignments than nodes" {
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
        const node_count = max_nodes / reqs.len + 1;
        const assignment_count = node_count * reqs.len;
        const allocator = testing.allocator;
        const nodes = try allocator.alloc(Node, node_count);
        defer allocator.free(nodes);
        const roots = try allocator.alloc(NodeIndex, node_count);
        defer allocator.free(roots);

        for (nodes, roots, 0..) |*node, *root, index| {
            node.* = .{ .parent = null, .type = .endpoint, .requirements = &reqs };
            root.* = @intCast(index);
        }

        const assignments = try assign(allocator, .{
            .nodes = nodes,
            .roots = roots,
            .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8000_0000, assignment_count * 0x1000) } },
        });
        defer allocator.free(assignments);

        try testing.expect(assignment_count > max_nodes);
        try testing.expectEqual(assignment_count, assignments.len);
    }

    test "DFS preorder emits parent requirements before children in input order" {
        var fixture = FunctionFixture{};
        fixture.init(2);
        const function = fixture.function;
        const root_reqs = [_]Requirement{bridgeWindowRequirement(function, .mem, .mmio32, 0x4000, 0x1000)};
        const child0_reqs = [_]Requirement{barRequirement(function, 0, .mmio32, 0x1000, 0x1000)};
        const child1_reqs = [_]Requirement{barRequirement(function, 1, .mmio32, 0x1000, 0x1000)};
        const nodes = [_]Node{
            .{ .parent = null, .type = .bridge, .requirements = &root_reqs },
            .{ .parent = 0, .type = .endpoint, .requirements = &child0_reqs },
            .{ .parent = 0, .type = .endpoint, .requirements = &child1_reqs },
        };
        const args = Args{
            .nodes = &nodes,
            .roots = &.{0},
            .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8000_0000, 0x8000) } },
        };

        const assignments = try assign(testing.allocator, args);
        defer testing.allocator.free(assignments);

        try testing.expectEqual(@as(usize, 3), assignments.len);
        try expectBridgeWindow(assignments[0], .mem);
        try expectBarIndex(assignments[1], 0);
        try expectBarIndex(assignments[2], 1);
        try testing.expectEqual(@as(u64, 0x8000_0000), assignments[0].base);
        try testing.expectEqual(@as(u64, 0x8000_0000), assignments[1].base);
        try testing.expectEqual(@as(u64, 0x8000_1000), assignments[2].base);
    }

    test "pool preference records natural pools" {
        var fixture = FunctionFixture{};
        fixture.init(3);
        const function = fixture.function;
        const cases = [_]PlacementCase{
            .{
                .name = "io natural",
                .requirement = barRequirement(function, 0, .io, 0x10, 0x10),
                .apertures = .{ .io = .{ .type = .io, .bounds = try Range.fromStartLen(0x1000, 0x100) } },
                .pool = .io,
                .base = 0x1000,
            },
            .{
                .name = "mmio32 natural",
                .requirement = barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
                .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8000_0000, 0x2000) } },
                .pool = .mmio32,
                .base = 0x8000_0000,
            },
            .{
                .name = "mmio32_prefetch natural",
                .requirement = barRequirement(function, 0, .mmio32_prefetch, 0x1000, 0x1000),
                .apertures = .{ .mmio32_prefetch = .{ .type = .mmio32_prefetch, .bounds = try Range.fromStartLen(0x9000_0000, 0x2000) } },
                .pool = .mmio32_prefetch,
                .base = 0x9000_0000,
            },
            .{
                .name = "mmio64 natural",
                .requirement = barRequirement(function, 0, .mmio64, 0x1000, 0x1000),
                .apertures = .{ .mmio64 = .{ .type = .mmio64, .bounds = try Range.fromStartLen(0x1_0000_0000, 0x2000) } },
                .pool = .mmio64,
                .base = 0x1_0000_0000,
            },
            .{
                .name = "mmio64_prefetch natural",
                .requirement = barRequirement(function, 0, .mmio64_prefetch, 0x1000, 0x1000),
                .apertures = .{ .mmio64_prefetch = .{ .type = .mmio64_prefetch, .bounds = try Range.fromStartLen(0x2_0000_0000, 0x2000) } },
                .pool = .mmio64_prefetch,
                .base = 0x2_0000_0000,
            },
        };

        try expectPlacements(&cases);
    }

    test "pool preference records fallback pools" {
        var fixture = FunctionFixture{};
        fixture.init(3);
        const function = fixture.function;
        const cases = [_]PlacementCase{
            .{
                .name = "mmio32_prefetch fallback",
                .requirement = barRequirement(function, 0, .mmio32_prefetch, 0x1000, 0x1000),
                .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0xA000_0000, 0x2000) } },
                .pool = .mmio32,
                .base = 0xA000_0000,
            },
            .{
                .name = "mmio64 fallback",
                .requirement = barRequirement(function, 0, .mmio64, 0x1000, 0x1000),
                .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0xB000_0000, 0x2000) } },
                .pool = .mmio32,
                .base = 0xB000_0000,
            },
            .{
                .name = "mmio64_prefetch prefetchable 32-bit fallback",
                .requirement = barRequirement(function, 0, .mmio64_prefetch, 0x1000, 0x1000),
                .apertures = .{ .mmio32_prefetch = .{ .type = .mmio32_prefetch, .bounds = try Range.fromStartLen(0xC000_0000, 0x2000) } },
                .pool = .mmio32_prefetch,
                .base = 0xC000_0000,
            },
            .{
                .name = "mmio64_prefetch non-prefetchable 64-bit fallback",
                .requirement = barRequirement(function, 0, .mmio64_prefetch, 0x1000, 0x1000),
                .apertures = .{ .mmio64 = .{ .type = .mmio64, .bounds = try Range.fromStartLen(0x3_0000_0000, 0x2000) } },
                .pool = .mmio64,
                .base = 0x3_0000_0000,
            },
            .{
                .name = "mmio64_prefetch non-prefetchable 32-bit fallback",
                .requirement = barRequirement(function, 0, .mmio64_prefetch, 0x1000, 0x1000),
                .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0xD000_0000, 0x2000) } },
                .pool = .mmio32,
                .base = 0xD000_0000,
            },
        };

        try expectPlacements(&cases);
    }

    test "alignment sort preserves caller requirements and placements stay contained" {
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
        const nodes = [_]Node{.{ .parent = null, .type = .endpoint, .requirements = &reqs }};
        const window = Aperture{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8010_0001, 0x20_0000) };
        const args = Args{
            .nodes = &nodes,
            .roots = &.{0},
            .apertures = .{ .mmio32 = window },
        };

        const assignments = try assign(testing.allocator, args);
        defer testing.allocator.free(assignments);

        try expectBarIndex(assignments[0], 1);
        try expectBarIndex(assignments[1], 2);
        try expectBarIndex(assignments[2], 5);
        try expectBarIndex(assignments[3], 3);
        try expectBarIndex(assignments[4], 4);
        try expectBarIndex(assignments[5], 0);
        try testing.expectEqual(@as(u64, 0x8020_0000), assignments[0].base);

        for (assignments) |placed| {
            try testing.expectEqual(@as(u64, 0), placed.base % placed.requirement.alignment);
            try testing.expect(window.contains(try Range.fromStartLen(placed.base, placed.requirement.size)));
        }

        try expectBarIndexFromRequirement(reqs[0], 0);
        try expectBarIndexFromRequirement(reqs[1], 1);
        try expectBarIndexFromRequirement(reqs[2], 2);
    }

    test "ResourceExhausted reports the first requirement whose chain has no room" {
        var fixture = FunctionFixture{};
        fixture.init(5);
        const function = fixture.function;
        const reqs = [_]Requirement{
            barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
            barRequirement(function, 1, .mmio32, 0x3000, 0x4000),
        };
        const nodes = [_]Node{.{ .parent = null, .type = .endpoint, .requirements = &reqs }};
        const args = Args{
            .nodes = &nodes,
            .roots = &.{0},
            .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8000_0000, 0x2000) } },
        };

        try testing.expectError(error.ResourceExhausted, assign(testing.allocator, args));
    }

    test "assign propagates allocation failure and frees successful output" {
        var fixture = FunctionFixture{};
        fixture.init(9);
        const reqs = [_]Requirement{
            barRequirement(fixture.function, 0, .mmio32, 0x1000, 0x1000),
        };
        const nodes = [_]Node{.{ .parent = null, .type = .endpoint, .requirements = &reqs }};
        const args = Args{
            .nodes = &nodes,
            .roots = &.{0},
            .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8000_0000, 0x1000) } },
        };

        try testing.checkAllAllocationFailures(testing.allocator, expectAllocatedAssignment, .{args});
    }

    test "ResourceExhausted frees output after a partial placement" {
        var fixture = FunctionFixture{};
        fixture.init(10);
        const reqs = [_]Requirement{
            barRequirement(fixture.function, 0, .mmio32, 0x1000, 0x1000),
            barRequirement(fixture.function, 1, .mmio32, 0x1000, 0x1000),
        };
        const nodes = [_]Node{.{ .parent = null, .type = .endpoint, .requirements = &reqs }};
        const args = Args{
            .nodes = &nodes,
            .roots = &.{0},
            .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8000_0000, 0x1000) } },
        };
        var tracking = FailingAllocator.init(testing.allocator, .{});

        try testing.expectError(error.ResourceExhausted, assign(tracking.allocator(), args));
        try testing.expect(tracking.allocated_bytes > 0);
        try testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    }

    test "fixed-buffer assignment allocates only reachable output and reports exhaustion" {
        var fixture = FunctionFixture{};
        fixture.init(11);
        const reqs = [_]Requirement{
            barRequirement(fixture.function, 0, .mmio32, 0x1000, 0x1000),
            barRequirement(fixture.function, 1, .mmio32, 0x1000, 0x1000),
        };
        const unreachable_reqs = [_]Requirement{
            barRequirement(fixture.function, 2, .io, 0x100, 0x100),
        };
        const nodes = [_]Node{
            .{ .parent = null, .type = .endpoint, .requirements = &reqs },
            .{ .parent = null, .type = .endpoint, .requirements = &unreachable_reqs },
        };
        const args = Args{
            .nodes = &nodes,
            .roots = &.{0},
            .apertures = .{ .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8000_0000, 0x2000) } },
        };
        var storage: [2 * @sizeOf(Assignment)]u8 align(@alignOf(Assignment)) = undefined;
        var fba = FixedBufferAllocator.init(&storage);
        const allocator = fba.allocator();
        const assignments = try assign(allocator, args);
        defer allocator.free(assignments);

        try testing.expectEqual(@as(usize, 2), assignments.len);
        try expectBarIndex(assignments[0], 0);
        try expectBarIndex(assignments[1], 1);
        try testing.expectEqual(@as(u64, 0x8000_1000), assignments[1].base);

        var short_storage: [2 * @sizeOf(Assignment) - 1]u8 align(@alignOf(Assignment)) = undefined;
        var short_fba = FixedBufferAllocator.init(&short_storage);
        try testing.expectError(error.OutOfMemory, assign(short_fba.allocator(), args));
    }

    test "bridge sub-apertures come only from bridge-window assignments" {
        var fixture = FunctionFixture{};
        fixture.init(7);
        const function = fixture.function;
        const root_reqs = [_]Requirement{
            barRequirement(function, 0, .mmio32, 0x1000, 0x1000),
            bridgeWindowRequirement(function, .io, .io, 0x1000, 0x1000),
            bridgeWindowRequirement(function, .mem_prefetch, .mmio32_prefetch, 0x4000, 0x1000),
        };
        const io_child_reqs = [_]Requirement{barRequirement(function, 1, .io, 0x100, 0x100)};
        const pref_child_reqs = [_]Requirement{barRequirement(function, 2, .mmio32_prefetch, 0x1000, 0x1000)};
        const nodes = [_]Node{
            .{ .parent = null, .type = .bridge, .requirements = &root_reqs },
            .{ .parent = 0, .type = .endpoint, .requirements = &io_child_reqs },
            .{ .parent = 0, .type = .endpoint, .requirements = &pref_child_reqs },
        };
        const args = Args{
            .nodes = &nodes,
            .roots = &.{0},
            .apertures = .{
                .io = .{ .type = .io, .bounds = try Range.fromStartLen(0x1000, 0x3000) },
                .mmio32 = .{ .type = .mmio32, .bounds = try Range.fromStartLen(0x8000_0000, 0x8000) },
            },
        };

        const assignments = try assign(testing.allocator, args);
        defer testing.allocator.free(assignments);

        try testing.expectEqual(@as(usize, 5), assignments.len);
        try testing.expectEqual(Type.mmio32, assignments[0].pool);
        try testing.expectEqual(Type.mmio32, assignments[1].pool);
        try testing.expectEqual(Type.io, assignments[2].pool);
        try testing.expectEqual(Type.io, assignments[3].pool);
        try testing.expectEqual(Type.mmio32_prefetch, assignments[4].pool);
        try expectBridgeWindow(assignments[0], .mem_prefetch);
        try expectBarIndex(assignments[1], 0);
        try expectBridgeWindow(assignments[2], .io);
        try expectBarIndex(assignments[3], 1);
        try expectBarIndex(assignments[4], 2);
        try testing.expectEqual(assignments[0].base, assignments[4].base);
        try testing.expectEqual(assignments[2].base, assignments[3].base);
    }

    fn expectAllocatedAssignment(allocator: Allocator, args: Args) !void {
        const assignments = try assign(allocator, args);
        defer allocator.free(assignments);

        try testing.expectEqual(@as(usize, 1), assignments.len);
        try testing.expectEqual(@as(u64, 0x8000_0000), assignments[0].base);
    }

    fn expectPlacements(cases: []const PlacementCase) !void {
        for (cases) |case| {
            errdefer std.debug.print("case: {s}\n", .{case.name});
            const reqs = [_]Requirement{case.requirement};
            const nodes = [_]Node{.{ .parent = null, .type = .endpoint, .requirements = &reqs }};
            const args = Args{ .nodes = &nodes, .roots = &.{0}, .apertures = case.apertures };

            const assignments = try assign(testing.allocator, args);
            defer testing.allocator.free(assignments);

            try testing.expectEqual(@as(usize, 1), assignments.len);
            try testing.expectEqual(case.pool, assignments[0].pool);
            try testing.expectEqual(case.base, assignments[0].base);
        }
    }

    fn barRequirement(function: Function, index: usize, resource_type: Type, size: u64, alignment: u64) Requirement {
        return .{
            .type = resource_type,
            .size = size,
            .alignment = alignment,
            .source = .{ .bar = BarRef.from(function, index) },
        };
    }

    fn romRequirement(function: Function, size: u64, alignment: u64) Requirement {
        return .{
            .type = .mmio32,
            .size = size,
            .alignment = alignment,
            .source = .{ .rom = function },
        };
    }

    fn bridgeWindowRequirement(
        function: Function,
        window: WindowType,
        resource_type: Type,
        size: u64,
        alignment: u64,
    ) Requirement {
        return .{
            .type = resource_type,
            .size = size,
            .alignment = alignment,
            .source = .{ .bridge = .{ .function = function, .window = window } },
        };
    }

    fn expectBarIndex(placed: Assignment, index: usize) !void {
        try expectBarIndexFromRequirement(placed.requirement, index);
    }

    fn expectBarIndexFromRequirement(requirement: Requirement, index: usize) !void {
        switch (requirement.source) {
            .bar => |source| try testing.expectEqual(index, source.index),
            else => return error.TestExpectedEqual,
        }
    }

    fn expectBridgeWindow(placed: Assignment, window: WindowType) !void {
        switch (placed.requirement.source) {
            .bridge => |source| try testing.expectEqual(window, source.window),
            else => return error.TestExpectedEqual,
        }
    }
};
