//! Tests for docs/specs/core/ids.md.

const std = @import("std");

const zpci = @import("zpci");

const BaseClass = zpci.core.BaseClass;
const ClassCode = zpci.core.ClassCode;
const DeviceId = zpci.core.DeviceId;
const ProgIf = zpci.core.ProgIf;
const RevisionId = zpci.core.RevisionId;
const SegmentId = zpci.core.SegmentId;
const Subclass = zpci.core.Subclass;
const VendorId = zpci.core.VendorId;

test "unit: SegmentId round-trip through of/from/eql" {
    const a: SegmentId = .of(0);
    const b: SegmentId = .from(0xFFFF);
    try std.testing.expect(a.eql(SegmentId.from(0)));
    try std.testing.expect(!a.eql(b));
    try std.testing.expectEqual(@as(u16, 0xFFFF), b.value);
}

test "layout: SegmentId packs to u16" {
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(SegmentId));
}

test "unit: VendorId.absent is the PCI-mandated 0xFFFF marker" {
    try std.testing.expectEqual(@as(u16, 0xFFFF), VendorId.absent.value);
    try std.testing.expect(VendorId.absent.isAbsent());
    try std.testing.expect(!VendorId.of(0x8086).isAbsent());
}

test "unit: VendorId accepts the full u16 range including zero" {
    try std.testing.expect(!VendorId.of(0).isAbsent());
    try std.testing.expect(VendorId.of(0x8086).eql(VendorId.from(0x8086)));
}

test "unit: DeviceId and RevisionId are opaque newtypes" {
    try std.testing.expect(DeviceId.of(0x1234).eql(DeviceId.from(0x1234)));
    try std.testing.expect(!DeviceId.of(0x1234).eql(DeviceId.of(0x5678)));
    try std.testing.expect(RevisionId.of(0x0A).eql(RevisionId.from(0x0A)));
    try std.testing.expect(!RevisionId.of(0x00).eql(RevisionId.of(0xFF)));
}

test "unit: BaseClass named constants match PCI-SIG assignments" {
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

test "unit: Subclass and ProgIf accept the full u8 range" {
    try std.testing.expect(Subclass.of(0x42).eql(Subclass.from(0x42)));
    try std.testing.expect(ProgIf.of(0x80).eql(ProgIf.from(0x80)));
}

test "layout: ClassCode wire shape (prog_if=0, subclass=1, base_class=2, size 3, align 1)" {
    try std.testing.expectEqual(@as(usize, 3), @sizeOf(ClassCode));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(ClassCode));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ClassCode, "prog_if"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(ClassCode, "subclass"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(ClassCode, "base_class"));
}

test "layout: ClassCode.of stores wire bytes as prog_if, subclass, base_class" {
    const cc = ClassCode.of(0x06, 0x04, 0x00);
    const bytes: [3]u8 = @bitCast(cc);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[0]); // prog_if
    try std.testing.expectEqual(@as(u8, 0x04), bytes[1]); // subclass
    try std.testing.expectEqual(@as(u8, 0x06), bytes[2]); // base_class
}

test "unit: byte-cast decode of ClassCode from a raw slice" {
    // Header modules read the class-code triple by reinterpreting bytes
    // 0x09..0x0C as *const ClassCode. Verify the layout supports that.
    const raw = [_]u8{ 0x02, 0x08, 0x01 }; // NVMe (base=01, sub=08, pif=02)
    const cc: *const ClassCode = @ptrCast(&raw[0]);
    try std.testing.expect(cc.eql(ClassCode.nvme));
}

test "unit: ClassCode named triples match PCI-SIG conventions" {
    try std.testing.expectEqual(@as(u8, 0x06), ClassCode.bridge.base_class.value);
    try std.testing.expectEqual(@as(u8, 0x04), ClassCode.bridge.subclass.value);
    try std.testing.expectEqual(@as(u8, 0x00), ClassCode.bridge.prog_if.value);

    try std.testing.expectEqual(@as(u8, 0x30), ClassCode.xhci.prog_if.value);
    try std.testing.expectEqual(@as(u8, 0x20), ClassCode.ehci.prog_if.value);
    try std.testing.expectEqual(@as(u8, 0x00), ClassCode.uhci.prog_if.value);
}

test "unit: ClassCode.eql compares all three components" {
    const a = ClassCode.of(0x01, 0x08, 0x02);
    const b = ClassCode.from(0x01, 0x08, 0x02);
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(ClassCode.of(0x01, 0x08, 0x00))); // prog_if differs
    try std.testing.expect(!a.eql(ClassCode.of(0x01, 0x06, 0x02))); // subclass differs
    try std.testing.expect(!a.eql(ClassCode.of(0x00, 0x08, 0x02))); // base_class differs
}

test "unit: BaseClass.eql routes generic branching" {
    const class = ClassCode.of(0x02, 0x00, 0x00);
    try std.testing.expect(class.base_class.eql(BaseClass.network_controller));
    try std.testing.expect(!class.base_class.eql(BaseClass.bridge));
}
