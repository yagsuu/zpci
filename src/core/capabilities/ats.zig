const stdx = @import("stdx");

const extended = @import("extended.zig");

const BitFieldExt = stdx.bits.BitFieldExt;

pub const id: extended.Id = .ats;

pub const Capabilities = BitFieldExt(u16, .{
    .queue_depth = .{ .type = u5, .access = .ro },
    .page_aligned = .{ .type = bool, .access = .ro },
    .global_invalidate = .{ .type = bool, .access = .ro },
    .relaxed_ordering = .{ .type = bool, .access = .ro },
    .mem_attributes = .{ .type = bool, .access = .ro },
}, .{ .unnamed = .reserved });

pub const Control = BitFieldExt(u16, .{
    .stu = .{ .type = Stu, .default = .size_4k },
    .mem_attr_default = .{ .offset = 11, .type = u3 },
    .mem_attr_enable = bool,
    .enable = bool,
}, .{ .unnamed = .reserved });

pub const Stu = enum(u5) {
    size_4k = 0,
    _,

    pub fn from(value: u5) Stu {
        return @fromBackingInt(value);
    }

    pub fn raw(self: Stu) u5 {
        return @backingInt(self);
    }

    pub fn shift(self: Stu) u6 {
        return @as(u6, self.raw()) + 12;
    }

    pub fn bytes(self: Stu) u64 {
        return @as(u64, 1) << self.shift();
    }
};

pub const offsets = struct {
    pub const capabilities: u8 = 0x04;
    pub const control: u8 = 0x06;
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "ATS fields match PCI positions and access classes" {
        inline for (.{
            .{ .queue_depth, 0x001F },
            .{ .page_aligned, 0x0020 },
            .{ .global_invalidate, 0x0040 },
            .{ .relaxed_ordering, 0x0080 },
            .{ .mem_attributes, 0x0100 },
        }) |case| {
            try testing.expectEqual(@as(u16, case[1]), Capabilities.mask(.{case[0]}));
        }

        inline for (.{
            .{ .stu, 0x001F },
            .{ .mem_attr_default, 0x3800 },
            .{ .mem_attr_enable, 0x4000 },
            .{ .enable, 0x8000 },
        }) |case| {
            try testing.expectEqual(@as(u16, case[1]), Control.mask(.{case[0]}));
        }

        try testing.expectEqual(@as(u16, 0), Capabilities.masks.assign);
        try testing.expectEqual(@as(u16, 0xFE00), Capabilities.masks.reserved);
        try testing.expectEqual(@as(u16, 0xF81F), Control.masks.assign);
        try testing.expectEqual(@as(u16, 0x07E0), Control.masks.reserved);
        try testing.expectEqual(@as(u16, 0), Control.masks.trigger | Control.masks.w1c);
        try testing.expectEqual(@as(u16, 0), Control.encode(.{}));
    }

    test "STU preserves every encoding and covers both size extremes" {
        for (0..32) |value| {
            const stu = Stu.from(@intCast(value));
            try testing.expectEqual(@as(u5, @intCast(value)), stu.raw());
            try testing.expectEqual(@as(u6, @intCast(value + 12)), stu.shift());
        }

        try testing.expectEqual(@as(u64, 4096), Stu.size_4k.bytes());
        try testing.expectEqual(@as(u64, 1) << 43, Stu.from(31).bytes());
    }
};
