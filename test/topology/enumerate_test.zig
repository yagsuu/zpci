//! Tests for docs/specs/topology/enumerate.md.

const std = @import("std");

const stdx = @import("stdx");

const zpci = @import("zpci");

const enumerate = zpci.topology.enumerate;
const Node = enumerate.Node;
const NodeIndex = enumerate.NodeIndex;
const ConfigSpace = zpci.config.ConfigSpace;
const Segment = zpci.config.Segment;
const Sbdf = zpci.core.Sbdf;
const HeaderKind = zpci.config.HeaderKind;
const SegmentId = zpci.core.SegmentId;
const VirtAddr = stdx.addr.VirtAddr;

const function_window_size: usize = 0x1000;
const cap_base: u8 = 0x40;
const offset = struct {
    const vendor_id: usize = 0x00;
    const device_id: usize = 0x02;
    const status: usize = 0x06;
    const header_type: usize = 0x0E;
    const secondary_bus: usize = 0x19;
    const subordinate_bus: usize = 0x1A;
    const capabilities_pointer: usize = 0x34;
};
const status = struct {
    const capabilities_list: u16 = 1 << 4;
};
const pcie = struct {
    const id: u8 = 0x10;
    const capabilities: u8 = 0x02;
    const device_control_2: u8 = 0x28;
    const ari_forwarding_enable: u16 = 1 << 5;
};

const ConfigEntry = struct {
    sbdf: Sbdf,
    bytes: []u8,
};

const TestConfigSpace = struct {
    entries: []ConfigEntry,
    fail_on_read_offset: ?usize = null,

    const Entry = ConfigEntry;

    fn init(entries: []ConfigEntry) TestConfigSpace {
        return .{ .entries = entries };
    }

    fn configSpace(self: *TestConfigSpace) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    fn functionBytes(self: *TestConfigSpace, address: Sbdf) ?[]u8 {
        for (self.entries) |entry| {
            if (entry.sbdf.eql(address)) return entry.bytes;
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

    fn read8(context: *anyopaque, address: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        if (self.fail_on_read_offset == byte_offset) return error.OutOfBounds;
        const bytes = self.functionBytes(address) orelse return 0xFF;
        return bytes[byte_offset];
    }

    fn read16(context: *anyopaque, address: Sbdf, byte_offset: usize) ConfigSpace.Error!u16 {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        if (self.fail_on_read_offset == byte_offset) return error.OutOfBounds;
        const bytes = self.functionBytes(address) orelse return 0xFFFF;
        return @as(u16, bytes[byte_offset]) | (@as(u16, bytes[byte_offset + 1]) << 8);
    }

    fn read32(context: *anyopaque, address: Sbdf, byte_offset: usize) ConfigSpace.Error!u32 {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        if (self.fail_on_read_offset == byte_offset) return error.OutOfBounds;
        const bytes = self.functionBytes(address) orelse return 0xFFFF_FFFF;
        return @as(u32, bytes[byte_offset]) |
            (@as(u32, bytes[byte_offset + 1]) << 8) |
            (@as(u32, bytes[byte_offset + 2]) << 16) |
            (@as(u32, bytes[byte_offset + 3]) << 24);
    }

    fn write8(context: *anyopaque, address: Sbdf, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(address) orelse return;
        bytes[byte_offset] = value;
    }

    fn write16(context: *anyopaque, address: Sbdf, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(address) orelse return;
        store16(bytes[0..function_window_size], byte_offset, value);
    }

    fn write32(context: *anyopaque, address: Sbdf, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(address) orelse return;
        bytes[byte_offset] = @truncate(value);
        bytes[byte_offset + 1] = @truncate(value >> 8);
        bytes[byte_offset + 2] = @truncate(value >> 16);
        bytes[byte_offset + 3] = @truncate(value >> 24);
    }
};

const Entry = ConfigEntry;

test "unit: empty segment list returns an empty tree" {
    // Build with no segments to pin the zero-work boundary and roots scratch borrowing.
    var entries = [_]Entry{};
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{};
    var nodes: [1]Node = undefined;
    var roots: [1]NodeIndex = .{0xBEEF};

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try std.testing.expectEqual(@as(usize, 0), view.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), view.roots.len);
    try std.testing.expectEqual(@as(NodeIndex, 0xBEEF), roots[0]);
}

test "topology: absent functions produce no nodes for a populated segment aperture" {
    // Scan one empty bus through a sparse byte backend so absence comes from vendor id 0xffff.
    var entries = [_]Entry{};
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(0, 0, 0)};
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try std.testing.expectEqual(@as(usize, 0), view.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), view.roots.len);
}

test "topology: single endpoint root is emitted as a root node" {
    // Seed one type-0 function and verify the returned tree borrows only the populated node prefix.
    var endpoint = functionBytes(.{ .header = 0x00 });
    var entries = [_]Entry{.{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &endpoint }};
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(0, 0, 0)};
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try expectNodeSbdfs(&view, &.{sbdf(0, 0, 0, 0)});
    try std.testing.expectEqualSlices(NodeIndex, &.{0}, view.roots);
    try std.testing.expectEqual(@as(?NodeIndex, null), view.node(0).parent);
    try std.testing.expectEqual(HeaderKind.type0, view.node(0).header_kind);
}

test "topology: multi-segment walk emits in input order before root sorting" {
    // Reverse segment order to prove enumeration order and tree root sorting are distinct contracts.
    var seg1_endpoint = functionBytes(.{ .header = 0x00 });
    var seg0_endpoint = functionBytes(.{ .header = 0x00 });
    var entries = [_]Entry{
        .{ .sbdf = sbdf(1, 0, 0, 0), .bytes = &seg1_endpoint },
        .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &seg0_endpoint },
    };
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{ segment(1, 0, 0), segment(0, 0, 0) };
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try expectNodeSbdfs(&view, &.{ sbdf(1, 0, 0, 0), sbdf(0, 0, 0, 0) });
    try std.testing.expectEqualSlices(NodeIndex, &.{ 1, 0 }, view.roots);
}

test "topology: multifunction gate controls sibling function probing" {
    // Function 1 is byte-backed and present; it must stay hidden when function 0 lacks the multifunction bit.
    var function0 = functionBytes(.{ .header = 0x00 });
    var function1 = functionBytes(.{ .header = 0x00 });
    var entries = [_]Entry{
        .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &function0 },
        .{ .sbdf = sbdf(0, 0, 0, 1), .bytes = &function1 },
    };
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(0, 0, 0)};
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try expectNodeSbdfs(&view, &.{sbdf(0, 0, 0, 0)});
}

test "topology: ARI forwarding maps flat function numbers through requester-id low byte" {
    // A sibling above function 7 is reachable only when the parent bridge advertises ARI forwarding.
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
    var classic_backend = TestConfigSpace.init(&classic_entries);
    var ari_backend = TestConfigSpace.init(&ari_entries);
    var segments = [_]Segment{segment(0, 0, 1)};
    var classic_nodes: [4]Node = undefined;
    var classic_roots: [4]NodeIndex = undefined;
    var ari_nodes: [4]Node = undefined;
    var ari_roots: [4]NodeIndex = undefined;

    const classic = try enumerate.intoScratch(.{
        .config = classic_backend.configSpace(),
        .segments = &segments,
        .nodes = &classic_nodes,
        .roots = &classic_roots,
    });
    const ari = try enumerate.intoScratch(.{
        .config = ari_backend.configSpace(),
        .segments = &segments,
        .nodes = &ari_nodes,
        .roots = &ari_roots,
    });

    try expectNodeSbdfs(&classic, &.{sbdf(0, 0, 0, 0)});
    try expectNodeSbdfs(&ari, &.{ sbdf(0, 0, 0, 0), sbdf(0, 1, 1, 1) });
    try std.testing.expectEqual(@as(?NodeIndex, 0), ari.node(1).parent);
}

test "topology: malformed capability list falls back to classic ARI mode" {
    // Malformed capability-list structure is not a config-space read error; it must only disable ARI.
    var bridge = functionBytes(.{ .header = 0x01, .secondary = 1, .subordinate = 1 });
    store16(&bridge, offset.status, status.capabilities_list);
    bridge[offset.capabilities_pointer] = cap_base;
    bridge[cap_base] = pcie.id;
    bridge[cap_base + 1] = cap_base | 0b01;
    var ari_function9 = functionBytes(.{ .header = 0x00 });
    var entries = [_]Entry{
        .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge },
        .{ .sbdf = sbdf(0, 1, 1, 1), .bytes = &ari_function9 },
    };
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(0, 0, 1)};
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try expectNodeSbdfs(&view, &.{sbdf(0, 0, 0, 0)});
}

test "topology: ARI detection propagates config-space read failures" {
    // Fail the DeviceControl2 read so ARI detection cannot silently fall back to classic mode.
    var bridge = functionBytes(.{ .header = 0x01, .secondary = 1, .subordinate = 1, .ari = true });
    var entries = [_]Entry{.{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge }};
    var backend = TestConfigSpace.init(&entries);
    backend.fail_on_read_offset = @as(usize, cap_base) + pcie.device_control_2;
    var segments = [_]Segment{segment(0, 0, 1)};
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    try std.testing.expectError(error.OutOfBounds, enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    }));
}

test "topology: valid bridge descent emits DFS preorder accepted by tree builder" {
    // Put a child behind a bridge and a later root sibling to verify descendants stay contiguous before siblings.
    var bridge = functionBytes(.{ .header = 0x01, .secondary = 1, .subordinate = 1 });
    var child = functionBytes(.{ .header = 0x00 });
    var sibling = functionBytes(.{ .header = 0x00 });
    var entries = [_]Entry{
        .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge },
        .{ .sbdf = sbdf(0, 1, 0, 0), .bytes = &child },
        .{ .sbdf = sbdf(0, 0, 1, 0), .bytes = &sibling },
    };
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(0, 0, 1)};
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try expectNodeSbdfs(&view, &.{ sbdf(0, 0, 0, 0), sbdf(0, 1, 0, 0), sbdf(0, 0, 1, 0) });
    try std.testing.expectEqualSlices(NodeIndex, &.{ 0, 2 }, view.roots);
    try std.testing.expectEqual(@as(?NodeIndex, 0), view.node(1).parent);
    try expectPreorder(&view, &.{ 0, 1, 2 });
}

test "topology: invalid secondary subordinate bridge numbers short-circuit descent" {
    // A bridge with subordinate < secondary is emitted but its otherwise-present downstream bus is not walked.
    var bridge = functionBytes(.{ .header = 0x01, .secondary = 2, .subordinate = 1 });
    var child = functionBytes(.{ .header = 0x00 });
    var entries = [_]Entry{
        .{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &bridge },
        .{ .sbdf = sbdf(0, 2, 0, 0), .bytes = &child },
    };
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(0, 0, 2)};
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try expectNodeSbdfs(&view, &.{sbdf(0, 0, 0, 0)});
}

test "topology: type-2 CardBus header is skipped without surfacing BadHeaderType" {
    // Seed a present type-2 header so Function.validate rejects it and enumeration translates it to absent.
    var cardbus = functionBytes(.{ .header = 0x02 });
    var entries = [_]Entry{.{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &cardbus }};
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(0, 0, 0)};
    var nodes: [4]Node = undefined;
    var roots: [4]NodeIndex = undefined;

    const view = try enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    });

    try std.testing.expectEqual(@as(usize, 0), view.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), view.roots.len);
}

test "failure: node scratch exhaustion stops before tree assembly" {
    // Supply zero node slots for a present endpoint to force StorageExhausted at the emission boundary.
    var endpoint = functionBytes(.{ .header = 0x00 });
    var entries = [_]Entry{.{ .sbdf = sbdf(0, 0, 0, 0), .bytes = &endpoint }};
    var backend = TestConfigSpace.init(&entries);
    var segments = [_]Segment{segment(0, 0, 0)};
    var nodes = [_]Node{};
    var roots: [1]NodeIndex = undefined;

    try std.testing.expectError(error.StorageExhausted, enumerate.intoScratch(.{
        .config = backend.configSpace(),
        .segments = &segments,
        .nodes = &nodes,
        .roots = &roots,
    }));
}

test "unit: sizeBound caps per-bus function-space upper bound at max nodes" {
    // Check zero, ordinary multi-bus, and full-aperture saturation cases without config I/O.
    var empty = [_]Segment{};
    var two_buses = [_]Segment{segment(0, 4, 5)};
    var full = [_]Segment{segment(0, 0, 0xFF)};

    try std.testing.expectEqual(@as(usize, 0), enumerate.sizeBound(&empty));
    try std.testing.expectEqual(@as(usize, 512), enumerate.sizeBound(&two_buses));
    try std.testing.expectEqual(@as(usize, 65_535), enumerate.sizeBound(&full));
}

fn functionBytes(fields: struct {
    vendor: u16 = 0x1234,
    device: u16 = 0x5678,
    header: u8 = 0x00,
    secondary: u8 = 0,
    subordinate: u8 = 0,
    ari: bool = false,
}) [function_window_size]u8 {
    var bytes: [function_window_size]u8 = @splat(0);
    store16(&bytes, offset.vendor_id, fields.vendor);
    store16(&bytes, offset.device_id, fields.device);
    bytes[offset.header_type] = fields.header;
    bytes[offset.secondary_bus] = fields.secondary;
    bytes[offset.subordinate_bus] = fields.subordinate;

    if (fields.ari) {
        store16(&bytes, offset.status, status.capabilities_list);
        bytes[offset.capabilities_pointer] = cap_base;
        bytes[cap_base] = pcie.id;
        bytes[cap_base + 1] = 0;
        store16(&bytes, cap_base + pcie.capabilities, 2);
        store16(&bytes, cap_base + pcie.device_control_2, pcie.ari_forwarding_enable);
    }

    return bytes;
}

fn segment(segment_id: u16, bus_start: u8, bus_end: u8) Segment {
    return .{
        .segment = SegmentId.from(segment_id),
        .base = VirtAddr.fromInt(0x1000),
        .bus_start = bus_start,
        .bus_end = bus_end,
    };
}

fn sbdf(segment_id: u16, bus: u8, device: u8, function: u8) Sbdf {
    return Sbdf.from(segment_id, bus, device, function) catch unreachable;
}

fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
    std.debug.assert(byte_offset + 2 <= bytes.len);
    bytes[byte_offset] = @truncate(value);
    bytes[byte_offset + 1] = @truncate(value >> 8);
}

fn expectNodeSbdfs(view: anytype, expected: []const Sbdf) !void {
    try std.testing.expectEqual(expected.len, view.nodes.len);
    for (expected, 0..) |expected_sbdf, index| {
        try std.testing.expect(view.nodes[index].sbdf.eql(expected_sbdf));
    }
}

fn expectPreorder(view: anytype, expected: []const NodeIndex) !void {
    var iterator = view.preorder();
    for (expected) |index| {
        const item = iterator.next();
        try std.testing.expect(item != null);
        try std.testing.expectEqual(index, item.?.index);
    }

    try std.testing.expect(iterator.next() == null);
}
