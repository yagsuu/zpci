//! PCI identifiers.

const std = @import("std");

pub const SegmentId = enum(u16) {
    _,

    pub fn from(n: u16) SegmentId {
        return @enumFromInt(n);
    }

    pub fn raw(self: SegmentId) u16 {
        return @intFromEnum(self);
    }

    comptime {
        std.debug.assert(@bitSizeOf(SegmentId) == 16);
    }
};

pub const VendorId = enum(u16) {
    absent = 0xFFFF,
    _,

    pub fn from(n: u16) VendorId {
        return @enumFromInt(n);
    }

    pub fn raw(self: VendorId) u16 {
        return @intFromEnum(self);
    }
};

pub const DeviceId = enum(u16) {
    _,

    pub fn from(n: u16) DeviceId {
        return @enumFromInt(n);
    }

    pub fn raw(self: DeviceId) u16 {
        return @intFromEnum(self);
    }
};

pub const RevisionId = enum(u8) {
    _,

    pub fn from(n: u8) RevisionId {
        return @enumFromInt(n);
    }

    pub fn raw(self: RevisionId) u8 {
        return @intFromEnum(self);
    }
};

pub const BaseClass = enum(u8) {
    unclassified = 0x00,
    mass_storage = 0x01,
    network_controller = 0x02,
    display_controller = 0x03,
    multimedia_controller = 0x04,
    memory_controller = 0x05,
    bridge = 0x06,
    simple_comm_controller = 0x07,
    base_system_peripheral = 0x08,
    input_device = 0x09,
    docking_station = 0x0A,
    processor = 0x0B,
    serial_bus_controller = 0x0C,
    wireless_controller = 0x0D,
    intelligent_controller = 0x0E,
    satellite_comm = 0x0F,
    encryption_controller = 0x10,
    signal_processing = 0x11,
    processing_accelerator = 0x12,
    non_essential_instr = 0x13,
    coprocessor = 0x40,
    unassigned = 0xFF,
    _,

    pub fn from(n: u8) BaseClass {
        return @enumFromInt(n);
    }

    pub fn raw(self: BaseClass) u8 {
        return @intFromEnum(self);
    }
};

pub const Subclass = enum(u8) {
    _,

    pub fn from(n: u8) Subclass {
        return @enumFromInt(n);
    }

    pub fn raw(self: Subclass) u8 {
        return @intFromEnum(self);
    }
};

pub const ProgIf = enum(u8) {
    _,

    pub fn from(n: u8) ProgIf {
        return @enumFromInt(n);
    }

    pub fn raw(self: ProgIf) u8 {
        return @intFromEnum(self);
    }
};

pub const ClassCode = extern struct {
    prog_if: ProgIf,
    subclass: Subclass,
    base: BaseClass,

    pub const bridge: ClassCode = .from(0x06, 0x04, 0x00);
    pub const nvme: ClassCode = .from(0x01, 0x08, 0x02);
    pub const ahci: ClassCode = .from(0x01, 0x06, 0x01);
    pub const vga: ClassCode = .from(0x03, 0x00, 0x00);
    pub const xhci: ClassCode = .from(0x0C, 0x03, 0x30);
    pub const ehci: ClassCode = .from(0x0C, 0x03, 0x20);
    pub const uhci: ClassCode = .from(0x0C, 0x03, 0x00);

    pub fn from(base: u8, sub: u8, pif: u8) ClassCode {
        return .{
            .prog_if = ProgIf.from(pif),
            .subclass = Subclass.from(sub),
            .base = BaseClass.from(base),
        };
    }

    pub fn eql(a: ClassCode, b: ClassCode) bool {
        return a.base == b.base and
            a.subclass == b.subclass and
            a.prog_if == b.prog_if;
    }

    comptime {
        std.debug.assert(@sizeOf(ClassCode) == 3);
        std.debug.assert(@alignOf(ClassCode) == 1);
        std.debug.assert(@offsetOf(ClassCode, "prog_if") == 0);
        std.debug.assert(@offsetOf(ClassCode, "subclass") == 1);
        std.debug.assert(@offsetOf(ClassCode, "base") == 2);
    }
};

pub const unit = struct {
    const testing = std.testing;

    test "VendorId.absent recognizes only the PCI 0xFFFF no-function marker" {
        try testing.expectEqual(@as(u16, 0xFFFF), VendorId.absent.raw());
        try testing.expect(VendorId.from(0x8086) != .absent);
    }

    test "VendorId accepts zero and ordinary u16 identifiers as present devices" {
        try testing.expect(VendorId.from(0) != .absent);
        try testing.expect(VendorId.from(0xFFFE) != .absent);
    }

    test "BaseClass named constants match PCI-SIG assignments" {
        try testing.expectEqual(@as(u8, 0x00), BaseClass.unclassified.raw());
        try testing.expectEqual(@as(u8, 0x01), BaseClass.mass_storage.raw());
        try testing.expectEqual(@as(u8, 0x02), BaseClass.network_controller.raw());
        try testing.expectEqual(@as(u8, 0x03), BaseClass.display_controller.raw());
        try testing.expectEqual(@as(u8, 0x04), BaseClass.multimedia_controller.raw());
        try testing.expectEqual(@as(u8, 0x05), BaseClass.memory_controller.raw());
        try testing.expectEqual(@as(u8, 0x06), BaseClass.bridge.raw());
        try testing.expectEqual(@as(u8, 0x07), BaseClass.simple_comm_controller.raw());
        try testing.expectEqual(@as(u8, 0x08), BaseClass.base_system_peripheral.raw());
        try testing.expectEqual(@as(u8, 0x09), BaseClass.input_device.raw());
        try testing.expectEqual(@as(u8, 0x0A), BaseClass.docking_station.raw());
        try testing.expectEqual(@as(u8, 0x0B), BaseClass.processor.raw());
        try testing.expectEqual(@as(u8, 0x0C), BaseClass.serial_bus_controller.raw());
        try testing.expectEqual(@as(u8, 0x0D), BaseClass.wireless_controller.raw());
        try testing.expectEqual(@as(u8, 0x0E), BaseClass.intelligent_controller.raw());
        try testing.expectEqual(@as(u8, 0x0F), BaseClass.satellite_comm.raw());
        try testing.expectEqual(@as(u8, 0x10), BaseClass.encryption_controller.raw());
        try testing.expectEqual(@as(u8, 0x11), BaseClass.signal_processing.raw());
        try testing.expectEqual(@as(u8, 0x12), BaseClass.processing_accelerator.raw());
        try testing.expectEqual(@as(u8, 0x13), BaseClass.non_essential_instr.raw());
        try testing.expectEqual(@as(u8, 0x40), BaseClass.coprocessor.raw());
        try testing.expectEqual(@as(u8, 0xFF), BaseClass.unassigned.raw());
    }

    test "BaseClass preserves unknown assignment values" {
        const unknown = BaseClass.from(0x42);

        try testing.expectEqual(@as(u8, 0x42), unknown.raw());
    }

    test "ClassCode.from stores PCI-SIG notation in wire byte order" {
        const cc = ClassCode.from(0x06, 0x04, 0x00);
        const bytes: [3]u8 = @bitCast(cc);

        try testing.expectEqual(@as(u8, 0x00), bytes[0]);
        try testing.expectEqual(@as(u8, 0x04), bytes[1]);
        try testing.expectEqual(@as(u8, 0x06), bytes[2]);
    }

    test "byte-cast decode of ClassCode from a raw config-space slice" {
        const raw = [_]u8{ 0x02, 0x08, 0x01 };
        const cc: *const ClassCode = @ptrCast(&raw[0]);

        try testing.expect(cc.eql(ClassCode.nvme));
    }

    test "ClassCode named triples match curated PCI-SIG conventions" {
        try testing.expect(ClassCode.bridge.eql(ClassCode.from(0x06, 0x04, 0x00)));
        try testing.expect(ClassCode.nvme.eql(ClassCode.from(0x01, 0x08, 0x02)));
        try testing.expect(ClassCode.ahci.eql(ClassCode.from(0x01, 0x06, 0x01)));
        try testing.expect(ClassCode.vga.eql(ClassCode.from(0x03, 0x00, 0x00)));
        try testing.expect(ClassCode.xhci.eql(ClassCode.from(0x0C, 0x03, 0x30)));
        try testing.expect(ClassCode.ehci.eql(ClassCode.from(0x0C, 0x03, 0x20)));
        try testing.expect(ClassCode.uhci.eql(ClassCode.from(0x0C, 0x03, 0x00)));
    }

    test "ClassCode.eql compares base class, subclass, and programming interface" {
        const a = ClassCode.from(0x01, 0x08, 0x02);
        const b = ClassCode.from(0x01, 0x08, 0x02);

        try testing.expect(a.eql(b));
        try testing.expect(!a.eql(ClassCode.from(0x01, 0x08, 0x00)));
        try testing.expect(!a.eql(ClassCode.from(0x01, 0x06, 0x02)));
        try testing.expect(!a.eql(ClassCode.from(0x00, 0x08, 0x02)));
    }

    test "uncatalogued identifiers preserve encoded values" {
        try testing.expectEqual(@as(u16, 0xFFFF), SegmentId.from(0xFFFF).raw());
        try testing.expectEqual(@as(u16, 0xFEDC), DeviceId.from(0xFEDC).raw());
        try testing.expectEqual(@as(u8, 0xFF), RevisionId.from(0xFF).raw());
        try testing.expectEqual(@as(u8, 0xFE), Subclass.from(0xFE).raw());
        try testing.expectEqual(@as(u8, 0xFD), ProgIf.from(0xFD).raw());
    }
};
