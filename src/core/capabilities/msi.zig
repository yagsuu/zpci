const stdx = @import("stdx");

const standard = @import("standard.zig");

const msi = @This();

const BitField = stdx.bits.BitField;
const Id = standard.Id;

pub const id: Id = .msi;

pub const Control = BitField(u16, .{
    .enable = bool,
    .multiple_msg_capable = .{ .type = u3, .access = .ro },
    .multiple_msg_enable = u3,
    .addr64_capable = .{ .type = bool, .access = .ro },
    .pvm_capable = .{ .type = bool, .access = .ro },
    .ext_data_capable = .{ .type = bool, .access = .ro },
    .ext_data_enable = bool,
    ._rsvd_11 = .{ .type = u5, .access = .reserved },
});

pub const VectorCount = enum(u3) {
    one = 0,
    two = 1,
    four = 2,
    eight = 3,
    sixteen = 4,
    thirty_two = 5,
    _,

    pub fn from(raw: u3) VectorCount {
        return @enumFromInt(raw);
    }

    pub fn count(self: VectorCount) error{MalformedField}!u6 {
        return switch (@intFromEnum(self)) {
            0...5 => @as(u6, 1) << @as(u3, @intCast(@intFromEnum(self))),
            else => error.MalformedField,
        };
    }

    pub fn fromCount(n: u6) error{InvalidRouting}!VectorCount {
        return switch (n) {
            1 => .one,
            2 => .two,
            4 => .four,
            8 => .eight,
            16 => .sixteen,
            32 => .thirty_two,
            else => error.InvalidRouting,
        };
    }
};

pub const offsets = struct {
    pub const control: u8 = 0x02;
    pub const address_lo: u8 = 0x04;
};

pub const addr32 = struct {
    pub const offsets = struct {
        pub const control = msi.offsets.control;
        pub const address_lo = msi.offsets.address_lo;
        pub const data: u8 = 0x08;
        pub const ext_data: u8 = 0x0A;
        pub const mask: u8 = 0x0C;
        pub const pending: u8 = 0x10;
    };
};

pub const addr64 = struct {
    pub const offsets = struct {
        pub const control = msi.offsets.control;
        pub const address_lo = msi.offsets.address_lo;
        pub const address_hi: u8 = 0x08;
        pub const data: u8 = 0x0C;
        pub const ext_data: u8 = 0x0E;
        pub const mask: u8 = 0x10;
        pub const pending: u8 = 0x14;
    };
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Control, 0x0471, 0, 0, 0xF800 },
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
