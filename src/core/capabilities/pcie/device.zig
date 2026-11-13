const stdx = @import("stdx");

const pcie = @import("../pcie.zig");

const BitField = stdx.bits.BitField;
const BitFieldExt = stdx.bits.BitFieldExt;
const DevicePortType = pcie.DevicePortType;
const PowerLimitScale = pcie.PowerLimitScale;

pub const Capabilities = BitFieldExt(u32, .{
    .max_payload_size = .{ .type = PayloadSize, .access = .ro, .default = .bytes_128 },
    .phantom_functions_supported = .{ .type = PhantomFunctions, .access = .ro, .default = .none },
    .ext_tag_supported = .{ .type = bool, .access = .ro },
    .l0s_acceptable_latency = .{ .type = L0sAcceptableLatency, .access = .ro, .default = .under_64ns },
    .l1_acceptable_latency = .{ .type = L1AcceptableLatency, .access = .ro, .default = .under_1us },
    .role_based_error_reporting = .{ .offset = 15, .type = bool, .access = .ro },
    .captured_power_limit = .{ .offset = 18, .type = u8, .access = .ro },
    .captured_power_scale = .{ .type = PowerLimitScale, .access = .ro, .default = .watts_1 },
    .flr_supported = .{ .type = bool, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control = struct {
    const Fields = BitField(u16, .{
        .correctable_error_report_enable = bool,
        .non_fatal_error_report_enable = bool,
        .fatal_error_report_enable = bool,
        .unsupported_request_report_enable = bool,
        .relaxed_ordering_enable = bool,
        .max_payload_size = .{ .type = PayloadSize, .default = .bytes_128 },
        .ext_tag_enable = bool,
        .phantom_functions_enable = bool,
        .aux_power_pm_enable = bool,
        .no_snoop_enable = bool,
        .max_read_request_size = .{ .type = ReadRequestSize, .default = .bytes_128 },
        // Context-dependent writes use rwMask/triggerMask, not static assignment.
        .bcre_initiate_flr = .{ .type = bool, .access = .ro },
    });

    pub const Word = Fields.Word;
    pub const Args = Fields.Args;
    pub const AssignArgs = Fields.AssignArgs;

    pub const masks = Fields.masks;

    pub const default = Fields.default;
    pub const init = Fields.init;
    pub const from = Fields.from;
    pub const raw = Fields.raw;

    pub const encode = Fields.encode;
    pub const replace = Fields.replace;

    pub const mask = Fields.mask;

    pub fn rwMask(port_type: DevicePortType) u16 {
        return switch (port_type) {
            .pcie_to_pci_bridge => masks.assign | mask(.{.bcre_initiate_flr}),
            else => masks.assign,
        };
    }

    pub fn triggerMask(port_type: DevicePortType, capabilities: Capabilities.Word) u16 {
        if (!capabilities.flr_supported) {
            return 0;
        }

        return switch (port_type) {
            .endpoint, .legacy_endpoint, .root_complex_integrated_endpoint => mask(.{.bcre_initiate_flr}),
            else => 0,
        };
    }
};

pub const Status = BitFieldExt(u16, .{
    .correctable_error_detected = .{ .type = bool, .write = .w1c },
    .non_fatal_error_detected = .{ .type = bool, .write = .w1c },
    .fatal_error_detected = .{ .type = bool, .write = .w1c },
    .unsupported_request_detected = .{ .type = bool, .write = .w1c },
    .aux_power_detected = .{ .type = bool, .access = .ro },
    .transactions_pending = .{ .type = bool, .access = .ro },
    .emergency_power_reduction_detected = .{ .type = bool, .write = .w1c },
}, .{ .unnamed = .reserved });

pub const Capabilities2 = BitFieldExt(u32, .{
    .completion_timeout_ranges_supported = .{ .type = CompletionTimeoutRanges, .access = .ro, .default = CompletionTimeoutRanges.from(0) },
    .completion_timeout_disable_supported = .{ .type = bool, .access = .ro },
    .ari_forwarding_supported = .{ .type = bool, .access = .ro },
    .atomic_op_routing_supported = .{ .type = bool, .access = .ro },
    .atomic_op_completer_32_supported = .{ .type = bool, .access = .ro },
    .atomic_op_completer_64_supported = .{ .type = bool, .access = .ro },
    .cas_completer_128_supported = .{ .type = bool, .access = .ro },
    .no_ro_enabled_pr_pr_passing = .{ .type = bool, .access = .ro },
    .ltr_supported = .{ .type = bool, .access = .ro },
    .tph_completer_supported = .{ .type = TphCompleterSupport, .access = .ro, .default = .unsupported },
    .ln_system_cls = .{ .type = LnSystemCacheLineSize, .access = .ro, .default = .unsupported },
    .tag_completer_10bit_supported = .{ .type = bool, .access = .ro },
    .tag_requester_10bit_supported = .{ .type = bool, .access = .ro },
    .obff_supported = .{ .type = ObffSupport, .access = .ro, .default = .unsupported },
    .ext_fmt_supported = .{ .type = bool, .access = .ro },
    .e2e_tlp_prefix_supported = .{ .type = bool, .access = .ro },
    .max_e2e_tlp_prefixes = .{ .type = E2eTlpPrefixCount, .access = .ro, .default = .four },
    .emergency_power_reduction_supported = .{ .type = EmergencyPowerReductionSupport, .access = .ro, .default = .unsupported },
    .emergency_power_reduction_init_required = .{ .type = bool, .access = .ro },
    .frs_supported = .{ .offset = 30, .type = bool, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control2 = BitField(u16, .{
    .completion_timeout = .{ .type = CompletionTimeout, .default = .default },
    .completion_timeout_disable = bool,
    .ari_forwarding_enable = bool,
    .atomic_op_requester_enable = bool,
    .atomic_op_egress_blocking = bool,
    .ido_request_enable = bool,
    .ido_completion_enable = bool,
    .ltr_enable = bool,
    .emergency_power_reduction_request = bool,
    .tag_requester_10bit_enable = bool,
    .obff_enable = .{ .type = ObffControl, .default = .disabled },
    .e2e_tlp_prefix_blocking = bool,
});

pub const Status2 = BitFieldExt(u16, .{}, .{ .unnamed = .reserved });

pub const PayloadSize = enum(u3) {
    bytes_128 = 0,
    bytes_256 = 1,
    bytes_512 = 2,
    bytes_1024 = 3,
    bytes_2048 = 4,
    bytes_4096 = 5,
    _,

    pub fn bytes(self: PayloadSize) error{MalformedField}!u32 {
        return switch (@intFromEnum(self)) {
            0...5 => @as(u32, 128) << @as(u5, @intCast(@intFromEnum(self))),
            else => error.MalformedField,
        };
    }
};

pub const ReadRequestSize = enum(u3) {
    bytes_128 = 0,
    bytes_256 = 1,
    bytes_512 = 2,
    bytes_1024 = 3,
    bytes_2048 = 4,
    bytes_4096 = 5,
    _,

    pub fn bytes(self: ReadRequestSize) error{MalformedField}!u32 {
        return switch (@intFromEnum(self)) {
            0...5 => @as(u32, 128) << @as(u5, @intCast(@intFromEnum(self))),
            else => error.MalformedField,
        };
    }
};

pub const CompletionTimeout = enum(u4) {
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

pub const L0sAcceptableLatency = enum(u3) {
    under_64ns = 0,
    under_128ns = 1,
    under_256ns = 2,
    under_512ns = 3,
    under_1us = 4,
    under_2us = 5,
    under_4us = 6,
    no_limit = 7,
};

pub const L1AcceptableLatency = enum(u3) {
    under_1us = 0,
    under_2us = 1,
    under_4us = 2,
    under_8us = 3,
    under_16us = 4,
    under_32us = 5,
    under_64us = 6,
    no_limit = 7,
};

pub const CompletionTimeoutRanges = enum(u4) {
    a = 0x1,
    b = 0x2,
    c = 0x4,
    d = 0x8,
    _,

    pub const Range = enum(u2) { a, b, c, d };

    pub fn from(bits: u4) CompletionTimeoutRanges {
        return @enumFromInt(bits);
    }

    pub fn raw(self: CompletionTimeoutRanges) u4 {
        return @intFromEnum(self);
    }

    pub fn supports(self: CompletionTimeoutRanges, range: Range) bool {
        return self.raw() & (@as(u4, 1) << @intFromEnum(range)) != 0;
    }
};

pub const TphCompleterSupport = enum(u2) {
    unsupported = 0,
    tph = 1,
    tph_extended = 3,
    _,
};

pub const LnSystemCacheLineSize = enum(u2) {
    unsupported = 0,
    bytes_64 = 1,
    bytes_128 = 2,
    _,
};

pub const ObffSupport = enum(u2) {
    unsupported = 0,
    message = 1,
    wake = 2,
    message_wake = 3,
};

pub const ObffControl = enum(u2) {
    disabled = 0,
    message_a = 1,
    message_b = 2,
    wake = 3,
};

pub const EmergencyPowerReductionSupport = enum(u2) {
    unsupported = 0,
    device_specific = 1,
    form_factor_device_specific = 2,
    _,
};

pub const PhantomFunctions = enum(u2) {
    none = 0,
    one = 1,
    three = 2,
    seven = 3,

    pub fn count(self: PhantomFunctions) u3 {
        return switch (self) {
            .none => 0,
            .one => 1,
            .three => 3,
            .seven => 7,
        };
    }
};

pub const E2eTlpPrefixCount = enum(u2) {
    four = 0,
    one = 1,
    two = 2,
    three = 3,

    pub fn count(self: E2eTlpPrefixCount) u3 {
        return switch (self) {
            .four => 4,
            .one => 1,
            .two => 2,
            .three => 3,
        };
    }
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x04;
    pub const control: u8 = 0x08;
    pub const status: u8 = 0x0A;
    pub const capabilities2: u8 = 0x24;
    pub const control2: u8 = 0x28;
    pub const status2: u8 = 0x2A;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "typed device encodings preserve raw values and field meanings" {
        try testing.expectEqual(@as(u16, 0x400E), Control2.encode(.{
            .completion_timeout = .range_d_17s_64s,
            .obff_enable = .message_b,
        }));
        try testing.expectEqual(@as(u32, 0x0008_3000), Capabilities2.encode(.{
            .tph_completer_supported = .tph_extended,
            .obff_supported = .wake,
        }));

        const caps = Capabilities.from((@as(u32, 7) << 6) | (@as(u32, 7) << 9) | (@as(u32, 3) << 26));

        try testing.expectEqual(L0sAcceptableLatency.no_limit, caps.l0s_acceptable_latency);
        try testing.expectEqual(L1AcceptableLatency.no_limit, caps.l1_acceptable_latency);
        try testing.expectEqual(PowerLimitScale.watts_0_001, caps.captured_power_scale);
        try testing.expectEqual(@as(u32, 0x0C00_0FC0), Capabilities.raw(caps));

        for (0..4) |encoding| {
            const bits: u32 = @intCast(encoding);
            const raw = (bits << 12) | (bits << 14) | (bits << 18) | (bits << 24);
            const caps2 = Capabilities2.from(raw);
            const control2 = Control2.from(@as(u16, @intCast(bits)) << 13);

            try testing.expectEqual(raw, Capabilities2.raw(caps2));
            try testing.expectEqual(bits, @as(u32, @intFromEnum(caps2.tph_completer_supported)));
            try testing.expectEqual(bits, @as(u32, @intFromEnum(caps2.ln_system_cls)));
            try testing.expectEqual(bits, @as(u32, @intFromEnum(caps2.emergency_power_reduction_supported)));
            try testing.expectEqual(bits << 13, @as(u32, Control2.raw(control2)));
        }

        try testing.expectEqual(TphCompleterSupport.tph_extended, Capabilities2.from(3 << 12).tph_completer_supported);
        try testing.expectEqual(LnSystemCacheLineSize.bytes_128, Capabilities2.from(2 << 14).ln_system_cls);
        try testing.expectEqual(ObffSupport.wake, Capabilities2.from(2 << 18).obff_supported);
        try testing.expectEqual(ObffControl.message_b, Control2.from(2 << 13).obff_enable);
        try testing.expectEqual(ObffControl.wake, Control2.from(3 << 13).obff_enable);
        try testing.expectEqual(EmergencyPowerReductionSupport.form_factor_device_specific, Capabilities2.from(2 << 24).emergency_power_reduction_supported);
        try testing.expectEqual(@as(u16, 3), Control2.raw(Control2.from(3)));
        try testing.expectEqual(CompletionTimeout.range_d_17s_64s, Control2.from(14).completion_timeout);
    }

    test "encoded quantities decode counts rather than raw integers" {
        const phantom_counts = [_]u3{ 0, 1, 3, 7 };
        const prefix_counts = [_]u3{ 4, 1, 2, 3 };

        for (0..4) |encoding| {
            const bits: u32 = @intCast(encoding);
            const caps = Capabilities.from(bits << 3);
            const caps2 = Capabilities2.from((bits << 22) | (1 << 21));

            try testing.expectEqual(phantom_counts[encoding], caps.phantom_functions_supported.count());
            try testing.expectEqual(prefix_counts[encoding], caps2.max_e2e_tlp_prefixes.count());
            try testing.expectEqual(bits << 3, Capabilities.raw(caps));
            try testing.expectEqual((bits << 22) | (1 << 21), Capabilities2.raw(caps2));
        }
    }

    test "completion timeout ranges preserve sparse membership" {
        const selectors = [_]CompletionTimeoutRanges.Range{ .a, .b, .c, .d };

        for (0..16) |encoding| {
            const bits: u4 = @intCast(encoding);
            const ranges = CompletionTimeoutRanges.from(bits);
            const caps = Capabilities2.from(bits);

            for (selectors, 0..) |selector, index| {
                const shift: u2 = @intCast(index);

                try testing.expectEqual(bits & (@as(u4, 1) << shift) != 0, ranges.supports(selector));
            }
            try testing.expectEqual(bits, ranges.raw());
            try testing.expectEqual(bits, caps.completion_timeout_ranges_supported.raw());
            try testing.expectEqual(@as(u32, bits), Capabilities2.raw(caps));
        }
    }

    test "register bit positions" {
        try testing.expectEqual(@as(comptime_int, 5), @bitOffsetOf(Control.Word, "max_payload_size"));
        try testing.expectEqual(@as(comptime_int, 12), @bitOffsetOf(Control.Word, "max_read_request_size"));
        try testing.expectEqual(@as(comptime_int, 15), @bitOffsetOf(Control.Word, "bcre_initiate_flr"));
        try testing.expectEqual(
            @as(comptime_int, 6),
            @bitOffsetOf(Status.Word, "emergency_power_reduction_detected"),
        );
        try testing.expectEqual(@as(u16, 0xFF80), Status.masks.reserved);
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
        try testing.expectError(error.MalformedField, (@as(PayloadSize, @enumFromInt(6))).bytes());
        try testing.expectError(error.MalformedField, (@as(PayloadSize, @enumFromInt(7))).bytes());

        try expectReadRequestBytes(.bytes_128, 128);
        try expectReadRequestBytes(.bytes_4096, 4096);
        try testing.expectError(error.MalformedField, (@as(ReadRequestSize, @enumFromInt(6))).bytes());
        try testing.expectError(error.MalformedField, (@as(ReadRequestSize, @enumFromInt(7))).bytes());
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
            try testing.expectEqual(@as(Raw, case[4]), T.raw(T.from(case[4])));
            try testing.expectEqual(@as(Raw, case[4]), T.raw(T.replace(T.from(case[4]), .{})));
            try testing.expectEqual(@as(Raw, 0), T.raw(T.default()) & T.masks.reserved);
            try testing.expectEqual(@as(Raw, 0), T.encode(.{}) & T.masks.reserved);
            try testing.expectEqual(~@as(Raw, 0), T.raw(T.from(~@as(Raw, 0))));
        }
    }

    test "device control classifies bit fifteen by port type and FLR support" {
        for (0..16) |encoding| {
            const port_type: DevicePortType = @enumFromInt(encoding);
            const ordinary: u16 = if (encoding == 7) 0xFFFF else 0x7FFF;

            try testing.expectEqual(ordinary, Control.rwMask(port_type));
            try testing.expectEqual(@as(u16, 0), Control.triggerMask(port_type, Capabilities.from(0)));

            const flr: u16 = switch (encoding) {
                0, 1, 9 => 0x8000,
                else => 0,
            };

            try testing.expectEqual(flr, Control.triggerMask(port_type, Capabilities.from(1 << 28)));
            try testing.expectEqual(@as(u16, 0), ordinary & flr);
        }
    }

    test "ordinary device updates preserve the contextual bit and unspecified fields" {
        const observed = Control.from(0xA100);
        const args: Control.AssignArgs = .{ .no_snoop_enable = true };
        const updated = Control.replace(observed, args);

        try testing.expectEqual(@as(u16, 0xA900), Control.raw(updated));
    }

    test "power reduction requests persist until explicitly cleared" {
        const observed = Control2.from(0x0800);
        const updated = Control2.replace(observed, .{ .ari_forwarding_enable = true });
        const cleared = Control2.replace(updated, .{ .emergency_power_reduction_request = false });

        try testing.expectEqual(@as(u16, 0x0820), Control2.raw(updated));
        try testing.expectEqual(@as(u16, 0x0020), Control2.raw(cleared));
    }

    test "field masks select payload and reserved masks include high bits" {
        try testing.expectEqual(@as(u16, 0x00E0), Control.mask(.{.max_payload_size}));
        try testing.expectEqual(@as(u32, 0x8000_0000), Capabilities2.masks.reserved & 0x8000_0000);
    }

    fn expectPayloadBytes(value: PayloadSize, expected: u32) !void {
        try testing.expectEqual(expected, try value.bytes());
    }

    fn expectReadRequestBytes(value: ReadRequestSize, expected: u32) !void {
        try testing.expectEqual(expected, try value.bytes());
    }
};
