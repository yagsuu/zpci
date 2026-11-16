const std = @import("std");
const stdx = @import("stdx");

const extended = @import("extended.zig");

const BitFieldExt = stdx.bits.BitFieldExt;

pub const id: extended.Id = .ari;

pub const Capabilities = BitFieldExt(u16, .{
    .mfvc_groups = .{ .type = bool, .access = .ro },
    .acs_groups = .{ .type = bool, .access = .ro },
    .next_function = .{ .offset = 8, .type = u8, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control = BitFieldExt(u16, .{
    .mfvc_groups_enable = bool,
    .acs_groups_enable = bool,
    .function_group = .{ .offset = 4, .type = u3 },
}, .{ .unnamed = .reserved });

pub const offsets = struct {
    pub const capabilities: u8 = 0x04;
    pub const control: u8 = 0x06;
};

pub const unit = struct {
    const testing = std.testing;

    test "ARI capability fields match wire positions" {
        const caps = Capabilities.from(0xAD03);

        try testing.expect(caps.mfvc_groups);
        try testing.expect(caps.acs_groups);
        try testing.expectEqual(@as(u8, 0xAD), caps.next_function);
        try testing.expectEqual(@as(u16, 0), Capabilities.masks.assign);
        try testing.expectEqual(@as(u16, 0x00FC), Capabilities.masks.reserved);
    }

    test "ARI control fields and access policies exclude reserved bits" {
        const word = Control.from(0x0073);

        try testing.expect(word.mfvc_groups_enable);
        try testing.expect(word.acs_groups_enable);
        try testing.expectEqual(@as(u3, 7), word.function_group);
        try testing.expectEqual(@as(u16, 0x0073), Control.masks.assign);
        try testing.expectEqual(@as(u16, 0xFF8C), Control.masks.reserved);
        try testing.expectEqual(@as(u16, 0), Control.masks.w1c);
        try testing.expectEqual(@as(u16, 0), Control.masks.trigger);
    }
};
