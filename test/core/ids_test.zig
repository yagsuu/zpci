//! Tests for docs/specs/core/ids.md.

const std = @import("std");

const pci = @import("pci");

const BaseClass = pci.core.BaseClass;
const ClassCode = pci.core.ClassCode;
const DeviceId = pci.core.DeviceId;
const ProgIf = pci.core.ProgIf;
const RevisionId = pci.core.RevisionId;
const SegmentId = pci.core.SegmentId;
const Subclass = pci.core.Subclass;
const VendorId = pci.core.VendorId;

test "unit: SegmentId accepts the full u16 range and compares by value" {
    const first = SegmentId.from(0);
    const last = SegmentId.from(0xFFFF);

    try std.testing.expect(first.eql(SegmentId.of(0)));
    try std.testing.expect(!first.eql(last));
    try std.testing.expectEqual(@as(u16, 0xFFFF), @intFromEnum(last));
}

test "layout: SegmentId packs to the PCI 16-bit segment-group field" {
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(SegmentId));
}

test "unit: VendorId.absent recognizes only the PCI 0xFFFF no-function marker" {
    try std.testing.expectEqual(@as(u16, 0xFFFF), @intFromEnum(VendorId.absent));
    try std.testing.expect(VendorId.absent.isAbsent());
    try std.testing.expect(!VendorId.of(0x8086).isAbsent());
}

test "unit: VendorId accepts zero and ordinary u16 identifiers as present devices" {
    try std.testing.expect(!VendorId.from(0).isAbsent());
    try std.testing.expect(!VendorId.from(0xFFFE).isAbsent());
    try std.testing.expect(VendorId.of(0x8086).eql(VendorId.from(0x8086)));
}

test "unit: DeviceId and RevisionId keep independent full-range identities" {
    try std.testing.expect(DeviceId.from(0).eql(DeviceId.of(0)));
    try std.testing.expect(DeviceId.from(0xFFFF).eql(DeviceId.of(0xFFFF)));
    try std.testing.expect(!DeviceId.of(0x1234).eql(DeviceId.of(0x5678)));
    try std.testing.expect(RevisionId.from(0).eql(RevisionId.of(0)));
    try std.testing.expect(RevisionId.from(0xFF).eql(RevisionId.of(0xFF)));
    try std.testing.expect(!RevisionId.of(0x00).eql(RevisionId.of(0xFF)));
}

test "unit: BaseClass named constants match PCI-SIG assignments" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(BaseClass.unclassified));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(BaseClass.mass_storage));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(BaseClass.network_controller));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(BaseClass.display_controller));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(BaseClass.multimedia_controller));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(BaseClass.memory_controller));
    try std.testing.expectEqual(@as(u8, 0x06), @intFromEnum(BaseClass.bridge));
    try std.testing.expectEqual(@as(u8, 0x07), @intFromEnum(BaseClass.simple_comm_controller));
    try std.testing.expectEqual(@as(u8, 0x08), @intFromEnum(BaseClass.base_system_peripheral));
    try std.testing.expectEqual(@as(u8, 0x09), @intFromEnum(BaseClass.input_device));
    try std.testing.expectEqual(@as(u8, 0x0A), @intFromEnum(BaseClass.docking_station));
    try std.testing.expectEqual(@as(u8, 0x0B), @intFromEnum(BaseClass.processor));
    try std.testing.expectEqual(@as(u8, 0x0C), @intFromEnum(BaseClass.serial_bus_controller));
    try std.testing.expectEqual(@as(u8, 0x0D), @intFromEnum(BaseClass.wireless_controller));
    try std.testing.expectEqual(@as(u8, 0x0E), @intFromEnum(BaseClass.intelligent_controller));
    try std.testing.expectEqual(@as(u8, 0x0F), @intFromEnum(BaseClass.satellite_comm));
    try std.testing.expectEqual(@as(u8, 0x10), @intFromEnum(BaseClass.encryption_controller));
    try std.testing.expectEqual(@as(u8, 0x11), @intFromEnum(BaseClass.signal_processing));
    try std.testing.expectEqual(@as(u8, 0x12), @intFromEnum(BaseClass.processing_accelerator));
    try std.testing.expectEqual(@as(u8, 0x13), @intFromEnum(BaseClass.non_essential_instr));
    try std.testing.expectEqual(@as(u8, 0x40), @intFromEnum(BaseClass.coprocessor));
    try std.testing.expectEqual(@as(u8, 0xFF), @intFromEnum(BaseClass.unassigned));
}

test "unit: BaseClass preserves unknown assignment values" {
    const unknown = BaseClass.from(0x42);

    try std.testing.expectEqual(@as(u8, 0x42), @intFromEnum(unknown));
}

test "unit: Subclass and ProgIf accept the full byte range without catalogs" {
    try std.testing.expect(Subclass.from(0).eql(Subclass.of(0)));
    try std.testing.expect(Subclass.from(0xFF).eql(Subclass.of(0xFF)));
    try std.testing.expect(ProgIf.from(0).eql(ProgIf.of(0)));
    try std.testing.expect(ProgIf.from(0xFF).eql(ProgIf.of(0xFF)));
}

test "layout: ClassCode wire shape is prog_if, subclass, base_class with byte alignment" {
    try std.testing.expectEqual(@as(usize, 3), @sizeOf(ClassCode));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(ClassCode));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ClassCode, "prog_if"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(ClassCode, "subclass"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(ClassCode, "base_class"));
}

test "layout: ClassCode.of stores PCI-SIG notation in wire byte order" {
    const cc = ClassCode.of(0x06, 0x04, 0x00);
    const bytes: [3]u8 = @bitCast(cc);

    try std.testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x04), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x06), bytes[2]);
}

test "unit: byte-cast decode of ClassCode from a raw config-space slice" {
    const raw = [_]u8{ 0x02, 0x08, 0x01 };
    const cc: *const ClassCode = @ptrCast(&raw[0]);

    try std.testing.expect(cc.eql(ClassCode.nvme));
}

test "unit: ClassCode named triples match curated PCI-SIG conventions" {
    try std.testing.expect(ClassCode.bridge.eql(ClassCode.of(0x06, 0x04, 0x00)));
    try std.testing.expect(ClassCode.nvme.eql(ClassCode.of(0x01, 0x08, 0x02)));
    try std.testing.expect(ClassCode.ahci.eql(ClassCode.of(0x01, 0x06, 0x01)));
    try std.testing.expect(ClassCode.vga.eql(ClassCode.of(0x03, 0x00, 0x00)));
    try std.testing.expect(ClassCode.xhci.eql(ClassCode.of(0x0C, 0x03, 0x30)));
    try std.testing.expect(ClassCode.ehci.eql(ClassCode.of(0x0C, 0x03, 0x20)));
    try std.testing.expect(ClassCode.uhci.eql(ClassCode.of(0x0C, 0x03, 0x00)));
}

test "unit: ClassCode.eql compares base class, subclass, and programming interface" {
    const a = ClassCode.of(0x01, 0x08, 0x02);
    const b = ClassCode.from(0x01, 0x08, 0x02);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(ClassCode.of(0x01, 0x08, 0x00)));
    try std.testing.expect(!a.eql(ClassCode.of(0x01, 0x06, 0x02)));
    try std.testing.expect(!a.eql(ClassCode.of(0x00, 0x08, 0x02)));
}

test "unit: BaseClass.eql supports generic class-level branching" {
    const class = ClassCode.of(0x02, 0x00, 0x00);

    try std.testing.expect(class.base_class.eql(BaseClass.network_controller));
    try std.testing.expect(!class.base_class.eql(BaseClass.bridge));
}
