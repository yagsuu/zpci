//! Read-only topology discovery.

const std = @import("std");

const stdx = @import("stdx");

const capabilities = @import("capabilities");
const cfg = @import("config");
const core = @import("core");
const header = @import("header");

const tree = @import("tree.zig");

const Allocator = std.mem.Allocator;
const AllocError = Allocator.Error;
const ConfigSpace = cfg.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Segment = cfg.Segment;
const Function = cfg.Function;
const Bdf = core.Bdf;
const Sbdf = core.Sbdf;
const Pcie = capabilities.pcie.Capability;
const Type1 = header.Type1;
const Tree = tree.Tree;
const NodeId = tree.NodeId;
const Node = tree.Node;
const NodeList = std.ArrayList(Node);

pub const Error = AllocError || ConfigError || error{ StorageExhausted, DepthExceeded };

pub const Args = struct {
    config: ConfigSpace,
    segments: []const Segment,
};

pub fn enumerate(allocator: Allocator, args: Args) Error!*const Tree {
    var nodes: NodeList = .empty;
    defer nodes.deinit(allocator);

    for (args.segments) |*segment| {
        var enumerator = Enumerator{
            .allocator = allocator,
            .config = args.config,
            .segment = segment,
            .nodes = &nodes,
        };

        try enumerator.enumerateBus(&.{ .bus = segment.buses.start });
    }

    return finish(allocator, &nodes);
}

const Enumerator = struct {
    allocator: Allocator,
    config: ConfigSpace,
    segment: *const Segment,
    nodes: *NodeList,

    const Self = @This();
    const max_depth = 31;

    const FunctionRouting = enum {
        classic,
        ari,
    };

    const BusArgs = struct {
        bus: u8,
        parent: ?NodeId = null,
        depth: u8 = 0,
        routing: FunctionRouting = .classic,
    };

    fn enumerateBus(self: *Self, args: *const BusArgs) Error!void {
        if (args.depth > max_depth) {
            return error.DepthExceeded;
        }

        switch (args.routing) {
            .ari => {
                var function: u16 = 0;
                while (function < 256) : (function += 1) {
                    const device: u5 = @intCast(function >> 3);
                    const index: u3 = @intCast(function & 0b111);
                    const bdf = Bdf.from(args.bus, device, index);

                    _ = try self.enumerateFunction(args, bdf);
                }
            },
            .classic => {
                var device: u8 = 0;
                while (device < core.device.count) : (device += 1) {
                    const bdf = Bdf.from(args.bus, @intCast(device), 0);

                    if (try self.enumerateFunction(args, bdf)) |function| {
                        if (try function.multifunction()) {
                            var index: u8 = 1;
                            while (index < core.function.count) : (index += 1) {
                                const sibling = Bdf.from(args.bus, @intCast(device), @intCast(index));
                                _ = try self.enumerateFunction(args, sibling);
                            }
                        }
                    }
                }
            },
        }
    }

    fn enumerateFunction(
        self: *Self,
        args: *const BusArgs,
        bdf: Bdf,
    ) Error!?Function {
        const sbdf = Sbdf.fromBdf(self.segment.segment, bdf);
        const function = Function.tryFrom(self.config, sbdf) catch |err| switch (err) {
            error.AbsentFunction, error.BadHeaderType => return null,
            else => |other| return other,
        };

        const format = function.format() catch |err| switch (err) {
            error.AbsentFunction, error.BadHeaderType => return null,
            else => |other| return other,
        };

        if (self.nodes.items.len >= tree.max_nodes) {
            return error.StorageExhausted;
        }

        const index = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .function = function,
            .format = format,
            .parent = args.parent,
            .subtree_end = index + 1,
        });

        if (format == .type1) {
            const bridge = Type1.from(function);
            const secondary_bus = try bridge.secondaryBus();
            const subordinate_bus = try bridge.subordinateBus();

            const descend = secondary_bus != 0 and
                secondary_bus > args.bus and
                secondary_bus <= self.segment.buses.end and
                secondary_bus <= subordinate_bus;

            if (descend) {
                const routing: FunctionRouting = routing: {
                    const capability = Pcie.find(function) catch |err| switch (err) {
                        error.MalformedCapability, error.UnsupportedRevision => break :routing .classic,
                        else => |other| return other,
                    } orelse break :routing .classic;

                    const control = capability.deviceControl2() catch |err| switch (err) {
                        error.MalformedCapability, error.UnsupportedRevision => break :routing .classic,
                        else => |other| return other,
                    };

                    break :routing if (control.ari_forwarding_enable) .ari else .classic;
                };

                const child_args: BusArgs = .{
                    .bus = secondary_bus,
                    .parent = NodeId.from(@intCast(index)),
                    .depth = args.depth + 1,
                    .routing = routing,
                };

                try self.enumerateBus(&child_args);
            }
        }

        self.nodes.items[index].subtree_end = self.nodes.items.len;

        return function;
    }
};

fn finish(allocator: Allocator, nodes: *NodeList) Error!*const Tree {
    std.debug.assert(nodes.items.len <= nodes.capacity);
    std.debug.assert(nodes.items.len <= tree.max_nodes);

    var num_roots: usize = 0;
    for (nodes.items) |*current| {
        if (current.parent == null) {
            num_roots += 1;
        }
    }

    const roots = try allocator.alloc(NodeId, num_roots);
    errdefer allocator.free(roots);

    var root_index: usize = 0;
    for (nodes.items, 0..) |*current, index| {
        if (current.parent == null) {
            roots[root_index] = NodeId.from(@intCast(index));
            root_index += 1;
        }
    }

    std.mem.sort(NodeId, roots, @as([]const Node, nodes.items), rootLessThan);

    const result = try allocator.create(Tree);
    result.* = .{
        .buffer = nodes.allocatedSlice(),
        .size = nodes.items.len,
        .roots = roots,
    };

    if (stdx.core.debug.checksEnabled()) {
        result.assertValid();
    }

    nodes.* = .empty;
    return result;
}

fn rootLessThan(nodes: []const Node, lhs: NodeId, rhs: NodeId) bool {
    std.debug.assert(lhs.raw() < nodes.len);
    std.debug.assert(rhs.raw() < nodes.len);

    const left = nodes[lhs.raw()].function.sbdf;
    const right = nodes[rhs.raw()].function.sbdf;

    if (Sbdf.lessThan(left, right)) {
        return true;
    }

    if (Sbdf.lessThan(right, left)) {
        return false;
    }

    return lhs.raw() < rhs.raw();
}

pub const unit = struct {
    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;
    const cap_base: u8 = 0x40;

    const FixedBufferAllocator = std.heap.FixedBufferAllocator;

    const HeaderFormat = core.header.Format;
    const SegmentId = core.SegmentId;

    const BusRange = stdx.ranges.InclusiveRange(core.bus.Index);

    const Entry = struct {
        sbdf: Sbdf,
        bytes: []u8,
    };

    const TestConfigSpace = struct {
        entries: []Entry,
        fail_on_read_offset: ?usize = null,
        pcie_reads: [3]usize = @splat(0),

        fn from(entries: []Entry) TestConfigSpace {
            return .{ .entries = entries };
        }

        fn config(self: *TestConfigSpace) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn functionBytes(self: *TestConfigSpace, address: Sbdf) ?[]u8 {
            for (self.entries) |entry| {
                if (entry.sbdf.eql(address)) {
                    return entry.bytes;
                }
            }

            return null;
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(context: *anyopaque, address: Sbdf, byte_offset: usize) ConfigError!u8 {
            const self: *TestConfigSpace = @ptrCast(@alignCast(context));
            if (address.bdf.bus == 0 and byte_offset == cap_base) {
                self.pcie_reads[0] += 1;
            }

            if (self.fail_on_read_offset == byte_offset) {
                return error.OutOfBounds;
            }

            const bytes = self.functionBytes(address) orelse return 0xFF;
            return bytes[byte_offset];
        }

        fn read16(context: *anyopaque, address: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *TestConfigSpace = @ptrCast(@alignCast(context));
            if (address.bdf.bus == 0) {
                for ([_]usize{ cap_base, cap_base + pcie.capabilities, cap_base + pcie.device_control_2 }, 0..) |position, index| {
                    if (byte_offset == position) {
                        self.pcie_reads[index] += 1;
                    }
                }
            }

            if (self.fail_on_read_offset == byte_offset) {
                return error.OutOfBounds;
            }

            const bytes = self.functionBytes(address) orelse return 0xFFFF;
            return std.mem.readInt(u16, bytes[byte_offset..][0..2], .little);
        }

        fn read32(context: *anyopaque, address: Sbdf, byte_offset: usize) ConfigError!u32 {
            const self: *TestConfigSpace = @ptrCast(@alignCast(context));
            if (self.fail_on_read_offset == byte_offset) {
                return error.OutOfBounds;
            }

            const bytes = self.functionBytes(address) orelse return 0xFFFF_FFFF;
            return std.mem.readInt(u32, bytes[byte_offset..][0..4], .little);
        }

        fn write8(context: *anyopaque, address: Sbdf, byte_offset: usize, value: u8) ConfigError!void {
            const self: *TestConfigSpace = @ptrCast(@alignCast(context));
            const bytes = self.functionBytes(address) orelse return;
            bytes[byte_offset] = value;
        }

        fn write16(context: *anyopaque, address: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *TestConfigSpace = @ptrCast(@alignCast(context));
            const bytes = self.functionBytes(address) orelse return;
            store16(bytes[0..pcie_window_size], byte_offset, value);
        }

        fn write32(context: *anyopaque, address: Sbdf, byte_offset: usize, value: u32) ConfigError!void {
            const self: *TestConfigSpace = @ptrCast(@alignCast(context));
            const bytes = self.functionBytes(address) orelse return;
            std.mem.writeInt(u32, bytes[byte_offset..][0..4], value, .little);
        }
    };

    const LimitConfigSpace = struct {
        chain_end: ?u8 = null,
        final_functions: u16 = 256,
        max_bus: u8 = 0,
        vendor_reads: usize = 0,
        final_header_reads: usize = 0,

        fn config(self: *LimitConfigSpace) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn present(self: *const LimitConfigSpace, address: Sbdf) bool {
            if (self.chain_end) |last_bus| {
                return address.bdf.bus <= last_bus and address.bdf.df() == 0;
            }

            return address.bdf.bus == 0 and
                (@intFromEnum(address.segment) < 255 or
                    (@intFromEnum(address.segment) == 255 and address.bdf.df() < self.final_functions));
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(context: *anyopaque, address: Sbdf, byte_offset: usize) ConfigError!u8 {
            const self: *LimitConfigSpace = @ptrCast(@alignCast(context));
            self.max_bus = @max(self.max_bus, address.bdf.bus);
            if (!self.present(address)) {
                return 0xFF;
            }

            switch (byte_offset) {
                offset.type => {
                    if (address.eql(sbdf(255, 0, 31, 7))) {
                        self.final_header_reads += 1;
                    }
                    if (self.chain_end) |last_bus| {
                        return if (address.bdf.bus < last_bus) 0x01 else 0x00;
                    }
                    return 0x80;
                },
                offset.secondary_bus => return address.bdf.bus + 1,
                offset.subordinate_bus => return self.chain_end orelse 0,
                else => return error.OutOfBounds,
            }
        }

        fn read16(context: *anyopaque, address: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *LimitConfigSpace = @ptrCast(@alignCast(context));
            self.max_bus = @max(self.max_bus, address.bdf.bus);
            if (byte_offset == offset.vendor_id) {
                self.vendor_reads += 1;
                return if (self.present(address)) 0x1234 else 0xFFFF;
            }
            if (byte_offset == offset.status) {
                return 0;
            }
            return error.OutOfBounds;
        }

        fn read32(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u32 {
            return error.OutOfBounds;
        }

        fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.OutOfBounds;
        }

        fn write16(_: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {
            return error.OutOfBounds;
        }

        fn write32(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            return error.OutOfBounds;
        }
    };

    const offset = struct {
        const vendor_id: usize = 0x00;
        const device_id: usize = 0x02;
        const status: usize = 0x06;
        const @"type": usize = 0x0E;
        const secondary_bus: usize = 0x19;
        const subordinate_bus: usize = 0x1A;
        const cap_ptr: usize = 0x34;
    };

    const status = struct {
        const cap_list: u16 = 1 << 4;
    };

    const pcie = struct {
        const id: u8 = 0x10;
        const capabilities: u8 = 0x02;
        const device_control_2: u8 = 0x28;
        const ari_forwarding_enable: u16 = 1 << 5;
    };

    test "finish preserves storage on allocation failure and transfers it on retry" {
        var context: u8 = 0;
        const space = ConfigSpace.from(&context, &.{
            .read8 = NoIo(u8).read,
            .read16 = NoIo(u16).read,
            .read32 = NoIo(u32).read,
            .write8 = NoIo(u8).write,
            .write16 = NoIo(u16).write,
            .write32 = NoIo(u32).write,
        });
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const allocator = failing.allocator();
        var nodes: NodeList = .empty;
        defer nodes.deinit(allocator);

        const originals = [_]Node{
            .{
                .function = Function.from(space, Sbdf.fromBdf(core.SegmentId.from(2), Bdf.from(0, 0, 0))),
                .format = .type0,
                .parent = null,
                .subtree_end = 1,
            },
            .{
                .function = Function.from(space, Sbdf.fromBdf(core.SegmentId.from(1), Bdf.from(0, 0, 0))),
                .format = .type0,
                .parent = null,
                .subtree_end = 2,
            },
            .{
                .function = Function.from(space, Sbdf.fromBdf(core.SegmentId.from(1), Bdf.from(0, 0, 0))),
                .format = .type0,
                .parent = null,
                .subtree_end = 3,
            },
        };
        try nodes.ensureTotalCapacity(allocator, 8);
        try nodes.appendSlice(allocator, &originals);

        const pointer = nodes.items.ptr;
        const capacity = nodes.capacity;
        const live_bytes = failing.allocated_bytes - failing.freed_bytes;
        failing.fail_index = failing.alloc_index + 1;

        try testing.expectError(error.OutOfMemory, finish(allocator, &nodes));
        try testing.expectEqual(pointer, nodes.items.ptr);
        try testing.expectEqual(capacity, nodes.capacity);
        try testing.expectEqualDeep(@as([]const Node, &originals), @as([]const Node, nodes.items));
        try testing.expectEqual(live_bytes, failing.allocated_bytes - failing.freed_bytes);

        failing.fail_index = std.math.maxInt(usize);
        const result = try finish(allocator, &nodes);
        defer result.deinit(allocator);

        try testing.expectEqual(pointer, result.buffer.ptr);
        try testing.expectEqual(capacity, result.buffer.len);
        try testing.expectEqualDeep(@as([]const Node, &originals), result.nodes());
        try testing.expectEqualSlices(NodeId, &.{ NodeId.from(1), NodeId.from(2), NodeId.from(0) }, result.roots);
        try testing.expectEqual(@as(usize, 0), nodes.items.len);
        try testing.expectEqual(@as(usize, 0), nodes.capacity);
    }

    test "empty segment list returns an empty tree" {
        var entries = [_]Entry{};
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{};

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 0), view.nodes().len);
        try testing.expectEqual(@as(usize, 0), view.roots.len);
    }

    test "absent functions produce no nodes for a populated segment aperture" {
        var entries = [_]Entry{};
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{segment(0, .of(0, 0))};

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 0), view.nodes().len);
        try testing.expectEqual(@as(usize, 0), view.roots.len);
    }

    test "single endpoint root is emitted as a root node" {
        var endpoint = functionBytes(.{ .header = 0x00 });
        var entries = [_]Entry{.{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &endpoint }};
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{segment(0, .of(0, 0))};

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try expectNodeSbdfs(view, &.{sbdf(0, 0, 0, 0)});
        try testing.expectEqualSlices(NodeId, &.{NodeId.from(0)}, view.roots);
        try testing.expectEqual(@as(?NodeId, null), view.node(NodeId.from(0)).parent);
        try testing.expectEqual(HeaderFormat.type0, view.node(NodeId.from(0)).format);
    }

    test "multi-segment walk emits in input order before root sorting" {
        var seg1_endpoint = functionBytes(.{ .header = 0x00 });
        var seg0_endpoint = functionBytes(.{ .header = 0x00 });
        var entries = [_]Entry{
            .{ .sbdf = sbdf(1, 0, 0, 0), .bytes = &seg1_endpoint },
            .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &seg0_endpoint },
        };
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{ segment(1, .of(0, 0)), segment(0, .of(0, 0)) };

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try expectNodeSbdfs(view, &.{ sbdf(1, 0, 0, 0), sbdf(0, 0, 0, 0) });
        try testing.expectEqualSlices(NodeId, &.{ NodeId.from(1), NodeId.from(0) }, view.roots);
        try expectPreorder(view, &.{ NodeId.from(1), NodeId.from(0) });
    }

    test "multifunction gate controls sibling function probing" {
        var function0 = functionBytes(.{ .header = 0x00 });
        var function1 = functionBytes(.{ .header = 0x00 });
        var entries = [_]Entry{
            .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &function0 },
            .{ .sbdf = sbdf(0, 0, 0, 1), .bytes = &function1 },
        };
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{segment(0, .of(0, 0))};

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try expectNodeSbdfs(view, &.{sbdf(0, 0, 0, 0)});
    }

    test "ARI forwarding maps flat function numbers through requester-id low byte" {
        var classic_bridge = functionBytes(.{ .header = 0x01, .secondary = 1, .subordinate = 1 });
        var ari_bridge = functionBytes(.{ .header = 0x01, .secondary = 1, .subordinate = 1, .ari = true });
        var ari_function9 = functionBytes(.{ .header = 0x00 });
        var classic_entries = [_]Entry{
            .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &classic_bridge },
            .{ .sbdf = sbdf(0, 1, 1, 1), .bytes = &ari_function9 },
        };
        var ari_entries = [_]Entry{
            .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &ari_bridge },
            .{ .sbdf = sbdf(0, 1, 1, 1), .bytes = &ari_function9 },
        };
        var classic_backend = TestConfigSpace.from(&classic_entries);
        var ari_backend = TestConfigSpace.from(&ari_entries);
        var segments = [_]Segment{segment(0, .of(0, 1))};

        const classic = try enumerate(testing.allocator, .{
            .config = classic_backend.config(),
            .segments = &segments,
        });
        defer classic.deinit(testing.allocator);

        const ari = try enumerate(testing.allocator, .{
            .config = ari_backend.config(),
            .segments = &segments,
        });
        defer ari.deinit(testing.allocator);

        try expectNodeSbdfs(classic, &.{sbdf(0, 0, 0, 0)});
        try expectNodeSbdfs(ari, &.{ sbdf(0, 0, 0, 0), sbdf(0, 1, 1, 1) });
        try testing.expectEqual(@as(?NodeId, NodeId.from(0)), ari.node(NodeId.from(1)).parent);
    }

    test "PCIe revision and forwarding control select the child scan mode" {
        const cases = [_]struct {
            version: u16,
            enabled: bool,
            expected_ari: bool,
        }{
            .{ .version = 0, .enabled = true, .expected_ari = false },
            .{ .version = 1, .enabled = true, .expected_ari = false },
            .{ .version = 2, .enabled = false, .expected_ari = false },
            .{ .version = 2, .enabled = true, .expected_ari = true },
            .{ .version = 3, .enabled = true, .expected_ari = true },
        };

        for (cases) |case| {
            var bridge = functionBytes(.{ .header = 1, .secondary = 1, .subordinate = 1, .ari = true });
            store16(&bridge, cap_base + pcie.capabilities, case.version);
            store16(&bridge, cap_base + pcie.device_control_2, if (case.enabled) pcie.ari_forwarding_enable else 0);
            var child = functionBytes(.{ .header = 0 });
            var entries = [_]Entry{
                .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge },
                .{ .sbdf = sbdf(0, 1, 1, 1), .bytes = &child },
            };
            var backend = TestConfigSpace.from(&entries);
            const segments = [_]Segment{segment(0, .of(0, 1))};
            const snapshot = try enumerate(testing.allocator, .{
                .config = backend.config(),
                .segments = &segments,
            });
            defer snapshot.deinit(testing.allocator);

            if (case.expected_ari) {
                try expectNodeSbdfs(snapshot, &.{ sbdf(0, 0, 0, 0), sbdf(0, 1, 1, 1) });
            } else {
                try expectNodeSbdfs(snapshot, &.{sbdf(0, 0, 0, 0)});
            }
            try testing.expectEqualSlices(usize, &.{ 1, 1, @intFromBool(case.version >= 2) }, &backend.pcie_reads);
        }
    }

    test "truncated PCIe control falls back without reading beyond the conventional window" {
        var bridge = functionBytes(.{ .header = 1, .secondary = 1, .subordinate = 1 });
        store16(&bridge, offset.status, status.cap_list);
        bridge[offset.cap_ptr] = 0xFC;
        bridge[0xFC] = pcie.id;
        store16(&bridge, 0xFE, 2);
        var child = functionBytes(.{ .header = 0 });
        var entries = [_]Entry{
            .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge },
            .{ .sbdf = sbdf(0, 1, 1, 1), .bytes = &child },
        };
        var backend = TestConfigSpace.from(&entries);
        backend.fail_on_read_offset = @as(usize, 0xFC) + pcie.device_control_2;
        const segments = [_]Segment{segment(0, .of(0, 1))};
        const snapshot = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer snapshot.deinit(testing.allocator);

        try expectNodeSbdfs(snapshot, &.{sbdf(0, 0, 0, 0)});
    }

    test "malformed capability list falls back to classic ARI mode" {
        var bridge = functionBytes(.{ .header = 0x01, .secondary = 1, .subordinate = 1 });
        store16(&bridge, offset.status, status.cap_list);
        bridge[offset.cap_ptr] = cap_base;
        bridge[cap_base] = pcie.id;
        bridge[cap_base + 1] = cap_base | 0b01;
        var ari_function9 = functionBytes(.{ .header = 0x00 });
        var entries = [_]Entry{
            .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge },
            .{ .sbdf = sbdf(0, 1, 1, 1), .bytes = &ari_function9 },
        };
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{segment(0, .of(0, 1))};

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try expectNodeSbdfs(view, &.{sbdf(0, 0, 0, 0)});
    }

    test "read failure after partial discovery releases owned storage" {
        var bridge = functionBytes(.{ .header = 0x01, .secondary = 1, .subordinate = 1, .ari = true });
        var entries = [_]Entry{.{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge }};
        const segments = [_]Segment{segment(0, .of(0, 1))};

        for ([_]usize{ cap_base + pcie.capabilities, cap_base + pcie.device_control_2 }) |position| {
            var backend = TestConfigSpace.from(&entries);
            backend.fail_on_read_offset = position;

            try testing.expectError(error.OutOfBounds, enumerate(testing.allocator, .{
                .config = backend.config(),
                .segments = &segments,
            }));
        }
    }

    test "valid bridge descent emits dense DFS preorder" {
        var bridge = functionBytes(.{ .header = 0x01, .secondary = 1, .subordinate = 1 });
        var child = functionBytes(.{ .header = 0x00 });
        var sibling = functionBytes(.{ .header = 0x00 });
        var entries = [_]Entry{
            .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge },
            .{ .sbdf = sbdf(0, 1, 0, 0), .bytes = &child },
            .{ .sbdf = sbdf(0, 0, 1, 0), .bytes = &sibling },
        };
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{segment(0, .of(0, 1))};

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try expectNodeSbdfs(view, &.{ sbdf(0, 0, 0, 0), sbdf(0, 1, 0, 0), sbdf(0, 0, 1, 0) });
        try testing.expectEqualSlices(NodeId, &.{ NodeId.from(0), NodeId.from(2) }, view.roots);
        try testing.expectEqual(@as(?NodeId, NodeId.from(0)), view.node(NodeId.from(1)).parent);
        try expectPreorder(view, &.{ NodeId.from(0), NodeId.from(1), NodeId.from(2) });
        view.assertValid();

        var subtree = view.preorderFrom(NodeId.from(0));
        try testing.expectEqual(NodeId.from(0), subtree.next().?.id);
        try testing.expectEqual(NodeId.from(1), subtree.next().?.id);
        try testing.expect(subtree.next() == null);
    }

    test "invalid secondary subordinate bridge numbers short-circuit descent" {
        var bridge = functionBytes(.{ .header = 0x01, .secondary = 2, .subordinate = 1 });
        var child = functionBytes(.{ .header = 0x00 });
        var entries = [_]Entry{
            .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge },
            .{ .sbdf = sbdf(0, 2, 0, 0), .bytes = &child },
        };
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{segment(0, .of(0, 2))};

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try expectNodeSbdfs(view, &.{sbdf(0, 0, 0, 0)});
    }

    test "type-2 CardBus header is skipped without surfacing BadHeaderType" {
        var cardbus = functionBytes(.{ .header = 0x02 });
        var entries = [_]Entry{.{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &cardbus }};
        var backend = TestConfigSpace.from(&entries);
        var segments = [_]Segment{segment(0, .of(0, 0))};

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 0), view.nodes().len);
        try testing.expectEqual(@as(usize, 0), view.roots.len);
    }

    test "allocation failures release partially constructed trees" {
        try testing.checkAllAllocationFailures(testing.allocator, enumerateManyRoots, .{});
    }

    test "fixed buffer allocator supports growing discovery storage" {
        var buffer: [64 * 1024]u8 = undefined;
        var allocator = FixedBufferAllocator.init(&buffer);

        try enumerateManyRoots(allocator.allocator());
    }

    test "fixed buffer exhaustion during discovery returns OutOfMemory" {
        var buffer: [16 * @sizeOf(Node)]u8 = undefined;
        var allocator = FixedBufferAllocator.init(&buffer);

        try testing.expectError(error.OutOfMemory, enumerateManyRoots(allocator.allocator()));
    }

    test "depth 31 is discoverable without probing a deeper bus" {
        var backend: LimitConfigSpace = .{ .chain_end = 31 };
        const segments = [_]Segment{segment(0, .of(0, 32))};
        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 32), view.nodes().len);
        try testing.expectEqual(@as(u8, 31), backend.max_bus);
        try testing.expectEqual(@as(?NodeId, NodeId.from(30)), view.node(NodeId.from(31)).parent);
        try testing.expect(view.node(NodeId.from(31)).function.sbdf.eql(sbdf(0, 31, 0, 0)));
        view.assertValid();
    }

    test "attempted depth 32 fails before probing and releases partial storage" {
        var backend: LimitConfigSpace = .{ .chain_end = 32 };
        const segments = [_]Segment{segment(0, .of(0, 32))};

        try testing.expectError(error.DepthExceeded, enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        }));
        try testing.expectEqual(@as(u8, 31), backend.max_bus);
        try testing.expectEqual(@as(usize, 32), backend.vendor_reads);
    }

    test "exactly 65535 nodes allow the final absent probe" {
        var backend: LimitConfigSpace = .{ .final_functions = 255 };
        var segments: [256]Segment = undefined;
        for (&segments, 0..) |*entry, index| {
            entry.* = segment(@intCast(index), .of(0, 0));
        }

        const view = try enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(testing.allocator);

        try testing.expectEqual(@as(usize, 65535), view.nodes().len);
        try testing.expectEqual(@as(usize, 65535), view.roots.len);
        try testing.expect(view.node(NodeId.from(65534)).function.sbdf.eql(sbdf(255, 0, 31, 6)));
        try testing.expectEqual(@as(usize, 65536), backend.vendor_reads);
        try testing.expectEqual(@as(usize, 0), backend.final_header_reads);
        view.assertValid();
    }

    test "node 65536 fails after presence and format and releases partial storage" {
        var backend: LimitConfigSpace = .{ .final_functions = 256 };
        var segments: [256]Segment = undefined;
        for (&segments, 0..) |*entry, index| {
            entry.* = segment(@intCast(index), .of(0, 0));
        }

        try testing.expectError(error.StorageExhausted, enumerate(testing.allocator, .{
            .config = backend.config(),
            .segments = &segments,
        }));
        try testing.expectEqual(@as(usize, 65536), backend.vendor_reads);
        try testing.expectEqual(@as(usize, 2), backend.final_header_reads);
    }

    fn enumerateManyRoots(allocator: Allocator) !void {
        var endpoint = functionBytes(.{});
        var entries: [32]Entry = undefined;
        for (&entries, 0..) |*entry, device| {
            entry.* = .{ .sbdf = sbdf(0, 0, @intCast(device), 0), .bytes = &endpoint };
        }

        var backend = TestConfigSpace.from(&entries);
        const segments = [_]Segment{segment(0, .of(0, 0))};

        const view = try enumerate(allocator, .{
            .config = backend.config(),
            .segments = &segments,
        });
        defer view.deinit(allocator);

        try testing.expectEqual(@as(usize, 32), view.nodes().len);
        try testing.expectEqual(@as(usize, 32), view.roots.len);

        var iterator = view.preorder();
        for (entries, 0..) |entry, index| {
            const item = iterator.next().?;
            try testing.expectEqual(NodeId.from(@intCast(index)), item.id);
            try testing.expect(item.node.function.sbdf.eql(entry.sbdf));
        }
        try testing.expect(iterator.next() == null);
    }

    fn functionBytes(fields: struct {
        vendor: u16 = 0x1234,
        device: u16 = 0x5678,
        header: u8 = 0x00,
        secondary: u8 = 0,
        subordinate: u8 = 0,
        ari: bool = false,
    }) [pcie_window_size]u8 {
        var bytes: [pcie_window_size]u8 = @splat(0);
        store16(&bytes, offset.vendor_id, fields.vendor);
        store16(&bytes, offset.device_id, fields.device);
        bytes[offset.type] = fields.header;
        bytes[offset.secondary_bus] = fields.secondary;
        bytes[offset.subordinate_bus] = fields.subordinate;

        if (fields.ari) {
            store16(&bytes, offset.status, status.cap_list);
            bytes[offset.cap_ptr] = cap_base;
            bytes[cap_base] = pcie.id;
            bytes[cap_base + 1] = 0;
            store16(&bytes, cap_base + pcie.capabilities, 2);
            store16(&bytes, cap_base + pcie.device_control_2, pcie.ari_forwarding_enable);
        }

        return bytes;
    }

    fn segment(segment_id: u16, buses: BusRange) Segment {
        return .{
            .segment = SegmentId.from(segment_id),
            .buses = buses,
        };
    }

    fn sbdf(segment_id: u16, bus: u8, device: u5, function: u3) Sbdf {
        return Sbdf.from(.from(segment_id), bus, device, function);
    }

    fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
        std.debug.assert(byte_offset + 2 <= bytes.len);
        std.mem.writeInt(u16, bytes[byte_offset..][0..2], value, .little);
    }

    fn expectNodeSbdfs(view: *const Tree, expected: []const Sbdf) !void {
        try testing.expectEqual(expected.len, view.nodes().len);

        for (expected, 0..) |expected_sbdf, index| {
            try testing.expect(view.nodes()[index].function.sbdf.eql(expected_sbdf));
        }
    }

    fn expectPreorder(view: *const Tree, expected: []const NodeId) !void {
        var iterator = view.preorder();
        for (expected) |index| {
            const item = iterator.next();
            try testing.expect(item != null);
            try testing.expectEqual(index, item.?.id);
        }

        try testing.expect(iterator.next() == null);
    }

    fn NoIo(comptime T: type) type {
        return struct {
            fn read(_: *anyopaque, _: Sbdf, _: usize) ConfigError!T {
                unreachable;
            }

            fn write(_: *anyopaque, _: Sbdf, _: usize, _: T) ConfigError!void {
                unreachable;
            }
        };
    }
};
