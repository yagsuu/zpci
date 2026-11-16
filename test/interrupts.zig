const std = @import("std");

const pci = @import("pci");
const support = @import("support.zig");

const Function = pci.config.Function;
const MsiVectorCount = pci.core.capabilities.msi.VectorCount;
const TableEntry = pci.core.capabilities.msix.TableEntry;
const TestBarMemory = pci.testing.memory.TestBarMemory;
const TestConfigSpace = pci.testing.config.TestConfigSpace;
const MsiCapability = pci.interrupts.msi.Capability;
const MsixCapability = pci.interrupts.msix.Capability;
const MsixTable = pci.interrupts.msix.Table;
const MsixPba = pci.interrupts.msix.Pba;
const MsiControl = pci.core.capabilities.msi.Control;
const MsixControl = pci.core.capabilities.msix.Control;

const msi = pci.core.capabilities.msi;
const msix = pci.core.capabilities.msix;

const testing = std.testing;

const pcie_window_size = support.pcie_window_size;

const offset = struct {
    const msi_capability: u8 = 0x60;
    const msix_capability: u8 = 0x70;
};

const status = struct {
    const cap_list: u16 = 1 << 4;
};

const seedFunction = support.seedFunction;
const seedCapability = support.seedCapability;
const sbdf = support.sbdf;
const store16 = support.store16;
const store32 = support.store32;

test "MSI routing programs discovered capability" {
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

test "MSI-X routing programs caller BAR memory" {
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
