const stdx = @import("stdx");

const pcie = @import("../pcie.zig");

const BitField = stdx.bits.BitField;
const BitFieldExt = stdx.bits.BitFieldExt;
const PowerLimitScale = pcie.PowerLimitScale;

pub const Capabilities = BitField(u32, .{
    .attention_button_present = .{ .type = bool, .access = .ro },
    .power_controller_present = .{ .type = bool, .access = .ro },
    .mrl_sensor_present = .{ .type = bool, .access = .ro },
    .attention_indicator_present = .{ .type = bool, .access = .ro },
    .power_indicator_present = .{ .type = bool, .access = .ro },
    .hot_plug_surprise = .{ .type = bool, .access = .ro },
    .hot_plug_capable = .{ .type = bool, .access = .ro },
    .power_limit = .{ .type = u8, .access = .ro },
    .power_scale = .{ .type = PowerLimitScale, .access = .ro, .default = .watts_1 },
    .interlock_present = .{ .type = bool, .access = .ro },
    .no_command_completed_support = .{ .type = bool, .access = .ro },
    .number = .{ .type = u13, .access = .ro },
});

pub const Control = BitFieldExt(u16, .{
    .attention_button_pressed_enable = bool,
    .power_fault_detected_enable = bool,
    .mrl_sensor_changed_enable = bool,
    .presence_detect_changed_enable = bool,
    .command_completed_intr_enable = bool,
    .hot_plug_intr_enable = bool,
    .attention_indicator = .{ .type = Indicator, .default = @as(Indicator, @enumFromInt(0)) },
    .power_indicator = .{ .type = Indicator, .default = @as(Indicator, @enumFromInt(0)) },
    .power_control = .{ .type = PowerControl, .default = .on },
    .interlock_control = .{ .type = bool, .write = .trigger },
    .dll_state_changed_enable = bool,
    .auto_slot_power_limit_disable = bool,
    .in_band_pd_disable = bool,
}, .{ .unnamed = .reserved });

pub const Status = BitFieldExt(u16, .{
    .attention_button_pressed = .{ .type = bool, .write = .w1c },
    .power_fault_detected = .{ .type = bool, .write = .w1c },
    .mrl_sensor_changed = .{ .type = bool, .write = .w1c },
    .presence_detect_changed = .{ .type = bool, .write = .w1c },
    .command_completed = .{ .type = bool, .write = .w1c },
    .mrl_sensor_state = .{ .type = bool, .access = .ro },
    .presence_detect_state = .{ .type = bool, .access = .ro },
    .interlock_status = .{ .type = bool, .access = .ro },
    .dll_state_changed = .{ .type = bool, .write = .w1c },
}, .{ .unnamed = .reserved });

pub const Capabilities2 = BitFieldExt(u32, .{
    .in_band_pd_disable_supported = .{ .type = bool, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control2 = BitFieldExt(u16, .{}, .{ .unnamed = .reserved });

pub const Status2 = BitFieldExt(u16, .{}, .{ .unnamed = .reserved });

pub const Indicator = enum(u2) {
    on = 1,
    blink = 2,
    off = 3,
    _,
};

pub const PowerControl = enum(u1) {
    on = 0,
    off = 1,
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x14;
    pub const control: u8 = 0x18;
    pub const status: u8 = 0x1A;
    pub const capabilities2: u8 = 0x34;
    pub const control2: u8 = 0x38;
    pub const status2: u8 = 0x3A;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "register bit positions" {
        try testing.expectEqual(@as(comptime_int, 6), @bitOffsetOf(Control.Word, "attention_indicator"));
        try testing.expectEqual(
            @as(comptime_int, 12),
            @bitOffsetOf(Control.Word, "dll_state_changed_enable"),
        );
        try testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(Status.Word, "dll_state_changed"));
    }

    test "slot controls encode indicator states and power polarity" {
        const word = Control.from(0x86C0);

        try testing.expectEqual(Indicator.off, word.attention_indicator);
        try testing.expectEqual(Indicator.blink, word.power_indicator);
        try testing.expectEqual(PowerControl.off, word.power_control);

        const updated = Control.replace(word, .{
            .attention_indicator = .on,
            .power_indicator = .off,
            .power_control = .on,
        });

        try testing.expectEqual(@as(u16, 0x8340), Control.raw(updated));
    }

    test "in-band presence disable support uses bit zero" {
        try testing.expect(Capabilities2.from(1).in_band_pd_disable_supported);
        try testing.expect(!Capabilities2.from(2).in_band_pd_disable_supported);
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Capabilities, 0, 0, 0, 0 },
            .{ Control, 0x77FF, 0, 0x0800, 0x8000 },
            .{ Status, 0, 0x011F, 0, 0xFE00 },
            .{ Capabilities2, 0, 0, 0, 0xFFFF_FFFE },
            .{ Control2, 0, 0, 0, 0xFFFF },
            .{ Status2, 0, 0, 0, 0xFFFF },
        }) |case| {
            const T = case[0];
            const Raw = @TypeOf(T.masks.assign);

            try testing.expectEqual(@as(Raw, case[1]), T.masks.assign);
            try testing.expectEqual(@as(Raw, case[2]), T.masks.w1c);
            try testing.expectEqual(@as(Raw, case[3]), T.masks.trigger);
            try testing.expectEqual(@as(Raw, case[4]), T.masks.reserved);
            try testing.expectEqual(@as(Raw, case[4]), T.raw(T.from(case[4])));
            try testing.expectEqual(@as(Raw, case[4]), T.raw(T.replace(T.from(case[4]), .{})));
            try testing.expectEqual(@as(Raw, 0), T.raw(T.default()) & T.masks.reserved);
            try testing.expectEqual(@as(Raw, 0), T.encode(.{}) & T.masks.reserved);
            try testing.expectEqual(~@as(Raw, 0), T.raw(T.from(~@as(Raw, 0))));
        }
    }

    test "empty schemas reserve entire control and status registers" {
        inline for (.{ Control2, Status2 }) |T| {
            try testing.expectEqual(@as(u16, 0xFFFF), T.masks.reserved);
            try testing.expectEqual(@as(u16, 0), T.mask(.{}));
            try testing.expectEqual(@as(u16, 0), T.encode(.{}));
            try testing.expectEqual(@as(u16, 0xA55A), T.raw(T.replace(T.from(0xA55A), .{})));
        }
    }
};
