//! PCI identifier newtypes. Spec: docs/specs/core/ids.md.

const std = @import("std");

pub const SegmentId = packed struct(u16) {
    value: u16,

    pub fn of(comptime n: u16) SegmentId {
        return .{ .value = n };
    }

    pub fn from(n: u16) SegmentId {
        return .{ .value = n };
    }

    pub fn eql(a: SegmentId, b: SegmentId) bool {
        return a.value == b.value;
    }

    comptime {
        std.debug.assert(@bitSizeOf(SegmentId) == 16);
    }
};

pub const VendorId = struct {
    value: u16,

    /// Spec-mandated absent-function marker. A vendor id of `0xFFFF`
    /// reported by hardware means "no function present at this BDF".
    pub const absent: VendorId = .{ .value = 0xFFFF };

    pub fn of(comptime n: u16) VendorId {
        return .{ .value = n };
    }

    pub fn from(n: u16) VendorId {
        return .{ .value = n };
    }

    pub fn eql(a: VendorId, b: VendorId) bool {
        return a.value == b.value;
    }

    pub fn isAbsent(self: VendorId) bool {
        return self.value == 0xFFFF;
    }
};

pub const DeviceId = struct {
    value: u16,

    pub fn of(comptime n: u16) DeviceId {
        return .{ .value = n };
    }

    pub fn from(n: u16) DeviceId {
        return .{ .value = n };
    }

    pub fn eql(a: DeviceId, b: DeviceId) bool {
        return a.value == b.value;
    }
};

pub const RevisionId = struct {
    value: u8,

    pub fn of(comptime n: u8) RevisionId {
        return .{ .value = n };
    }

    pub fn from(n: u8) RevisionId {
        return .{ .value = n };
    }

    pub fn eql(a: RevisionId, b: RevisionId) bool {
        return a.value == b.value;
    }
};

pub const BaseClass = extern struct {
    value: u8,

    pub const unclassified: BaseClass = .of(0x00);
    pub const mass_storage: BaseClass = .of(0x01);
    pub const network_controller: BaseClass = .of(0x02);
    pub const display_controller: BaseClass = .of(0x03);
    pub const multimedia_controller: BaseClass = .of(0x04);
    pub const memory_controller: BaseClass = .of(0x05);
    pub const bridge: BaseClass = .of(0x06);
    pub const simple_comm_controller: BaseClass = .of(0x07);
    pub const base_system_peripheral: BaseClass = .of(0x08);
    pub const input_device: BaseClass = .of(0x09);
    pub const docking_station: BaseClass = .of(0x0A);
    pub const processor: BaseClass = .of(0x0B);
    pub const serial_bus_controller: BaseClass = .of(0x0C);
    pub const wireless_controller: BaseClass = .of(0x0D);
    pub const intelligent_controller: BaseClass = .of(0x0E);
    pub const satellite_comm: BaseClass = .of(0x0F);
    pub const encryption_controller: BaseClass = .of(0x10);
    pub const signal_processing: BaseClass = .of(0x11);
    pub const processing_accelerator: BaseClass = .of(0x12);
    pub const non_essential_instr: BaseClass = .of(0x13);
    pub const coprocessor: BaseClass = .of(0x40);
    pub const unassigned: BaseClass = .of(0xFF);

    pub fn of(comptime n: u8) BaseClass {
        return .{ .value = n };
    }

    pub fn from(n: u8) BaseClass {
        return .{ .value = n };
    }

    pub fn eql(a: BaseClass, b: BaseClass) bool {
        return a.value == b.value;
    }

    comptime {
        std.debug.assert(@sizeOf(BaseClass) == 1);
        std.debug.assert(@alignOf(BaseClass) == 1);
    }
};

pub const Subclass = extern struct {
    value: u8,

    pub fn of(comptime n: u8) Subclass {
        return .{ .value = n };
    }

    pub fn from(n: u8) Subclass {
        return .{ .value = n };
    }

    pub fn eql(a: Subclass, b: Subclass) bool {
        return a.value == b.value;
    }

    comptime {
        std.debug.assert(@sizeOf(Subclass) == 1);
        std.debug.assert(@alignOf(Subclass) == 1);
    }
};

pub const ProgIf = extern struct {
    value: u8,

    pub fn of(comptime n: u8) ProgIf {
        return .{ .value = n };
    }

    pub fn from(n: u8) ProgIf {
        return .{ .value = n };
    }

    pub fn eql(a: ProgIf, b: ProgIf) bool {
        return a.value == b.value;
    }

    comptime {
        std.debug.assert(@sizeOf(ProgIf) == 1);
        std.debug.assert(@alignOf(ProgIf) == 1);
    }
};

/// PCI class code triple at configuration-space offsets 0x09..0x0C,
/// little-endian: prog_if at 0x09, subclass at 0x0A, base_class at 0x0B.
/// `@alignOf == 1`, so header decode may byte-cast a `*const u8` into
/// `*const ClassCode` without `@alignCast`.
pub const ClassCode = extern struct {
    prog_if: ProgIf,
    subclass: Subclass,
    base_class: BaseClass,

    pub const bridge: ClassCode = .of(0x06, 0x04, 0x00);
    pub const nvme: ClassCode = .of(0x01, 0x08, 0x02);
    pub const ahci: ClassCode = .of(0x01, 0x06, 0x01);
    pub const vga: ClassCode = .of(0x03, 0x00, 0x00);
    pub const xhci: ClassCode = .of(0x0C, 0x03, 0x30);
    pub const ehci: ClassCode = .of(0x0C, 0x03, 0x20);
    pub const uhci: ClassCode = .of(0x0C, 0x03, 0x00);

    /// Order: (base_class, subclass, prog_if) matching PCI-SIG assignment
    /// notation; wire layout stays prog-if-first.
    pub fn of(comptime base: u8, comptime sub: u8, comptime pif: u8) ClassCode {
        return .{
            .prog_if = ProgIf.of(pif),
            .subclass = Subclass.of(sub),
            .base_class = BaseClass.of(base),
        };
    }

    pub fn from(base: u8, sub: u8, pif: u8) ClassCode {
        return .{
            .prog_if = ProgIf.from(pif),
            .subclass = Subclass.from(sub),
            .base_class = BaseClass.from(base),
        };
    }

    pub fn eql(a: ClassCode, b: ClassCode) bool {
        return a.base_class.eql(b.base_class) and
            a.subclass.eql(b.subclass) and
            a.prog_if.eql(b.prog_if);
    }

    comptime {
        std.debug.assert(@sizeOf(ClassCode) == 3);
        std.debug.assert(@alignOf(ClassCode) == 1);
        std.debug.assert(@offsetOf(ClassCode, "prog_if") == 0);
        std.debug.assert(@offsetOf(ClassCode, "subclass") == 1);
        std.debug.assert(@offsetOf(ClassCode, "base_class") == 2);
    }
};
