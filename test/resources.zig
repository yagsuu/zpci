const std = @import("std");
const stdx = @import("stdx");

const pci = @import("pci");
const support = @import("support.zig");

const BusRange = stdx.ranges.InclusiveRange(pci.core.bus.Index);
const Range = stdx.ranges.Range(u64);

const AssignmentNode = pci.resources.assignment.Node;
const Bar = pci.bar.Bar;
const Function = pci.config.Function;
const ResourceType = pci.resources.Type;
const NodeId = pci.topology.NodeId;
const Requirement = pci.resources.Requirement;
const Sbdf = pci.core.Sbdf;
const Segment = pci.config.Segment;
const SegmentId = pci.core.SegmentId;
const TestConfigSpace = pci.testing.config.TestConfigSpace;
const Type1 = pci.header.Type1;
const ConfigEntry = TestConfigSpace.Entry;

const testing = std.testing;

const pcie_window_size = support.pcie_window_size;

const offset = struct {
    const command: usize = 0x04;
    const bar0: usize = 0x10;
    const primary_bus: usize = 0x18;
    const secondary_bus: usize = 0x19;
    const subordinate_bus: usize = 0x1A;
};

const seedFunction = support.seedFunction;
const sbdf = support.sbdf;
const store16 = support.store16;
const store32 = support.store32;

const ColdConfig = struct {
    bridge: []u8,
    endpoint: []u8,
    probing_bar: bool = false,

    fn config(self: *ColdConfig) pci.config.ConfigSpace {
        return .from(self, &vtable);
    }

    fn bytes(self: *ColdConfig, address: Sbdf) ?[]u8 {
        if (address.segment != SegmentId.from(0) or address.bdf.device != 0 or address.bdf.function != 0) {
            return null;
        }

        if (address.bdf.bus == 0) {
            return self.bridge;
        }

        const secondary = self.bridge[offset.secondary_bus];
        const subordinate = self.bridge[offset.subordinate_bus];
        if (secondary != 0 and address.bdf.bus == secondary and secondary <= subordinate) {
            return self.endpoint;
        }

        return null;
    }

    const vtable: pci.config.ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn read8(context: *anyopaque, address: Sbdf, position: usize) pci.config.ConfigSpace.Error!u8 {
        const self: *ColdConfig = @ptrCast(@alignCast(context));
        const storage = self.bytes(address) orelse return 0xFF;
        return storage[position];
    }

    fn read16(context: *anyopaque, address: Sbdf, position: usize) pci.config.ConfigSpace.Error!u16 {
        const self: *ColdConfig = @ptrCast(@alignCast(context));
        const storage = self.bytes(address) orelse return 0xFFFF;
        return load16(storage, position);
    }

    fn read32(context: *anyopaque, address: Sbdf, position: usize) pci.config.ConfigSpace.Error!u32 {
        const self: *ColdConfig = @ptrCast(@alignCast(context));
        const storage = self.bytes(address) orelse return 0xFFFF_FFFF;

        if (storage.ptr == self.endpoint.ptr and position == offset.bar0 and self.probing_bar) {
            return 0xFFFF_F000;
        }

        return load32(storage, position);
    }

    fn write8(context: *anyopaque, address: Sbdf, position: usize, value: u8) pci.config.ConfigSpace.Error!void {
        const self: *ColdConfig = @ptrCast(@alignCast(context));
        const storage = self.bytes(address) orelse return error.OutOfBounds;
        storage[position] = value;
    }

    fn write16(context: *anyopaque, address: Sbdf, position: usize, value: u16) pci.config.ConfigSpace.Error!void {
        const self: *ColdConfig = @ptrCast(@alignCast(context));
        const storage = self.bytes(address) orelse return error.OutOfBounds;
        store16(storage, position, value);
    }

    fn write32(context: *anyopaque, address: Sbdf, position: usize, value: u32) pci.config.ConfigSpace.Error!void {
        const self: *ColdConfig = @ptrCast(@alignCast(context));
        const storage = self.bytes(address) orelse return error.OutOfBounds;

        if (storage.ptr == self.endpoint.ptr and position == offset.bar0) {
            self.probing_bar = value == 0xFFFF_FFFF;
            if (self.probing_bar) {
                return;
            }
        }

        store32(storage, position, value);
    }
};

test "enumerate assign program memory BAR" {
    var endpoint: [pcie_window_size]u8 = undefined;
    seedFunction(&endpoint, .{ .command = 0x0003 });
    store32(&endpoint, offset.bar0, 0x0000_0000);

    const endpoint_address = sbdf(.{ .bus = 0 });
    var entries = [_]ConfigEntry{.{ .sbdf = endpoint_address, .bytes = &endpoint }};
    var backend = TestConfigSpace.from(&entries);
    var segments = [_]Segment{segment(.of(0, 0))};

    const tree = try pci.topology.enumerate(testing.allocator, .{
        .config = backend.config(),
        .segments = &segments,
    });
    defer tree.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), tree.nodes().len);
    try testing.expect(tree.node(NodeId.from(0)).function.sbdf.eql(endpoint_address));

    const function = tree.node(NodeId.from(0)).function;
    const bar_entry: Bar = .{
        .index = 0,
        .type = .{ .memory = .{
            .base = 0,
            .size = 0x1000,
            .width = .bits_32,
            .prefetchable = false,
        } },
    };
    const requirements = try Requirement.fromBars(testing.allocator, function, &.{bar_entry});
    defer testing.allocator.free(requirements);

    var assignment_nodes = [_]AssignmentNode{.{
        .parent = null,
        .type = .endpoint,
        .requirements = requirements,
    }};
    const assignments = try pci.resources.assign(testing.allocator, .{
        .nodes = &assignment_nodes,
        .roots = &.{0},
        .apertures = .{
            .mmio32 = .{
                .type = .mmio32,
                .bounds = try Range.fromStartLen(0x8000_0000, 0x1000),
            },
        },
    });
    defer testing.allocator.free(assignments);

    try testing.expectEqual(@as(usize, 1), assignments.len);
    try testing.expectEqual(ResourceType.mmio32, assignments[0].pool);
    try testing.expectEqual(@as(u64, 0x8000_0000), assignments[0].base);

    try pci.resources.commit(assignments);

    try testing.expectEqual(@as(u32, 0x8000_0000), load32(&endpoint, offset.bar0));
    try testing.expectEqual(@as(u16, 0x0003), load16(&endpoint, offset.command));
}

test "cold configuration sizes and programs a downstream memory BAR" {
    var bridge: [pcie_window_size]u8 = undefined;
    var endpoint: [pcie_window_size]u8 = undefined;
    seedFunction(&bridge, .{ .header = 0x01 });
    seedFunction(&endpoint, .{ .header = 0x00 });

    const bridge_address = sbdf(.{ .bus = 0 });
    const endpoint_address = sbdf(.{ .bus = 1 });
    var backend = ColdConfig{ .bridge = &bridge, .endpoint = &endpoint };
    var segments = [_]Segment{segment(.of(0, 1))};

    const before = try pci.topology.enumerate(testing.allocator, .{
        .config = backend.config(),
        .segments = &segments,
    });
    defer before.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), before.nodes().len);
    try testing.expect(before.node(NodeId.from(0)).function.sbdf.eql(bridge_address));

    const after = try pci.topology.configure(testing.allocator, .{
        .config = backend.config(),
        .roots = &.{.{ .segment = .from(0), .buses = .of(0, 1) }},
    });
    defer after.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0), bridge[offset.primary_bus]);
    try testing.expectEqual(@as(u8, 1), bridge[offset.secondary_bus]);
    try testing.expectEqual(@as(u8, 1), bridge[offset.subordinate_bus]);

    try testing.expectEqual(@as(usize, 2), after.nodes().len);
    try testing.expect(after.node(NodeId.from(0)).function.sbdf.eql(bridge_address));
    try testing.expect(after.node(NodeId.from(1)).function.sbdf.eql(endpoint_address));
    try testing.expectEqual(@as(?NodeId, NodeId.from(0)), after.node(NodeId.from(1)).parent);

    const live_bridge = Type1.from(after.node(NodeId.from(0)).function);
    const buses = try live_bridge.busRange();
    try testing.expect(buses.forwards(1));

    const endpoint_function = after.node(NodeId.from(1)).function;
    const bars = (try pci.bar.Bars.tryFrom(endpoint_function)).?;
    const measured = try bars.probe(0);
    const requirement = (try Requirement.fromBar(endpoint_function, measured)).?;
    const bridge_requirements = try pci.resources.bridge.aggregate(
        testing.allocator,
        live_bridge.function,
        &.{requirement},
    );
    const nodes = [_]AssignmentNode{
        .{ .parent = null, .type = .bridge, .requirements = bridge_requirements.slice() },
        .{ .parent = 0, .type = .endpoint, .requirements = &.{requirement} },
    };
    const assignments = try pci.resources.assign(testing.allocator, .{
        .nodes = &nodes,
        .roots = &.{0},
        .apertures = .{
            .mmio32 = .{
                .type = .mmio32,
                .bounds = try Range.fromStartLen(0x8000_0000, 0x10_0000),
            },
        },
    });
    defer testing.allocator.free(assignments);

    try pci.resources.commit(assignments);

    const windows = try live_bridge.windows();
    const endpoint_base = load32(&endpoint, offset.bar0) & 0xFFFF_FFF0;
    try testing.expectEqual(@as(u32, 0x8000_0000), endpoint_base);
    try testing.expectEqual(@as(u64, 0x8000_0000), windows.mem.range.?.start);
    try testing.expectEqual(@as(u64, 0x800F_FFFF), windows.mem.range.?.end);
    try testing.expect(windows.mem.contains(endpoint_base, requirement.size));
    try testing.expect(!windows.mem.contains(0x8010_0000, 1));

    const path = try after.pathTo(testing.allocator, NodeId.from(1));
    defer testing.allocator.free(path);
    try testing.expectEqualSlices(NodeId, &.{ NodeId.from(0), NodeId.from(1) }, path);
}

fn segment(buses: BusRange) Segment {
    return .{
        .segment = SegmentId.from(0),
        .buses = buses,
    };
}

fn load16(bytes: []const u8, byte_offset: usize) u16 {
    return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
}

fn load32(bytes: []const u8, byte_offset: usize) u32 {
    return std.mem.readInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], .little);
}
