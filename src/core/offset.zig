//! Width-specific configuration-space access offsets.

const config = @import("config.zig");

pub fn Offset(comptime T: type) type {
    if (T != u8 and T != u16 and T != u32) {
        @compileError("configuration offsets require u8, u16, or u32");
    }

    return enum(u12) {
        _,

        const Self = @This();

        pub const Int = T;
        pub const Error = error{ OutOfBounds, UnalignedAccess };

        pub fn from(offset: usize) Self {
            return tryFrom(offset) catch unreachable;
        }

        pub fn tryFrom(offset: usize) Error!Self {
            if (offset > config.extended_size - @sizeOf(T)) {
                return error.OutOfBounds;
            }

            if (offset % @sizeOf(T) != 0) {
                return error.UnalignedAccess;
            }

            return @enumFromInt(offset);
        }

        pub fn raw(self: Self) usize {
            return @intFromEnum(self);
        }
    };
}

pub fn RelativeOffset(comptime T: type) type {
    if (T != u8 and T != u16 and T != u32) {
        @compileError("configuration offsets require u8, u16, or u32");
    }

    return enum(u12) {
        _,

        const Self = @This();

        pub const Int = T;
        pub const Error = error{ OutOfBounds, UnalignedAccess };

        pub fn from(offset: usize) Self {
            return tryFrom(offset) catch unreachable;
        }

        pub fn tryFrom(offset: usize) Error!Self {
            if (offset > config.extended_size - @sizeOf(T)) {
                return error.OutOfBounds;
            }

            if (offset % @sizeOf(T) != 0) {
                return error.UnalignedAccess;
            }

            return @enumFromInt(offset);
        }

        pub fn raw(self: Self) usize {
            return @intFromEnum(self);
        }
    };
}

pub const unit = struct {
    const std = @import("std");

    const testing = std.testing;

    test "offset construction accepts each aligned access within the config window" {
        inline for (.{ u8, u16, u32 }) |T| {
            var position: usize = 0;

            while (position <= config.extended_size - @sizeOf(T)) : (position += @sizeOf(T)) {
                inline for (.{ Offset(T), RelativeOffset(T) }) |O| {
                    try testing.expectEqual(position, O.from(position).raw());
                }
            }
        }
    }

    test "offset containment precedes alignment and rejects arithmetic overflow inputs" {
        inline for (.{ u8, u16, u32 }) |T| {
            inline for (.{ Offset(T), RelativeOffset(T) }) |O| {
                try testing.expectError(error.OutOfBounds, O.tryFrom(0x1000));
                try testing.expectError(error.OutOfBounds, O.tryFrom(std.math.maxInt(usize)));
            }
        }

        inline for (.{ Offset, RelativeOffset }) |O| {
            try testing.expectError(error.OutOfBounds, O(u16).tryFrom(0xFFF));
            try testing.expectError(error.OutOfBounds, O(u32).tryFrom(0xFFD));
            try testing.expectError(error.OutOfBounds, O(u32).tryFrom(0xFFF));
        }
    }

    test "offset construction rejects misalignment inside the config window" {
        inline for (.{ Offset, RelativeOffset }) |O| {
            try testing.expectError(error.UnalignedAccess, O(u16).tryFrom(1));
            try testing.expectError(error.UnalignedAccess, O(u16).tryFrom(0xFFD));

            for (1..4) |position| {
                try testing.expectError(error.UnalignedAccess, O(u32).tryFrom(position));
            }
        }
    }
};
