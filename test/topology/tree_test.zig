//! Tests for docs/specs/topology/tree.md.

const std = @import("std");

const zpci = @import("zpci");

const ConfigSpace = zpci.config.ConfigSpace;
const Function = zpci.config.Function;
const HeaderKind = zpci.config.HeaderKind;
const Node = zpci.topology.tree.Node;
const NodeIndex = zpci.topology.tree.NodeIndex;
const PreorderIterator = zpci.topology.tree.PreorderIterator;
const Sbdf = zpci.core.Sbdf;
const SegmentId = zpci.core.SegmentId;
const Tree = zpci.topology.tree.Tree;

const tree = zpci.topology.tree;

test "layout: public bounds match fixed-index and fixed-stack contracts" {
    // Pin the caller-visible index width and iterator stack bound used for scratch sizing.
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(NodeIndex));
    try std.testing.expectEqual(@as(usize, 65_535), tree.max_nodes);
    try std.testing.expectEqual(@as(u8, 32), tree.max_depth);
}

test "unit: empty tree has no roots and no traversal output" {
    // Build over empty node storage to defend the zero-function topology boundary.
    var nodes = [_]Node{};
    var roots: [1]NodeIndex = .{0xBEEF};

    const view = try tree.intoScratch(&nodes, &roots);
    var iterator = view.preorder();

    try std.testing.expectEqual(@as(usize, 0), view.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), view.roots.len);
    try std.testing.expectEqual(@as(?PreorderIterator.Item, null), iterator.next());
    try std.testing.expectEqual(@as(?NodeIndex, null), view.rootOfSegment(SegmentId.of(0)));
    try std.testing.expectEqual(@as(NodeIndex, 0xBEEF), roots[0]);
}

test "unit: one root publishes stable borrowed node without config I/O" {
    // Walk one unchecked function through the public tree API while a counting backend rejects hidden I/O.
    var backend = NoIoConfig{};
    var nodes = [_]Node{node(&backend, 0, 0, 0, 0, .type0, null)};
    var roots: [1]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try std.testing.expectEqual(@as(usize, 1), view.nodes.len);
    try std.testing.expectEqualSlices(NodeIndex, &.{0}, view.roots);
    try std.testing.expect(view.node(0) == &nodes[0]);
    try std.testing.expectEqual(@as(?NodeIndex, null), view.parentOf(0));
    try expectPreorder(&view, &.{0});
    try expectNoIo(&backend);
}

test "topology: bridge children and preorder follow ascending sibling linkage" {
    // Build a bridge with endpoint and bridge children so direct iteration and DFS order diverge at the grandchild.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 0, 0, 0, 0, .type1, null),
        node(&backend, 0, 1, 0, 0, .type0, 0),
        node(&backend, 0, 2, 0, 0, .type1, 0),
        node(&backend, 0, 3, 0, 0, .type0, 2),
    };
    var roots: [1]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try expectChildren(&view, 0, &.{ 1, 2 });
    try expectChildren(&view, 2, &.{3});
    try expectPreorder(&view, &.{ 0, 1, 2, 3 });
}

test "topology: nested preorder descends before siblings and later roots" {
    // Arrange child, grandchild, sibling, and second root cases to catch stack push ordering mistakes.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 0, 0, 0, 0, .type1, null),
        node(&backend, 0, 1, 0, 0, .type1, 0),
        node(&backend, 0, 2, 0, 0, .type0, 1),
        node(&backend, 0, 3, 0, 0, .type0, 0),
        node(&backend, 0, 4, 0, 0, .type0, null),
    };
    var roots: [2]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try expectPreorder(&view, &.{ 0, 1, 2, 3, 4 });
}

test "topology: direct children exclude grandchildren" {
    // Compare children() against preorderFrom() so a child iterator cannot accidentally recurse.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 0, 0, 0, 0, .type1, null),
        node(&backend, 0, 1, 0, 0, .type1, 0),
        node(&backend, 0, 2, 0, 0, .type0, 1),
        node(&backend, 0, 3, 0, 0, .type0, 0),
    };
    var roots: [1]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try expectChildren(&view, 0, &.{ 1, 3 });
    try expectPreorderFrom(&view, 0, &.{ 0, 1, 2, 3 });
}

test "topology: preorderFrom is isolated to the requested subtree" {
    // Start at an interior bridge and ensure its parent, sibling, and a later root remain unreachable.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 0, 0, 0, 0, .type1, null),
        node(&backend, 0, 1, 0, 0, .type1, 0),
        node(&backend, 0, 2, 0, 0, .type0, 1),
        node(&backend, 0, 3, 0, 0, .type0, 0),
        node(&backend, 1, 0, 0, 0, .type0, null),
    };
    var roots: [2]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try expectPreorderFrom(&view, 1, &.{ 1, 2 });
}

test "unit: rootOfSegment returns first sorted root for a segment" {
    // Give one segment two roots and another no roots to pin first-match and absent-segment behavior.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 1, 0, 0, 0, .type0, null),
        node(&backend, 0, 0, 2, 0, .type0, null),
        node(&backend, 0, 0, 1, 0, .type0, null),
    };
    var roots: [3]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try std.testing.expectEqualSlices(NodeIndex, &.{ 2, 1, 0 }, view.roots);
    try std.testing.expectEqual(@as(?NodeIndex, 2), view.rootOfSegment(SegmentId.of(0)));
    try std.testing.expectEqual(@as(?NodeIndex, 0), view.rootOfSegment(SegmentId.of(1)));
    try std.testing.expectEqual(@as(?NodeIndex, null), view.rootOfSegment(SegmentId.of(2)));
}

test "topology: root ordering is ascending by full SBDF" {
    // Supply roots out of segment and BDF order to ensure sorting uses the public address identity.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 1, 0, 0, 0, .type0, null),
        node(&backend, 0, 0, 2, 0, .type0, null),
        node(&backend, 0, 0, 1, 0, .type0, null),
        node(&backend, 2, 0, 0, 0, .type0, null),
    };
    var roots: [4]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try std.testing.expectEqualSlices(NodeIndex, &.{ 2, 1, 0, 3 }, view.roots);
    try expectPreorder(&view, &.{ 2, 1, 0, 3 });
}

test "malformed: parent cannot be self or greater than child index" {
    // Probe both topological-order boundary violations without relying on assertion-only checks.
    var backend = NoIoConfig{};
    const cases = [_]struct {
        name: []const u8,
        parent: NodeIndex,
    }{
        .{ .name = "self", .parent = 1 },
        .{ .name = "future", .parent = 2 },
    };

    for (cases) |case| {
        var nodes = [_]Node{
            node(&backend, 0, 0, 0, 0, .type1, null),
            node(&backend, 0, 1, 0, 0, .type0, case.parent),
            node(&backend, 0, 2, 0, 0, .type0, null),
        };
        var roots: [3]NodeIndex = .{ 0xAAAA, 0xBBBB, 0xCCCC };

        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectError(error.InvalidTopology, tree.intoScratch(&nodes, &roots));
        try std.testing.expectEqual(@as(?NodeIndex, null), nodes[0].first_child);
        try std.testing.expectEqual(@as(?NodeIndex, null), nodes[1].next_sibling);
        try std.testing.expectEqualSlices(NodeIndex, &.{ 0xAAAA, 0xBBBB, 0xCCCC }, &roots);
    }
}

test "failure: roots scratch exhaustion leaves nodes and roots untouched" {
    // Force the upfront root-capacity guard while stale links and root sentinel values prove no mutation occurred.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 0, 0, 0, 0, .type0, null),
        node(&backend, 1, 0, 0, 0, .type0, null),
    };
    nodes[0].first_child = 1;
    nodes[0].next_sibling = 0;
    nodes[1].first_child = 0;
    nodes[1].next_sibling = 1;
    var roots: [1]NodeIndex = .{0xBEEF};

    try std.testing.expectError(error.StorageExhausted, tree.intoScratch(&nodes, &roots));

    try std.testing.expectEqual(@as(?NodeIndex, 1), nodes[0].first_child);
    try std.testing.expectEqual(@as(?NodeIndex, 0), nodes[0].next_sibling);
    try std.testing.expectEqual(@as(?NodeIndex, 0), nodes[1].first_child);
    try std.testing.expectEqual(@as(?NodeIndex, 1), nodes[1].next_sibling);
    try std.testing.expectEqual(@as(NodeIndex, 0xBEEF), roots[0]);
}

test "unit: builder overwrites stale linkage on every node" {
    // Seed impossible links before building to ensure computed child chains replace producer leftovers.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 0, 0, 0, 0, .type1, null),
        node(&backend, 0, 1, 0, 0, .type0, 0),
        node(&backend, 0, 2, 0, 0, .type0, 0),
    };
    for (&nodes) |*entry| {
        entry.first_child = 0xAAAA;
        entry.next_sibling = 0xBBBB;
    }
    var roots: [1]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try std.testing.expectEqual(@as(?NodeIndex, 1), view.node(0).first_child);
    try std.testing.expectEqual(@as(?NodeIndex, 2), view.node(1).next_sibling);
    try std.testing.expectEqual(@as(?NodeIndex, null), view.node(1).first_child);
    try std.testing.expectEqual(@as(?NodeIndex, null), view.node(2).first_child);
    try std.testing.expectEqual(@as(?NodeIndex, null), view.node(2).next_sibling);
}

test "topology: multi-segment roots remain independent root subtrees" {
    // Build two segment roots with one child each to defend the no-virtual-root multi-segment shape.
    var backend = NoIoConfig{};
    var nodes = [_]Node{
        node(&backend, 1, 0, 0, 0, .type1, null),
        node(&backend, 1, 1, 0, 0, .type0, 0),
        node(&backend, 0, 0, 0, 0, .type1, null),
        node(&backend, 0, 1, 0, 0, .type0, 2),
    };
    var roots: [2]NodeIndex = undefined;

    const view = try tree.intoScratch(&nodes, &roots);

    try std.testing.expectEqualSlices(NodeIndex, &.{ 2, 0 }, view.roots);
    try std.testing.expectEqual(@as(?NodeIndex, 2), view.rootOfSegment(SegmentId.of(0)));
    try std.testing.expectEqual(@as(?NodeIndex, 0), view.rootOfSegment(SegmentId.of(1)));
    try expectPreorder(&view, &.{ 2, 3, 0, 1 });
}

fn node(
    backend: *NoIoConfig,
    comptime segment: u16,
    comptime bus: u8,
    comptime device: u5,
    comptime function: u3,
    header_kind: HeaderKind,
    parent: ?NodeIndex,
) Node {
    const sbdf = Sbdf.of(segment, bus, device, function);
    return .{
        .sbdf = sbdf,
        .function = Function.unchecked(backend.configSpace(), sbdf),
        .header_kind = header_kind,
        .parent = parent,
    };
}

fn expectPreorder(view: *const Tree, expected: []const NodeIndex) !void {
    var iterator = view.preorder();
    try expectIterator(&iterator, expected);
}

fn expectPreorderFrom(view: *const Tree, root: NodeIndex, expected: []const NodeIndex) !void {
    var iterator = view.preorderFrom(root);
    try expectIterator(&iterator, expected);
}

fn expectIterator(iterator: *PreorderIterator, expected: []const NodeIndex) !void {
    for (expected) |index| {
        const item = iterator.next();
        try std.testing.expect(item != null);
        try std.testing.expectEqual(index, item.?.index);
        try std.testing.expect(item.?.node == iterator.tree.node(index));
    }

    try std.testing.expectEqual(@as(?PreorderIterator.Item, null), iterator.next());
}

fn expectChildren(view: *const Tree, bridge: NodeIndex, expected: []const NodeIndex) !void {
    var iterator = view.children(bridge);
    for (expected) |index| {
        const item = iterator.next();
        try std.testing.expect(item != null);
        try std.testing.expectEqual(index, item.?.index);
        try std.testing.expect(item.?.node == view.node(index));
    }

    try std.testing.expectEqual(@as(?PreorderIterator.Item, null), iterator.next());
}

fn expectNoIo(backend: *const NoIoConfig) !void {
    try std.testing.expectEqual(@as(usize, 0), backend.read_count);
    try std.testing.expectEqual(@as(usize, 0), backend.write_count);
}

const NoIoConfig = struct {
    read_count: usize = 0,
    write_count: usize = 0,

    fn configSpace(self: *NoIoConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn read8(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u8 {
        _ = sbdf;
        _ = offset;
        const self: *NoIoConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        return error.UnsupportedAccessWidth;
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u16 {
        _ = sbdf;
        _ = offset;
        const self: *NoIoConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        return error.UnsupportedAccessWidth;
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u32 {
        _ = sbdf;
        _ = offset;
        const self: *NoIoConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        return error.UnsupportedAccessWidth;
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigSpace.Error!void {
        _ = sbdf;
        _ = offset;
        _ = value;
        const self: *NoIoConfig = @ptrCast(@alignCast(context));
        self.write_count += 1;
        return error.UnsupportedAccessWidth;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigSpace.Error!void {
        _ = sbdf;
        _ = offset;
        _ = value;
        const self: *NoIoConfig = @ptrCast(@alignCast(context));
        self.write_count += 1;
        return error.UnsupportedAccessWidth;
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigSpace.Error!void {
        _ = sbdf;
        _ = offset;
        _ = value;
        const self: *NoIoConfig = @ptrCast(@alignCast(context));
        self.write_count += 1;
        return error.UnsupportedAccessWidth;
    }
};
