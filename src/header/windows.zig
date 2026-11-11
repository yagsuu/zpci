//! Bridge forwarding-window values and register codecs.

const stdx = @import("stdx");
const core = @import("core");

const IoRegisters = core.bridge.Io;
const MemoryRegisters = core.bridge.Memory;
const PrefetchRegisters = MemoryRegisters.Prefetch;

const Range = stdx.ranges.InclusiveRange(u64);

pub const Io = struct {
    range: ?Range,

    pub fn decode(registers: IoRegisters) Io {
        const base_format = registers.base_lo & 0xF;
        const limit_format = registers.limit_lo & 0xF;

        if (base_format != limit_format or base_format > 1) {
            return .{ .range = null };
        }

        const base_hi = if (base_format == 1) registers.base_hi else 0;
        const limit_hi = if (base_format == 1) registers.limit_hi else 0;
        const base = (@as(u64, registers.base_lo & 0xF0) << 8) | (@as(u64, base_hi) << 16);
        const limit = (@as(u64, registers.limit_lo & 0xF0) << 8) | (@as(u64, IoRegisters.alignment) - 1) | (@as(u64, limit_hi) << 16);

        return .{ .range = Range.init(base, limit) catch null };
    }

    pub fn contains(self: Io, address: u64, size: u64) bool {
        const bounds = self.range orelse return false;
        const request = Range.fromStartLen(address, size) catch return false;

        return bounds.containsRange(request);
    }
};

pub const Memory = struct {
    range: ?Range,

    pub const Prefetch = struct {
        range: Range,
        width: Width,

        pub const Width = enum { mem32, mem64 };

        pub fn decode(registers: PrefetchRegisters) ?Prefetch {
            const base_format = registers.base_lo & 0xF;
            const limit_format = registers.limit_lo & 0xF;

            if (base_format != limit_format) {
                return null;
            }

            const width: Width = switch (base_format) {
                0 => .mem32,
                1 => .mem64,
                else => return null,
            };

            const base_hi = if (width == .mem64) registers.base_hi else 0;
            const limit_hi = if (width == .mem64) registers.limit_hi else 0;
            const base = Base.init(registers.base_lo) | (@as(u64, base_hi) << 32);
            const limit = Limit.init(registers.limit_lo) | (@as(u64, limit_hi) << 32);

            return .{
                .range = Range.init(base, limit) catch return null,
                .width = width,
            };
        }

        pub fn contains(self: Prefetch, address: u64, size: u64) bool {
            const request = Range.fromStartLen(address, size) catch return false;
            return self.range.containsRange(request);
        }
    };

    pub fn decode(registers: MemoryRegisters) Memory {
        return .{
            .range = Range.init(Base.init(registers.base), Limit.init(registers.limit)) catch null,
        };
    }

    pub fn contains(self: Memory, address: u64, size: u64) bool {
        const bounds = self.range orelse return false;
        const request = Range.fromStartLen(address, size) catch return false;

        return bounds.containsRange(request);
    }

    const Base = struct {
        fn init(encoded: u16) u64 {
            return @as(u64, encoded & 0xFFF0) << 16;
        }
    };

    const Limit = struct {
        fn init(encoded: u16) u64 {
            return Base.init(encoded) | (MemoryRegisters.alignment - 1);
        }
    };
};

pub const State = struct {
    io: Io,
    mem: Memory,
    mem_prefetch: ?Memory.Prefetch,
};

pub const unit = struct {
    const std = @import("std");
    const testing = std.testing;

    test "Io contains checks closed bounds zero size disabled and overflow" {
        const w = Io{ .range = .{ .start = 0x1000, .end = 0x1FFF } };
        const inactive = Io{ .range = null };

        try testing.expect(w.contains(0x1000, 1));
        try testing.expect(w.contains(0x1FF0, 0x10));
        try testing.expect(!w.contains(0x0FFF, 1));
        try testing.expect(!w.contains(0x1FF0, 0x11));
        try testing.expect(!w.contains(0x1000, 0));
        try testing.expect(!w.contains(std.math.maxInt(u64), 2));
        try testing.expect(!inactive.contains(0x1000, 1));
    }

    test "Prefetch contains checks closed bounds zero size and overflow" {
        const w = Memory.Prefetch{
            .range = .{ .start = 0x1_0000_0000, .end = 0x1_0000_FFFF },
            .width = .mem64,
        };

        try testing.expect(w.contains(0x1_0000_0000, 1));
        try testing.expect(w.contains(0x1_0000_F000, 0x1000));
        try testing.expect(!w.contains(0x0_FFFF_FFFF, 1));
        try testing.expect(!w.contains(0x1_0000_F000, 0x1001));
        try testing.expect(!w.contains(0x1_0000_0000, 0));
        try testing.expect(!w.contains(std.math.maxInt(u64), 2));
    }

    test "disabled register values decode to inactive windows" {
        try testing.expectEqual(null, Io.decode(IoRegisters.disabled()).range);
        try testing.expectEqual(null, Memory.decode(MemoryRegisters.disabled()).range);
        try testing.expectEqual(null, Memory.Prefetch.decode(.{
            .base_lo = 0xFFF0,
            .limit_lo = 0,
            .base_hi = 0,
            .limit_hi = 0,
        }));
    }

    test "IO decoding validates formats and ignores 16-bit upper words" {
        try testing.expectEqualDeep(
            Io{ .range = .{ .start = 0, .end = 0xFFF } },
            Io.decode(try IoRegisters.encode(0, 0xFFF)),
        );
        try testing.expectEqualDeep(
            Io{ .range = .{ .start = 0x2000, .end = 0x3FFF } },
            Io.decode(.{ .base_lo = 0x20, .limit_lo = 0x30, .base_hi = 2, .limit_hi = 1 }),
        );
        try testing.expectEqualDeep(
            Io{ .range = .{ .start = 0x1_2000, .end = 0x2_3FFF } },
            Io.decode(.{ .base_lo = 0x21, .limit_lo = 0x31, .base_hi = 1, .limit_hi = 2 }),
        );
        try testing.expectEqualDeep(
            Io{ .range = .{ .start = 0, .end = std.math.maxInt(u32) } },
            Io.decode(try IoRegisters.encode(0, std.math.maxInt(u32))),
        );
        try testing.expectEqual(null, Io.decode(.{ .base_lo = 1, .limit_lo = 1, .base_hi = 2, .limit_hi = 1 }).range);

        for (0..16) |base_format| {
            for (0..16) |limit_format| {
                if (base_format == limit_format and base_format <= 1) {
                    continue;
                }

                try testing.expectEqual(null, Io.decode(.{
                    .base_lo = 0x20 | @as(u8, @intCast(base_format)),
                    .limit_lo = 0x30 | @as(u8, @intCast(limit_format)),
                    .base_hi = 0,
                    .limit_hi = 0,
                }).range);
            }
        }
    }

    test "memory decoders compare expanded addresses and preserve inclusive limits" {
        try testing.expectEqualDeep(
            Memory{ .range = .{ .start = 0x2000_0000, .end = 0x200F_FFFF } },
            Memory.decode(.{ .base = 0x2000, .limit = 0x2000 }),
        );
        try testing.expectEqualDeep(
            Memory{ .range = .{ .start = 0x2000_0000, .end = 0x200F_FFFF } },
            Memory.decode(.{ .base = 0x2001, .limit = 0x2000 }),
        );
        try testing.expectEqual(null, Memory.decode(.{ .base = 0x2010, .limit = 0x200F }).range);

        try testing.expectEqualDeep(Memory.Prefetch{
            .range = .{ .start = 0xD000_0000, .end = 0xDFFF_FFFF },
            .width = .mem32,
        }, Memory.Prefetch.decode(.{ .base_lo = 0xD000, .limit_lo = 0xDFF0, .base_hi = 0, .limit_hi = 0 }).?);
        try testing.expectEqualDeep(Memory.Prefetch{
            .range = .{ .start = 0x1_0000_0000, .end = 0x1_0FFF_FFFF },
            .width = .mem64,
        }, Memory.Prefetch.decode(.{ .base_lo = 1, .limit_lo = 0xFF1, .base_hi = 1, .limit_hi = 1 }).?);

        const window = Memory.Prefetch.decode(.{
            .base_lo = 0xD000,
            .limit_lo = 0xDFF0,
            .base_hi = std.math.maxInt(u32),
            .limit_hi = 0,
        }).?;
        try testing.expectEqualDeep(Memory.Prefetch{
            .range = .{ .start = 0xD000_0000, .end = 0xDFFF_FFFF },
            .width = .mem32,
        }, window);
    }

    test "prefetch decoding rejects mixed and reserved formats" {
        for (0..16) |base_format| {
            for (0..16) |limit_format| {
                if (base_format == limit_format and base_format <= 1) {
                    continue;
                }

                try testing.expectEqual(null, Memory.Prefetch.decode(.{
                    .base_lo = 0xD000 | @as(u16, @intCast(base_format)),
                    .limit_lo = 0xDFF0 | @as(u16, @intCast(limit_format)),
                    .base_hi = 0,
                    .limit_hi = 0,
                }));
            }
        }
    }

    test "explicit 64-bit encoding preserves decoded width below 4 GiB" {
        const explicit = try MemoryRegisters.Prefetch64.encode(0xF000_0000, 0xFFFF_FFFF);

        try testing.expectEqualDeep(Memory.Prefetch{
            .range = .{ .start = 0xF000_0000, .end = 0xFFFF_FFFF },
            .width = .mem64,
        }, Memory.Prefetch.decode(.{
            .base_lo = explicit.base_lo,
            .limit_lo = explicit.limit_lo,
            .base_hi = explicit.base_hi,
            .limit_hi = explicit.limit_hi,
        }).?);
    }

    test "full u64 prefetch window contains checked requests" {
        const max = std.math.maxInt(u64);
        const window = Memory.Prefetch.decode(.{
            .base_lo = 1,
            .limit_lo = 0xFFF1,
            .base_hi = 0,
            .limit_hi = std.math.maxInt(u32),
        }).?;

        try testing.expectEqual(@as(u64, 0), window.range.start);
        try testing.expectEqual(max, window.range.end);
        try testing.expectEqual(Memory.Prefetch.Width.mem64, window.width);
        try testing.expect(window.contains(0, max));
        try testing.expect(window.contains(1, max));
        try testing.expect(window.contains(max, 1));
        try testing.expect(!window.contains(0, 0));
        try testing.expect(!window.contains(max, 0));
        try testing.expect(!window.contains(max, 2));
        try testing.expect(!window.contains(2, max));
    }

    test "Memory contains checks closed bounds zero size disabled and overflow" {
        const window = Memory.decode(.{ .base = 0x2000, .limit = 0x2000 });
        const inactive = Memory.decode(.{ .base = 0x2010, .limit = 0x200F });

        try testing.expect(window.contains(0x2000_0000, 0x10_0000));
        try testing.expect(window.contains(0x200F_FFFF, 1));
        try testing.expect(!window.contains(0x1FFF_FFFF, 1));
        try testing.expect(!window.contains(0x200F_FFFF, 2));
        try testing.expect(!window.contains(0x2000_0000, 0));
        try testing.expect(!window.contains(std.math.maxInt(u64), 2));
        try testing.expectEqual(null, inactive.range);
        try testing.expect(!inactive.contains(0x2000_0000, 1));
    }
};
