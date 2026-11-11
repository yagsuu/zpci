//! PIO configuration-space backend.

const builtin = @import("builtin");

const stdx = @import("stdx");

const accessor = @import("accessor.zig");
const core = @import("core");

const ConfigSpace = accessor.ConfigSpace;
const ConfigError = ConfigSpace.Error;

const SegmentId = core.SegmentId;
const Sbdf = core.Sbdf;
const Offset = core.Offset;
const Port = stdx.arch.x86_64.io.Port;

const supported = builtin.cpu.arch == .x86_64;

pub const Pio = struct {
    pub const address_port = Port.from(0xCF8);
    pub const data_port = Port.from(0xCFC);
    pub const segment = SegmentId.from(0);

    pub fn from() Pio {
        return .{};
    }

    pub fn config(self: *Pio) ConfigSpace {
        return ConfigSpace.from(@ptrCast(self), &vtable);
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn read8(_: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u8 {
        try checkAccess(sbdf, offset, 1);

        if (comptime !supported) {
            return error.UnsupportedAccessWidth;
        }

        const address = 0x8000_0000 | (@as(u32, sbdf.bdf.raw()) << 8) | @as(u32, @intCast(offset & 0xFC));
        const port = Port.from(data_port.raw() + @as(u16, @intCast(offset & 0x03)));

        address_port.out32(address);
        return port.in8();
    }

    fn read16(_: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u16 {
        try checkAccess(sbdf, offset, 2);

        if (comptime !supported) {
            return error.UnsupportedAccessWidth;
        }

        const address = 0x8000_0000 | (@as(u32, sbdf.bdf.raw()) << 8) | @as(u32, @intCast(offset & 0xFC));
        const port = Port.from(data_port.raw() + @as(u16, @intCast(offset & 0x03)));

        address_port.out32(address);
        return port.in16();
    }

    fn read32(_: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u32 {
        try checkAccess(sbdf, offset, 4);

        if (comptime !supported) {
            return error.UnsupportedAccessWidth;
        }

        const address = 0x8000_0000 | (@as(u32, sbdf.bdf.raw()) << 8) | @as(u32, @intCast(offset & 0xFC));

        address_port.out32(address);
        return data_port.in32();
    }

    fn write8(_: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigError!void {
        try checkAccess(sbdf, offset, 1);

        if (comptime !supported) {
            return error.UnsupportedAccessWidth;
        }

        const address = 0x8000_0000 | (@as(u32, sbdf.bdf.raw()) << 8) | @as(u32, @intCast(offset & 0xFC));
        const port = Port.from(data_port.raw() + @as(u16, @intCast(offset & 0x03)));

        address_port.out32(address);
        port.out8(value);
    }

    fn write16(_: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigError!void {
        try checkAccess(sbdf, offset, 2);

        if (comptime !supported) {
            return error.UnsupportedAccessWidth;
        }

        const address = 0x8000_0000 | (@as(u32, sbdf.bdf.raw()) << 8) | @as(u32, @intCast(offset & 0xFC));
        const port = Port.from(data_port.raw() + @as(u16, @intCast(offset & 0x03)));

        address_port.out32(address);
        port.out16(value);
    }

    fn write32(_: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigError!void {
        try checkAccess(sbdf, offset, 4);

        if (comptime !supported) {
            return error.UnsupportedAccessWidth;
        }

        const address = 0x8000_0000 | (@as(u32, sbdf.bdf.raw()) << 8) | @as(u32, @intCast(offset & 0xFC));

        address_port.out32(address);
        data_port.out32(value);
    }

    fn checkAccess(sbdf: Sbdf, offset: usize, width: usize) ConfigError!void {
        if (sbdf.segment != segment) {
            return error.OutOfBounds;
        }

        if (offset > core.config.size) {
            return error.OutOfBounds;
        }

        if (width > core.config.size - offset) {
            return error.OutOfBounds;
        }
    }
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "PIO rejects unsupported segments and extended accesses before port I/O" {
        var backend = Pio.from();
        const config = backend.config();
        const sbdf = Sbdf.from(.from(0), 0x12, 0x1F, 7);
        const absent_segment = Sbdf.from(.from(1), 0x12, 0x1F, 7);

        try testing.expectError(error.OutOfBounds, config.read(absent_segment, Offset(u8).from(0)));
        try testing.expectError(error.OutOfBounds, config.write(absent_segment, Offset(u16).from(0), 0));
        try testing.expectError(error.OutOfBounds, config.read(sbdf, Offset(u8).from(0x100)));
        try testing.expectError(error.OutOfBounds, config.read(sbdf, Offset(u16).from(0x100)));
        try testing.expectError(error.OutOfBounds, config.write(sbdf, Offset(u32).from(0x100), 0));
    }
};
