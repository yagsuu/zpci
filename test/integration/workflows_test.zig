//! Public API workflows.

const std = @import("std");

const stdx = @import("stdx");

const pci = @import("pci");

const AssignmentNode = pci.resources.assignment.Node;
const Bar = pci.bar.Bar;
const BusBridge = pci.resources.bus.Bridge;
const StandardEntry = pci.capabilities.standard.Entry;
const StandardId = pci.core.capabilities.standard.Id;
const ExtendedEntry = pci.capabilities.extended.Entry;
const Function = pci.config.Function;
const ResourceType = pci.resources.Type;
const MsiVectorCount = pci.core.capabilities.msi.VectorCount;
const NodeId = pci.topology.NodeId;
const Requirement = pci.resources.Requirement;
const Sbdf = pci.core.Sbdf;
const Segment = pci.config.Segment;
const SegmentId = pci.core.SegmentId;
const TableEntry = pci.core.capabilities.msix.TableEntry;
const TestBarMemory = pci.testing.memory.TestBarMemory;
const TestConfigSpace = pci.testing.config.TestConfigSpace;
const Type1 = pci.header.Type1;
const BusRange = stdx.ranges.InclusiveRange(pci.core.bus.Index);
const Range = stdx.ranges.Range(u64);
const ConfigEntry = TestConfigSpace.Entry;
const StandardIterator = pci.capabilities.standard.Iterator;
const ExtendedIterator = pci.capabilities.extended.Iterator;
const MsiCapability = pci.interrupts.msi.Capability;
const MsixCapability = pci.interrupts.msix.Capability;
const MsixTable = pci.interrupts.msix.Table;
const MsixPba = pci.interrupts.msix.Pba;
const MsiControl = pci.core.capabilities.msi.Control;
const MsixControl = pci.core.capabilities.msix.Control;

const msi = pci.core.capabilities.msi;
const msix = pci.core.capabilities.msix;

const testing = std.testing;

const pcie_window_size = pci.core.config.extended_size;

const offset = struct {
    const vendor_id: usize = 0x00;
    const device_id: usize = 0x02;
    const command: usize = 0x04;
    const status: usize = 0x06;
    const @"type": usize = 0x0E;
    const bar0: usize = 0x10;
    const primary_bus: usize = 0x18;
    const secondary_bus: usize = 0x19;
    const subordinate_bus: usize = 0x1A;
    const cap_ptr: usize = 0x34;
    const pcie_capability: u8 = 0x40;
    const msi_capability: u8 = 0x60;
    const msix_capability: u8 = 0x70;
    const msi_chain_capability: u8 = 0x80;
};

const status = struct {
    const cap_list: u16 = 1 << 4;
};

test "integration: capability traversal walks seeded config bytes" {
    var bytes: [pcie_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .status = status.cap_list, .cap_head = offset.pcie_capability });
    seedCapability(&bytes, .{
        .base = offset.pcie_capability,
        .id = @intFromEnum(StandardId.pcie),
        .next = offset.msi_chain_capability,
    });
    seedCapability(&bytes, .{
        .base = offset.msi_chain_capability,
        .id = @intFromEnum(StandardId.msi),
        .next = 0,
    });
    storeExtHeader(&bytes, .{ .byte_offset = 0x100, .id = 0x0001, .version = 1, .next = 0x120 });
    storeExtHeader(&bytes, .{ .byte_offset = 0x120, .id = 0x0002, .version = 2, .next = 0 });

    const address = sbdf(.{ .bus = 0 });
    var backend = TestConfigSpace.fromSingle(address, &bytes);
    const function = try Function.tryFrom(backend.config(), address);

    var standard = try StandardIterator.tryFrom(function);
    const first = (try standard.next()).?;
    const second = (try standard.next()).?;

    try testing.expectEqual(@intFromEnum(StandardId.pcie), @intFromEnum(first.id));
    try testing.expectEqual(offset.pcie_capability, first.offset);
    try testing.expectEqual(@intFromEnum(StandardId.msi), @intFromEnum(second.id));
    try testing.expectEqual(offset.msi_chain_capability, second.offset);
    try testing.expectEqual(@as(?StandardEntry, null), try standard.next());

    var extended = try ExtendedIterator.tryFrom(function);
    const ext_first = (try extended.next()).?;
    const ext_second = (try extended.next()).?;

    try testing.expectEqual(@as(u16, 0x0001), @intFromEnum(ext_first.id));
    try testing.expectEqual(@as(u4, 1), ext_first.version);
    try testing.expectEqual(@as(u16, 0x100), ext_first.offset);
    try testing.expectEqual(@as(u16, 0x0002), @intFromEnum(ext_second.id));
    try testing.expectEqual(@as(u4, 2), ext_second.version);
    try testing.expectEqual(@as(u16, 0x120), ext_second.offset);
    try testing.expectEqual(@as(?ExtendedEntry, null), try extended.next());
}

test "integration: enumerate assign program memory BAR" {
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

test "integration: bridge bus and window programming preserves the discovered subtree" {
    var bridge: [pcie_window_size]u8 = undefined;
    var endpoint: [pcie_window_size]u8 = undefined;
    seedFunction(&bridge, .{ .header = 0x01 });
    seedFunction(&endpoint, .{ .header = 0x00 });

    const bridge_address = sbdf(.{ .bus = 0 });
    const endpoint_address = sbdf(.{ .bus = 1 });
    var entries = [_]ConfigEntry{
        .{ .sbdf = bridge_address, .bytes = &bridge },
        .{ .sbdf = endpoint_address, .bytes = &endpoint },
    };
    var backend = TestConfigSpace.from(&entries);
    var segments = [_]Segment{segment(.of(0, 1))};

    const before = try pci.topology.enumerate(testing.allocator, .{
        .config = backend.config(),
        .segments = &segments,
    });
    defer before.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), before.nodes().len);
    try testing.expect(before.node(NodeId.from(0)).function.sbdf.eql(bridge_address));

    const bridges = [_]BusBridge{.{
        .parent = null,
        .function = before.node(NodeId.from(0)).function,
    }};
    try pci.resources.bus.commit(.{
        .bridges = &bridges,
        .roots = &.{0},
        .root_primary_bus = 0,
        .bus_end = 1,
    });

    try testing.expectEqual(@as(u8, 0), bridge[offset.primary_bus]);
    try testing.expectEqual(@as(u8, 1), bridge[offset.secondary_bus]);
    try testing.expectEqual(@as(u8, 1), bridge[offset.subordinate_bus]);

    const after = try pci.topology.enumerate(testing.allocator, .{
        .config = backend.config(),
        .segments = &segments,
    });
    defer after.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), after.nodes().len);
    try testing.expect(after.node(NodeId.from(0)).function.sbdf.eql(bridge_address));
    try testing.expect(after.node(NodeId.from(1)).function.sbdf.eql(endpoint_address));
    try testing.expectEqual(@as(?NodeId, NodeId.from(0)), after.node(NodeId.from(1)).parent);

    const live_bridge = Type1.from(after.node(NodeId.from(0)).function);
    const buses = try live_bridge.busRange();
    try testing.expect(buses.forwards(1));

    const endpoint_function = after.node(NodeId.from(1)).function;
    const requirement = (try Requirement.fromBar(endpoint_function, .{
        .index = 0,
        .type = .{ .memory = .{
            .base = 0,
            .size = 0x1000,
            .width = .bits_32,
            .prefetchable = false,
        } },
    })).?;
    const bridge_requirements = try pci.resources.bridge.aggregate(
        testing.allocator,
        live_bridge.function,
        &.{requirement},
    );
    const nodes = [_]AssignmentNode{
        .{ .parent = null, .type = .bridge, .requirements = bridge_requirements.asSlice() },
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

test "integration: MSI routing programs discovered capability" {
    var bytes: [pcie_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .status = status.cap_list, .cap_head = offset.msi_capability });
    seedCapability(&bytes, .{
        .base = offset.msi_capability,
        .id = @intFromEnum(msi.id),
        .next = 0,
    });
    store16(&bytes, offset.msi_capability + msi.addr32.offsets.control, msiControlRaw(.{
        .multi_msg_capable = @intFromEnum(MsiVectorCount.two),
    }));

    const address = sbdf(.{ .bus = 0 });
    var backend = TestConfigSpace.fromSingle(address, &bytes);
    const function = try Function.tryFrom(backend.config(), address);
    const capability = (try MsiCapability.find(function)).?;

    try capability.program(.{
        .address = 0xFEE0_0000,
        .data = 0x0040,
        .num_vectors = .two,
    });

    try testing.expectEqual(@as(u64, 0xFEE0_0000), try capability.address());
    try testing.expectEqual(@as(u16, 0x0040), try capability.data());
    const control = try capability.control();
    try testing.expectEqual(MsiVectorCount.two, control.multi_msg_enable);
    try testing.expect(control.enable);
}

test "integration: MSI-X routing programs caller BAR memory" {
    var bytes: [pcie_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .status = status.cap_list, .cap_head = offset.msix_capability });
    seedCapability(&bytes, .{
        .base = offset.msix_capability,
        .id = @intFromEnum(msix.id),
        .next = 0,
    });
    seedMsixPayload(&bytes, offset.msix_capability, .{
        .table_size_minus_one = 1,
        .table_bir = 0,
        .table_offset = 0,
        .pba_bir = 1,
        .pba_offset = 0,
    });

    const address = sbdf(.{ .bus = 0 });
    var config_backend = TestConfigSpace.fromSingle(address, &bytes);
    const function = try Function.tryFrom(config_backend.config(), address);
    const capability = (try MsixCapability.find(function)).?;

    const control = try capability.control();
    const num_vectors = @as(u16, control.table_size_minus_one) + 1;
    const table_location = try capability.table();
    const pba_location = try capability.pba();

    try testing.expectEqual(@as(u16, 2), num_vectors);
    try testing.expectEqual(@as(u3, 0), table_location.bir);
    try testing.expectEqual(@as(u3, 1), pba_location.bir);

    var table_bytes: [2 * @sizeOf(TableEntry)]u8 = @splat(0);
    var table_backend: TestBarMemory = .{ .bytes = &table_bytes };
    var pba_bytes: [4]u8 = @splat(0);
    store32(&pba_bytes, 0, @as(u32, 1) << 1);
    var pba_backend: TestBarMemory = .{ .bytes = &pba_bytes };

    const table = MsixTable.from(table_backend.accessor(), num_vectors);
    const pba = MsixPba.from(pba_backend.accessor(), num_vectors);

    try table.program(1, .{
        .address = 0xFEE0_0000,
        .data = 0x0045,
        .masked = false,
    });

    const entry = try table.read(1);
    try testing.expectEqual(@as(u64, 0xFEE0_0000), entry.address);
    try testing.expectEqual(@as(u32, 0x0045), entry.data);
    try testing.expect(!entry.masked);
    try testing.expect(try pba.pending(1));

    try capability.enable();

    try testing.expect((try capability.control()).enable);
}

test "integration: command field masks preserve unrelated live control bits" {
    const Command = pci.core.header.Command;
    var bytes: [pcie_window_size]u8 = @splat(0);
    const address = Sbdf.from(.from(0), 0, 1, 0);
    var backend = TestConfigSpace.fromSingle(address, &bytes);
    const function = Function.from(backend.config(), address);
    store16(&bytes, 0x04, 0x0547);

    const selected = Command.mask(.{ .mem_enable, .bus_master });
    const desired = Command.encode(.{ .mem_enable = false, .bus_master = true });
    const observed = Command.raw(try function.command());

    try function.setCommand(Command.from((observed & ~selected) | (desired & selected)));

    try testing.expectEqual(@as(u16, 0x0545), try function.config.read(address, Function.offsets.command));
}

fn seedFunction(bytes: *[pcie_window_size]u8, fields: struct {
    vendor: u16 = 0x1234,
    device: u16 = 0x5678,
    command: u16 = 0,
    status: u16 = 0,
    header: u8 = 0,
    cap_head: u8 = 0,
}) void {
    bytes.* = @splat(0);
    store16(bytes, offset.vendor_id, fields.vendor);
    store16(bytes, offset.device_id, fields.device);
    store16(bytes, offset.command, fields.command);
    store16(bytes, offset.status, fields.status);
    bytes[offset.type] = fields.header;
    bytes[offset.cap_ptr] = fields.cap_head;
}

fn segment(buses: BusRange) Segment {
    return .{
        .segment = SegmentId.from(0),
        .buses = buses,
    };
}

fn sbdf(fields: struct {
    bus: u8,
    device: u5 = 0,
    function: u3 = 0,
}) Sbdf {
    return Sbdf.from(.from(0), fields.bus, fields.device, fields.function);
}

fn seedCapability(bytes: []u8, fields: struct {
    base: u8,
    id: u8,
    next: u8,
}) void {
    store16(bytes, fields.base, pci.core.capabilities.standard.Header.encode(.{
        .id = @as(StandardId, @enumFromInt(fields.id)),
        .next = fields.next,
    }));
}

fn storeExtHeader(bytes: []u8, fields: struct {
    byte_offset: usize,
    id: u16,
    version: u4,
    next: u16,
}) void {
    std.debug.assert(fields.next & 0xF000 == 0);
    const raw = pci.core.capabilities.extended.Header.encode(.{
        .id = @as(pci.core.capabilities.extended.Id, @enumFromInt(fields.id)),
        .version = fields.version,
        .next = @as(u12, @intCast(fields.next)),
    });
    store32(bytes, fields.byte_offset, raw);
}

fn seedMsixPayload(bytes: []u8, base: u8, fields: struct {
    table_size_minus_one: u11 = 0,
    table_bir: u3 = 0,
    table_offset: u32 = 0,
    pba_bir: u3 = 0,
    pba_offset: u32 = 0,
}) void {
    store16(bytes, @as(usize, base) + msix.offsets.control, msixControlRaw(.{
        .table_size_minus_one = fields.table_size_minus_one,
    }));
    store32(bytes, @as(usize, base) + msix.offsets.table, locationRaw(
        fields.table_bir,
        fields.table_offset,
    ));
    store32(bytes, @as(usize, base) + msix.offsets.pba, locationRaw(
        fields.pba_bir,
        fields.pba_offset,
    ));
}

fn msiControlRaw(fields: struct {
    enable: bool = false,
    multi_msg_capable: u3 = 0,
    multi_msg_enable: u3 = 0,
    addr64_capable: bool = false,
    pvm_capable: bool = false,
    ext_data_capable: bool = false,
    ext_data_enable: bool = false,
    reserved11: u5 = 0,
}) u16 {
    return MsiControl.raw(.{
        .enable = fields.enable,
        .multi_msg_capable = MsiVectorCount.from(fields.multi_msg_capable),
        .multi_msg_enable = MsiVectorCount.from(fields.multi_msg_enable),
        .addr64_capable = fields.addr64_capable,
        .pvm_capable = fields.pvm_capable,
        .ext_data_capable = fields.ext_data_capable,
        .ext_data_enable = fields.ext_data_enable,
    }) | (@as(u16, fields.reserved11) << 11);
}

fn msixControlRaw(fields: struct {
    table_size_minus_one: u11 = 0,
    reserved11: u3 = 0,
    function_mask: bool = false,
    enable: bool = false,
}) u16 {
    return MsixControl.raw(.{
        .table_size_minus_one = fields.table_size_minus_one,
        .function_mask = fields.function_mask,
        .enable = fields.enable,
    }) | (@as(u16, fields.reserved11) << 11);
}

fn locationRaw(bir: u3, byte_offset: u32) u32 {
    std.debug.assert(byte_offset & 0b111 == 0);
    return msix.Location.encode(.{
        .bir = bir,
        .offset_shifted = @as(u29, @intCast(byte_offset >> 3)),
    });
}

fn load16(bytes: []const u8, byte_offset: usize) u16 {
    return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
}

fn load32(bytes: []const u8, byte_offset: usize) u32 {
    return std.mem.readInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], .little);
}

fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
}

fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], value, .little);
}
