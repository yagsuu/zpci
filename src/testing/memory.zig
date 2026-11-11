//! BAR-memory test support.

const std = @import("std");

const memory = @import("memory");

const BarMemory = memory.BarMemory;
const BarMemoryError = BarMemory.Error;

pub const TestBarMemory = struct {
    bytes: []u8,

    pub fn accessor(self: *TestBarMemory) BarMemory {
        return BarMemory.from(@ptrCast(self), &vtable, self.bytes.len);
    }

    const vtable: BarMemory.VTable = .{
        .read32 = read32,
        .write32 = write32,
    };

    fn read32(context: *anyopaque, offset: usize) BarMemoryError!u32 {
        const self: *TestBarMemory = @ptrCast(@alignCast(context));

        if (offset > self.bytes.len or self.bytes.len - offset < @sizeOf(u32)) {
            return error.BarMemoryOutOfBounds;
        }

        return std.mem.readInt(u32, self.bytes[offset..][0..@sizeOf(u32)], .little);
    }

    fn write32(context: *anyopaque, offset: usize, value: u32) BarMemoryError!void {
        const self: *TestBarMemory = @ptrCast(@alignCast(context));

        if (offset > self.bytes.len or self.bytes.len - offset < @sizeOf(u32)) {
            return error.BarMemoryOutOfBounds;
        }

        std.mem.writeInt(u32, self.bytes[offset..][0..@sizeOf(u32)], value, .little);
    }
};

pub const unit = struct {
    const testing = std.testing;

    test "read32 returns native integers from little-endian bytes" {
        var backing: [8]u8 = .{ 0xEF, 0xBE, 0xAD, 0xDE, 0x21, 0x00, 0x00, 0x00 };
        var backend: TestBarMemory = .{ .bytes = &backing };
        const table = backend.accessor();

        try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try table.read32(0));
        try testing.expectEqual(@as(u32, 0x0000_0021), try table.read32(4));
    }

    test "write32 encodes native integers as little-endian bytes" {
        var backing: [8]u8 = @splat(0);
        var backend: TestBarMemory = .{ .bytes = &backing };
        const table = backend.accessor();

        try table.write32(0, 0xFEE0_0000);
        try table.write32(4, 0x0000_0021);

        try testing.expectEqualSlices(
            u8,
            &.{ 0x00, 0x00, 0xE0, 0xFE, 0x21, 0x00, 0x00, 0x00 },
            &backing,
        );
    }

    test "aligned dword offsets remain independent across the buffer" {
        var backing: [16]u8 = @splat(0);
        var backend: TestBarMemory = .{ .bytes = &backing };
        const table = backend.accessor();

        const values = [_]u32{ 0xDEAD_BEEF, 0x1234_5678, 0xFEE0_0000, 0x0000_0021 };
        inline for (values, 0..) |v, i| {
            try table.write32(i * 4, v);
        }

        inline for (values, 0..) |v, i| {
            try testing.expectEqual(v, try table.read32(i * 4));
        }
    }
};
