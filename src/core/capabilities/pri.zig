const stdx = @import("stdx");

const extended = @import("extended.zig");

const BitFieldExt = stdx.bits.BitFieldExt;

pub const id: extended.Id = .pri;

pub const Control = BitFieldExt(u16, .{
    .enable = bool,
    .reset = .{ .type = bool, .write = .trigger },
}, .{ .unnamed = .reserved });

pub const Status = BitFieldExt(u16, .{
    .response_failure = .{ .type = bool, .write = .w1c },
    .unexpected_prg = .{ .type = bool, .write = .w1c },
    .stopped = .{ .offset = 8, .type = bool, .access = .ro, .default = true },
    .response_pasid_required = .{ .offset = 15, .type = bool, .access = .ro },
}, .{ .unnamed = .reserved });

pub const offsets = struct {
    pub const control: u8 = 0x04;
    pub const status: u8 = 0x06;
    pub const request_capacity: u8 = 0x08;
    pub const request_allocation: u8 = 0x0C;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "PRI fields match PCI positions and access classes" {
        try testing.expectEqual(@as(u16, 0x0001), Control.mask(.{.enable}));
        try testing.expectEqual(@as(u16, 0x0002), Control.mask(.{.reset}));
        try testing.expectEqual(@as(u16, 0x0001), Control.masks.assign);
        try testing.expectEqual(@as(u16, 0x0002), Control.masks.trigger);
        try testing.expectEqual(@as(u16, 0xFFFC), Control.masks.reserved);

        inline for (.{
            .{ .response_failure, 0x0001 },
            .{ .unexpected_prg, 0x0002 },
            .{ .stopped, 0x0100 },
            .{ .response_pasid_required, 0x8000 },
        }) |case| {
            try testing.expectEqual(@as(u16, case[1]), Status.mask(.{case[0]}));
        }

        try testing.expectEqual(@as(u16, 0x0100), Status.encode(.{}));
        try testing.expectEqual(@as(u16, 0x0003), Status.masks.w1c);
        try testing.expectEqual(@as(u16, 0), Status.masks.assign | Status.masks.trigger);
        try testing.expectEqual(@as(u16, 0x7EFC), Status.masks.reserved);
    }
};
