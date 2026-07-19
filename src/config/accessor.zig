//! Config-space accessor. Spec: docs/specs/config/accessor.md.

const std = @import("std");

const stdx = @import("stdx");

const core = @import("../core.zig");

const OffsetRange = stdx.core.Range(usize);

/// One PCIe function's configuration window is 4 KiB.
pub const pcie_window_size: usize = 0x1000;

/// Borrowed handle over backend-owned PCI configuration space. The only
/// public function-pointer seam for config-space I/O in zpci; views and
/// iterators carry this value plus an `Sbdf` and walk state.
///
/// Non-allocating; never sleeps or blocks. Handle copies share the
/// backend context. Concurrency and memory ordering are backend-defined;
/// this type adds no synchronization. `context` must outlive every copy.
pub const ConfigSpace = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        OutOfBounds,
        UnsupportedAccessWidth,
        UnalignedAccess,
    };

    pub const VTable = struct {
        read8: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize) Error!u8,
        read16: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize) Error!u16,
        read32: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize) Error!u32,
        write8: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize, value: u8) Error!void,
        write16: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize, value: u16) Error!void,
        write32: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize, value: u32) Error!void,
    };

    pub fn init(context: *anyopaque, vtable: *const VTable) ConfigSpace {
        return .{ .context = context, .vtable = vtable };
    }

    /// Native-endian `u8` from config space. Fails with `OutOfBounds`
    /// when `offset` lies outside `[0, 0x1000)` or `UnsupportedAccessWidth`
    /// when the backend cannot honor a 1-byte access at `offset`.
    pub fn read8(self: ConfigSpace, sbdf: core.Sbdf, offset: usize) Error!u8 {
        try validateAccess(offset, 1);
        return self.vtable.read8(self.context, sbdf, offset);
    }

    /// Native-endian `u16` from config space. Fails with `OutOfBounds`
    /// when the 2-byte window escapes `[0, 0x1000)`, `UnalignedAccess`
    /// when `offset % 2 != 0`, or `UnsupportedAccessWidth` when the
    /// backend cannot honor a 2-byte access at `offset`.
    pub fn read16(self: ConfigSpace, sbdf: core.Sbdf, offset: usize) Error!u16 {
        try validateAccess(offset, 2);
        return self.vtable.read16(self.context, sbdf, offset);
    }

    /// Native-endian `u32` from config space. Fails with `OutOfBounds`
    /// when the 4-byte window escapes `[0, 0x1000)`, `UnalignedAccess`
    /// when `offset % 4 != 0`, or `UnsupportedAccessWidth` when the
    /// backend cannot honor a 4-byte access at `offset`.
    pub fn read32(self: ConfigSpace, sbdf: core.Sbdf, offset: usize) Error!u32 {
        try validateAccess(offset, 4);
        return self.vtable.read32(self.context, sbdf, offset);
    }

    /// Native-endian `u8` write. Same validation and error mapping as
    /// `read8`; on error the backend leaves storage unchanged.
    pub fn write8(self: ConfigSpace, sbdf: core.Sbdf, offset: usize, value: u8) Error!void {
        try validateAccess(offset, 1);
        return self.vtable.write8(self.context, sbdf, offset, value);
    }

    /// Native-endian `u16` write. Same validation and error mapping as
    /// `read16`; on error the backend leaves storage unchanged.
    pub fn write16(self: ConfigSpace, sbdf: core.Sbdf, offset: usize, value: u16) Error!void {
        try validateAccess(offset, 2);
        return self.vtable.write16(self.context, sbdf, offset, value);
    }

    /// Native-endian `u32` write. Same validation and error mapping as
    /// `read32`; on error the backend leaves storage unchanged.
    pub fn write32(self: ConfigSpace, sbdf: core.Sbdf, offset: usize, value: u32) Error!void {
        try validateAccess(offset, 4);
        return self.vtable.write32(self.context, sbdf, offset, value);
    }
};

/// Validation order: containment inside the 4 KiB function window, then
/// natural width alignment. An access such as `read32(0xFFF)` yields
/// `OutOfBounds`, not `UnalignedAccess`.
fn validateAccess(offset: usize, width: usize) ConfigSpace.Error!void {
    std.debug.assert(width == 1 or width == 2 or width == 4);

    const window = OffsetRange.fromBounds(0, pcie_window_size) catch |err| switch (err) {
        // 0 <= pcie_window_size, so InvalidRange cannot fire.
        error.InvalidRange => unreachable,
    };
    const access = OffsetRange.fromStartLen(offset, width) catch return error.OutOfBounds;

    if (!window.containsRange(access)) return error.OutOfBounds;
    if (width == 2 and offset % 2 != 0) return error.UnalignedAccess;
    if (width == 4 and offset % 4 != 0) return error.UnalignedAccess;
}
