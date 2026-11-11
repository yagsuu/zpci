const stdx = @import("stdx");

const BitField = stdx.bits.BitField;

pub const Capabilities = BitField(u32, .{
    .attention_button_present = .{ .type = bool, .access = .ro },
    .power_controller_present = .{ .type = bool, .access = .ro },
    .mrl_sensor_present = .{ .type = bool, .access = .ro },
    .attention_indicator_present = .{ .type = bool, .access = .ro },
    .power_indicator_present = .{ .type = bool, .access = .ro },
    .hot_plug_surprise = .{ .type = bool, .access = .ro },
    .hot_plug_capable = .{ .type = bool, .access = .ro },
    .power_limit_value = .{ .type = u8, .access = .ro },
    .power_limit_scale = .{ .type = u2, .access = .ro },
    .electromechanical_interlock_present = .{ .type = bool, .access = .ro },
    .no_command_completed_support = .{ .type = bool, .access = .ro },
    .number = .{ .type = u13, .access = .ro },
});

pub const Control = BitField(u16, .{
    .attention_button_pressed_enable = bool,
    .power_fault_detected_enable = bool,
    .mrl_sensor_changed_enable = bool,
    .presence_detect_changed_enable = bool,
    .command_completed_interrupt_enable = bool,
    .hot_plug_interrupt_enable = bool,
    .attention_indicator = u2,
    .power_indicator = u2,
    .power_control = bool,
    .electromechanical_interlock_control = .{ .type = bool, .write = .trigger },
    .data_link_layer_state_changed_enable = bool,
    .auto_slot_power_limit_disable = bool,
    .in_band_pd_disable = bool,
    ._rsvd_15 = .{ .type = u1, .access = .reserved },
});

pub const Status = BitField(u16, .{
    .attention_button_pressed = .{ .type = bool, .write = .w1c },
    .power_fault_detected = .{ .type = bool, .write = .w1c },
    .mrl_sensor_changed = .{ .type = bool, .write = .w1c },
    .presence_detect_changed = .{ .type = bool, .write = .w1c },
    .command_completed = .{ .type = bool, .write = .w1c },
    .mrl_sensor_state = .{ .type = bool, .access = .ro },
    .presence_detect_state = .{ .type = bool, .access = .ro },
    .electromechanical_interlock_status = .{ .type = bool, .access = .ro },
    .data_link_layer_state_changed = .{ .type = bool, .write = .w1c },
    ._rsvd_9 = .{ .type = u7, .access = .reserved },
});

pub const Capabilities2 = BitField(u32, .{
    ._rsvd_0 = .{ .type = u1, .access = .reserved },
    .in_band_pd_disable_supported = .{ .type = bool, .access = .ro },
    ._rsvd_2 = .{ .type = u30, .access = .reserved },
});

pub const Control2 = BitField(u16, .{
    ._rsvd_0 = .{ .type = u16, .access = .reserved },
});

pub const Status2 = BitField(u16, .{
    ._rsvd_0 = .{ .type = u16, .access = .reserved },
});

pub const offsets = struct {
    pub const capabilities: u8 = 0x14;
    pub const control: u8 = 0x18;
    pub const status: u8 = 0x1A;
    pub const capabilities_2: u8 = 0x34;
    pub const control_2: u8 = 0x38;
    pub const status_2: u8 = 0x3A;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "register bit positions" {
        try testing.expectEqual(@as(comptime_int, 6), @bitOffsetOf(Control.Word, "attention_indicator"));
        try testing.expectEqual(
            @as(comptime_int, 12),
            @bitOffsetOf(Control.Word, "data_link_layer_state_changed_enable"),
        );
        try testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(Status.Word, "data_link_layer_state_changed"));
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Capabilities, 0, 0, 0, 0 },
            .{ Control, 0x77FF, 0, 0x0800, 0x8000 },
            .{ Status, 0, 0x011F, 0, 0xFE00 },
            .{ Capabilities2, 0, 0, 0, 0xFFFF_FFFD },
            .{ Control2, 0, 0, 0, 0xFFFF },
            .{ Status2, 0, 0, 0, 0xFFFF },
        }) |case| {
            const T = case[0];
            const Raw = @TypeOf(T.masks.assign);

            try testing.expectEqual(@as(Raw, case[1]), T.masks.assign);
            try testing.expectEqual(@as(Raw, case[2]), T.masks.w1c);
            try testing.expectEqual(@as(Raw, case[3]), T.masks.trigger);
            try testing.expectEqual(@as(Raw, case[4]), T.masks.reserved);
        }
    }

    test "field mask includes the full reserved status register" {
        try testing.expectEqual(@as(u16, 0xFFFF), Status2.mask(.{._rsvd_0}));
    }
};
