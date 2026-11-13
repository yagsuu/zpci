//! PCI header wire types.

const std = @import("std");
const stdx = @import("stdx");

const ids = @import("ids.zig");

pub const type0 = @import("header/type0.zig");
pub const type1 = @import("header/type1.zig");

const BitField = stdx.bits.BitField;
const BitFieldExt = stdx.bits.BitFieldExt;

const DeviceId = ids.DeviceId;
const VendorId = ids.VendorId;
const ClassCode = ids.ClassCode;

pub const Type0 = type0.Header;
pub const Type1 = type1.Header;

pub const Format = enum {
    type0,
    type1,
};

pub const WireFormat = enum(u7) {
    type0 = 0,
    type1 = 1,
    cardbus = 2,
    _,
};

pub const DevselTiming = enum(u2) {
    fast = 0,
    medium = 1,
    slow = 2,
    _,
};

pub const Type = BitField(u8, .{
    .format = .{ .type = WireFormat, .access = .ro, .default = .type0 },
    .multifunction = .{ .type = bool, .access = .ro },
});

pub const Command = BitFieldExt(u16, .{
    .io_enable = bool,
    .mem_enable = bool,
    .bus_master = bool,
    .special_cycles = bool,
    .mwi_enable = bool,
    .vga_palette_snoop = bool,
    .parity_response = bool,
    .serr_enable = .{ .offset = 8, .type = bool },
    .fast_back_to_back = bool,
    .intr_disable = bool,
}, .{ .unnamed = .reserved });

pub const Status = BitFieldExt(u16, .{
    .intr_pending = .{ .offset = 3, .type = bool, .access = .ro },
    .cap_list = .{ .type = bool, .access = .ro },
    .capable_66mhz = .{ .type = bool, .access = .ro },
    .fast_back_to_back_capable = .{ .offset = 7, .type = bool, .access = .ro },
    .master_data_parity_error = .{ .type = bool, .write = .w1c },
    .devsel_timing = .{ .type = DevselTiming, .access = .ro, .default = .fast },
    .signaled_target_abort = .{ .type = bool, .write = .w1c },
    .received_target_abort = .{ .type = bool, .write = .w1c },
    .received_master_abort = .{ .type = bool, .write = .w1c },
    .signaled_system_error = .{ .type = bool, .write = .w1c },
    .detected_parity_error = .{ .type = bool, .write = .w1c },
}, .{ .unnamed = .reserved });

pub const Bist = BitFieldExt(u8, .{
    .code = .{ .type = u4, .access = .ro },
    .start = .{ .offset = 6, .type = bool, .write = .trigger },
    .capable = .{ .type = bool, .access = .ro },
}, .{ .unnamed = .reserved });

pub const ExpansionRom = BitFieldExt(u32, .{
    .enable = bool,
    .base_shifted = .{ .offset = 11, .type = u21 },
}, .{ .unnamed = .reserved });

pub const BridgeControl = BitFieldExt(u16, .{
    .parity_response = bool,
    .serr_enable = bool,
    .isa_enable = bool,
    .vga_enable = bool,
    .vga_decode_16bit = bool,
    .master_abort_mode = bool,
    .secondary_bus_reset = bool,
    .fast_back_to_back_enable = bool,
    .primary_discard_timer = bool,
    .secondary_discard_timer = bool,
    .discard_timer_status = .{ .type = bool, .write = .w1c },
    .discard_timer_serr_enable = bool,
}, .{ .unnamed = .reserved });

pub const Subsystem = struct {
    vendor_id: VendorId,
    id: DeviceId,
};

pub const IntrPin = enum(u8) {
    none = 0,
    inta = 1,
    intb = 2,
    intc = 3,
    intd = 4,

    pub const Error = error{MalformedField};

    pub fn tryFrom(encoded: u8) Error!IntrPin {
        return switch (encoded) {
            0 => .none,
            1 => .inta,
            2 => .intb,
            3 => .intc,
            4 => .intd,
            else => error.MalformedField,
        };
    }

    pub fn raw(self: IntrPin) u8 {
        return @intFromEnum(self);
    }

    comptime {
        std.debug.assert(@sizeOf(IntrPin) == 1);
        std.debug.assert(@intFromEnum(IntrPin.none) == 0);
        std.debug.assert(@intFromEnum(IntrPin.inta) == 1);
        std.debug.assert(@intFromEnum(IntrPin.intb) == 2);
        std.debug.assert(@intFromEnum(IntrPin.intc) == 3);
        std.debug.assert(@intFromEnum(IntrPin.intd) == 4);
    }
};

pub const offsets = struct {
    pub const vendor_id: u8 = 0x00;
    pub const device_id: u8 = 0x02;
    pub const command: u8 = 0x04;
    pub const status: u8 = 0x06;
    pub const revision_id: u8 = 0x08;
    pub const class_code: u8 = 0x09;
    pub const prog_if: u8 = class_code;
    pub const subclass: u8 = 0x0A;
    pub const base_class: u8 = 0x0B;
    pub const cache_line_size: u8 = 0x0C;
    pub const latency_timer: u8 = 0x0D;
    pub const @"type": u8 = 0x0E;
    pub const bist: u8 = 0x0F;
    pub const bar_base: u8 = 0x10;
    pub const cap_ptr: u8 = 0x34;
    pub const intr_line: u8 = 0x3C;
    pub const intr_pin: u8 = 0x3D;
};

pub const unit = struct {
    const testing = std.testing;

    test "IntrPin.tryFrom decodes every valid interrupt-pin byte" {
        try testing.expectEqual(IntrPin.none, try IntrPin.tryFrom(0));
        try testing.expectEqual(IntrPin.inta, try IntrPin.tryFrom(1));
        try testing.expectEqual(IntrPin.intb, try IntrPin.tryFrom(2));
        try testing.expectEqual(IntrPin.intc, try IntrPin.tryFrom(3));
        try testing.expectEqual(IntrPin.intd, try IntrPin.tryFrom(4));
    }

    test "IntrPin.tryFrom rejects reserved interrupt-pin bytes" {
        try testing.expectError(error.MalformedField, IntrPin.tryFrom(5));
        try testing.expectError(error.MalformedField, IntrPin.tryFrom(0xFF));
    }

    test "IntrPin.tryFrom round-trips encoded values" {
        inline for (.{ IntrPin.none, IntrPin.inta, IntrPin.intb, IntrPin.intc, IntrPin.intd }) |pin| {
            try testing.expectEqual(pin, try IntrPin.tryFrom(pin.raw()));
        }
    }

    test "Type maps format and multifunction bits" {
        const decoded = Type.from(0x81);

        try testing.expectEqual(WireFormat.type1, decoded.format);
        try testing.expect(decoded.multifunction);

        const word: Type.Word = .{ .format = .cardbus };

        try testing.expectEqual(@as(u8, 0x02), Type.raw(word));
    }

    test "unknown header format and DEVSEL timing preserve wire encodings" {
        const header_type = Type.from(0xFF);
        try testing.expectEqual(@as(u7, 0x7F), @intFromEnum(header_type.format));
        try testing.expectEqual(@as(u8, 0xFF), Type.raw(header_type));
        const status = Status.from(0x0600);
        try testing.expectEqual(@as(u2, 3), @intFromEnum(status.devsel_timing));
        try testing.expectEqual(@as(u16, 0x0600), Status.raw(status));
    }

    test "Command maps the PCI command register bits" {
        const decoded = Command.from(0x0557);

        try testing.expect(decoded.io_enable);
        try testing.expect(decoded.mem_enable);
        try testing.expect(decoded.bus_master);
        try testing.expect(!decoded.special_cycles);
        try testing.expect(decoded.mwi_enable);
        try testing.expect(!decoded.vga_palette_snoop);
        try testing.expect(decoded.parity_response);
        try testing.expectEqual(@as(u16, 0), Command.raw(decoded) & Command.masks.reserved);
        try testing.expect(decoded.serr_enable);
        try testing.expect(!decoded.fast_back_to_back);
        try testing.expect(decoded.intr_disable);
        try testing.expectEqual(@as(u16, 0x0557), Command.raw(decoded));
    }

    test "Status maps PCI status bits and sticky-error mask" {
        const decoded = Status.from(0xFDB8);

        try testing.expect(decoded.intr_pending);
        try testing.expect(decoded.cap_list);
        try testing.expect(decoded.capable_66mhz);
        try testing.expect(decoded.fast_back_to_back_capable);
        try testing.expect(decoded.master_data_parity_error);
        try testing.expectEqual(DevselTiming.slow, decoded.devsel_timing);
        try testing.expect(decoded.signaled_target_abort);
        try testing.expect(decoded.received_target_abort);
        try testing.expect(decoded.received_master_abort);
        try testing.expect(decoded.signaled_system_error);
        try testing.expect(decoded.detected_parity_error);

        try testing.expectEqual(@as(u16, 0xF900), Status.masks.w1c);
    }

    test "Bist maps completion, start, and capable bits" {
        const decoded = Bist.from(0xD7);

        try testing.expectEqual(@as(u4, 0x7), decoded.code);
        try testing.expectEqual(@as(u8, 0x10), Bist.raw(decoded) & Bist.masks.reserved);
        try testing.expect(decoded.start);
        try testing.expect(decoded.capable);
        try testing.expectEqual(@as(u8, 0xD7), Bist.raw(decoded));
    }

    test "ExpansionRom maps enable and base address bits" {
        const raw: u32 = 0xD5E6_5AAB;
        const decoded = ExpansionRom.from(raw);

        try testing.expect(decoded.enable);
        try testing.expectEqual(@as(u32, 0x2AA), ExpansionRom.raw(decoded) & ExpansionRom.masks.reserved);
        try testing.expectEqual(@as(u21, 0x1ABC_CB), decoded.base_shifted);
        try testing.expectEqual(raw, ExpansionRom.raw(decoded));
    }

    test "BridgeControl maps parity response and timer bits" {
        const raw: u16 = 0xAD53;
        const decoded = BridgeControl.from(raw);

        try testing.expect(decoded.parity_response);
        try testing.expect(decoded.serr_enable);
        try testing.expect(!decoded.isa_enable);
        try testing.expect(!decoded.vga_enable);
        try testing.expect(decoded.vga_decode_16bit);
        try testing.expect(!decoded.master_abort_mode);
        try testing.expect(decoded.secondary_bus_reset);
        try testing.expect(!decoded.fast_back_to_back_enable);
        try testing.expect(decoded.primary_discard_timer);
        try testing.expect(!decoded.secondary_discard_timer);
        try testing.expect(decoded.discard_timer_status);
        try testing.expect(decoded.discard_timer_serr_enable);
        try testing.expectEqual(@as(u16, 0xA000), BridgeControl.raw(decoded) & BridgeControl.masks.reserved);
        try testing.expectEqual(raw, BridgeControl.raw(decoded));
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Type, 0, 0, 0, 0 },
            .{ Command, 0x077F, 0, 0, 0xF880 },
            .{ Status, 0, 0xF900, 0, 0x0047 },
            .{ Bist, 0, 0, 0x40, 0x30 },
            .{ ExpansionRom, 0xFFFF_F801, 0, 0, 0x0000_07FE },
            .{ BridgeControl, 0x0BFF, 0x0400, 0, 0xF000 },
        }) |case| {
            const T = case[0];
            const Raw = @TypeOf(T.masks.assign);

            try testing.expectEqual(@as(Raw, case[1]), T.masks.assign);
            try testing.expectEqual(@as(Raw, case[2]), T.masks.w1c);
            try testing.expectEqual(@as(Raw, case[3]), T.masks.trigger);
            try testing.expectEqual(@as(Raw, case[4]), T.masks.reserved);
            const raw = std.math.maxInt(Raw);
            const decoded = T.from(raw);
            try testing.expectEqual(raw, T.raw(decoded));
            try testing.expectEqual(raw, T.raw(T.replace(decoded, .{})));
        }
    }

    test "consumers can update controls without acknowledging unrelated sticky bits" {
        const T = BridgeControl;
        const observed: u16 = 0xF441;
        const requested = T.encode(.{ .vga_enable = true });
        const selected = T.mask(.{ .vga_enable, .parity_response });
        const ordinary = selected & T.masks.assign;
        const updated = (observed & ~ordinary) | (requested & ordinary);

        try testing.expectEqual(@as(u16, 0xF448), updated);

        const acknowledged = updated & ~(T.masks.w1c & T.mask(.{.discard_timer_status}));

        try testing.expectEqual(@as(u16, 0xF048), acknowledged);
        try testing.expectEqual(observed & T.masks.reserved, acknowledged & T.masks.reserved);
    }

    test "field masks select command and header fields" {
        try testing.expectEqual(@as(u8, 0x80), Type.mask(.{.multifunction}));
        try testing.expectEqual(@as(u16, 0), Command.mask(.{}));
        try testing.expectEqual(@as(u16, 0x0006), Command.mask(.{ .mem_enable, .bus_master, .mem_enable }));
    }
};
