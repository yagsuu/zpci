const stdx = @import("stdx");

const extended = @import("extended.zig");

const BitField = stdx.bits.BitField;
const BitFieldExt = stdx.bits.BitFieldExt;

pub const id: extended.Id = .acs;

pub const Capabilities = BitField(u16, .{
    .source_validation = .{ .type = bool, .access = .ro },
    .translation_blocking = .{ .type = bool, .access = .ro },
    .p2p_request_redirect = .{ .type = bool, .access = .ro },
    .p2p_completion_redirect = .{ .type = bool, .access = .ro },
    .upstream_forwarding = .{ .type = bool, .access = .ro },
    .p2p_egress_control = .{ .type = bool, .access = .ro },
    .direct_translated_p2p = .{ .type = bool, .access = .ro },
    .enhanced = .{ .type = bool, .access = .ro },
    .egress_size = .{ .type = u8, .access = .ro },
});

pub const Control = BitFieldExt(u16, .{
    .source_validation_enable = bool,
    .translation_blocking_enable = bool,
    .p2p_request_redirect_enable = bool,
    .p2p_completion_redirect_enable = bool,
    .upstream_forwarding_enable = bool,
    .p2p_egress_control_enable = bool,
    .direct_translated_p2p_enable = bool,
    .io_request_blocking_enable = bool,
    .dsp_mem_access = .{ .type = MemoryAccess, .default = .direct },
    .usp_mem_access = .{ .type = MemoryAccess, .default = .direct },
    .unclaimed_request_redirect_enable = bool,
}, .{ .unnamed = .reserved });

pub const MemoryAccess = enum(u2) {
    direct = 0,
    block = 1,
    redirect = 2,
    _,
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x04;
    pub const control: u8 = 0x06;
    pub const egress: u8 = 0x08;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "ACS support fields match architectural bit positions" {
        inline for (.{
            .{ .source_validation, 0 },
            .{ .translation_blocking, 1 },
            .{ .p2p_request_redirect, 2 },
            .{ .p2p_completion_redirect, 3 },
            .{ .upstream_forwarding, 4 },
            .{ .p2p_egress_control, 5 },
            .{ .direct_translated_p2p, 6 },
            .{ .enhanced, 7 },
        }) |case| {
            try testing.expectEqual(@as(u16, 1) << case[1], Capabilities.mask(.{case[0]}));
        }

        const caps = Capabilities.from(0x2180);
        try testing.expectEqual(@as(u8, 33), caps.egress_size);
        try testing.expect(caps.enhanced);
        try testing.expectEqual(@as(u16, 0), Capabilities.masks.assign);
        try testing.expectEqual(@as(u16, 0), Capabilities.masks.reserved);
    }

    test "ACS controls and memory access modes match architectural encodings" {
        inline for (.{
            .{ .source_validation_enable, 0 },
            .{ .translation_blocking_enable, 1 },
            .{ .p2p_request_redirect_enable, 2 },
            .{ .p2p_completion_redirect_enable, 3 },
            .{ .upstream_forwarding_enable, 4 },
            .{ .p2p_egress_control_enable, 5 },
            .{ .direct_translated_p2p_enable, 6 },
            .{ .io_request_blocking_enable, 7 },
            .{ .unclaimed_request_redirect_enable, 12 },
        }) |case| {
            try testing.expectEqual(@as(u16, 1) << case[1], Control.mask(.{case[0]}));
        }

        try testing.expectEqual(@as(u16, 0x0300), Control.mask(.{.dsp_mem_access}));
        try testing.expectEqual(@as(u16, 0x0C00), Control.mask(.{.usp_mem_access}));
        try testing.expectEqual(@as(u2, 0), @intFromEnum(MemoryAccess.direct));
        try testing.expectEqual(@as(u2, 1), @intFromEnum(MemoryAccess.block));
        try testing.expectEqual(@as(u2, 2), @intFromEnum(MemoryAccess.redirect));
        try testing.expectEqual(@as(u16, 0), Control.encode(.{}));
        try testing.expectEqual(@as(u16, 0x1FFF), Control.masks.assign);
        try testing.expectEqual(@as(u16, 0xE000), Control.masks.reserved);
        try testing.expectEqual(@as(u16, 0), Control.masks.w1c | Control.masks.trigger);
    }
};
