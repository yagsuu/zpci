//! PIO config-space backend. Spec: docs/specs/config/pio.md.

const builtin = @import("builtin");

const stdx = @import("stdx");

const accessor = @import("accessor.zig");
const core = @import("../core.zig");

const ConfigSpace = accessor.ConfigSpace;
const Port = stdx.arch.x86_64.Port;
const Sbdf = core.Sbdf;

const pio_supported = builtin.cpu.arch == .x86_64;

pub const config_address_port = Port.fromInt(0xCF8);
pub const config_data_port_base = Port.fromInt(0xCFC);
pub const pci_window_size: usize = 0x100;
pub const supported_segment = core.SegmentId.from(0);

pub const Pio = struct {
    pub fn init() Pio {
        return .{};
    }

    pub fn configSpace(self: *Pio) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn read8(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u8 {
        _ = context;
        try checkAccess(sbdf, offset, 1);
        if (comptime !pio_supported) return error.UnsupportedAccessWidth;
        config_address_port.out32(configAddress(sbdf, offset));
        return dataPort(offset).in8();
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u16 {
        _ = context;
        try checkAccess(sbdf, offset, 2);
        if (comptime !pio_supported) return error.UnsupportedAccessWidth;
        config_address_port.out32(configAddress(sbdf, offset));
        return dataPort(offset).in16();
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u32 {
        _ = context;
        try checkAccess(sbdf, offset, 4);
        if (comptime !pio_supported) return error.UnsupportedAccessWidth;
        config_address_port.out32(configAddress(sbdf, offset));
        return dataPort(offset).in32();
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigSpace.Error!void {
        _ = context;
        try checkAccess(sbdf, offset, 1);
        if (comptime !pio_supported) return error.UnsupportedAccessWidth;
        config_address_port.out32(configAddress(sbdf, offset));
        dataPort(offset).out8(value);
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigSpace.Error!void {
        _ = context;
        try checkAccess(sbdf, offset, 2);
        if (comptime !pio_supported) return error.UnsupportedAccessWidth;
        config_address_port.out32(configAddress(sbdf, offset));
        dataPort(offset).out16(value);
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigSpace.Error!void {
        _ = context;
        try checkAccess(sbdf, offset, 4);
        if (comptime !pio_supported) return error.UnsupportedAccessWidth;
        config_address_port.out32(configAddress(sbdf, offset));
        dataPort(offset).out32(value);
    }
};

fn checkAccess(sbdf: Sbdf, offset: usize, width: usize) ConfigSpace.Error!void {
    if (!sbdf.segment.eql(supported_segment)) return error.OutOfBounds;
    if (offset > pci_window_size) return error.OutOfBounds;
    if (width > pci_window_size - offset) return error.OutOfBounds;
    if (width == 2 and offset % 2 != 0) return error.UnalignedAccess;
    if (width == 4 and offset % 4 != 0) return error.UnalignedAccess;
}

fn configAddress(sbdf: Sbdf, offset: usize) u32 {
    return 0x8000_0000 |
        (@as(u32, sbdf.bdf.bus) << 16) |
        (@as(u32, sbdf.bdf.device) << 11) |
        (@as(u32, sbdf.bdf.function) << 8) |
        @as(u32, @intCast(offset & 0xFC));
}

fn dataPort(offset: usize) Port {
    return Port.fromInt(config_data_port_base.raw() + @as(u16, @intCast(offset & 0x03)));
}

test "unit: PIO constants expose the conventional CF8/CFC ports and 256-byte window" {
    const testing = @import("std").testing;

    try testing.expectEqual(@as(u16, 0xCF8), config_address_port.raw());
    try testing.expectEqual(@as(u16, 0xCFC), config_data_port_base.raw());
    try testing.expectEqual(@as(usize, 0x100), pci_window_size);
    try testing.expect(supported_segment.eql(core.SegmentId.from(0)));
}

test "unit: PIO access checks enforce segment zero and the conventional config window" {
    const testing = @import("std").testing;
    const sbdf = Sbdf.of(0, 0x12, 0x1F, 7);

    try checkAccess(sbdf, 0x00, 1);
    try checkAccess(sbdf, 0xFE, 2);
    try checkAccess(sbdf, 0xFC, 4);

    try testing.expectError(error.OutOfBounds, checkAccess(Sbdf.of(1, 0x12, 0x1F, 7), 0x00, 1));
    try testing.expectError(error.OutOfBounds, checkAccess(sbdf, 0x100, 1));
    try testing.expectError(error.OutOfBounds, checkAccess(sbdf, 0xFF, 2));
    try testing.expectError(error.OutOfBounds, checkAccess(sbdf, 0xFD, 4));
    try testing.expectError(error.UnalignedAccess, checkAccess(sbdf, 0x01, 2));
    try testing.expectError(error.UnalignedAccess, checkAccess(sbdf, 0x02, 4));
}

test "unit: PIO CF8 address and CFC data port math follow conventional PCI config cycles" {
    const testing = @import("std").testing;
    const sbdf = Sbdf.of(0, 0x12, 0x1F, 7);

    try testing.expectEqual(
        @as(u32, 0x8000_0000 | (0x12 << 16) | (0x1F << 11) | (7 << 8) | 0xFC),
        configAddress(sbdf, 0xFF),
    );
    try testing.expectEqual(@as(u16, 0xCFC), dataPort(0x00).raw());
    try testing.expectEqual(@as(u16, 0xCFD), dataPort(0x01).raw());
    try testing.expectEqual(@as(u16, 0xCFE), dataPort(0x02).raw());
    try testing.expectEqual(@as(u16, 0xCFF), dataPort(0x03).raw());
    try testing.expectEqual(@as(u16, 0xCFF), dataPort(0xFF).raw());
}
