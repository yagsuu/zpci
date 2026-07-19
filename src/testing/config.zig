//! Config-space test support. Spec: docs/specs/config/accessor.md §Testing `TestConfigSpace`.

const std = @import("std");

const stdx = @import("stdx");

const config = @import("../config.zig");
const core = @import("../core.zig");

const ConfigSpace = config.ConfigSpace;
const Sbdf = core.Sbdf;

const pcie_window_size: usize = 0x1000;

/// Byte-backed host-test backend for `ConfigSpace`.
pub const TestConfigSpace = struct {
    backing: Backing,

    pub const Entry = struct {
        sbdf: Sbdf,
        bytes: []u8,
    };

    const Backing = union(enum) {
        single: Entry,
        multi: []Entry,
    };

    pub fn initSingle(sbdf: Sbdf, bytes: []u8) TestConfigSpace {
        std.debug.assert(bytes.len == pcie_window_size);
        return .{ .backing = .{ .single = .{ .sbdf = sbdf, .bytes = bytes } } };
    }

    pub fn init(entries: []Entry) TestConfigSpace {
        for (entries) |entry| std.debug.assert(entry.bytes.len == pcie_window_size);
        return .{ .backing = .{ .multi = entries } };
    }

    pub fn configSpace(self: *TestConfigSpace) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    fn functionBytes(self: *TestConfigSpace, sbdf: Sbdf) ?[]u8 {
        switch (self.backing) {
            .single => |entry| {
                if (entry.sbdf.eql(sbdf)) return entry.bytes;
            },
            .multi => |entries| {
                for (entries) |entry| {
                    if (entry.sbdf.eql(sbdf)) return entry.bytes;
                }
            },
        }

        return null;
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
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFF;
        return bytes[offset];
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u16 {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFFFF;
        const wrapped = stdx.bytes.load(stdx.layout.Le(u16), bytes, offset) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
        return wrapped.native();
    }

    fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u32 {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return 0xFFFF_FFFF;
        const wrapped = stdx.bytes.load(stdx.layout.Le(u32), bytes, offset) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
        return wrapped.native();
    }

    fn write8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigSpace.Error!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        bytes[offset] = value;
    }

    fn write16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigSpace.Error!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        const encoded = stdx.layout.Le(u16).fromNative(value);
        stdx.bytes.store(stdx.layout.Le(u16), bytes, offset, encoded) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
    }

    fn write32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigSpace.Error!void {
        const self: *TestConfigSpace = @ptrCast(@alignCast(context));
        const bytes = self.functionBytes(sbdf) orelse return;
        const encoded = stdx.layout.Le(u32).fromNative(value);
        stdx.bytes.store(stdx.layout.Le(u32), bytes, offset, encoded) catch |err| switch (err) {
            error.EndOfStream => return error.OutOfBounds,
        };
    }
};
