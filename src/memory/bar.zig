//! BAR memory accessor.

/// Borrowed handle over backend-owned BAR memory.
pub const BarMemory = struct {
    context: *anyopaque,
    vtable: *const VTable,
    len: usize,

    pub const Error = error{
        BarMemoryOutOfBounds,
        UnalignedAccess,
    };

    pub const VTable = struct {
        read32: *const fn (context: *anyopaque, offset: usize) Error!u32,
        write32: *const fn (context: *anyopaque, offset: usize, value: u32) Error!void,
    };

    pub fn from(context: *anyopaque, vtable: *const VTable, len: usize) BarMemory {
        return .{
            .context = context,
            .vtable = vtable,
            .len = len,
        };
    }

    pub fn read32(self: BarMemory, offset: usize) Error!u32 {
        try self.check(offset);
        return self.vtable.read32(self.context, offset);
    }

    pub fn write32(self: BarMemory, offset: usize, value: u32) Error!void {
        try self.check(offset);
        return self.vtable.write32(self.context, offset, value);
    }

    fn check(self: BarMemory, offset: usize) Error!void {
        if (offset > self.len) {
            return error.BarMemoryOutOfBounds;
        }

        if (4 > self.len - offset) {
            return error.BarMemoryOutOfBounds;
        }

        if (offset % 4 != 0) {
            return error.UnalignedAccess;
        }
    }
};

pub const unit = struct {
    const std = @import("std");

    const testing = std.testing;

    const ValidationBackend = struct {
        bytes: []u8,
        calls: usize = 0,

        fn accessor(self: *ValidationBackend) BarMemory {
            return BarMemory.from(@ptrCast(self), &vtable, self.bytes.len);
        }

        const vtable: BarMemory.VTable = .{
            .read32 = read32,
            .write32 = write32,
        };

        fn read32(context: *anyopaque, offset: usize) BarMemory.Error!u32 {
            const self: *ValidationBackend = @ptrCast(@alignCast(context));
            self.calls += 1;

            return std.mem.readInt(u32, self.bytes[offset..][0..@sizeOf(u32)], .little);
        }

        fn write32(context: *anyopaque, offset: usize, value: u32) BarMemory.Error!void {
            const self: *ValidationBackend = @ptrCast(@alignCast(context));
            self.calls += 1;

            std.mem.writeInt(u32, self.bytes[offset..][0..@sizeOf(u32)], value, .little);
        }
    };

    test "read starting exactly at the end reports BarMemoryOutOfBounds" {
        var backing: [16]u8 = @splat(0);
        var backend: ValidationBackend = .{ .bytes = &backing };
        const table = backend.accessor();

        try testing.expectError(error.BarMemoryOutOfBounds, table.read32(backing.len));

        try testing.expectEqual(@as(usize, 0), backend.calls);
    }

    test "write past the region reports BarMemoryOutOfBounds" {
        var backing: [16]u8 = @splat(0);
        var backend: ValidationBackend = .{ .bytes = &backing };
        const table = backend.accessor();

        try testing.expectError(error.BarMemoryOutOfBounds, table.write32(backing.len, 0));
        try testing.expectError(
            error.BarMemoryOutOfBounds,
            table.write32(backing.len - 3, 0xAABBCCDD),
        );

        try testing.expectEqual(@as(usize, 0), backend.calls);
    }

    test "unaligned read of an in-region offset reports UnalignedAccess" {
        var backing: [16]u8 = @splat(0);
        var backend: ValidationBackend = .{ .bytes = &backing };
        const table = backend.accessor();

        try testing.expectError(error.UnalignedAccess, table.read32(1));
        try testing.expectError(error.UnalignedAccess, table.read32(2));
        try testing.expectError(error.UnalignedAccess, table.read32(3));

        try testing.expectEqual(@as(usize, 0), backend.calls);
    }

    test "unaligned write of an in-region offset reports UnalignedAccess" {
        var backing: [16]u8 = @splat(0);
        var backend: ValidationBackend = .{ .bytes = &backing };
        const table = backend.accessor();

        try testing.expectError(error.UnalignedAccess, table.write32(1, 0));
        try testing.expectError(error.UnalignedAccess, table.write32(2, 0));
        try testing.expectError(error.UnalignedAccess, table.write32(3, 0));

        try testing.expectEqual(@as(usize, 0), backend.calls);
    }

    test "containment beats alignment for end-of-region offsets" {
        var backing: [16]u8 = @splat(0);
        var backend: ValidationBackend = .{ .bytes = &backing };
        const table = backend.accessor();

        try testing.expectError(error.BarMemoryOutOfBounds, table.read32(13));

        try testing.expectEqual(@as(usize, 0), backend.calls);
    }

    test "zero-length region rejects any read or write" {
        var backing: [0]u8 = .{};
        var backend: ValidationBackend = .{ .bytes = &backing };
        const table = backend.accessor();

        try testing.expectError(error.BarMemoryOutOfBounds, table.read32(0));
        try testing.expectError(error.BarMemoryOutOfBounds, table.write32(0, 0));

        try testing.expectEqual(@as(usize, 0), backend.calls);
    }

    test "out-of-region and overflowing offsets do not reach the backend" {
        var backing: [16]u8 = @splat(0);
        var backend: ValidationBackend = .{ .bytes = &backing };
        const table = backend.accessor();

        for ([_]usize{ 17, std.math.maxInt(usize) }) |offset| {
            try testing.expectError(error.BarMemoryOutOfBounds, table.read32(offset));
            try testing.expectError(error.BarMemoryOutOfBounds, table.write32(offset, 0));
        }

        const full = BarMemory.from(
            @ptrCast(&backend),
            &ValidationBackend.vtable,
            std.math.maxInt(usize),
        );

        for ([_]usize{ std.math.maxInt(usize) - 3, std.math.maxInt(usize) }) |offset| {
            try testing.expectError(error.BarMemoryOutOfBounds, full.read32(offset));
            try testing.expectError(error.BarMemoryOutOfBounds, full.write32(offset, 0));
        }

        try testing.expectEqual(@as(usize, 0), backend.calls);
    }
};
