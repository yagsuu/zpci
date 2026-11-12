const stdx = @import("stdx");

const standard = @import("standard.zig");

const BitField = stdx.bits.BitField;
const Id = standard.Id;

pub const id: Id = .pm;

pub const Capabilities = BitField(u16, .{
    .version = .{ .type = u3, .access = .ro },
    .pme_clock_required = .{ .type = bool, .access = .ro },
    ._rsvd_4 = .{ .type = u1, .access = .reserved },
    .device_specific_init = .{ .type = bool, .access = .ro },
    .aux_current = .{ .type = AuxCurrent, .access = .ro, .default = .ma_0 },
    .d1_supported = .{ .type = bool, .access = .ro },
    .d2_supported = .{ .type = bool, .access = .ro },
    .pme_support = .{ .type = PmeSupport, .access = .ro, .default = PmeSupport.from(0) },
});

pub const Control = BitField(u16, .{
    .state = .{ .type = State, .default = .d0 },
    ._rsvd_2 = .{ .type = u1, .access = .reserved },
    .no_soft_reset = .{ .type = bool, .access = .ro },
    ._rsvd_4 = .{ .type = u4, .access = .reserved },
    .pme_enable = bool,
    .data_select = .{ .type = DataSelect, .default = .consumed_d0 },
    .data_scale = .{ .type = DataScale, .access = .ro, .default = .unknown },
    .pme_status = .{ .type = bool, .write = .w1c },
});

pub const BridgeSupport = BitField(u8, .{
    ._rsvd_0 = .{ .type = u6, .access = .reserved },
    .secondary_state = .{ .type = SecondaryState, .access = .ro, .default = .power_off },
    .bus_control_enabled = .{ .type = bool, .access = .ro },
});

pub const State = enum(u2) {
    d0 = 0,
    d1 = 1,
    d2 = 2,
    d3hot = 3,
};

pub const PmeSupport = enum(u5) {
    d0 = 0x01,
    d1 = 0x02,
    d2 = 0x04,
    d3hot = 0x08,
    d3cold = 0x10,
    _,

    pub const State = enum(u3) {
        d0,
        d1,
        d2,
        d3hot,
        d3cold,
    };

    pub fn from(bits: u5) PmeSupport {
        return @enumFromInt(bits);
    }

    pub fn raw(self: PmeSupport) u5 {
        return @intFromEnum(self);
    }

    pub fn supports(self: PmeSupport, state: PmeSupport.State) bool {
        const mask = @as(u5, 1) << @intFromEnum(state);
        return self.raw() & mask != 0;
    }
};

pub const AuxCurrent = enum(u3) {
    ma_0 = 0,
    ma_55 = 1,
    ma_100 = 2,
    ma_160 = 3,
    ma_220 = 4,
    ma_270 = 5,
    ma_320 = 6,
    ma_375 = 7,

    pub fn ma(self: AuxCurrent) u9 {
        return switch (self) {
            .ma_0 => 0,
            .ma_55 => 55,
            .ma_100 => 100,
            .ma_160 => 160,
            .ma_220 => 220,
            .ma_270 => 270,
            .ma_320 => 320,
            .ma_375 => 375,
        };
    }
};

pub const DataSelect = enum(u4) {
    consumed_d0 = 0,
    consumed_d1 = 1,
    consumed_d2 = 2,
    consumed_d3hot = 3,
    dissipated_d0 = 4,
    dissipated_d1 = 5,
    dissipated_d2 = 6,
    dissipated_d3hot = 7,
    common_power = 8,
    _,
};

pub const DataScale = enum(u2) {
    unknown = 0,
    tenths = 1,
    hundredths = 2,
    thousandths = 3,
};

pub const SecondaryState = enum(u1) {
    power_off = 0,
    clock_stopped = 1,
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x02;
    pub const control: u8 = 0x04;
    pub const bridge_support: u8 = 0x06;
    pub const data: u8 = 0x07;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "PM capabilities decode auxiliary current and independent PME state support" {
        const caps = Capabilities.from(0xCAEB);

        try testing.expectEqual(@as(u3, 3), caps.version);
        try testing.expect(caps.pme_clock_required);
        try testing.expect(caps.device_specific_init);
        try testing.expectEqual(AuxCurrent.ma_160, caps.aux_current);
        try testing.expect(caps.d1_supported);
        try testing.expect(!caps.d2_supported);
        try testing.expect(caps.pme_support.supports(.d0));
        try testing.expect(!caps.pme_support.supports(.d1));
        try testing.expect(!caps.pme_support.supports(.d2));
        try testing.expect(caps.pme_support.supports(.d3hot));
        try testing.expect(caps.pme_support.supports(.d3cold));

        const future = Capabilities.from(0x0007);
        try testing.expectEqual(@as(u3, 7), future.version);
    }

    test "PME support preserves all combinations including D3cold independently of D3hot" {
        const states = [_]PmeSupport.State{ .d0, .d1, .d2, .d3hot, .d3cold };
        const masks = [_]u5{ 0x01, 0x02, 0x04, 0x08, 0x10 };

        for (0..32) |bits| {
            const encoded: u5 = @intCast(bits);
            const support = PmeSupport.from(encoded);

            for (states, masks) |state, mask| {
                try testing.expectEqual(encoded & mask != 0, support.supports(state));
            }
        }
    }

    test "PMCSR separates programmable state and selection from read-only scale and W1C status" {
        const control = Control.from(0xEF0B);

        try testing.expectEqual(State.d3hot, control.state);
        try testing.expect(control.no_soft_reset);
        try testing.expect(control.pme_enable);
        try testing.expectEqual(DataSelect.dissipated_d3hot, control.data_select);
        try testing.expectEqual(DataScale.thousandths, control.data_scale);
        try testing.expect(control.pme_status);

        try testing.expectEqual(@as(u16, 0x1F03), Control.masks.assign);
        try testing.expectEqual(@as(u16, 0x8000), Control.masks.w1c);
        try testing.expectEqual(@as(u16, 0x00F4), Control.masks.reserved);
        try testing.expectEqual(@as(u16, 0x8000), Control.ack(control, .{.pme_status}));
        try testing.expectEqual(@as(u16, 0), Control.ack(Control.from(0x6F0B), .{.pme_status}));
    }

    test "PMCSR partial updates preserve omitted controls without reclassifying PME status as assignment" {
        const observed = Control.from(0xEF0B);
        const updated = Control.replace(observed, .{ .pme_enable = false, .data_select = .common_power });

        try testing.expectEqual(@as(u16, 0xF00B), Control.raw(updated));
        try testing.expectEqual(State.d3hot, updated.state);
        try testing.expect(updated.pme_status);
        try testing.expect(updated.no_soft_reset);
        try testing.expectEqual(DataScale.thousandths, updated.data_scale);
    }

    test "power data selectors preserve reserved encodings and unknown scale remains distinct" {
        for (9..16) |encoding| {
            const raw = (@as(u16, @intCast(encoding)) << 9) | 1;
            const control = Control.from(raw);

            try testing.expectEqual(@as(u4, @intCast(encoding)), @intFromEnum(control.data_select));
            try testing.expectEqual(State.d1, control.state);
            try testing.expectEqual(DataScale.unknown, control.data_scale);
            try testing.expectEqual(raw, Control.raw(control));
        }
    }

    test "auxiliary-current encodings use the specified non-linear milliamp values" {
        const currents = [_]u9{ 0, 55, 100, 160, 220, 270, 320, 375 };

        for (currents, 0..) |expected, encoding| {
            const current: AuxCurrent = @enumFromInt(encoding);
            try testing.expectEqual(expected, current.ma());
        }
    }

    test "bridge support reports secondary power-off versus clock-stop without writable fields" {
        const stopped = BridgeSupport.from(0xC0);
        const powered_off = BridgeSupport.from(0x80);

        try testing.expect(stopped.bus_control_enabled);
        try testing.expectEqual(SecondaryState.clock_stopped, stopped.secondary_state);
        try testing.expect(powered_off.bus_control_enabled);
        try testing.expectEqual(SecondaryState.power_off, powered_off.secondary_state);
        try testing.expectEqual(@as(u8, 0), BridgeSupport.masks.assign);
        try testing.expectEqual(@as(u8, 0x3F), BridgeSupport.masks.reserved);
    }
};
