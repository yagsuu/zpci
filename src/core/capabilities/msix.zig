const std = @import("std");

const stdx = @import("stdx");

const standard = @import("standard.zig");

const BitField = stdx.bits.BitField;
const Id = standard.Id;
const Struct = stdx.layout.Struct;

pub const id: Id = .msix;

pub const max_vectors: u16 = @as(u16, std.math.maxInt(@FieldType(Control.Word, "table_size_minus_one"))) + 1;

pub const Control = BitField(u16, .{
    .table_size_minus_one = .{ .type = u11, .access = .ro },
    ._rsvd_11 = .{ .type = u3, .access = .reserved },
    .function_mask = bool,
    .enable = bool,
});

pub const Location = BitField(u32, .{
    .bir = .{ .type = u3, .access = .ro },
    .offset_shifted = .{ .type = u29, .access = .ro },
});

pub const TableEntry = Struct(.{ .size = 16, .alignment = 4 }, .{
    .address_lo = .{ .type = u32, .offset = table.offsets.address_lo },
    .address_hi = .{ .type = u32, .offset = table.offsets.address_hi },
    .data = .{ .type = u32, .offset = table.offsets.data },
    .control = .{ .type = VectorControl.Word, .offset = table.offsets.control },
});

pub const VectorControl = BitField(u32, .{
    .masked = bool,
    ._rsvd_1 = .{ .type = u31, .access = .reserved },
});

pub const offsets = struct {
    pub const control: u8 = 0x02;
    pub const table: u8 = 0x04;
    pub const pba: u8 = 0x08;
};

pub const table = struct {
    pub const offsets = struct {
        pub const address_lo: u8 = 0x00;
        pub const address_hi: u8 = 0x04;
        pub const data: u8 = 0x08;
        pub const control: u8 = 0x0C;
    };
};

pub const unit = struct {
    const testing = std.testing;

    test "MSI-X location preserves BIR and encoded offset bits" {
        const location = Location.from(0x1234_5005);

        try testing.expectEqual(@as(u3, 5), location.bir);
        try testing.expectEqual(@as(u29, 0x1234_5000 >> 3), location.offset_shifted);
        try testing.expectEqual(@as(u32, 0x1234_5005), Location.raw(location));

        const maximum = Location.from(0xFFFF_FFFF);

        try testing.expectEqual(@as(u3, 7), maximum.bir);
        try testing.expectEqual(@as(u29, 0x1FFF_FFFF), maximum.offset_shifted);
    }

    test "MSI-X table entry matches the four-dword wire record" {
        const entry = TableEntry{
            .address_lo = 0x89AB_CDEF,
            .address_hi = 0x0123_4567,
            .data = 0xCAFE_BABE,
            .control = VectorControl.from(0xA5A5_A5A5),
        };

        try testing.expectEqualSlices(u8, &.{
            0xEF, 0xCD, 0xAB, 0x89,
            0x67, 0x45, 0x23, 0x01,
            0xBE, 0xBA, 0xFE, 0xCA,
            0xA5, 0xA5, 0xA5, 0xA5,
        }, std.mem.asBytes(&entry));
    }

    test "access masks distinguish writable, sticky, action, and reserved bits" {
        inline for (.{
            .{ Control, 0xC000, 0, 0, 0x3800 },
            .{ VectorControl, 0x0000_0001, 0, 0, 0xFFFF_FFFE },
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
