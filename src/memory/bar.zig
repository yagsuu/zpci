//! BAR memory accessor. Spec: docs/specs/memory/bar.md.

const std = @import("std");

/// Borrowed handle over backend-owned BAR memory. Distinct from
/// `config.ConfigSpace`: MSI-X table and PBA writes go through this seam.
///
/// Non-allocating; never sleeps or blocks. Handle copies share the
/// backend context. Concurrency and memory ordering are backend-defined;
/// this type adds no synchronization. `context` and the backing storage
/// must outlive every copy of the handle.
pub const BarMemory = struct {
    context: *anyopaque,
    vtable: *const VTable,
    len_bytes: usize,

    pub const Error = error{
        BarMemoryOutOfBounds,
        UnalignedAccess,
    };

    pub const VTable = struct {
        read32: *const fn (context: *anyopaque, offset: usize) Error!u32,
        write32: *const fn (context: *anyopaque, offset: usize, value: u32) Error!void,
    };

    pub fn init(context: *anyopaque, vtable: *const VTable, len_bytes: usize) BarMemory {
        return .{ .context = context, .vtable = vtable, .len_bytes = len_bytes };
    }

    pub fn len(self: BarMemory) usize {
        return self.len_bytes;
    }

    /// Returns a native `u32` from the little-endian storage. Fails with
    /// `BarMemoryOutOfBounds` when the 4-byte window overruns `len()`
    /// and `UnalignedAccess` when `offset % 4 != 0`.
    pub fn read32(self: BarMemory, offset: usize) Error!u32 {
        try self.check(offset, 4);
        return self.vtable.read32(self.context, offset);
    }

    /// Encodes `value` little-endian into storage. Same validation and
    /// error mapping as `read32`. On error, storage is unchanged.
    pub fn write32(self: BarMemory, offset: usize, value: u32) Error!void {
        try self.check(offset, 4);
        return self.vtable.write32(self.context, offset, value);
    }

    /// Containment before alignment: `read32(len_bytes - 3)` yields
    /// `BarMemoryOutOfBounds`, not `UnalignedAccess`.
    fn check(self: BarMemory, offset: usize, width: usize) Error!void {
        std.debug.assert(width == 4);

        if (offset > self.len_bytes) return error.BarMemoryOutOfBounds;
        std.debug.assert(self.len_bytes >= offset);
        if (width > self.len_bytes - offset) return error.BarMemoryOutOfBounds;
        if (offset % width != 0) return error.UnalignedAccess;
    }
};
