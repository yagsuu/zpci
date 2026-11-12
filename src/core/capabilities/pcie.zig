const stdx = @import("stdx");

const standard = @import("standard.zig");

const Id = standard.Id;
const BitField = stdx.bits.BitField;

pub const device = @import("pcie/device.zig");
pub const link = @import("pcie/link.zig");
pub const slot = @import("pcie/slot.zig");
pub const root = @import("pcie/root.zig");

pub const id: Id = .pcie;

pub const Capabilities = BitField(u16, .{
    .version = .{ .type = u4, .access = .ro },
    .type = .{ .type = DevicePortType, .access = .ro, .default = .endpoint },
    .has_slot = .{ .type = bool, .access = .ro },
    .intr_message = .{ .type = u5, .access = .ro },
    ._rsvd_14 = .{ .type = u1, .access = .reserved },
    .flit_mode_supported = .{ .type = bool, .access = .ro },
});

pub const DevicePortType = enum(u4) {
    endpoint = 0x0,
    legacy_endpoint = 0x1,
    root_port = 0x4,
    upstream = 0x5,
    downstream = 0x6,
    pcie_to_pci_bridge = 0x7,
    pci_to_pcie_bridge = 0x8,
    root_complex_integrated_endpoint = 0x9,
    root_complex_event_collector = 0xA,
    _,
};

pub const PowerLimitScale = enum(u2) {
    watts_1 = 0,
    watts_0_1 = 1,
    watts_0_01 = 2,
    watts_0_001 = 3,
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x02;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "register bit positions" {
        try testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Capabilities.Word, "version"));
        try testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(Capabilities.Word, "type"));
        try testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(Capabilities.Word, "has_slot"));
        try testing.expectEqual(@as(comptime_int, 14), @bitOffsetOf(Capabilities.Word, "_rsvd_14"));
    }

    test "capabilities decode flit support independently of slot and port type" {
        const word = Capabilities.from(0x8052);

        try testing.expect(word.flit_mode_supported);
        try testing.expect(!word.has_slot);
        try testing.expectEqual(DevicePortType.upstream, word.type);
        try testing.expectEqual(@as(u4, 2), word.version);
        try testing.expectEqual(@as(u16, 0x8052), Capabilities.raw(word));
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Capabilities, 0, 0, 0, 0x4000 },
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
