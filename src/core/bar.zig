//! PCI BAR register representations.

pub const stride: usize = @sizeOf(u32);

pub const Space = enum(u1) {
    mem = 0,
    io = 1,
};

pub const Io = packed struct(u32) {
    space: Space = .io,
    _rsvd_1: bool = false,
    address_shifted: u30 = 0,

    pub fn from(value: u32) Io {
        return @bitCast(value);
    }

    pub fn raw(self: Io) u32 {
        return @bitCast(self);
    }

    pub fn base(self: Io) u32 {
        return @as(u32, self.address_shifted) << 2;
    }

    pub fn withBase(self: Io, address: u32) Io {
        var result = self;
        result.address_shifted = @truncate(address >> 2);
        return result;
    }
};

pub const Memory = packed struct(u32) {
    space: Space = .mem,
    type: Type = .bits_32,
    prefetchable: bool = false,
    address_shifted: u28 = 0,

    pub const Type = enum(u2) {
        bits_32 = 0,
        below_1m = 1,
        bits_64 = 2,
        reserved = 3,
    };

    pub fn from(value: u32) Memory {
        return @bitCast(value);
    }

    pub fn raw(self: Memory) u32 {
        return @bitCast(self);
    }

    pub fn base(self: Memory) u32 {
        return @as(u32, self.address_shifted) << 4;
    }

    pub fn withBase(self: Memory, address: u32) Memory {
        var result = self;
        result.address_shifted = @truncate(address >> 4);
        return result;
    }
};

pub const Memory64 = struct {
    lo: Memory,
    hi: u32,

    pub fn from(lo: u32, hi: u32) Memory64 {
        return .{ .lo = Memory.from(lo), .hi = hi };
    }

    pub fn base(self: Memory64) u64 {
        return (@as(u64, self.hi) << 32) | self.lo.base();
    }

    pub fn withBase(self: Memory64, address: u64) Memory64 {
        return .{
            .lo = self.lo.withBase(@truncate(address)),
            .hi = @truncate(address >> 32),
        };
    }
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "BAR address replacement preserves low-dword attributes" {
        const io = Io.from(0x1237);

        try testing.expectEqual(Space.io, io.space);
        try testing.expect(io._rsvd_1);
        try testing.expectEqual(@as(u32, 0x1234), io.base());
        try testing.expectEqual(@as(u32, 0xABCF), io.withBase(0xABCD).raw());

        const memory = Memory.from(0x8000_000C);

        try testing.expectEqual(Space.mem, memory.space);
        try testing.expectEqual(Memory.Type.bits_64, memory.type);
        try testing.expect(memory.prefetchable);
        try testing.expectEqual(@as(u32, 0x8000_0000), memory.base());
        try testing.expectEqual(@as(u32, 0x1234_567C), memory.withBase(0x1234_567F).raw());
    }

    test "memory BAR type encoding retains unsupported and reserved formats" {
        try testing.expectEqual(Memory.Type.bits_32, Memory.from(0).type);
        try testing.expectEqual(Memory.Type.below_1m, Memory.from(2).type);
        try testing.expectEqual(Memory.Type.bits_64, Memory.from(4).type);
        try testing.expectEqual(Memory.Type.reserved, Memory.from(6).type);
    }

    test "64-bit BAR composition retains all high address bits and low attributes" {
        const value = Memory64.from(0x1234_500C, 0x89AB_CDEF);

        try testing.expectEqual(@as(u64, 0x89AB_CDEF_1234_5000), value.base());

        const changed = value.withBase(0x7654_321F_ABC0_0000);

        try testing.expectEqual(@as(u64, 0x7654_321F_ABC0_0000), changed.base());
        try testing.expectEqual(@as(u32, 0xABC0_000C), changed.lo.raw());
        try testing.expectEqual(@as(u32, 0x7654_321F), changed.hi);
    }
};
