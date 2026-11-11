const stdx = @import("stdx");

const header = @import("../../header.zig");

const BitField = stdx.bits.BitField;
const HeaderFormat = header.Format;

pub const Capabilities = BitField(u32, .{
    .max_payload_size = .{ .type = MaxPayloadSize, .access = .ro, .default = .bytes_128 },
    .phantom_functions_supported = .{ .type = u2, .access = .ro },
    .extended_tag_supported = .{ .type = bool, .access = .ro },
    .l0s_acceptable_latency = .{ .type = u3, .access = .ro },
    .l1_acceptable_latency = .{ .type = u3, .access = .ro },
    ._rsvd_12 = .{ .type = u3, .access = .reserved },
    .role_based_error_reporting = .{ .type = bool, .access = .ro },
    ._rsvd_16 = .{ .type = u2, .access = .reserved },
    .captured_slot_power_limit_value = .{ .type = u8, .access = .ro },
    .captured_slot_power_limit_scale = .{ .type = u2, .access = .ro },
    .flr_supported = .{ .type = bool, .access = .ro },
    ._rsvd_29 = .{ .type = u3, .access = .reserved },
});

pub const Control = struct {
    const Fields = BitField(u16, .{
        .correctable_error_reporting_enable = bool,
        .non_fatal_error_reporting_enable = bool,
        .fatal_error_reporting_enable = bool,
        .unsupported_request_reporting_enable = bool,
        .relaxed_ordering_enable = bool,
        .max_payload_size = .{ .type = MaxPayloadSize, .default = .bytes_128 },
        .extended_tag_enable = bool,
        .phantom_functions_enable = bool,
        .aux_power_pm_enable = bool,
        .no_snoop_enable = bool,
        .max_read_request_size = .{ .type = MaxReadRequestSize, .default = .bytes_128 },
        // Context-dependent writes use rwMask/triggerMask, not static assignment.
        .bcre_initiate_flr = .{ .type = bool, .access = .ro },
    });

    pub const Word = Fields.Word;
    pub const masks = Fields.masks;

    pub const default = Fields.default;
    pub const init = Fields.init;
    pub const from = Fields.from;
    pub const raw = Fields.raw;

    pub const encode = Fields.encode;
    pub const replace = Fields.replace;

    pub const mask = Fields.mask;

    /// Bit 15 is BCRE on bridges and an FLR action on endpoints.
    pub fn rwMask(format: HeaderFormat) u16 {
        return switch (format) {
            .type0 => masks.assign,
            .type1 => masks.assign | mask(.{.bcre_initiate_flr}),
        };
    }

    pub fn triggerMask(format: HeaderFormat) u16 {
        return switch (format) {
            .type0 => mask(.{.bcre_initiate_flr}),
            .type1 => 0,
        };
    }
};

pub const Status = BitField(u16, .{
    .correctable_error_detected = .{ .type = bool, .write = .w1c },
    .non_fatal_error_detected = .{ .type = bool, .write = .w1c },
    .fatal_error_detected = .{ .type = bool, .write = .w1c },
    .unsupported_request_detected = .{ .type = bool, .write = .w1c },
    .aux_power_detected = .{ .type = bool, .access = .ro },
    .transactions_pending = .{ .type = bool, .access = .ro },
    .emergency_power_reduction_detected = .{ .type = bool, .write = .w1c },
    ._rsvd_7 = .{ .type = u9, .access = .reserved },
});

pub const Capabilities2 = BitField(u32, .{
    .completion_timeout_ranges_supported = .{ .type = u4, .access = .ro },
    .completion_timeout_disable_supported = .{ .type = bool, .access = .ro },
    .ari_forwarding_supported = .{ .type = bool, .access = .ro },
    .atomic_op_routing_supported = .{ .type = bool, .access = .ro },
    .atomic_op_completer_32_supported = .{ .type = bool, .access = .ro },
    .atomic_op_completer_64_supported = .{ .type = bool, .access = .ro },
    .cas_completer_128_supported = .{ .type = bool, .access = .ro },
    .no_ro_enabled_pr_pr_passing = .{ .type = bool, .access = .ro },
    .ltr_supported = .{ .type = bool, .access = .ro },
    .tph_completer_supported = .{ .type = u2, .access = .ro },
    .ln_system_cls = .{ .type = u2, .access = .ro },
    .tag_completer_10bit_supported = .{ .type = bool, .access = .ro },
    .tag_requester_10bit_supported = .{ .type = bool, .access = .ro },
    .obff_supported = .{ .type = u2, .access = .ro },
    .extended_fmt_supported = .{ .type = bool, .access = .ro },
    .end_end_tlp_prefix_supported = .{ .type = bool, .access = .ro },
    .max_end_end_tlp_prefixes = .{ .type = u2, .access = .ro },
    .emergency_power_reduction_supported = .{ .type = u2, .access = .ro },
    .emergency_power_reduction_init_required = .{ .type = bool, .access = .ro },
    ._rsvd_27 = .{ .type = u3, .access = .reserved },
    .frs_supported = .{ .type = bool, .access = .ro },
    ._rsvd_31 = .{ .type = u1, .access = .reserved },
});

pub const Control2 = BitField(u16, .{
    .completion_timeout = .{ .type = CompletionTimeoutValue, .default = .default },
    .completion_timeout_disable = bool,
    .ari_forwarding_enable = bool,
    .atomic_op_requester_enable = bool,
    .atomic_op_egress_blocking = bool,
    .ido_request_enable = bool,
    .ido_completion_enable = bool,
    .ltr_enable = bool,
    .emergency_power_reduction_request = bool,
    .tag_requester_10bit_enable = bool,
    .obff_enable = u2,
    .end_end_tlp_prefix_blocking = bool,
});

pub const Status2 = BitField(u16, .{
    ._rsvd_0 = .{ .type = u16, .access = .reserved },
});

pub const MaxPayloadSize = enum(u3) {
    bytes_128 = 0,
    bytes_256 = 1,
    bytes_512 = 2,
    bytes_1024 = 3,
    bytes_2048 = 4,
    bytes_4096 = 5,
    _,

    pub fn bytes(self: MaxPayloadSize) error{MalformedField}!u32 {
        return switch (@intFromEnum(self)) {
            0...5 => @as(u32, 128) << @as(u5, @intCast(@intFromEnum(self))),
            else => error.MalformedField,
        };
    }
};

pub const MaxReadRequestSize = enum(u3) {
    bytes_128 = 0,
    bytes_256 = 1,
    bytes_512 = 2,
    bytes_1024 = 3,
    bytes_2048 = 4,
    bytes_4096 = 5,
    _,

    pub fn bytes(self: MaxReadRequestSize) error{MalformedField}!u32 {
        return switch (@intFromEnum(self)) {
            0...5 => @as(u32, 128) << @as(u5, @intCast(@intFromEnum(self))),
            else => error.MalformedField,
        };
    }
};

pub const CompletionTimeoutValue = enum(u4) {
    default = 0x0,
    range_a_50us_100us = 0x1,
    range_a_1ms_10ms = 0x2,
    range_b_16ms_55ms = 0x5,
    range_b_65ms_210ms = 0x6,
    range_c_260ms_900ms = 0x9,
    range_c_1s_3_5s = 0xA,
    range_d_4s_13s = 0xD,
    range_d_17s_64s = 0xE,
    _,
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x04;
    pub const control: u8 = 0x08;
    pub const status: u8 = 0x0A;
    pub const capabilities_2: u8 = 0x24;
    pub const control_2: u8 = 0x28;
    pub const status_2: u8 = 0x2A;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "register bit positions" {
        try testing.expectEqual(@as(comptime_int, 5), @bitOffsetOf(Control.Word, "max_payload_size"));
        try testing.expectEqual(@as(comptime_int, 12), @bitOffsetOf(Control.Word, "max_read_request_size"));
        try testing.expectEqual(@as(comptime_int, 15), @bitOffsetOf(Control.Word, "bcre_initiate_flr"));
        try testing.expectEqual(
            @as(comptime_int, 6),
            @bitOffsetOf(Status.Word, "emergency_power_reduction_detected"),
        );
        try testing.expectEqual(@as(comptime_int, 7), @bitOffsetOf(Status.Word, "_rsvd_7"));
        try testing.expectEqual(
            @as(comptime_int, 4),
            @bitOffsetOf(Control2.Word, "completion_timeout_disable"),
        );
        try testing.expectEqual(@as(comptime_int, 13), @bitOffsetOf(Control2.Word, "obff_enable"));
    }

    test "enum helpers map named encodings and reject reserved encodings" {
        try expectPayloadBytes(.bytes_128, 128);
        try expectPayloadBytes(.bytes_256, 256);
        try expectPayloadBytes(.bytes_512, 512);
        try expectPayloadBytes(.bytes_1024, 1024);
        try expectPayloadBytes(.bytes_2048, 2048);
        try expectPayloadBytes(.bytes_4096, 4096);
        try testing.expectError(error.MalformedField, (@as(MaxPayloadSize, @enumFromInt(6))).bytes());
        try testing.expectError(error.MalformedField, (@as(MaxPayloadSize, @enumFromInt(7))).bytes());

        try expectReadRequestBytes(.bytes_128, 128);
        try expectReadRequestBytes(.bytes_4096, 4096);
        try testing.expectError(error.MalformedField, (@as(MaxReadRequestSize, @enumFromInt(6))).bytes());
        try testing.expectError(error.MalformedField, (@as(MaxReadRequestSize, @enumFromInt(7))).bytes());
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Capabilities, 0, 0, 0, 0xE003_7000 },
            .{ Status, 0, 0x004F, 0, 0xFF80 },
            .{ Capabilities2, 0, 0, 0, 0xB800_0000 },
            .{ Control2, 0xFFFF, 0, 0, 0 },
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

    test "device control classifies BCRE and FLR by header format" {
        try testing.expectEqual(@as(u16, 0x7FFF), Control.rwMask(.type0));
        try testing.expectEqual(@as(u16, 0x8000), Control.triggerMask(.type0));
        try testing.expectEqual(@as(u16, 0xFFFF), Control.rwMask(.type1));
        try testing.expectEqual(@as(u16, 0), Control.triggerMask(.type1));
        try testing.expectEqual(@as(u16, 0), Control.masks.w1c);
        try testing.expectEqual(@as(u16, 0), Control.masks.reserved);

        const observed = Control.from(0x8000);
        const updated = Control.replace(observed, .{ .no_snoop_enable = true });

        try testing.expectEqual(@as(u16, 0x8800), Control.raw(updated));
        try testing.expectEqual(@as(u16, 0), Control.masks.assign & 0x8000);
        try testing.expectEqual(@as(u16, 0), Control.masks.trigger & 0x8000);
    }

    test "field masks select payload and high reserved bits" {
        try testing.expectEqual(@as(u16, 0x00E0), Control.mask(.{.max_payload_size}));
        try testing.expectEqual(@as(u32, 0x8000_0000), Capabilities2.mask(.{._rsvd_31}));
    }

    fn expectPayloadBytes(value: MaxPayloadSize, expected: u32) !void {
        try testing.expectEqual(expected, try value.bytes());
    }

    fn expectReadRequestBytes(value: MaxReadRequestSize, expected: u32) !void {
        try testing.expectEqual(expected, try value.bytes());
    }
};
