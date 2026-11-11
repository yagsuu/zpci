//! Bridge forwarding-window register values.

const std = @import("std");

pub const Io = struct {
    base_lo: u8,
    limit_lo: u8,
    base_hi: u16,
    limit_hi: u16,

    pub const alignment: u64 = 0x1000;

    pub fn encode(base: u64, limit: u64) Error!Io {
        if (base > std.math.maxInt(u32)) {
            return error.Unencodable;
        }

        if (limit > std.math.maxInt(u32)) {
            return error.Unencodable;
        }

        if (base % alignment != 0) {
            return error.Unencodable;
        }

        if (limit & (alignment - 1) != alignment - 1) {
            return error.Unencodable;
        }

        const wide = limit > std.math.maxInt(u16);
        const format: u8 = if (wide) 0x1 else 0x0;

        return .{
            .base_lo = (@as(u8, @truncate(base >> 8)) & 0xF0) | format,
            .limit_lo = (@as(u8, @truncate(limit >> 8)) & 0xF0) | format,
            .base_hi = if (wide) @as(u16, @truncate(base >> 16)) else 0,
            .limit_hi = if (wide) @as(u16, @truncate(limit >> 16)) else 0,
        };
    }

    pub fn disabled() Io {
        return .{ .base_lo = 0xF0, .limit_lo = 0, .base_hi = 0, .limit_hi = 0 };
    }
};

pub const Memory = struct {
    base: u16,
    limit: u16,

    pub const alignment: u64 = 0x10_0000;

    pub const Prefetch = struct {
        base_lo: u16,
        limit_lo: u16,
        base_hi: u32,
        limit_hi: u32,
    };

    pub const Prefetch32 = struct {
        base_lo: u16,
        limit_lo: u16,

        pub fn encode(base: u64, limit: u64) Error!Prefetch32 {
            try checkAlignment(base, limit);

            if (limit > std.math.maxInt(u32)) {
                return error.Unencodable;
            }

            return .{
                .base_lo = @as(u16, @truncate(base >> 16)) & 0xFFF0,
                .limit_lo = @as(u16, @truncate(limit >> 16)) & 0xFFF0,
            };
        }

        pub fn disabled() Prefetch32 {
            return .{ .base_lo = 0xFFF0, .limit_lo = 0 };
        }
    };

    pub const Prefetch64 = struct {
        base_lo: u16,
        limit_lo: u16,
        base_hi: u32,
        limit_hi: u32,

        pub fn encode(base: u64, limit: u64) Error!Prefetch64 {
            try checkAlignment(base, limit);

            return .{
                .base_lo = (@as(u16, @truncate(base >> 16)) & 0xFFF0) | 0x1,
                .limit_lo = (@as(u16, @truncate(limit >> 16)) & 0xFFF0) | 0x1,
                .base_hi = @as(u32, @truncate(base >> 32)),
                .limit_hi = @as(u32, @truncate(limit >> 32)),
            };
        }
    };

    pub fn encode(base: u64, limit: u64) Error!Memory {
        if (base > std.math.maxInt(u32)) {
            return error.Unencodable;
        }

        if (limit > std.math.maxInt(u32)) {
            return error.Unencodable;
        }

        try checkAlignment(base, limit);

        return .{
            .base = @as(u16, @truncate(base >> 16)) & 0xFFF0,
            .limit = @as(u16, @truncate(limit >> 16)) & 0xFFF0,
        };
    }

    pub fn disabled() Memory {
        return .{ .base = 0xFFF0, .limit = 0 };
    }

    fn checkAlignment(base: u64, limit: u64) Error!void {
        if (base % alignment != 0) {
            return error.Unencodable;
        }

        if (limit & (alignment - 1) != alignment - 1) {
            return error.Unencodable;
        }
    }
};

pub const Type = enum { io, mem, mem_prefetch };
pub const Error = error{Unencodable};

pub const Encoding = union(enum) {
    io: Io,
    mem: Memory,
    mem_prefetch_32: Memory.Prefetch32,
    mem_prefetch_64: Memory.Prefetch64,

    pub fn encode(window_type: Type, base: u64, limit: u64) Error!Encoding {
        return switch (window_type) {
            .io => .{ .io = try Io.encode(base, limit) },
            .mem => .{ .mem = try Memory.encode(base, limit) },
            .mem_prefetch => if (limit <= std.math.maxInt(u32))
                .{ .mem_prefetch_32 = try Memory.Prefetch32.encode(base, limit) }
            else
                .{ .mem_prefetch_64 = try Memory.Prefetch64.encode(base, limit) },
        };
    }

    pub fn disabled(window_type: Type) Encoding {
        return switch (window_type) {
            .io => .{ .io = Io.disabled() },
            .mem => .{ .mem = Memory.disabled() },
            .mem_prefetch => .{ .mem_prefetch_32 = Memory.Prefetch32.disabled() },
        };
    }
};

pub const unit = struct {
    const testing = std.testing;

    const Prefetch64Registers = Memory.Prefetch64;

    test "disabled encodings preserve inverted bounds" {
        try testing.expectEqualDeep(Encoding{ .io = .{
            .base_lo = 0xF0,
            .limit_lo = 0,
            .base_hi = 0,
            .limit_hi = 0,
        } }, Encoding.disabled(.io));
        try testing.expectEqualDeep(
            Encoding{ .mem = .{ .base = 0xFFF0, .limit = 0 } },
            Encoding.disabled(.mem),
        );
        try testing.expectEqualDeep(
            Encoding{ .mem_prefetch_32 = .{ .base_lo = 0xFFF0, .limit_lo = 0 } },
            Encoding.disabled(.mem_prefetch),
        );
    }

    test "IO encoding selects 16-bit and 32-bit fields" {
        try testing.expectEqualDeep(Encoding{ .io = .{
            .base_lo = 0x20,
            .limit_lo = 0x20,
            .base_hi = 0,
            .limit_hi = 0,
        } }, try Encoding.encode(.io, 0x2000, 0x2FFF));

        try testing.expectEqualDeep(Encoding{ .io = .{
            .base_lo = 0x21,
            .limit_lo = 0x21,
            .base_hi = 1,
            .limit_hi = 1,
        } }, try Encoding.encode(.io, 0x1_2000, 0x1_2FFF));
    }

    test "memory and prefetchable encodings preserve wire fields" {
        try testing.expectEqualDeep(
            Encoding{ .mem = .{ .base = 0x2000, .limit = 0x2000 } },
            try Encoding.encode(.mem, 0x2000_0000, 0x200F_FFFF),
        );
        try testing.expectEqualDeep(
            Encoding{ .mem_prefetch_32 = .{ .base_lo = 0xD000, .limit_lo = 0xDFF0 } },
            try Encoding.encode(.mem_prefetch, 0xD000_0000, 0xDFFF_FFFF),
        );

        try testing.expectEqualDeep(Encoding{ .mem_prefetch_64 = .{
            .base_lo = 1,
            .limit_lo = 0xFF1,
            .base_hi = 1,
            .limit_hi = 1,
        } }, try Encoding.encode(.mem_prefetch, 0x1_0000_0000, 0x1_0FFF_FFFF));
    }

    test "prefetchable width changes at the 4 GiB boundary" {
        try testing.expectEqualDeep(
            Encoding{ .mem_prefetch_32 = .{ .base_lo = 0xF000, .limit_lo = 0xFFF0 } },
            try Encoding.encode(.mem_prefetch, 0xF000_0000, 0xFFFF_FFFF),
        );

        const explicit = try Memory.Prefetch64.encode(0xF000_0000, 0xFFFF_FFFF);
        try testing.expectEqualDeep(Prefetch64Registers{
            .base_lo = 0xF001,
            .limit_lo = 0xFFF1,
            .base_hi = 0,
            .limit_hi = 0,
        }, explicit);

        try testing.expectEqualDeep(Encoding{ .mem_prefetch_64 = .{
            .base_lo = 0xFFF1,
            .limit_lo = 1,
            .base_hi = 0,
            .limit_hi = 1,
        } }, try Encoding.encode(.mem_prefetch, 0xFFF0_0000, 0x1_000F_FFFF));
    }

    test "encoders reject unrepresentable bounds and granularity" {
        try testing.expectError(error.Unencodable, Io.encode(0x1_0000_0000, 0x1_0000_0FFF));
        try testing.expectError(error.Unencodable, Io.encode(0xFFFF_F000, 0x1_0000_0FFF));
        try testing.expectError(error.Unencodable, Io.encode(1, 0xFFF));
        try testing.expectError(error.Unencodable, Io.encode(0, 0xFFE));

        try testing.expectError(error.Unencodable, Memory.encode(0x1_0000_0000, 0x1_000F_FFFF));
        try testing.expectError(error.Unencodable, Memory.encode(0xFFF0_0000, 0x1_000F_FFFF));
        try testing.expectError(error.Unencodable, Memory.encode(1, 0xF_FFFF));
        try testing.expectError(error.Unencodable, Memory.encode(0, 0xF_FFFE));

        try testing.expectError(error.Unencodable, Encoding.encode(.mem_prefetch, 1, 0xF_FFFF));
        try testing.expectError(error.Unencodable, Encoding.encode(.mem_prefetch, 0, 0xF_FFFE));
        try testing.expectError(error.Unencodable, Memory.Prefetch32.encode(0, 0x1_000F_FFFF));
    }

    test "encoders preserve full inclusive endpoints" {
        const max = std.math.maxInt(u64);
        const full = try Memory.Prefetch64.encode(0, max);

        try testing.expectEqualDeep(Prefetch64Registers{
            .base_lo = 1,
            .limit_lo = 0xFFF1,
            .base_hi = 0,
            .limit_hi = std.math.maxInt(u32),
        }, full);
        try testing.expectEqualDeep(Encoding{ .mem_prefetch_64 = full }, try Encoding.encode(.mem_prefetch, 0, max));
        try testing.expectEqualDeep(Encoding{ .mem_prefetch_64 = .{
            .base_lo = 0xFFF1,
            .limit_lo = 0xFFF1,
            .base_hi = std.math.maxInt(u32),
            .limit_hi = std.math.maxInt(u32),
        } }, try Encoding.encode(.mem_prefetch, 0xFFFF_FFFF_FFF0_0000, max));
        try testing.expectEqual(@as(u16, 0xFFFF), (try Io.encode(0, std.math.maxInt(u32))).limit_hi);
        try testing.expectEqual(@as(u16, 0xFFF0), (try Memory.encode(0, std.math.maxInt(u32))).limit);
    }
};
