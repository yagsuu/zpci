const stdx = @import("stdx");

const BitField = stdx.bits.BitField;

pub const Control = BitField(u16, .{
    .sys_error_on_correctable_enable = bool,
    .sys_error_on_non_fatal_enable = bool,
    .sys_error_on_fatal_enable = bool,
    .pme_interrupt_enable = bool,
    .crs_software_visibility_enable = bool,
    ._rsvd_5 = .{ .type = u11, .access = .reserved },
});

pub const Capabilities = BitField(u16, .{
    .crs_software_visibility = .{ .type = bool, .access = .ro },
    ._rsvd_1 = .{ .type = u15, .access = .reserved },
});

pub const Status = BitField(u32, .{
    .pme_requester_id = .{ .type = u16, .access = .ro },
    .pme_status = .{ .type = bool, .write = .w1c },
    .pme_pending = .{ .type = bool, .access = .ro },
    ._rsvd_18 = .{ .type = u14, .access = .reserved },
});

pub const offsets = struct {
    pub const control: u8 = 0x1C;
    pub const capabilities: u8 = 0x1E;
    pub const status: u8 = 0x20;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "register bit positions" {
        try testing.expectEqual(@as(comptime_int, 16), @bitOffsetOf(Status.Word, "pme_status"));
        try testing.expectEqual(@as(comptime_int, 17), @bitOffsetOf(Status.Word, "pme_pending"));
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Control, 0x001F, 0, 0, 0xFFE0 },
            .{ Capabilities, 0, 0, 0, 0xFFFE },
            .{ Status, 0, 0x0001_0000, 0, 0xFFFC_0000 },
        }) |case| {
            const T = case[0];
            const Raw = @TypeOf(T.masks.assign);

            try testing.expectEqual(@as(Raw, case[1]), T.masks.assign);
            try testing.expectEqual(@as(Raw, case[2]), T.masks.w1c);
            try testing.expectEqual(@as(Raw, case[3]), T.masks.trigger);
            try testing.expectEqual(@as(Raw, case[4]), T.masks.reserved);
        }
    }
};
