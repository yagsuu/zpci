const std = @import("std");

const pci = @import("pci");
const support = @import("support.zig");

const msi = pci.core.capabilities.msi;
const msix = pci.core.capabilities.msix;

const Function = pci.config.Function;
const MsiVectorCount = msi.VectorCount;
const TableEntry = msix.TableEntry;
const TestBarMemory = pci.testing.memory.TestBarMemory;
const TestConfigSpace = pci.testing.config.TestConfigSpace;
const MsiCapability = pci.capabilities.msi.Capability;
const MsixCapability = pci.capabilities.msix.Capability;
const MsixTable = pci.capabilities.msix.Table;
const MsixPba = pci.capabilities.msix.Pba;
const HeaderStatus = pci.core.header.Status;

const testing = std.testing;

const pcie_window_size = support.pcie_window_size;

const offset = struct {
    const msi_capability: u8 = 0x60;
    const msix_capability: u8 = 0x70;
};

const cap_list = HeaderStatus.raw(.{ .cap_list = true });

const seedFunction = support.seedFunction;
const seedCapability = support.seedCapability;
const sbdf = support.sbdf;
const store16 = support.store16;
const store32 = support.store32;

test "MSI routing programs discovered capability" {
    var bytes: [pcie_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .status = cap_list, .cap_head = offset.msi_capability });
    seedCapability(&bytes, .{
        .base = offset.msi_capability,
        .id = @backingInt(msi.id),
        .next = 0,
    });
    store16(&bytes, offset.msi_capability + msi.offsets.control, msi.Control.raw(.{
        .multi_msg_capable = .two,
        .pvm_capable = true,
    }));

    const address = sbdf(.{ .bus = 0 });
    var backend = TestConfigSpace.fromSingle(address, &bytes);
    const function = try Function.tryFrom(backend.config(), address);
    const capability = (try MsiCapability.find(function)).?;

    try capability.program(.{
        .address = 0xFEE0_0000,
        .data = 0x0040,
        .num_vectors = .two,
        .mask = 3,
    });

    const routing = try capability.routing();
    try testing.expectEqual(@as(u64, 0xFEE0_0000), routing.address);
    try testing.expectEqual(@as(u16, 0x0040), routing.data);
    try testing.expectEqual(@as(?u32, 3), routing.mask);

    const control = try capability.control();
    try testing.expectEqual(MsiVectorCount.two, control.multi_msg_enable);
    try testing.expect(!control.enable);

    try capability.setMasked(0, false);
    try testing.expectEqual(@as(u32, 2), try capability.mask());

    try capability.updateControl(.{ .enable = true });
    try testing.expect((try capability.control()).enable);
}

test "MSI-X routing programs caller BAR memory" {
    var bytes: [pcie_window_size]u8 = undefined;
    seedFunction(&bytes, .{ .status = cap_list, .cap_head = offset.msix_capability });
    seedCapability(&bytes, .{
        .base = offset.msix_capability,
        .id = @backingInt(msix.id),
        .next = 0,
    });
    store16(&bytes, offset.msix_capability + msix.offsets.control, msix.Control.raw(.{
        .table_size_minus_one = 1,
    }));
    store32(&bytes, offset.msix_capability + msix.offsets.table, msix.BarLocation.raw(.{
        .bir = 0,
        .offset_shifted = 0,
    }));
    store32(&bytes, offset.msix_capability + msix.offsets.pba, msix.BarLocation.raw(.{
        .bir = 1,
        .offset_shifted = 0,
    }));

    const address = sbdf(.{ .bus = 0 });
    var config_backend = TestConfigSpace.fromSingle(address, &bytes);
    const function = try Function.tryFrom(config_backend.config(), address);
    const capability = (try MsixCapability.find(function)).?;

    const num_vectors = try capability.numVectors();
    const table_offset = try capability.table();
    const pba_offset = try capability.pba();

    try testing.expectEqual(@as(u16, 2), num_vectors);
    try testing.expectEqual(@as(u3, 0), table_offset.bar);
    try testing.expectEqual(@as(u3, 1), pba_offset.bar);

    var table_bytes: [2 * @sizeOf(TableEntry)]u8 = @splat(0);
    var table_backend: TestBarMemory = .{ .bytes = &table_bytes };
    var pba_bytes: [4]u8 = @splat(0);
    store32(&pba_bytes, 0, @as(u32, 1) << 1);
    var pba_backend: TestBarMemory = .{ .bytes = &pba_bytes };

    const table = MsixTable.from(table_backend.accessor(), num_vectors);
    const pba = MsixPba.from(pba_backend.accessor(), num_vectors);

    try capability.updateControl(.{ .enable = true, .function_mask = true });
    try table.setMasked(1, true);

    try table.program(1, .{
        .address = 0xFEE0_0000,
        .data = 0x0045,
    });

    const entry = try table.read(1);
    try testing.expectEqual(@as(u64, 0xFEE0_0000), entry.address);
    try testing.expectEqual(@as(u32, 0x0045), entry.data);
    try testing.expect(entry.masked);
    try testing.expect(try pba.pending(1));

    try table.setMasked(1, false);
    try capability.updateControl(.{ .function_mask = false });

    try testing.expect((try capability.control()).enable);
    try testing.expect(!(try table.read(1)).masked);
    try testing.expect(!(try capability.control()).function_mask);

    try table.setMasked(1, true);
    try capability.updateControl(.{ .enable = false });
    try testing.expect((try table.read(1)).masked);
    try testing.expect(!(try capability.control()).enable);
}
