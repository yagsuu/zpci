const stdx = @import("stdx");

const BitField = stdx.bits.BitField;

pub const Capabilities = BitField(u32, .{
    .max_speed = .{ .type = MaxLinkSpeed, .access = .ro, .default = @as(MaxLinkSpeed, @enumFromInt(0)) },
    .max_width = .{ .type = MaxLinkWidth, .access = .ro, .default = @as(MaxLinkWidth, @enumFromInt(0)) },
    .aspm_support = .{ .type = AspmSupport, .access = .ro, .default = .disabled },
    .l0s_exit_latency = .{ .type = u3, .access = .ro },
    .l1_exit_latency = .{ .type = u3, .access = .ro },
    .clock_power_management = .{ .type = bool, .access = .ro },
    .surprise_down_error_reporting_capable = .{ .type = bool, .access = .ro },
    .data_link_layer_link_active_reporting_capable = .{ .type = bool, .access = .ro },
    .link_bandwidth_notification_capability = .{ .type = bool, .access = .ro },
    .aspm_optionality_compliance = .{ .type = bool, .access = .ro },
    ._rsvd_23 = .{ .type = u1, .access = .reserved },
    .port = .{ .type = u8, .access = .ro },
});

pub const Control = BitField(u16, .{
    .aspm = .{ .type = AspmControl, .default = .disabled },
    ._rsvd_2 = .{ .type = u1, .access = .reserved },
    .read_completion_boundary = bool,
    .disable = bool,
    .retrain = .{ .type = bool, .write = .trigger },
    .common_clock_configuration = bool,
    .extended_synch = bool,
    .clock_power_management_enable = bool,
    .hardware_autonomous_width_disable = bool,
    .link_bandwidth_management_interrupt_enable = bool,
    .link_autonomous_bandwidth_interrupt_enable = bool,
    ._rsvd_12 = .{ .type = u2, .access = .reserved },
    .drs_signaling_control = bool,
    ._rsvd_15 = .{ .type = u1, .access = .reserved },
});

pub const Status = BitField(u16, .{
    .speed = .{ .type = MaxLinkSpeed, .access = .ro, .default = @as(MaxLinkSpeed, @enumFromInt(0)) },
    .width = .{ .type = MaxLinkWidth, .access = .ro, .default = @as(MaxLinkWidth, @enumFromInt(0)) },
    ._undefined_10 = .{ .type = u1, .access = .ro },
    .training = .{ .type = bool, .access = .ro },
    .slot_clock_configuration = .{ .type = bool, .access = .ro },
    .data_link_layer_link_active = .{ .type = bool, .access = .ro },
    .link_bandwidth_management_status = .{ .type = bool, .write = .w1c },
    .link_autonomous_bandwidth_status = .{ .type = bool, .write = .w1c },
});

pub const Capabilities2 = BitField(u32, .{
    ._rsvd_0 = .{ .type = u1, .access = .reserved },
    .supported_speeds = .{ .type = u7, .access = .ro },
    .crosslink_supported = .{ .type = bool, .access = .ro },
    .lower_skp_os_generation_supported = .{ .type = u7, .access = .ro },
    .lower_skp_os_reception_supported = .{ .type = u7, .access = .ro },
    .retimer_presence_detect_supported = .{ .type = bool, .access = .ro },
    .two_retimers_presence_detect_supported = .{ .type = bool, .access = .ro },
    ._rsvd_25 = .{ .type = u6, .access = .reserved },
    .drs_supported = .{ .type = bool, .access = .ro },
});

pub const Control2 = BitField(u16, .{
    .target_speed = .{ .type = MaxLinkSpeed, .default = @as(MaxLinkSpeed, @enumFromInt(0)) },
    .enter_compliance = bool,
    .hardware_autonomous_speed_disable = bool,
    .selectable_deemphasis = bool,
    .transmit_margin = u3,
    .enter_modified_compliance = bool,
    .compliance_sos = bool,
    .compliance_preset_or_deemphasis = u4,
});

pub const Status2 = BitField(u16, .{
    .current_deemphasis_level = .{ .type = bool, .access = .ro },
    .equalization_8gt_complete = .{ .type = bool, .access = .ro },
    .equalization_8gt_phase1_successful = .{ .type = bool, .access = .ro },
    .equalization_8gt_phase2_successful = .{ .type = bool, .access = .ro },
    .equalization_8gt_phase3_successful = .{ .type = bool, .access = .ro },
    .link_equalization_request_8gt = .{ .type = bool, .write = .w1c },
    .retimer_presence_detected = .{ .type = bool, .access = .ro },
    .two_retimers_presence_detected = .{ .type = bool, .access = .ro },
    .crosslink_resolution = .{ .type = u2, .access = .ro },
    ._rsvd_10 = .{ .type = u2, .access = .reserved },
    .downstream_component_presence = .{ .type = u3, .access = .ro },
    .drs_message_received = .{ .type = bool, .write = .w1c },
});

pub const MaxLinkSpeed = enum(u4) {
    gen1 = 0x1,
    gen2 = 0x2,
    gen3 = 0x3,
    gen4 = 0x4,
    gen5 = 0x5,
    gen6 = 0x6,
    _,

    pub fn megaTransfersPerSecond(self: MaxLinkSpeed) error{MalformedField}!u32 {
        return switch (self) {
            .gen1 => 2500,
            .gen2 => 5000,
            .gen3 => 8000,
            .gen4 => 16000,
            .gen5 => 32000,
            .gen6 => 64000,
            _ => error.MalformedField,
        };
    }
};

pub const MaxLinkWidth = enum(u6) {
    x1 = 1,
    x2 = 2,
    x4 = 4,
    x8 = 8,
    x12 = 12,
    x16 = 16,
    x32 = 32,
    _,

    pub fn lanes(self: MaxLinkWidth) error{MalformedField}!u6 {
        return switch (self) {
            .x1 => 1,
            .x2 => 2,
            .x4 => 4,
            .x8 => 8,
            .x12 => 12,
            .x16 => 16,
            .x32 => 32,
            _ => error.MalformedField,
        };
    }
};

pub const AspmSupport = enum(u2) {
    disabled = 0,
    l0s = 1,
    l1 = 2,
    l0s_l1 = 3,
};

pub const AspmControl = enum(u2) {
    disabled = 0,
    l0s = 1,
    l1 = 2,
    l0s_l1 = 3,
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x0C;
    pub const control: u8 = 0x10;
    pub const status: u8 = 0x12;
    pub const capabilities_2: u8 = 0x2C;
    pub const control_2: u8 = 0x30;
    pub const status_2: u8 = 0x32;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "register bit positions" {
        try testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(Capabilities.Word, "max_width"));
        try testing.expectEqual(@as(comptime_int, 10), @bitOffsetOf(Capabilities.Word, "aspm_support"));
        try testing.expectEqual(@as(comptime_int, 24), @bitOffsetOf(Capabilities.Word, "port"));
        try testing.expectEqual(@as(comptime_int, 14), @bitOffsetOf(Control.Word, "drs_signaling_control"));
        try testing.expectEqual(
            @as(comptime_int, 14),
            @bitOffsetOf(Status.Word, "link_bandwidth_management_status"),
        );
        try testing.expectEqual(
            @as(comptime_int, 15),
            @bitOffsetOf(Status.Word, "link_autonomous_bandwidth_status"),
        );
        try testing.expectEqual(
            @as(comptime_int, 1),
            @bitOffsetOf(Capabilities2.Word, "supported_speeds"),
        );
        try testing.expectEqual(@as(comptime_int, 25), @bitOffsetOf(Capabilities2.Word, "_rsvd_25"));
        try testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Control2.Word, "target_speed"));
        try testing.expectEqual(
            @as(comptime_int, 12),
            @bitOffsetOf(Control2.Word, "compliance_preset_or_deemphasis"),
        );
        try testing.expectEqual(
            @as(comptime_int, 5),
            @bitOffsetOf(Status2.Word, "link_equalization_request_8gt"),
        );
        try testing.expectEqual(@as(comptime_int, 15), @bitOffsetOf(Status2.Word, "drs_message_received"));
    }

    test "enum helpers map named encodings and reject reserved encodings" {
        try expectLinkSpeed(.gen1, 2500);
        try expectLinkSpeed(.gen2, 5000);
        try expectLinkSpeed(.gen3, 8000);
        try expectLinkSpeed(.gen4, 16000);
        try expectLinkSpeed(.gen5, 32000);
        try expectLinkSpeed(.gen6, 64000);
        try testing.expectError(
            error.MalformedField,
            (@as(MaxLinkSpeed, @enumFromInt(0))).megaTransfersPerSecond(),
        );
        try testing.expectError(
            error.MalformedField,
            (@as(MaxLinkSpeed, @enumFromInt(7))).megaTransfersPerSecond(),
        );
        try testing.expectError(
            error.MalformedField,
            (@as(MaxLinkSpeed, @enumFromInt(15))).megaTransfersPerSecond(),
        );

        try expectLinkWidth(.x1, 1);
        try expectLinkWidth(.x2, 2);
        try expectLinkWidth(.x4, 4);
        try expectLinkWidth(.x8, 8);
        try expectLinkWidth(.x12, 12);
        try expectLinkWidth(.x16, 16);
        try expectLinkWidth(.x32, 32);
        try testing.expectError(error.MalformedField, (@as(MaxLinkWidth, @enumFromInt(0))).lanes());
        try testing.expectError(error.MalformedField, (@as(MaxLinkWidth, @enumFromInt(3))).lanes());
        try testing.expectError(error.MalformedField, (@as(MaxLinkWidth, @enumFromInt(63))).lanes());
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Capabilities, 0, 0, 0, 0x0080_0000 },
            .{ Control, 0x4FDB, 0, 0x0020, 0xB004 },
            .{ Status, 0, 0xC000, 0, 0 },
            .{ Capabilities2, 0, 0, 0, 0x7E00_0001 },
            .{ Control2, 0xFFFF, 0, 0, 0 },
            .{ Status2, 0, 0x8020, 0, 0x0C00 },
        }) |case| {
            const T = case[0];
            const Raw = @TypeOf(T.masks.assign);

            try testing.expectEqual(@as(Raw, case[1]), T.masks.assign);
            try testing.expectEqual(@as(Raw, case[2]), T.masks.w1c);
            try testing.expectEqual(@as(Raw, case[3]), T.masks.trigger);
            try testing.expectEqual(@as(Raw, case[4]), T.masks.reserved);
        }
    }

    fn expectLinkSpeed(value: MaxLinkSpeed, expected: u32) !void {
        try testing.expectEqual(expected, try value.megaTransfersPerSecond());
    }

    fn expectLinkWidth(value: MaxLinkWidth, expected: u6) !void {
        try testing.expectEqual(expected, try value.lanes());
    }
};
