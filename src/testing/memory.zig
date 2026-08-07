//! BAR-memory test support. Spec: docs/specs/memory/bar.md §Testing `TestBarMemory`.

const std = @import("std");

const memory = @import("../memory.zig");

const BarMemory = memory.BarMemory;

/// Byte-backed host-test backend for `BarMemory`.
pub const TestBarMemory = struct {
    bytes: []u8,

    pub fn accessor(self: *TestBarMemory) BarMemory {
        return BarMemory.init(@ptrCast(self), &vtable, self.bytes.len);
    }

    const vtable: BarMemory.VTable = .{
        .read32 = read32,
        .write32 = write32,
    };

    fn read32(context: *anyopaque, offset: usize) BarMemory.Error!u32 {
        const self: *TestBarMemory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or self.bytes.len - offset < @sizeOf(u32)) return error.BarMemoryOutOfBounds;
        return std.mem.readInt(u32, self.bytes[offset..][0..@sizeOf(u32)], .little);
    }

    fn write32(context: *anyopaque, offset: usize, value: u32) BarMemory.Error!void {
        const self: *TestBarMemory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or self.bytes.len - offset < @sizeOf(u32)) return error.BarMemoryOutOfBounds;
        std.mem.writeInt(u32, self.bytes[offset..][0..@sizeOf(u32)], value, .little);
    }
};
