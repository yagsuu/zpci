//! PCI identifier newtypes. Spec: docs/specs/core/ids.md.

const std = @import("std");

pub const SegmentId = enum(u16) {
    _,

    pub fn of(comptime n: u16) SegmentId {
        return @enumFromInt(n);
    }

    pub fn from(n: u16) SegmentId {
        return @enumFromInt(n);
    }

    pub fn eql(a: SegmentId, b: SegmentId) bool {
        return a == b;
    }

    comptime {
        std.debug.assert(@bitSizeOf(SegmentId) == 16);
    }
};

pub const VendorId = enum(u16) {
    _,

    /// PCI absent-function marker (0xFFFF).
    pub const absent: VendorId = @enumFromInt(0xFFFF);

    pub fn of(comptime n: u16) VendorId {
        return @enumFromInt(n);
    }

    pub fn from(n: u16) VendorId {
        return @enumFromInt(n);
    }

    pub fn eql(a: VendorId, b: VendorId) bool {
        return a == b;
    }

    pub fn isAbsent(self: VendorId) bool {
        return self == absent;
    }
};

pub const DeviceId = enum(u16) {
    _,

    pub fn of(comptime n: u16) DeviceId {
        return @enumFromInt(n);
    }

    pub fn from(n: u16) DeviceId {
        return @enumFromInt(n);
    }

    pub fn eql(a: DeviceId, b: DeviceId) bool {
        return a == b;
    }
};

pub const RevisionId = enum(u8) {
    _,

    pub fn of(comptime n: u8) RevisionId {
        return @enumFromInt(n);
    }

    pub fn from(n: u8) RevisionId {
        return @enumFromInt(n);
    }

    pub fn eql(a: RevisionId, b: RevisionId) bool {
        return a == b;
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

    pub fn of(comptime n: u8) BaseClass {
        return @enumFromInt(n);
    }

    pub fn from(n: u8) BaseClass {
        return @enumFromInt(n);
    }

    pub fn eql(a: BaseClass, b: BaseClass) bool {
        return a == b;
    }
};

pub const Subclass = enum(u8) {
    _,

    pub fn of(comptime n: u8) Subclass {
        return @enumFromInt(n);
    }

    pub fn from(n: u8) Subclass {
        return @enumFromInt(n);
    }

    pub fn eql(a: Subclass, b: Subclass) bool {
        return a == b;
    }
};

pub const ProgIf = enum(u8) {
    _,

    pub fn of(comptime n: u8) ProgIf {
        return @enumFromInt(n);
    }

    pub fn from(n: u8) ProgIf {
        return @enumFromInt(n);
    }

    pub fn eql(a: ProgIf, b: ProgIf) bool {
        return a == b;
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
