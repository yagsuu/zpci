const stdx = @import("stdx");

const extended = @import("extended.zig");

const BitFieldExt = stdx.bits.BitFieldExt;

pub const id: extended.Id = .pasid;

pub const Capabilities = BitFieldExt(u16, .{
    .execute = .{ .offset = 1, .type = bool, .access = .ro },
    .privileged = .{ .type = bool, .access = .ro },
    .translated_requests = .{ .type = bool, .access = .ro },
    .max_width = .{ .offset = 8, .type = u5, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control = BitFieldExt(u16, .{
    .enable = bool,
    .execute_enable = bool,
    .privileged_enable = bool,
    .translated_requests_enable = bool,
}, .{ .unnamed = .reserved });

pub const offsets = struct {
    pub const capabilities: u8 = 0x04;
    pub const control: u8 = 0x06;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "PASID fields match PCI positions and access classes" {
        inline for (.{
            .{ .execute, 0x0002 },
            .{ .privileged, 0x0004 },
            .{ .translated_requests, 0x0008 },
            .{ .max_width, 0x1F00 },
        }) |case| {
            try testing.expectEqual(@as(u16, case[1]), Capabilities.mask(.{case[0]}));
        }

        inline for (.{
            .{ .enable, 0x0001 },
            .{ .execute_enable, 0x0002 },
            .{ .privileged_enable, 0x0004 },
            .{ .translated_requests_enable, 0x0008 },
        }) |case| {
            try testing.expectEqual(@as(u16, case[1]), Control.mask(.{case[0]}));
        }

        try testing.expectEqual(@as(u16, 0), Capabilities.masks.assign);
        try testing.expectEqual(@as(u16, 0xE0F1), Capabilities.masks.reserved);
        try testing.expectEqual(@as(u16, 0x000F), Control.masks.assign);
        try testing.expectEqual(@as(u16, 0xFFF0), Control.masks.reserved);
        try testing.expectEqual(@as(u16, 0), Control.masks.trigger | Control.masks.w1c);
        try testing.expectEqual(@as(u16, 0), Control.encode(.{}));
        try testing.expectEqual(@as(u5, 31), Capabilities.from(0x1F00).max_width);
    }
};
