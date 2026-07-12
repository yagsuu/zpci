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
    // Exercise the segment-id endpoints so opaque segment keys do not collapse or reject legal values.
    const first = SegmentId.from(0);
    const last = SegmentId.from(0xFFFF);

    try std.testing.expect(first.eql(SegmentId.of(0)));
    try std.testing.expect(!first.eql(last));
    try std.testing.expectEqual(@as(u16, 0xFFFF), last.value);
}

test "layout: SegmentId packs to the PCI 16-bit segment-group field" {
    // Guard the bit width consumed by SBDF packing and config-space address keys.
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(SegmentId));
}

test "unit: VendorId.absent recognizes only the PCI 0xFFFF no-function marker" {
    // Check the reserved absence marker and a real vendor id through the public predicate.
    try std.testing.expectEqual(@as(u16, 0xFFFF), VendorId.absent.value);
    try std.testing.expect(VendorId.absent.isAbsent());
    try std.testing.expect(!VendorId.of(0x8086).isAbsent());
}

test "unit: VendorId accepts zero and ordinary u16 identifiers as present devices" {
    // PCI gives no absence meaning to zero, so only 0xFFFF may be treated as no function.
    try std.testing.expect(!VendorId.from(0).isAbsent());
    try std.testing.expect(!VendorId.from(0xFFFE).isAbsent());
    try std.testing.expect(VendorId.of(0x8086).eql(VendorId.from(0x8086)));
}

test "unit: DeviceId and RevisionId keep independent full-range identities" {
    // Cover both endpoint acceptance and inequality so these opaque ids stay value-distinct.
    try std.testing.expect(DeviceId.from(0).eql(DeviceId.of(0)));
    try std.testing.expect(DeviceId.from(0xFFFF).eql(DeviceId.of(0xFFFF)));
    try std.testing.expect(!DeviceId.of(0x1234).eql(DeviceId.of(0x5678)));
    try std.testing.expect(RevisionId.from(0).eql(RevisionId.of(0)));
    try std.testing.expect(RevisionId.from(0xFF).eql(RevisionId.of(0xFF)));
    try std.testing.expect(!RevisionId.of(0x00).eql(RevisionId.of(0xFF)));
}

test "unit: BaseClass named constants match PCI-SIG assignments" {
    // Pin every curated base-class constant to its externally assigned byte value.
    try std.testing.expectEqual(@as(u8, 0x00), BaseClass.unclassified.value);
    try std.testing.expectEqual(@as(u8, 0x01), BaseClass.mass_storage.value);
    try std.testing.expectEqual(@as(u8, 0x02), BaseClass.network_controller.value);
    try std.testing.expectEqual(@as(u8, 0x03), BaseClass.display_controller.value);
    try std.testing.expectEqual(@as(u8, 0x04), BaseClass.multimedia_controller.value);
    try std.testing.expectEqual(@as(u8, 0x05), BaseClass.memory_controller.value);
    try std.testing.expectEqual(@as(u8, 0x06), BaseClass.bridge.value);
    try std.testing.expectEqual(@as(u8, 0x07), BaseClass.simple_comm_controller.value);
    try std.testing.expectEqual(@as(u8, 0x08), BaseClass.base_system_peripheral.value);
    try std.testing.expectEqual(@as(u8, 0x09), BaseClass.input_device.value);
    try std.testing.expectEqual(@as(u8, 0x0A), BaseClass.docking_station.value);
    try std.testing.expectEqual(@as(u8, 0x0B), BaseClass.processor.value);
    try std.testing.expectEqual(@as(u8, 0x0C), BaseClass.serial_bus_controller.value);
    try std.testing.expectEqual(@as(u8, 0x0D), BaseClass.wireless_controller.value);
    try std.testing.expectEqual(@as(u8, 0x0E), BaseClass.intelligent_controller.value);
    try std.testing.expectEqual(@as(u8, 0x0F), BaseClass.satellite_comm.value);
    try std.testing.expectEqual(@as(u8, 0x10), BaseClass.encryption_controller.value);
    try std.testing.expectEqual(@as(u8, 0x11), BaseClass.signal_processing.value);
    try std.testing.expectEqual(@as(u8, 0x12), BaseClass.processing_accelerator.value);
    try std.testing.expectEqual(@as(u8, 0x13), BaseClass.non_essential_instr.value);
    try std.testing.expectEqual(@as(u8, 0x40), BaseClass.coprocessor.value);
    try std.testing.expectEqual(@as(u8, 0xFF), BaseClass.unassigned.value);
}

test "unit: Subclass and ProgIf accept the full byte range without catalogs" {
    // Check byte endpoints because zpci intentionally does not validate these open value spaces.
    try std.testing.expect(Subclass.from(0).eql(Subclass.of(0)));
    try std.testing.expect(Subclass.from(0xFF).eql(Subclass.of(0xFF)));
    try std.testing.expect(ProgIf.from(0).eql(ProgIf.of(0)));
    try std.testing.expect(ProgIf.from(0xFF).eql(ProgIf.of(0xFF)));
}

test "layout: ClassCode wire shape is prog_if, subclass, base_class with byte alignment" {
    // Header decoders byte-cast config-space bytes, so size, alignment, and offsets are contract.
    try std.testing.expectEqual(@as(usize, 3), @sizeOf(ClassCode));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(ClassCode));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ClassCode, "prog_if"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(ClassCode, "subclass"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(ClassCode, "base_class"));
}

test "layout: ClassCode.of stores PCI-SIG notation in wire byte order" {
    // Pass (base, subclass, prog_if) and bit-cast to prove the wire bytes stay prog-if first.
    const cc = ClassCode.of(0x06, 0x04, 0x00);
    const bytes: [3]u8 = @bitCast(cc);

    try std.testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x04), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x06), bytes[2]);
}

test "unit: byte-cast decode of ClassCode from a raw config-space slice" {
    // Reinterpret NVMe class-code bytes exactly as header modules do at offsets 0x09..0x0C.
    const raw = [_]u8{ 0x02, 0x08, 0x01 };
    const cc: *const ClassCode = @ptrCast(&raw[0]);

    try std.testing.expect(cc.eql(ClassCode.nvme));
}

test "unit: ClassCode named triples match curated PCI-SIG conventions" {
    // Compare each closed named triple through eql so wrong base, subclass, or prog-if bytes fail.
    try std.testing.expect(ClassCode.bridge.eql(ClassCode.of(0x06, 0x04, 0x00)));
    try std.testing.expect(ClassCode.nvme.eql(ClassCode.of(0x01, 0x08, 0x02)));
    try std.testing.expect(ClassCode.ahci.eql(ClassCode.of(0x01, 0x06, 0x01)));
    try std.testing.expect(ClassCode.vga.eql(ClassCode.of(0x03, 0x00, 0x00)));
    try std.testing.expect(ClassCode.xhci.eql(ClassCode.of(0x0C, 0x03, 0x30)));
    try std.testing.expect(ClassCode.ehci.eql(ClassCode.of(0x0C, 0x03, 0x20)));
    try std.testing.expect(ClassCode.uhci.eql(ClassCode.of(0x0C, 0x03, 0x00)));
}

test "unit: ClassCode.eql compares base class, subclass, and programming interface" {
    // Flip one component at a time so equality cannot ignore any byte of the class-code triple.
    const a = ClassCode.of(0x01, 0x08, 0x02);
    const b = ClassCode.from(0x01, 0x08, 0x02);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(ClassCode.of(0x01, 0x08, 0x00)));
    try std.testing.expect(!a.eql(ClassCode.of(0x01, 0x06, 0x02)));
    try std.testing.expect(!a.eql(ClassCode.of(0x00, 0x08, 0x02)));
}

test "unit: BaseClass.eql supports generic class-level branching" {
    // Compare only the base-class byte from a full ClassCode so subclass/prog-if do not affect coarse dispatch.
    const class = ClassCode.of(0x02, 0x00, 0x00);

    try std.testing.expect(class.base_class.eql(BaseClass.network_controller));
    try std.testing.expect(!class.base_class.eql(BaseClass.bridge));
}
