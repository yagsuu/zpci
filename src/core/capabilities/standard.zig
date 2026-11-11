const stdx = @import("stdx");
const config = @import("../config.zig");

const BitField = stdx.bits.BitField;

const OffsetRange = stdx.ranges.InclusiveRange(u8);

pub const Header = BitField(u16, .{
    .id = .{ .type = Id, .access = .ro, .default = @as(Id, @enumFromInt(0)) },
    .next = .{ .type = u8, .access = .ro },
});

pub const Id = enum(u8) {
    pcie = 0x10,
    msi = 0x05,
    msix = 0x11,
    _,
};

pub const window = struct {
    pub const range = OffsetRange.of(0x40, config.size - stride);
    pub const stride: u8 = 4;
    pub const count: usize = @divExact(@as(usize, range.end) - range.start, stride) + 1;
};

pub const offsets = struct {
    pub const id: u8 = 0x00;
    pub const next: u8 = 0x01;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "standard capability Header maps ID and next bytes" {
        try testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(Header.Word));
        try testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Header.Word, "id"));
        try testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(Header.Word, "next"));

        const decoded = Header.from(0x8010);

        try testing.expectEqual(@as(u8, 0x10), @intFromEnum(decoded.id));
        try testing.expectEqual(@as(u8, 0x80), decoded.next);
        try testing.expectEqual(@as(u16, 0x4411), Header.encode(.{ .id = .msix, .next = 0x44 }));
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Header, 0, 0, 0, 0 },
        }) |case| {
            const T = case[0];
            const Raw = @TypeOf(T.masks.assign);

            try testing.expectEqual(@as(Raw, case[1]), T.masks.assign);
            try testing.expectEqual(@as(Raw, case[2]), T.masks.w1c);
            try testing.expectEqual(@as(Raw, case[3]), T.masks.trigger);
            try testing.expectEqual(@as(Raw, case[4]), T.masks.reserved);
        }
    }

    test "next pointer field mask" {
        try testing.expectEqual(@as(u16, 0xFF00), Header.mask(.{.next}));
    }
};
