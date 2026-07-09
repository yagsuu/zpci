//! BAR-memory test support. Spec: docs/specs/memory/bar.md §Testing `TestBarMemory`.

const stdx = @import("stdx");

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
        const wrapped = stdx.bytes.load(stdx.layout.Le(u32), self.bytes, offset) catch |err| switch (err) {
            error.EndOfStream => return error.BarMemoryOutOfBounds,
        };
        return wrapped.native();
    }

    fn write32(context: *anyopaque, offset: usize, value: u32) BarMemory.Error!void {
        const self: *TestBarMemory = @ptrCast(@alignCast(context));
        const encoded = stdx.layout.Le(u32).fromNative(value);
        stdx.bytes.store(stdx.layout.Le(u32), self.bytes, offset, encoded) catch |err| switch (err) {
            error.EndOfStream => return error.BarMemoryOutOfBounds,
        };
    }
};
