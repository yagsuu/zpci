const stdx = @import("stdx");
const config = @import("../config.zig");

const BitField = stdx.bits.BitField;

const OffsetRange = stdx.ranges.InclusiveRange(u16);

pub const Header = BitField(u32, .{
    .id = .{ .type = Id, .access = .ro },
    .version = .{ .type = u4, .access = .ro },
    .next = .{ .type = u12, .access = .ro },
});

pub const Id = enum(u16) {
    _,
};

pub const window = struct {
    pub const range = OffsetRange.of(config.size, config.extended_size - stride);
    pub const stride: u16 = 4;
    pub const count: usize = @divExact(@as(usize, range.end) - range.start, stride) + 1;
};

pub const unit = struct {
    const testing = @import("std").testing;

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

    test "next pointer and full header field masks" {
        try testing.expectEqual(@as(u32, 0xFFF0_0000), Header.mask(.{.next}));
        try testing.expectEqual(@as(u32, 0xFFFF_FFFF), Header.mask(.{ .id, .version, .next }));
    }
};
