//! Public-facade workflow tests. Spec: docs/guidelines/testing.md.

const std = @import("std");

const stdx = @import("stdx");

const zpci = @import("zpci");

const Aperture = zpci.resources.model.Aperture;
const Assignment = zpci.resources.model.Assignment;
const AssignmentNode = zpci.resources.assignment.Node;
const BarEntry = zpci.bar.Entry;
const BusBridge = zpci.resources.bus.Bridge;
const Capability = zpci.capabilities.list.Capability;
const CapabilityId = zpci.capabilities.list.Id;
const ExtCapability = zpci.capabilities.extended.ExtCapability;
const Function = zpci.config.Function;
const Kind = zpci.resources.model.Kind;
const MsiVectorCount = zpci.interrupts.msi.VectorCount;
const Node = zpci.topology.enumerate.Node;
const NodeIndex = zpci.topology.tree.NodeIndex;
const Requirement = zpci.resources.model.Requirement;
const Sbdf = zpci.core.Sbdf;
const Segment = zpci.config.Segment;
const SegmentId = zpci.core.SegmentId;
const TestBarMemory = zpci.testing.memory.TestBarMemory;
const TestConfigSpace = zpci.testing.config.TestConfigSpace;
const VirtAddr = stdx.addr.VirtAddr;

const function_window_size: usize = 0x1000;

const offset = struct {
    const vendor_id: usize = 0x00;
    const device_id: usize = 0x02;
    const command: usize = 0x04;
    const status: usize = 0x06;
    const header_type: usize = 0x0E;
    const bar0: usize = 0x10;
    const primary_bus: usize = 0x18;
    const secondary_bus: usize = 0x19;
    const subordinate_bus: usize = 0x1A;
    const capabilities_pointer: usize = 0x34;
    const pcie_capability: u8 = 0x40;
    const msi_capability: u8 = 0x60;
    const msix_capability: u8 = 0x70;
    const msi_chain_capability: u8 = 0x80;
};

const status = struct {
    const capabilities_list: u16 = 1 << 4;
};

test "integration: public facade exposes workflow namespaces" {
    // Compile representative namespace references so facade drift fails at the package boundary.
    _ = zpci.core.Bdf;
    _ = zpci.config.Function;
    _ = zpci.header.common;
    _ = zpci.bar.View;
    _ = zpci.capabilities.list.Iterator;
    _ = zpci.capabilities.extended.Iterator;
    _ = zpci.resources.assignment;
    _ = zpci.resources.programming;
    _ = zpci.resources.bus;
    _ = zpci.interrupts.msi;
    _ = zpci.interrupts.msix;
    _ = zpci.topology.enumerate;
    _ = zpci.testing.config.TestConfigSpace;
    _ = zpci.testing.memory.TestBarMemory;
}

test "integration: capability traversal walks seeded config bytes" {
    // Walk standard and extended capability chains from one byte-backed function.
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .status = status.capabilities_list, .cap_head = offset.pcie_capability });
    seedCapability(&bytes, .{
        .base = offset.pcie_capability,
        .id = @intFromEnum(CapabilityId.pci_express),
        .next = offset.msi_chain_capability,
    });
    seedCapability(&bytes, .{
        .base = offset.msi_chain_capability,
        .id = @intFromEnum(CapabilityId.msi),
        .next = 0,
    });
    storeExtHeader(&bytes, .{ .byte_offset = 0x100, .id = 0x0001, .version = 1, .next = 0x120 });
    storeExtHeader(&bytes, .{ .byte_offset = 0x120, .id = 0x0002, .version = 2, .next = 0 });

    const address = sbdf(.{ .bus = 0 });
    var backend = TestConfigSpace.initSingle(address, &bytes);
    const function = try Function.validate(backend.configSpace(), address);

    var standard = try zpci.capabilities.list.Iterator.validate(function);
    const first = (try standard.next()).?;
    const second = (try standard.next()).?;
    try std.testing.expectEqual(@intFromEnum(CapabilityId.pci_express), first.id);
    try std.testing.expectEqual(offset.pcie_capability, first.offset);
    try std.testing.expectEqual(@intFromEnum(CapabilityId.msi), second.id);
    try std.testing.expectEqual(offset.msi_chain_capability, second.offset);
    try std.testing.expectEqual(@as(?Capability, null), try standard.next());

    var extended = try zpci.capabilities.extended.Iterator.validate(function);
    const ext_first = (try extended.next()).?;
    const ext_second = (try extended.next()).?;
    try std.testing.expectEqual(@as(u16, 0x0001), ext_first.id);
    try std.testing.expectEqual(@as(u4, 1), ext_first.version);
    try std.testing.expectEqual(@as(u16, 0x100), ext_first.offset);
    try std.testing.expectEqual(@as(u16, 0x0002), ext_second.id);
    try std.testing.expectEqual(@as(u4, 2), ext_second.version);
    try std.testing.expectEqual(@as(u16, 0x120), ext_second.offset);
    try std.testing.expectEqual(@as(?ExtCapability, null), try extended.next());
}

test "integration: enumerate assign program memory BAR" {
    // Enumerate a function, lower one BAR requirement, then assert commit writes the assigned base.
    var endpoint: [function_window_size]u8 = undefined;
    seedFunction(&endpoint, .{ .command = 0x0003 });
    store32(&endpoint, offset.bar0, 0x0000_0000);

    const endpoint_address = sbdf(.{ .bus = 0 });
    var entries = [_]TestConfigSpace.Entry{.{ .sbdf = endpoint_address, .bytes = &endpoint }};
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(.{ .bus_start = 0, .bus_end = 0 })};
    var topology_nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const tree = try zpci.topology.enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &topology_nodes,
        .roots = &roots,
    });
    try std.testing.expectEqual(@as(usize, 1), tree.nodes.len);
    try std.testing.expect(tree.node(0).sbdf.eql(endpoint_address));

    const function = tree.node(0).function;
    const bar_entry: BarEntry = .{
        .index = 0,
        .slot_count = 1,
        .kind = .{ .memory = .{
            .base = 0,
            .size = 0x1000,
            .width = .bits_32,
            .prefetchable = false,
        } },
    };
    var requirements_buf: [zpci.bar.max_entries]Requirement = undefined;
    const requirements = try Requirement.fromBarSlice(function, &.{bar_entry}, &requirements_buf);
    var assignment_nodes = [_]AssignmentNode{.{
        .parent = null,
        .kind = .endpoint,
        .requirements = requirements,
    }};
    var assignment_scratch: [4]Assignment = undefined;
    const plan = try zpci.resources.assignment.intoScratch(.{
        .nodes = &assignment_nodes,
        .roots = &.{0},
        .root_windows = .{
            .mmio32 = Aperture.range(.mmio32, 0x8000_0000, 0x1000),
        },
    }, &assignment_scratch);

    try std.testing.expectEqual(@as(usize, 1), plan.assignments.len);
    try std.testing.expectEqual(Kind.mmio32, plan.assignments[0].pool);
    try std.testing.expectEqual(@as(u64, 0x8000_0000), plan.assignments[0].base);

    try zpci.resources.programming.commit(plan);

    try std.testing.expectEqual(@as(u32, 0x8000_0000), load32(&endpoint, offset.bar0));
    try std.testing.expectEqual(@as(u16, 0x0003), load16(&endpoint, offset.command));
}

test "integration: bus commit enables bridge subtree enumeration" {
    // Program bridge bus numbers and re-enumerate to prove the child bus becomes reachable.
    var bridge: [function_window_size]u8 = undefined;
    var endpoint: [function_window_size]u8 = undefined;
    seedFunction(&bridge, .{ .header = 0x01 });
    seedFunction(&endpoint, .{ .header = 0x00 });

    const bridge_address = sbdf(.{ .bus = 0 });
    const endpoint_address = sbdf(.{ .bus = 1 });
    var entries = [_]TestConfigSpace.Entry{
        .{ .sbdf = bridge_address, .bytes = &bridge },
        .{ .sbdf = endpoint_address, .bytes = &endpoint },
    };
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(.{ .bus_start = 0, .bus_end = 1 })};
    var before_nodes: [4]Node = undefined;
    var before_roots: [4]NodeIndex = undefined;

    const before = try zpci.topology.enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &before_nodes,
        .roots = &before_roots,
    });
    try std.testing.expectEqual(@as(usize, 1), before.nodes.len);
    try std.testing.expect(before.node(0).sbdf.eql(bridge_address));

    const bridges = [_]BusBridge{.{
        .parent = null,
        .function = before.node(0).function,
    }};
    try zpci.resources.bus.commit(.{
        .bridges = &bridges,
        .roots = &.{0},
        .root_primary_bus = 0,
        .bus_end = 1,
    });

    try std.testing.expectEqual(@as(u8, 0), bridge[offset.primary_bus]);
    try std.testing.expectEqual(@as(u8, 1), bridge[offset.secondary_bus]);
    try std.testing.expectEqual(@as(u8, 1), bridge[offset.subordinate_bus]);

    var after_nodes: [4]Node = undefined;
    var after_roots: [4]NodeIndex = undefined;
    const after = try zpci.topology.enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &after_nodes,
        .roots = &after_roots,
    });

    try std.testing.expectEqual(@as(usize, 2), after.nodes.len);
    try std.testing.expect(after.node(0).sbdf.eql(bridge_address));
    try std.testing.expect(after.node(1).sbdf.eql(endpoint_address));
    try std.testing.expectEqual(@as(?NodeIndex, 0), after.node(1).parent);
}

test "integration: MSI routing programs discovered capability" {
    // Discover an MSI capability and verify caller routing is reflected in config-space state.
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .status = status.capabilities_list, .cap_head = offset.msi_capability });
    seedCapability(&bytes, .{ .base = offset.msi_capability, .id = zpci.interrupts.msi.cap_id, .next = 0 });
    store16(&bytes, offset.msi_capability + zpci.interrupts.msi.register.message_control, msiControlRaw(.{
        .multiple_message_capable = @intFromEnum(MsiVectorCount.two),
    }));

    const address = sbdf(.{ .bus = 0 });
    var backend = TestConfigSpace.initSingle(address, &bytes);
    const function = try Function.validate(backend.configSpace(), address);
    const view = (try zpci.interrupts.msi.View.find(function)).?;

    try view.program(.{
        .address = 0xFEE0_0000,
        .data = 0x0040,
        .vector_count = .two,
    });

    try std.testing.expectEqual(@as(u64, 0xFEE0_0000), try view.messageAddress());
    try std.testing.expectEqual(@as(u16, 0x0040), try view.messageData());
    try std.testing.expectEqual(MsiVectorCount.two, try view.multipleMessageEnable());
    try std.testing.expect((try view.messageControl()).msi_enable);
}

test "integration: MSI-X routing programs caller BAR memory" {
    // Discover MSI-X metadata, program caller-owned table memory, and read pending state from PBA memory.
    var bytes: [function_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .status = status.capabilities_list, .cap_head = offset.msix_capability });
    seedCapability(&bytes, .{ .base = offset.msix_capability, .id = zpci.interrupts.msix.cap_id, .next = 0 });
    seedMsixPayload(&bytes, offset.msix_capability, .{
        .table_size_minus_one = 1,
        .table_bir = 0,
        .table_offset = 0,
        .pba_bir = 1,
        .pba_offset = 0,
    });

    const address = sbdf(.{ .bus = 0 });
    var config_backend = TestConfigSpace.initSingle(address, &bytes);
    const function = try Function.validate(config_backend.configSpace(), address);
    const view = (try zpci.interrupts.msix.View.find(function)).?;
    try std.testing.expectEqual(@as(u16, 2), view.tableSize());
    try std.testing.expectEqual(@as(u3, 0), view.tableLocation().bir);
    try std.testing.expectEqual(@as(u3, 1), view.pbaLocation().bir);

    var table_bytes: [2 * zpci.interrupts.msix.table_entry_size]u8 = @splat(0);
    var table_backend: TestBarMemory = .{ .bytes = &table_bytes };
    var pba_bytes: [4]u8 = @splat(0);
    store32(&pba_bytes, 0, @as(u32, 1) << 1);
    var pba_backend: TestBarMemory = .{ .bytes = &pba_bytes };

    try view.programEntry(table_backend.accessor(), 1, .{
        .address = 0xFEE0_0000,
        .data = 0x0045,
        .masked = false,
    });

    const entry = try view.readEntry(table_backend.accessor(), 1);
    try std.testing.expectEqual(@as(u64, 0xFEE0_0000), entry.address);
    try std.testing.expectEqual(@as(u32, 0x0045), entry.data);
    try std.testing.expect(!entry.masked);
    try std.testing.expect(try view.vectorPending(pba_backend.accessor(), 1));

    try view.enable();
    try std.testing.expect(try view.enabled());
}

fn seedFunction(bytes: *[function_window_size]u8, fields: struct {
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
    bytes[offset.header_type] = fields.header;
    bytes[offset.capabilities_pointer] = fields.cap_head;
}

fn segment(fields: struct {
    bus_start: u8,
    bus_end: u8,
}) Segment {
    return .{
        .segment = SegmentId.from(0),
        .base = VirtAddr.fromInt(0x1000),
        .bus_start = fields.bus_start,
        .bus_end = fields.bus_end,
    };
}

fn sbdf(fields: struct {
    bus: u8,
    device: u8 = 0,
    function: u8 = 0,
}) Sbdf {
    return Sbdf.from(0, fields.bus, fields.device, fields.function) catch unreachable;
}

fn seedCapability(bytes: []u8, fields: struct {
    base: u8,
    id: u8,
    next: u8,
}) void {
    bytes[fields.base] = fields.id;
    bytes[@as(usize, fields.base) + 1] = fields.next;
}

fn storeExtHeader(bytes: []u8, fields: struct {
    byte_offset: usize,
    id: u16,
    version: u4,
    next: u16,
}) void {
    std.debug.assert(fields.next & 0xF000 == 0);
    const raw = @as(u32, fields.id) |
        (@as(u32, fields.version) << 16) |
        (@as(u32, fields.next) << 20);
    store32(bytes, fields.byte_offset, raw);
}

fn seedMsixPayload(bytes: []u8, base: u8, fields: struct {
    table_size_minus_one: u11 = 0,
    table_bir: u3 = 0,
    table_offset: u32 = 0,
    pba_bir: u3 = 0,
    pba_offset: u32 = 0,
}) void {
    store16(bytes, @as(usize, base) + zpci.interrupts.msix.register.message_control, msixControlRaw(.{
        .table_size_minus_one = fields.table_size_minus_one,
    }));
    store32(bytes, @as(usize, base) + zpci.interrupts.msix.register.table_offset_bir, locationRaw(
        fields.table_bir,
        fields.table_offset,
    ));
    store32(bytes, @as(usize, base) + zpci.interrupts.msix.register.pba_offset_bir, locationRaw(
        fields.pba_bir,
        fields.pba_offset,
    ));
}

fn msiControlRaw(fields: struct {
    msi_enable: bool = false,
    multiple_message_capable: u3 = 0,
    multiple_message_enable: u3 = 0,
    addr_64_capable: bool = false,
    pvm_capable: bool = false,
    ext_msg_data_capable: bool = false,
    ext_msg_data_enable: bool = false,
    reserved11: u5 = 0,
}) u16 {
    const control = zpci.interrupts.msi.MessageControl{
        .msi_enable = fields.msi_enable,
        .multiple_message_capable = fields.multiple_message_capable,
        .multiple_message_enable = fields.multiple_message_enable,
        .addr_64_capable = fields.addr_64_capable,
        .pvm_capable = fields.pvm_capable,
        .ext_msg_data_capable = fields.ext_msg_data_capable,
        .ext_msg_data_enable = fields.ext_msg_data_enable,
        ._reserved11 = fields.reserved11,
    };
    return @bitCast(control);
}

fn msixControlRaw(fields: struct {
    table_size_minus_one: u11 = 0,
    reserved11: u3 = 0,
    function_mask: bool = false,
    msix_enable: bool = false,
}) u16 {
    const control = zpci.interrupts.msix.MessageControl{
        .table_size_minus_one = fields.table_size_minus_one,
        ._reserved11 = fields.reserved11,
        .function_mask = fields.function_mask,
        .msix_enable = fields.msix_enable,
    };
    return @bitCast(control);
}

fn locationRaw(bir: u3, byte_offset: u32) u32 {
    std.debug.assert(byte_offset & 0b111 == 0);
    return byte_offset | bir;
}

fn load16(bytes: []const u8, byte_offset: usize) u16 {
    const wrapped = stdx.bytes.load(stdx.layout.Le(u16), bytes, byte_offset) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
    return wrapped.native();
}

fn load32(bytes: []const u8, byte_offset: usize) u32 {
    const wrapped = stdx.bytes.load(stdx.layout.Le(u32), bytes, byte_offset) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
    return wrapped.native();
}

fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
    const encoded = stdx.layout.Le(u16).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u16), bytes, byte_offset, encoded) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
}

fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
    const encoded = stdx.layout.Le(u32).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u32), bytes, byte_offset, encoded) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
}
