const std = @import("std");

const cfg = @import("config");
const core = @import("core");

const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;
const Function = cfg.Function;
const HeaderFormat = core.header.Format;
const SegmentId = core.SegmentId;
const Sbdf = core.Sbdf;

pub const max_nodes: usize = std.math.maxInt(@typeInfo(NodeId).@"enum".tag_type);

pub const Tree = struct {
    buffer: []const Node,
    size: usize,
    roots: []const NodeId,

    const Self = @This();

    pub fn deinit(self: *const Self, allocator: Allocator) void {
        self.assertStorage();

        const buffer = self.buffer;
        const roots = self.roots;

        allocator.destroy(self);
        allocator.free(roots);
        allocator.free(buffer);
    }

    pub fn nodes(self: *const Self) []const Node {
        self.assertStorage();
        return self.buffer[0..self.size];
    }

    pub fn node(self: *const Self, id: NodeId) *const Node {
        self.assertStorage();
        std.debug.assert(id.raw() < self.size);
        return &self.buffer[id.raw()];
    }

    pub fn parent(self: *const Self, id: NodeId) ?NodeId {
        const current = self.node(id);
        if (current.parent) |parent_id| {
            std.debug.assert(parent_id.raw() < id.raw());
        }

        return current.parent;
    }

    pub fn root(self: *const Self, segment: SegmentId) ?NodeId {
        self.assertStorage();

        for (self.roots) |id| {
            if (self.node(id).function.sbdf.segment == segment) {
                return id;
            }
        }

        return null;
    }

    pub fn preorder(self: *const Self) PreorderIterator {
        self.assertStorage();
        return .{ .tree = self };
    }

    pub fn preorderFrom(self: *const Self, id: NodeId) PreorderIterator {
        const current = self.node(id);
        std.debug.assert(current.subtree_end > id.raw() and current.subtree_end <= self.size);

        return .{
            .tree = self,
            .next_root = self.roots.len,
            .cursor = id.raw(),
            .end = current.subtree_end,
        };
    }

    pub fn children(self: *const Self, id: NodeId) ChildrenIterator {
        const current = self.node(id);
        std.debug.assert(current.format == .type1);
        std.debug.assert(current.subtree_end > id.raw() and current.subtree_end <= self.size);

        return .{
            .tree = self,
            .cursor = @as(usize, id.raw()) + 1,
            .end = current.subtree_end,
        };
    }

    pub fn pathTo(self: *const Self, allocator: Allocator, id: NodeId) AllocError![]NodeId {
        var len: usize = 0;
        var cursor: ?NodeId = id;

        while (cursor) |current| {
            std.debug.assert(len < self.size);
            len += 1;
            cursor = self.parent(current);
        }

        const path = try allocator.alloc(NodeId, len);

        cursor = id;

        while (cursor) |current| {
            std.debug.assert(len > 0);
            len -= 1;
            path[len] = current;
            cursor = self.parent(current);
        }

        std.debug.assert(len == 0);
        return path;
    }

    pub fn assertValid(self: *const Self) void {
        self.assertStorage();

        var open: ?NodeId = null;
        var num_roots: usize = 0;
        for (self.nodes(), 0..) |*current, index| {
            while (open) |id| {
                const ancestor = self.node(id);
                std.debug.assert(index <= ancestor.subtree_end);

                if (index < ancestor.subtree_end) {
                    break;
                }

                open = ancestor.parent;
            }

            std.debug.assert(current.parent == open);
            std.debug.assert(current.subtree_end > index and current.subtree_end <= self.size);

            if (open) |id| {
                const ancestor = self.node(id);
                std.debug.assert(ancestor.format == .type1);
                std.debug.assert(current.subtree_end <= ancestor.subtree_end);
            } else {
                num_roots += 1;
            }

            if (current.subtree_end > index + 1) {
                std.debug.assert(current.format == .type1);
            }

            std.debug.assert(index < max_nodes);
            open = NodeId.from(@intCast(index));
        }

        while (open) |id| {
            const current = self.node(id);
            std.debug.assert(current.subtree_end == self.size);
            open = current.parent;
        }

        std.debug.assert(num_roots == self.roots.len);

        for (self.roots, 0..) |id, index| {
            std.debug.assert(self.node(id).parent == null);

            if (index > 0) {
                const previous_id = self.roots[index - 1];
                const previous = self.node(previous_id).function.sbdf;
                const current = self.node(id).function.sbdf;
                std.debug.assert(Sbdf.lessThan(previous, current) or
                    (previous.eql(current) and previous_id.raw() < id.raw()));
            }
        }
    }

    fn assertStorage(self: *const Self) void {
        std.debug.assert(self.size <= self.buffer.len);
        std.debug.assert(self.size <= max_nodes);
        std.debug.assert(self.roots.len <= self.size);
        std.debug.assert((self.size == 0) == (self.roots.len == 0));
    }
};

pub const NodeId = enum(u16) {
    _,

    const Self = @This();

    pub fn from(value: u16) Self {
        return @enumFromInt(value);
    }

    pub fn raw(self: Self) u16 {
        return @intFromEnum(self);
    }
};

pub const Node = struct {
    function: Function,
    format: HeaderFormat,
    parent: ?NodeId,
    subtree_end: usize,
};

pub const Item = struct {
    id: NodeId,
    node: *const Node,
};

pub const PreorderIterator = struct {
    tree: *const Tree,
    next_root: usize = 0,
    cursor: usize = 0,
    end: usize = 0,

    const Self = @This();

    pub fn next(self: *Self) ?Item {
        self.tree.assertStorage();
        std.debug.assert(self.cursor <= self.end and self.end <= self.tree.size);
        std.debug.assert(self.next_root <= self.tree.roots.len);

        if (self.cursor == self.end) {
            if (self.next_root == self.tree.roots.len) {
                return null;
            }

            const root_id = self.tree.roots[self.next_root];
            self.next_root += 1;
            self.cursor = root_id.raw();
            self.end = self.tree.node(root_id).subtree_end;
        }

        std.debug.assert(self.cursor < self.end and self.end <= self.tree.size);
        std.debug.assert(self.cursor < max_nodes);

        const id = NodeId.from(@intCast(self.cursor));
        self.cursor += 1;

        return .{
            .id = id,
            .node = self.tree.node(id),
        };
    }
};

pub const ChildrenIterator = struct {
    tree: *const Tree,
    cursor: usize = 0,
    end: usize = 0,

    const Self = @This();

    pub fn next(self: *Self) ?Item {
        self.tree.assertStorage();
        std.debug.assert(self.cursor <= self.end and self.end <= self.tree.size);

        if (self.cursor == self.end) {
            return null;
        }

        std.debug.assert(self.cursor < max_nodes);
        const id = NodeId.from(@intCast(self.cursor));
        const current = self.tree.node(id);
        std.debug.assert(current.subtree_end > self.cursor and current.subtree_end <= self.end);

        self.cursor = current.subtree_end;

        return .{
            .id = id,
            .node = current,
        };
    }
};

pub const unit = struct {
    const testing = std.testing;

    const ConfigSpace = cfg.ConfigSpace;
    const ConfigError = ConfigSpace.Error;

    const NodeList = std.ArrayList(Node);

    const NoIoConfig = struct {
        read_count: usize = 0,
        write_count: usize = 0,

        const Self = @This();

        fn config(self: *Self) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(context: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            self.read_count += 1;
            return error.UnsupportedAccessWidth;
        }

        fn read16(context: *anyopaque, _: Sbdf, _: usize) ConfigError!u16 {
            const self: *Self = @ptrCast(@alignCast(context));
            self.read_count += 1;
            return error.UnsupportedAccessWidth;
        }

        fn read32(context: *anyopaque, _: Sbdf, _: usize) ConfigError!u32 {
            const self: *Self = @ptrCast(@alignCast(context));
            self.read_count += 1;
            return error.UnsupportedAccessWidth;
        }

        fn write8(context: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.write_count += 1;
            return error.UnsupportedAccessWidth;
        }

        fn write16(context: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.write_count += 1;
            return error.UnsupportedAccessWidth;
        }

        fn write32(context: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.write_count += 1;
            return error.UnsupportedAccessWidth;
        }
    };

    test "empty snapshot" {
        var nodes: NodeList = .empty;
        defer nodes.deinit(testing.allocator);

        const tree = try fixture(testing.allocator, &nodes, &.{});
        defer tree.deinit(testing.allocator);
        tree.assertValid();

        var iterator = tree.preorder();
        try expectIterator(&iterator, &.{});
        try testing.expectEqual(@as(usize, 0), tree.roots.len);
        try testing.expect(tree.root(SegmentId.from(0)) == null);
    }

    test "preorder respects explicit root order" {
        var backend = NoIoConfig{};
        var nodes: NodeList = .empty;
        defer nodes.deinit(testing.allocator);
        try nodes.appendSlice(testing.allocator, &.{
            makeNode(&backend, Sbdf.from(.from(1), 0, 0, 0), null, 1),
            makeNode(&backend, Sbdf.from(.from(0), 1, 0, 0), null, 2),
            makeNode(&backend, Sbdf.from(.from(0), 0, 1, 1), null, 3),
            makeNode(&backend, Sbdf.from(.from(0), 0, 1, 0), null, 4),
            makeNode(&backend, Sbdf.from(.from(0), 0, 1, 0), null, 5),
        });

        const tree = try fixture(testing.allocator, &nodes, &.{
            NodeId.from(3),
            NodeId.from(4),
            NodeId.from(2),
            NodeId.from(1),
            NodeId.from(0),
        });
        defer tree.deinit(testing.allocator);
        tree.assertValid();

        var iterator = tree.preorder();
        try expectIterator(&iterator, &.{ 3, 4, 2, 1, 0 });
        try testing.expectEqual(NodeId.from(3), tree.root(SegmentId.from(0)).?);
        try testing.expectEqual(NodeId.from(0), tree.root(SegmentId.from(1)).?);
        try testing.expect(tree.root(SegmentId.from(2)) == null);
    }

    test "preorder and children stay within their subtree ranges" {
        var backend = NoIoConfig{};
        const tree = try sampleTree(testing.allocator, &backend);
        defer tree.deinit(testing.allocator);
        tree.assertValid();

        var all = tree.preorder();
        try expectIterator(&all, &.{ 0, 1, 2, 3 });

        var subtree = tree.preorderFrom(NodeId.from(1));
        try expectIterator(&subtree, &.{ 1, 2 });

        var children = tree.children(NodeId.from(0));
        try expectIterator(&children, &.{ 1, 3 });

        var leaf = tree.children(NodeId.from(3));
        try expectIterator(&leaf, &.{});

        try testing.expectEqual(@as(usize, 0), backend.read_count);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    test "paths include the root and selected node" {
        var backend = NoIoConfig{};
        const tree = try sampleTree(testing.allocator, &backend);
        defer tree.deinit(testing.allocator);
        tree.assertValid();

        const path = try tree.pathTo(testing.allocator, NodeId.from(2));
        defer testing.allocator.free(path);
        try testing.expectEqualSlices(NodeId, &.{ NodeId.from(0), NodeId.from(1), NodeId.from(2) }, path);

        const root_path = try tree.pathTo(testing.allocator, NodeId.from(0));
        defer testing.allocator.free(root_path);
        try testing.expectEqualSlices(NodeId, &.{NodeId.from(0)}, root_path);

        try testing.expectEqual(@as(usize, 0), backend.read_count);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    test "node pointers remain stable while allocating paths" {
        var backend = NoIoConfig{};
        const tree = try sampleTree(testing.allocator, &backend);
        defer tree.deinit(testing.allocator);
        tree.assertValid();

        const node = tree.node(NodeId.from(3));
        const path = try tree.pathTo(testing.allocator, NodeId.from(3));
        defer testing.allocator.free(path);

        try testing.expectEqualSlices(NodeId, &.{ NodeId.from(0), NodeId.from(3) }, path);
        try testing.expect(node == tree.node(NodeId.from(3)));
        try testing.expect(node.function.sbdf.eql(Sbdf.from(.from(1), 3, 0, 0)));
    }

    test "path allocation failures preserve snapshot" {
        var backend = NoIoConfig{};
        const tree = try sampleTree(testing.allocator, &backend);
        defer tree.deinit(testing.allocator);

        try testing.checkAllAllocationFailures(testing.allocator, allocationCase, .{tree});
    }

    test "wide and deep traversal has no discovery depth bound" {
        for ([_]bool{ false, true }) |deep| {
            var backend = NoIoConfig{};
            var nodes: NodeList = .empty;
            defer nodes.deinit(testing.allocator);

            const count = 100;
            for (0..count) |index| {
                try nodes.append(testing.allocator, makeNode(
                    &backend,
                    Sbdf.from(.from(0), 0, 0, 0),
                    if (index == 0) null else if (deep) @intCast(index - 1) else 0,
                    if (deep or index == 0) count else index + 1,
                ));
            }

            const tree = try fixture(testing.allocator, &nodes, &.{NodeId.from(0)});
            defer tree.deinit(testing.allocator);
            tree.assertValid();

            var iterator = tree.preorder();
            var index: u16 = 0;
            while (iterator.next()) |item| : (index += 1) {
                try testing.expectEqual(NodeId.from(index), item.id);
            }
            try testing.expectEqual(@as(u16, count), index);

            const path = try tree.pathTo(testing.allocator, NodeId.from(count - 1));
            defer testing.allocator.free(path);
            try testing.expectEqual(@as(usize, if (deep) count else 2), path.len);
            try testing.expectEqual(NodeId.from(0), path[0]);
            try testing.expectEqual(NodeId.from(count - 1), path[path.len - 1]);
        }
    }

    test "last valid node traversal" {
        var backend = NoIoConfig{};
        var nodes: NodeList = .empty;
        defer nodes.deinit(testing.allocator);
        try nodes.ensureTotalCapacity(testing.allocator, max_nodes);
        for (0..max_nodes) |index| {
            nodes.appendAssumeCapacity(makeNode(
                &backend,
                Sbdf.from(.from(0), 0, 0, 0),
                if (index == 0) null else 0,
                if (index == 0) max_nodes else index + 1,
            ));
        }

        const tree = try fixture(testing.allocator, &nodes, &.{NodeId.from(0)});
        defer tree.deinit(testing.allocator);
        tree.assertValid();

        const last = NodeId.from(@intCast(max_nodes - 1));
        var iterator = tree.preorderFrom(last);
        try expectIterator(&iterator, &.{last.raw()});

        var all = tree.preorder();
        var count: usize = 0;
        while (all.next() != null) {
            count += 1;
        }
        try testing.expectEqual(max_nodes, count);
    }

    fn sampleTree(allocator: Allocator, backend: *NoIoConfig) AllocError!*const Tree {
        var nodes: NodeList = .empty;
        defer nodes.deinit(allocator);

        try nodes.appendSlice(allocator, &.{
            makeNode(backend, Sbdf.from(.from(1), 0, 0, 0), null, 4),
            makeNode(backend, Sbdf.from(.from(1), 1, 0, 0), 0, 3),
            makeNode(backend, Sbdf.from(.from(1), 2, 0, 0), 1, 3),
            makeNode(backend, Sbdf.from(.from(1), 3, 0, 0), 0, 4),
        });
        nodes.items[2].format = .type0;

        return fixture(allocator, &nodes, &.{NodeId.from(0)});
    }

    fn fixture(allocator: Allocator, nodes: *NodeList, roots: []const NodeId) AllocError!*const Tree {
        const owned_roots = try allocator.dupe(NodeId, roots);
        errdefer allocator.free(owned_roots);

        const tree = try allocator.create(Tree);
        tree.* = .{
            .buffer = nodes.allocatedSlice(),
            .size = nodes.items.len,
            .roots = owned_roots,
        };
        nodes.* = .empty;
        return tree;
    }

    fn makeNode(backend: *NoIoConfig, sbdf: Sbdf, parent: ?u16, subtree_end: usize) Node {
        return .{
            .function = Function.from(backend.config(), sbdf),
            .format = .type1,
            .parent = if (parent) |id| NodeId.from(id) else null,
            .subtree_end = subtree_end,
        };
    }

    fn expectIterator(iterator: anytype, expected: []const u16) !void {
        for (expected) |raw| {
            const item = iterator.next() orelse return error.TestUnexpectedResult;
            try testing.expectEqual(NodeId.from(raw), item.id);
            try testing.expect(item.node == iterator.tree.node(item.id));
        }

        try testing.expect(iterator.next() == null);
    }

    fn allocationCase(allocator: Allocator, tree: *const Tree) !void {
        const path = try tree.pathTo(allocator, NodeId.from(1));
        defer allocator.free(path);
        try testing.expectEqualSlices(NodeId, &.{ NodeId.from(0), NodeId.from(1) }, path);
    }
};
