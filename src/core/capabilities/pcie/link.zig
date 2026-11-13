const stdx = @import("stdx");

const BitField = stdx.bits.BitField;
const BitFieldExt = stdx.bits.BitFieldExt;

pub const Capabilities = BitFieldExt(u32, .{
    .max_speed = .{ .type = LinkSpeed, .access = .ro, .default = @as(LinkSpeed, @enumFromInt(0)) },
    .max_width = .{ .type = LinkWidth, .access = .ro, .default = @as(LinkWidth, @enumFromInt(0)) },
    .aspm_support = .{ .type = AspmSupport, .access = .ro, .default = .unsupported },
    .l0s_exit_latency = .{ .type = L0sExitLatency, .access = .ro, .default = .below_64ns },
    .l1_exit_latency = .{ .type = L1ExitLatency, .access = .ro, .default = .below_1us },
    .clock_pm_supported = .{ .type = bool, .access = .ro },
    .surprise_down_report_capable = .{ .type = bool, .access = .ro },
    .dll_active_report_capable = .{ .type = bool, .access = .ro },
    .bw_notification_capable = .{ .type = bool, .access = .ro },
    .aspm_optionality_compliance = .{ .type = bool, .access = .ro },
    .port = .{ .offset = 24, .type = u8, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control = BitFieldExt(u16, .{
    .aspm = .{ .type = AspmControl, .default = .disabled },
    .read_completion_boundary = .{ .offset = 3, .type = ReadCompletionBoundary, .default = .bytes_64 },
    .disable = bool,
    .retrain = .{ .type = bool, .write = .trigger },
    .common_clock = bool,
    .ext_sync = bool,
    .clock_pm_enable = bool,
    .hw_auto_width_disable = bool,
    .bw_management_intr_enable = bool,
    .bw_autonomous_intr_enable = bool,
    .flit_mode_disable = .{ .offset = 13, .type = bool },
    .drs_signaling_control = bool,
}, .{ .unnamed = .reserved });

pub const Status = BitField(u16, .{
    .speed = .{ .type = LinkSpeed, .access = .ro, .default = @as(LinkSpeed, @enumFromInt(0)) },
    .width = .{ .type = LinkWidth, .access = .ro, .default = @as(LinkWidth, @enumFromInt(0)) },
    ._undefined_10 = .{ .type = u1, .access = .ro },
    .training = .{ .type = bool, .access = .ro },
    .slot_clock = .{ .type = bool, .access = .ro },
    .dll_active = .{ .type = bool, .access = .ro },
    .bw_management = .{ .type = bool, .write = .w1c },
    .bw_autonomous = .{ .type = bool, .write = .w1c },
});

pub const Capabilities2 = BitFieldExt(u32, .{
    .supported_speeds = .{ .offset = 1, .type = LinkSpeeds, .access = .ro, .default = LinkSpeeds.from(0) },
    .crosslink_supported = .{ .type = bool, .access = .ro },
    .lower_skp_os_generation_supported = .{ .type = u7, .access = .ro },
    .lower_skp_os_reception_supported = .{ .type = u7, .access = .ro },
    .retimer_detect_supported = .{ .type = bool, .access = .ro },
    .two_retimers_detect_supported = .{ .type = bool, .access = .ro },
    .drs_supported = .{ .offset = 31, .type = bool, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control2 = BitField(u16, .{
    .target_speed = .{ .type = LinkSpeed, .default = @as(LinkSpeed, @enumFromInt(0)) },
    .enter_compliance = bool,
    .hw_auto_speed_disable = bool,
    .deemphasis = .{ .type = Deemphasis, .default = .db_6 },
    .tx_margin = u3,
    .enter_modified_compliance = bool,
    .compliance_sos = bool,
    .compliance_preset_or_deemphasis = u4,
});

pub const Status2 = BitFieldExt(u16, .{
    .deemphasis = .{ .type = Deemphasis, .access = .ro, .default = .db_6 },
    .eq_8gt_complete = .{ .type = bool, .access = .ro },
    .eq_8gt_phase1_success = .{ .type = bool, .access = .ro },
    .eq_8gt_phase2_success = .{ .type = bool, .access = .ro },
    .eq_8gt_phase3_success = .{ .type = bool, .access = .ro },
    .eq_8gt_request = .{ .type = bool, .write = .w1c },
    .retimer_detected = .{ .type = bool, .access = .ro },
    .two_retimers_detected = .{ .type = bool, .access = .ro },
    .crosslink_resolution = .{ .type = CrosslinkResolution, .access = .ro, .default = .unsupported },
    .flit_mode = .{ .type = bool, .access = .ro },
    .downstream_component_presence = .{ .offset = 12, .type = DownstreamComponentPresence, .access = .ro, .default = .link_down_not_determined },
    .drs_received = .{ .type = bool, .write = .w1c },
}, .{ .unnamed = .reserved });

pub const LinkSpeed = enum(u4) {
    gen1 = 0x1,
    gen2 = 0x2,
    gen3 = 0x3,
    gen4 = 0x4,
    gen5 = 0x5,
    gen6 = 0x6,
    _,

    pub fn mtps(self: LinkSpeed) error{MalformedField}!u32 {
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

pub const LinkSpeeds = enum(u7) {
    gen1 = 0x01,
    gen2 = 0x02,
    gen3 = 0x04,
    gen4 = 0x08,
    gen5 = 0x10,
    gen6 = 0x20,
    gen7_plus = 0x40,
    _,

    pub const Generation = enum(u3) {
        gen1,
        gen2,
        gen3,
        gen4,
        gen5,
        gen6,
        gen7_plus,
    };

    pub fn from(bits: u7) LinkSpeeds {
        return @enumFromInt(bits);
    }

    pub fn raw(self: LinkSpeeds) u7 {
        return @intFromEnum(self);
    }

    pub fn supports(self: LinkSpeeds, generation: Generation) bool {
        const mask = @as(u7, 1) << @intFromEnum(generation);
        return self.raw() & mask != 0;
    }
};

pub const LinkWidth = enum(u6) {
    x1 = 1,
    x2 = 2,
    x4 = 4,
    x8 = 8,
    x12 = 12,
    x16 = 16,
    x32 = 32,
    _,

    pub fn lanes(self: LinkWidth) error{MalformedField}!u6 {
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
    unsupported = 0,
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

pub const L0sExitLatency = enum(u3) {
    below_64ns = 0,
    ns_64_128 = 1,
    ns_128_256 = 2,
    ns_256_512 = 3,
    ns_512_1000 = 4,
    us_1_2 = 5,
    us_2_4 = 6,
    above_4us = 7,
};

pub const L1ExitLatency = enum(u3) {
    below_1us = 0,
    us_1_2 = 1,
    us_2_4 = 2,
    us_4_8 = 3,
    us_8_16 = 4,
    us_16_32 = 5,
    us_32_64 = 6,
    above_64us = 7,
};

pub const ReadCompletionBoundary = enum(u1) {
    bytes_64 = 0,
    bytes_128 = 1,
};

pub const Deemphasis = enum(u1) {
    db_6 = 0,
    db_3_5 = 1,
};

pub const CrosslinkResolution = enum(u2) {
    unsupported = 0,
    upstream = 1,
    downstream = 2,
    incomplete = 3,
};

pub const DownstreamComponentPresence = enum(u3) {
    link_down_not_determined = 0,
    link_down_not_present = 1,
    link_down_present = 2,
    link_up_present = 4,
    link_up_present_drs_received = 5,
    _,
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x0C;
    pub const control: u8 = 0x10;
    pub const status: u8 = 0x12;
    pub const capabilities2: u8 = 0x2C;
    pub const control2: u8 = 0x30;
    pub const status2: u8 = 0x32;
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
            @bitOffsetOf(Status.Word, "bw_management"),
        );
        try testing.expectEqual(
            @as(comptime_int, 15),
            @bitOffsetOf(Status.Word, "bw_autonomous"),
        );
        try testing.expectEqual(
            @as(comptime_int, 1),
            @bitOffsetOf(Capabilities2.Word, "supported_speeds"),
        );
        try testing.expectEqual(@as(comptime_int, 31), @bitOffsetOf(Capabilities2.Word, "drs_supported"));
        try testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Control2.Word, "target_speed"));
        try testing.expectEqual(
            @as(comptime_int, 12),
            @bitOffsetOf(Control2.Word, "compliance_preset_or_deemphasis"),
        );
        try testing.expectEqual(
            @as(comptime_int, 5),
            @bitOffsetOf(Status2.Word, "eq_8gt_request"),
        );
        try testing.expectEqual(@as(comptime_int, 15), @bitOffsetOf(Status2.Word, "drs_received"));
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
            (@as(LinkSpeed, @enumFromInt(0))).mtps(),
        );

        try testing.expectError(
            error.MalformedField,
            (@as(LinkSpeed, @enumFromInt(7))).mtps(),
        );

        try testing.expectError(
            error.MalformedField,
            (@as(LinkSpeed, @enumFromInt(15))).mtps(),
        );

        try expectLinkWidth(.x1, 1);
        try expectLinkWidth(.x2, 2);
        try expectLinkWidth(.x4, 4);
        try expectLinkWidth(.x8, 8);
        try expectLinkWidth(.x12, 12);
        try expectLinkWidth(.x16, 16);
        try expectLinkWidth(.x32, 32);
        try testing.expectError(error.MalformedField, (@as(LinkWidth, @enumFromInt(0))).lanes());
        try testing.expectError(error.MalformedField, (@as(LinkWidth, @enumFromInt(3))).lanes());
        try testing.expectError(error.MalformedField, (@as(LinkWidth, @enumFromInt(63))).lanes());
    }

    test "supported speeds preserve sparse membership and register encoding" {
        const generations = [_]LinkSpeeds.Generation{
            .gen1, .gen2, .gen3, .gen4, .gen5, .gen6, .gen7_plus,
        };
        const masks = [_]u7{ 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40 };

        for (0..128) |bits| {
            const encoded: u7 = @intCast(bits);
            const speeds = LinkSpeeds.from(encoded);

            for (generations, masks) |generation, mask| {
                try testing.expectEqual(encoded & mask != 0, speeds.supports(generation));
            }

            const raw = (@as(u32, encoded) << 1) | 0x8000_0100;
            const capabilities = Capabilities2.from(raw);

            try testing.expectEqual(encoded, capabilities.supported_speeds.raw());
            try testing.expect(capabilities.crosslink_supported);
            try testing.expect(capabilities.drs_supported);
            try testing.expectEqual(raw, Capabilities2.raw(capabilities));
        }
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Capabilities, 0, 0, 0, 0x0080_0000 },
            .{ Control, 0x6FDB, 0, 0x0020, 0x9004 },
            .{ Status, 0, 0xC000, 0, 0 },
            .{ Capabilities2, 0, 0, 0, 0x7E00_0001 },
            .{ Control2, 0xFFFF, 0, 0, 0 },
            .{ Status2, 0, 0x8020, 0, 0x0800 },
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

    test "typed link choices preserve encodings and neighboring bits" {
        for (0..8) |encoding| {
            const raw: u32 = @intCast(encoding);
            const capabilities = Capabilities.from((raw << 12) | (raw << 15));

            try testing.expectEqual(raw, @intFromEnum(capabilities.l0s_exit_latency));
            try testing.expectEqual(raw, @intFromEnum(capabilities.l1_exit_latency));
            try testing.expectEqual((raw << 12) | (raw << 15), Capabilities.raw(capabilities));

            const status = Status2.from(@as(u16, @intCast(encoding)) << 12);

            try testing.expectEqual(encoding, @as(usize, @intFromEnum(status.downstream_component_presence)));
            try testing.expect(!status.flit_mode);
            try testing.expect(!status.drs_received);
        }

        try testing.expectEqual(L0sExitLatency.above_4us, Capabilities.from(7 << 12).l0s_exit_latency);
        try testing.expectEqual(L1ExitLatency.above_64us, Capabilities.from(7 << 15).l1_exit_latency);
    }

    test "link control choices decode units and crosslink roles" {
        try testing.expectEqual(AspmSupport.unsupported, Capabilities.from(0).aspm_support);
        try testing.expectEqual(ReadCompletionBoundary.bytes_128, Control.from(0x0008).read_completion_boundary);
        try testing.expectEqual(ReadCompletionBoundary.bytes_64, Control.from(0).read_completion_boundary);

        try testing.expectEqual(Deemphasis.db_3_5, Control2.from(0x0040).deemphasis);
        try testing.expectEqual(Deemphasis.db_6, Control2.from(0).deemphasis);
        try testing.expectEqual(Deemphasis.db_3_5, Status2.from(1).deemphasis);

        for (0..4) |encoding| {
            const raw: u16 = @intCast(encoding);

            try testing.expectEqual(encoding, @as(usize, @intFromEnum(Status2.from(raw << 8).crosslink_resolution)));
        }
    }

    test "flit controls use distinct writable and read-only bits" {
        try testing.expect(Control.from(0x2000).flit_mode_disable);
        try testing.expect(!Control.from(0x1000).flit_mode_disable);
        try testing.expect(Status2.from(0x0400).flit_mode);
        try testing.expect(!Status2.from(0x0800).flit_mode);
        try testing.expectEqual(@as(u16, 0x2000), Control.mask(.{.flit_mode_disable}));
        try testing.expectEqual(@as(u16, 0x0400), Status2.mask(.{.flit_mode}));
    }

    test "control updates preserve gaps and undefined status remains read-only" {
        const updated = Control.replace(Control.from(0x9004), .{ .common_clock = true });

        try testing.expectEqual(@as(u16, 0x9044), Control.raw(updated));
        try testing.expectEqual(@as(u16, 0x0400), Status.mask(.{._undefined_10}));
        try testing.expectEqual(@as(u16, 0), Status.masks.reserved & 0x0400);
        try testing.expectEqual(@as(u16, 0), Status.masks.assign & 0x0400);
        try testing.expectEqual(@as(u16, 0x0400), Status.raw(Status.from(0x0400)));
    }

    test "compliance settings persist across unrelated control updates" {
        const configured = Control2.replace(Control2.default(), .{
            .enter_compliance = true,
            .enter_modified_compliance = true,
        });

        const updated = Control2.replace(configured, .{ .hw_auto_speed_disable = true });
        const cleared = Control2.replace(updated, .{
            .enter_compliance = false,
            .enter_modified_compliance = false,
        });

        try testing.expectEqual(@as(u16, 0x0430), Control2.raw(updated));
        try testing.expectEqual(@as(u16, 0x0020), Control2.raw(cleared));
    }

    fn expectLinkSpeed(value: LinkSpeed, expected: u32) !void {
        try testing.expectEqual(expected, try value.mtps());
    }

    fn expectLinkWidth(value: LinkWidth, expected: u6) !void {
        try testing.expectEqual(expected, try value.lanes());
    }
};
