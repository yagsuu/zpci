//! Configuration-space access.

const core = @import("core");

const Sbdf = core.Sbdf;
const Offset = core.Offset;

pub const ConfigSpace = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        OutOfBounds,
        UnsupportedAccessWidth,
        UnalignedAccess,
    };

    pub const VTable = struct {
        read8: *const fn (context: *anyopaque, sbdf: Sbdf, offset: usize) Error!u8,
        read16: *const fn (context: *anyopaque, sbdf: Sbdf, offset: usize) Error!u16,
        read32: *const fn (context: *anyopaque, sbdf: Sbdf, offset: usize) Error!u32,
        write8: *const fn (context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) Error!void,
        write16: *const fn (context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) Error!void,
        write32: *const fn (context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) Error!void,
    };

    pub fn from(context: *anyopaque, vtable: *const VTable) ConfigSpace {
        return .{
            .context = context,
            .vtable = vtable,
        };
    }

    pub fn read(self: ConfigSpace, sbdf: Sbdf, offset: anytype) Error!AccessInt(@TypeOf(offset)) {
        return switch (AccessInt(@TypeOf(offset))) {
            u8 => self.vtable.read8(self.context, sbdf, offset.raw()),
            u16 => self.vtable.read16(self.context, sbdf, offset.raw()),
            u32 => self.vtable.read32(self.context, sbdf, offset.raw()),
            else => unreachable,
        };
    }

    pub fn write(self: ConfigSpace, sbdf: Sbdf, offset: anytype, value: AccessInt(@TypeOf(offset))) Error!void {
        return switch (AccessInt(@TypeOf(offset))) {
            u8 => self.vtable.write8(self.context, sbdf, offset.raw(), value),
            u16 => self.vtable.write16(self.context, sbdf, offset.raw(), value),
            u32 => self.vtable.write32(self.context, sbdf, offset.raw(), value),
            else => unreachable,
        };
    }

    fn AccessInt(comptime O: type) type {
        return switch (O) {
            Offset(u8) => u8,
            Offset(u16) => u16,
            Offset(u32) => u32,
            else => @compileError("configuration access requires an absolute Offset"),
        };
    }
};

pub const unit = struct {
    const std = @import("std");

    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;

    const ConfigError = ConfigSpace.Error;

    const NoDwordConfig = struct {
        bytes: [pcie_window_size]u8 = @splat(0),

        fn config(self: *NoDwordConfig) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32Unsupported,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32Unsupported,
        };

        fn read8(context: *anyopaque, _: Sbdf, offset: usize) ConfigError!u8 {
            const self: *NoDwordConfig = @ptrCast(@alignCast(context));
            return self.bytes[offset];
        }

        fn read16(context: *anyopaque, _: Sbdf, offset: usize) ConfigError!u16 {
            const self: *NoDwordConfig = @ptrCast(@alignCast(context));
            return std.mem.readInt(u16, self.bytes[offset..][0..@sizeOf(u16)], .little);
        }

        fn read32Unsupported(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u32 {
            return error.UnsupportedAccessWidth;
        }

        fn write8(context: *anyopaque, _: Sbdf, offset: usize, value: u8) ConfigError!void {
            const self: *NoDwordConfig = @ptrCast(@alignCast(context));
            self.bytes[offset] = value;
        }

        fn write16(context: *anyopaque, _: Sbdf, offset: usize, value: u16) ConfigError!void {
            const self: *NoDwordConfig = @ptrCast(@alignCast(context));
            std.mem.writeInt(u16, self.bytes[offset..][0..@sizeOf(u16)], value, .little);
        }

        fn write32Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }
    };

    test "unsupported-width writes leave storage unchanged" {
        var backend = NoDwordConfig{ .bytes = @splat(0x5A) };
        const config = backend.config();
        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        const before = backend.bytes;
        const offset = Offset(u32).from(0x10);

        try testing.expectError(error.UnsupportedAccessWidth, config.write(sbdf, offset, 0xDEAD_BEEF));
        try testing.expectEqualSlices(u8, &before, &backend.bytes);
    }

    test "backend UnsupportedAccessWidth propagates for valid offsets" {
        var backend = NoDwordConfig{};
        const config = backend.config();
        const sbdf = Sbdf.from(.from(0), 0, 0, 0);
        const dword = Offset(u32).from(0x10);
        const byte = Offset(u8).from(0);
        const word = Offset(u16).from(2);

        try testing.expectError(error.UnsupportedAccessWidth, config.read(sbdf, dword));
        try testing.expectError(error.UnsupportedAccessWidth, config.write(sbdf, dword, 0));

        try config.write(sbdf, byte, 0x42);
        try config.write(sbdf, word, 0xBEEF);

        try testing.expectEqual(@as(u8, 0x42), try config.read(sbdf, byte));
        try testing.expectEqual(@as(u16, 0xBEEF), try config.read(sbdf, word));
    }
};
