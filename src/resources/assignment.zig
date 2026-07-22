//! Pure resource assignment planner. Spec: docs/specs/resources/assignment.md.

const std = @import("std");

const model = @import("model.zig");

pub const Requirement = model.Requirement;
pub const Assignment = model.Assignment;
pub const Kind = model.Kind;
pub const Aperture = model.Aperture;
pub const RootWindows = model.RootWindows;
pub const Source = model.Source;

pub const NodeIndex = u16;
pub const max_nodes: usize = std.math.maxInt(NodeIndex);
pub const max_depth: u8 = 32;

pub const NodeKind = enum { endpoint, bridge };

pub const Node = struct {
    parent: ?NodeIndex,
    kind: NodeKind,
    requirements: []const Requirement,
};

pub const Input = struct {
    nodes: []const Node,
    roots: []const NodeIndex,
    root_windows: RootWindows,
};

pub const Plan = struct {
    assignments: []const Assignment,
};

pub const Error = error{
    ResourceExhausted,
    StorageExhausted,
};

/// Places reachable node requirements into root and bridge windows using caller-provided scratch.
///
/// Allocation: never allocates. I/O: none. Ordering: emits DFS-preorder placements after deterministic pool sorting.
/// Errors: `StorageExhausted` is checked before scratch mutation; `ResourceExhausted` names the first
/// unplaced requirement.
pub fn intoScratch(input: Input, scratch: []Assignment) Error!Plan {
    std.debug.assert(input.nodes.len <= max_nodes);
    assertRootWindowsKinds(input.root_windows);
    assertInputShape(input);

    const required = try reachableRequirementCount(input);
    if (required > scratch.len) return error.StorageExhausted;

    var context = Context{
        .input = input,
        .scratch = scratch,
        .out_len = 0,
        .frames = undefined,
        .depth = 0,
    };

    for (input.roots) |root| {
        std.debug.assert(root < input.nodes.len);
        std.debug.assert(input.nodes[root].parent == null);
        context.pushFrame(input.root_windows);
        try context.visit(root);
        context.popFrame();
    }

    std.debug.assert(context.out_len == required);
    return .{ .assignments = scratch[0..context.out_len] };
}

/// Returns the maximum number of assignments any plan over `nodes` can emit.
///
/// Allocation: never allocates. I/O: none. Bounds: saturates at `max_nodes`.
pub fn sizeBound(nodes: []const Node) usize {
    var total: usize = 0;
    for (nodes) |node| total += node.requirements.len;
    return total;
}

const max_endpoint_requirements: usize = 7;
const max_bridge_requirements: usize = 5;
const max_node_requirements: usize = max_endpoint_requirements;

const Context = struct {
    input: Input,
    scratch: []Assignment,
    out_len: usize,
    frames: [max_depth]RootWindows,
    depth: usize,

    fn visit(self: *Context, index: NodeIndex) Error!void {
        std.debug.assert(index < self.input.nodes.len);
        const node = self.input.nodes[index];
        assertNodeRequirements(node);
        if (node.parent) |parent| {
            std.debug.assert(parent < index);
            std.debug.assert(self.input.nodes[parent].kind == .bridge);
        }

        const start = self.out_len;
        var sorted: [max_node_requirements]Requirement = undefined;
        const requirements = sortedRequirements(node.requirements, &sorted);

        for (requirements) |requirement| {
            const assignment = try place(requirement, self.currentFrame());
            self.scratch[self.out_len] = assignment;
            self.out_len += 1;
        }

        if (node.kind == .bridge) {
            const child_frame = childFrame(self.scratch[start..self.out_len]);
            self.pushFrame(child_frame);
            for (self.input.nodes, 0..) |child, child_index| {
                if (child.parent == index) {
                    std.debug.assert(child_index <= max_nodes);
                    try self.visit(@intCast(child_index));
                }
            }
            self.popFrame();
        }
    }

    fn currentFrame(self: *Context) *RootWindows {
        std.debug.assert(self.depth > 0);
        return &self.frames[self.depth - 1];
    }

    fn pushFrame(self: *Context, frame: RootWindows) void {
        std.debug.assert(self.depth < max_depth);
        self.frames[self.depth] = frame;
        self.depth += 1;
    }

    fn popFrame(self: *Context) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }
};

fn reachableRequirementCount(input: Input) Error!usize {
    var total: usize = 0;
    for (input.roots) |root| {
        std.debug.assert(root < input.nodes.len);
        std.debug.assert(input.nodes[root].parent == null);
        total = try addCount(total, try countSubtreeRequirements(input, root, 1));
    }

    return total;
}

fn countSubtreeRequirements(input: Input, index: NodeIndex, depth: usize) Error!usize {
    std.debug.assert(index < input.nodes.len);
    std.debug.assert(depth <= max_depth);
    const node = input.nodes[index];
    assertNodeRequirements(node);
    if (node.parent) |parent| {
        std.debug.assert(parent < index);
        std.debug.assert(input.nodes[parent].kind == .bridge);
    }

    var total = node.requirements.len;
    if (node.kind == .bridge) {
        for (input.nodes, 0..) |child, child_index| {
            if (child.parent == index) {
                std.debug.assert(child_index <= max_nodes);
                total = try addCount(total, try countSubtreeRequirements(input, @intCast(child_index), depth + 1));
            }
        }
    }

    return total;
}

fn addCount(a: usize, b: usize) Error!usize {
    const sum = std.math.add(usize, a, b) catch return error.StorageExhausted;
    return sum;
}

fn assertInputShape(input: Input) void {
    for (input.nodes, 0..) |node, index| {
        std.debug.assert(index <= max_nodes);
        assertNodeRequirements(node);
        if (node.parent) |parent| {
            std.debug.assert(parent < index);
            std.debug.assert(input.nodes[parent].kind == .bridge);
        }
    }
}

fn assertNodeRequirements(node: Node) void {
    switch (node.kind) {
        .endpoint => std.debug.assert(node.requirements.len <= max_endpoint_requirements),
        .bridge => std.debug.assert(node.requirements.len <= max_bridge_requirements),
    }
}

fn sortedRequirements(
    requirements: []const Requirement,
    buffer: *[max_node_requirements]Requirement,
) []const Requirement {
    std.debug.assert(requirements.len <= buffer.len);
    for (requirements, 0..) |requirement, index| buffer[index] = requirement;

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
    if (left.alignment != right.alignment) return left.alignment > right.alignment;
    if (left.size != right.size) return left.size > right.size;
    return false;
}

fn place(requirement: Requirement, frame: *RootWindows) Error!Assignment {
    assertRequirement(requirement);
    return switch (requirement.kind) {
        .io => placeInPools(requirement, frame, &.{.io}),
        .mmio32 => placeInPools(requirement, frame, &.{.mmio32}),
        .mmio32_pref => placeInPools(requirement, frame, &.{ .mmio32_pref, .mmio32 }),
        .mmio64 => placeInPools(requirement, frame, &.{ .mmio64, .mmio32 }),
        .mmio64_pref => placeInPools(requirement, frame, &.{ .mmio64_pref, .mmio32_pref, .mmio64, .mmio32 }),
    };
}

fn placeInPools(requirement: Requirement, frame: *RootWindows, comptime pools: []const Kind) Error!Assignment {
    for (pools) |pool| {
        std.debug.assert(model.eligiblePools(requirement.kind).has(pool));
        if (tryPlaceInPool(requirement, pool, aperturePtr(frame, pool))) |assignment| return assignment;
    }

    return error.ResourceExhausted;
}

fn tryPlaceInPool(requirement: Requirement, pool: Kind, aperture: *Aperture) ?Assignment {
    std.debug.assert(aperture.kind == pool);
    const base = aperture.allocate(requirement.size, requirement.alignment) orelse return null;

    std.debug.assert(base % requirement.alignment == 0);
    std.debug.assert(model.eligiblePools(requirement.kind).has(pool));
    return .{ .requirement = requirement, .pool = pool, .base = base };
}

fn childFrame(assignments: []const Assignment) RootWindows {
    var child = RootWindows{};
    for (assignments) |assignment| {
        switch (assignment.requirement.source) {
            .bridge_window => switch (assignment.requirement.kind) {
                .io => child.io = .{ .kind = .io, .base = assignment.base, .size = assignment.requirement.size },
                .mmio32 => child.mmio32 = .{
                    .kind = .mmio32,
                    .base = assignment.base,
                    .size = assignment.requirement.size,
                },
                .mmio32_pref => child.mmio32_pref = .{
                    .kind = .mmio32_pref,
                    .base = assignment.base,
                    .size = assignment.requirement.size,
                },
                .mmio64 => unreachable,
                .mmio64_pref => child.mmio64_pref = .{
                    .kind = .mmio64_pref,
                    .base = assignment.base,
                    .size = assignment.requirement.size,
                },
            },
            .endpoint_bar, .endpoint_expansion_rom => {},
        }
    }

    return child;
}

fn aperturePtr(frame: *RootWindows, kind: Kind) *Aperture {
    return switch (kind) {
        .io => &frame.io,
        .mmio32 => &frame.mmio32,
        .mmio32_pref => &frame.mmio32_pref,
        .mmio64 => &frame.mmio64,
        .mmio64_pref => &frame.mmio64_pref,
    };
}

fn assertRootWindowsKinds(windows: RootWindows) void {
    std.debug.assert(windows.io.kind == .io);
    std.debug.assert(windows.mmio32.kind == .mmio32);
    std.debug.assert(windows.mmio32_pref.kind == .mmio32_pref);
    std.debug.assert(windows.mmio64.kind == .mmio64);
    std.debug.assert(windows.mmio64_pref.kind == .mmio64_pref);
}

fn assertRequirement(requirement: Requirement) void {
    std.debug.assert(requirement.size > 0);
    std.debug.assert(requirement.alignment > 0);
    std.debug.assert(std.math.isPowerOfTwo(requirement.alignment));
}

comptime {
    std.debug.assert(@sizeOf(NodeIndex) == 2);
    std.debug.assert(max_nodes == 65_535);
    std.debug.assert(max_depth == 32);
}
