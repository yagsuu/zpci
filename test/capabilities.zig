const std = @import("std");

const pci = @import("pci");
const support = @import("support.zig");

const StandardEntry = pci.capabilities.standard.Entry;
const StandardId = pci.core.capabilities.standard.Id;
const ExtendedEntry = pci.capabilities.extended.Entry;
const Function = pci.config.Function;
const TestConfigSpace = pci.testing.config.TestConfigSpace;
const StandardIterator = pci.capabilities.standard.Iterator;
const ExtendedIterator = pci.capabilities.extended.Iterator;

const testing = std.testing;

const pcie_window_size = support.pcie_window_size;

const offset = struct {
    const pcie_capability: u8 = 0x40;
    const msi_chain_capability: u8 = 0x80;
};

const status = struct {
    const cap_list: u16 = 1 << 4;
};

const seedFunction = support.seedFunction;
const seedCapability = support.seedCapability;
const sbdf = support.sbdf;
const store32 = support.store32;

test "capability traversal walks seeded config bytes" {
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
