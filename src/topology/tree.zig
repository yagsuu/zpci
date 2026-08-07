//! Borrowed PCI topology tree. Spec: docs/specs/topology/tree.md.

const std = @import("std");

const config = @import("../config.zig");
const core = @import("../core.zig");

pub const NodeIndex = u16;

pub const max_nodes: usize = std.math.maxInt(NodeIndex);
pub const max_depth: u8 = 32;

pub const Error = error{
    StorageExhausted,
    InvalidTopology,
};

pub const Node = struct {
    sbdf: core.Sbdf,
    function: config.Function,
    header_kind: config.HeaderKind,
    parent: ?NodeIndex,
    first_child: ?NodeIndex = null,
    next_sibling: ?NodeIndex = null,
};

/// Borrowed topology view over caller-owned node and root scratch slices.
pub const Tree = struct {
    nodes: []const Node,
    roots: []const NodeIndex,

    pub fn node(self: *const Tree, index: NodeIndex) *const Node {
        std.debug.assert(@as(usize, index) < self.nodes.len);
        return &self.nodes[@as(usize, index)];
    }

    pub fn parentOf(self: *const Tree, index: NodeIndex) ?NodeIndex {
        return self.node(index).parent;
    }

    pub fn rootOfSegment(self: *const Tree, segment: core.SegmentId) ?NodeIndex {
        for (self.roots) |root| {
            std.debug.assert(@as(usize, root) < self.nodes.len);
            if (core.SegmentId.eql(self.nodes[@as(usize, root)].sbdf.segment, segment)) return root;
        }

        return null;
    }

    pub fn preorder(self: *const Tree) PreorderIterator {
        std.debug.assert(self.roots.len <= max_nodes);

        return .{
            .tree = self,
            .stack = undefined,
            .depth = 0,
            .next_root = 0,
            .path_depths = undefined,
            .subtree_root = null,
        };
    }

    pub fn preorderFrom(self: *const Tree, root: NodeIndex) PreorderIterator {
        std.debug.assert(@as(usize, root) < self.nodes.len);

        var iterator = PreorderIterator{
            .tree = self,
            .stack = undefined,
            .depth = 0,
            .next_root = 0,
            .path_depths = undefined,
            .subtree_root = root,
        };
        iterator.push(root, 0);
        return iterator;
    }

    pub fn children(self: *const Tree, bridge: NodeIndex) ChildrenIterator {
        const bridge_node = self.node(bridge);
        std.debug.assert(bridge_node.header_kind == .type1);

        return .{
            .tree = self,
            .cursor = bridge_node.first_child,
        };
    }
};

/// Non-allocating DFS preorder iterator over one subtree or every root subtree.
pub const PreorderIterator = struct {
    tree: *const Tree,
    stack: [max_depth]NodeIndex,
    depth: u8,
    path_depths: [max_depth]u8,
    next_root: u16,
    subtree_root: ?NodeIndex,

    pub const Item = struct {
        index: NodeIndex,
        node: *const Node,
    };

    const Pending = struct {
        index: NodeIndex,
        path_depth: u8,
    };

    pub fn next(self: *PreorderIterator) ?Item {
        if (self.depth == 0) {
            if (self.subtree_root != null) return null;
            if (@as(usize, self.next_root) >= self.tree.roots.len) return null;

            self.push(self.tree.roots[@as(usize, self.next_root)], 0);
            self.next_root += 1;
        }

        const pending = self.pop();
        const current = self.tree.node(pending.index);
        const sibling_is_in_scope = self.subtree_root == null or pending.index != self.subtree_root.?;

        if (sibling_is_in_scope) {
            if (current.next_sibling) |sibling| self.push(sibling, pending.path_depth);
        }

        if (current.first_child) |child| self.push(child, pending.path_depth + 1);

        return .{ .index = pending.index, .node = current };
    }

    fn push(self: *PreorderIterator, index: NodeIndex, path_depth: u8) void {
        std.debug.assert(@as(usize, index) < self.tree.nodes.len);
        std.debug.assert(path_depth <= max_depth);
        std.debug.assert(self.depth < max_depth);

        self.stack[@as(usize, self.depth)] = index;
        self.path_depths[@as(usize, self.depth)] = path_depth;
        self.depth += 1;
    }

    fn pop(self: *PreorderIterator) Pending {
        std.debug.assert(self.depth > 0);

        self.depth -= 1;
        const slot = @as(usize, self.depth);
        return .{
            .index = self.stack[slot],
            .path_depth = self.path_depths[slot],
        };
    }
};

/// Non-allocating direct-child iterator over one bridge's linked child chain.
pub const ChildrenIterator = struct {
    tree: *const Tree,
    cursor: ?NodeIndex,

    pub const Item = PreorderIterator.Item;

    pub fn next(self: *ChildrenIterator) ?Item {
        const index = self.cursor orelse return null;
        const current = self.tree.node(index);
        self.cursor = current.next_sibling;

        return .{ .index = index, .node = current };
    }
};

/// Builds tree linkage in caller scratch and returns slices borrowed from that scratch.
pub fn intoScratch(nodes: []Node, roots: []NodeIndex) Error!Tree {
    if (nodes.len > max_nodes) return error.StorageExhausted;

    const root_count = countRoots(nodes);
    if (roots.len < root_count) return error.StorageExhausted;

    try validateTopology(nodes);

    clearLinks(nodes);
    linkChildren(nodes);
    fillRoots(nodes, roots[0..root_count]);

    const read_only_nodes: []const Node = nodes;
    std.mem.sort(NodeIndex, roots[0..root_count], read_only_nodes, rootLessThan);

    return .{
        .nodes = nodes,
        .roots = roots[0..root_count],
    };
}

fn countRoots(nodes: []const Node) usize {
    var count: usize = 0;
    for (nodes) |node| {
        if (node.parent == null) count += 1;
    }

    return count;
}

fn validateTopology(nodes: []const Node) Error!void {
    for (nodes, 0..) |node, index| {
        if (node.parent) |parent| {
            const parent_index = @as(usize, parent);
            if (parent_index >= index) return error.InvalidTopology;
            if (nodes[parent_index].header_kind != .type1) return error.InvalidTopology;
        }
    }
}

fn clearLinks(nodes: []Node) void {
    for (nodes) |*node| {
        node.first_child = null;
        node.next_sibling = null;
    }
}

fn linkChildren(nodes: []Node) void {
    var index = nodes.len;
    while (index > 0) {
        index -= 1;

        if (nodes[index].parent) |parent| {
            const parent_index = @as(usize, parent);
            std.debug.assert(parent_index < index);
            std.debug.assert(nodes[parent_index].header_kind == .type1);

            const child: NodeIndex = @intCast(index);
            nodes[index].next_sibling = nodes[parent_index].first_child;
            nodes[parent_index].first_child = child;
        }
    }
}

fn fillRoots(nodes: []const Node, roots: []NodeIndex) void {
    var count: usize = 0;
    for (nodes, 0..) |node, index| {
        if (node.parent == null) {
            roots[count] = @intCast(index);
            count += 1;
        }
    }

    std.debug.assert(count == roots.len);
}

fn rootLessThan(nodes: []const Node, lhs: NodeIndex, rhs: NodeIndex) bool {
    const lhs_node = nodes[@as(usize, lhs)];
    const rhs_node = nodes[@as(usize, rhs)];
    if (core.Sbdf.lessThan(lhs_node.sbdf, rhs_node.sbdf)) return true;
    if (core.Sbdf.lessThan(rhs_node.sbdf, lhs_node.sbdf)) return false;

    return lhs < rhs;
}

comptime {
    std.debug.assert(@sizeOf(NodeIndex) == 2);
    std.debug.assert(max_nodes == 65_535);
}
