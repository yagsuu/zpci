//! Bus/device/function primitives. Spec: docs/specs/core/bdf.md.

const std = @import("std");

const ids = @import("ids.zig");

const SegmentId = ids.SegmentId;

/// Conventional-bus iteration bound: devices 0..32 per bus.
pub const max_device: u8 = 32;

/// Conventional-bus iteration bound: functions 0..8 per device.
pub const max_function: u8 = 8;

pub const Bdf = packed struct(u16) {
    function: u3,
    device: u5,
    bus: u8,

    pub const Error = error{InvalidIdentifier};

    pub fn of(comptime b: u8, comptime d: u5, comptime f: u3) Bdf {
        return .{ .function = f, .device = d, .bus = b };
    }

    /// Runtime constructor. Full `u8` range of `bus` accepted; segment
    /// containment is a separate check (`inSegmentRange`).
    pub fn from(b: u8, d: u8, f: u8) Error!Bdf {
        if (d > 31 or f > 7) return error.InvalidIdentifier;
        return .{
            .function = @intCast(f),
            .device = @intCast(d),
            .bus = b,
        };
    }

    /// Parses exactly "bb:dd.f". Non-allocating; malformed syntax or out-of-range
    /// device/function fields return `error.InvalidIdentifier`.
    pub fn parse(text: []const u8) Error!Bdf {
        if (text.len != 7) return error.InvalidIdentifier;
        if (text[2] != ':' or text[5] != '.') return error.InvalidIdentifier;

        return Bdf.from(
            try parseFixedHex(u8, text[0..2], 2),
            try parseFixedHex(u8, text[3..5], 2),
            try parseFixedHex(u8, text[6..7], 1),
        );
    }

    pub fn eql(a: Bdf, b: Bdf) bool {
        return @as(u16, @bitCast(a)) == @as(u16, @bitCast(b));
    }

    /// Total ordering: bus-major, device-minor, function-least.
    pub fn lessThan(a: Bdf, b: Bdf) bool {
        return @as(u16, @bitCast(a)) < @as(u16, @bitCast(b));
    }

    pub fn function0(self: Bdf) Bdf {
        return .{ .function = 0, .device = self.device, .bus = self.bus };
    }

    pub fn withFunction(self: Bdf, f: u3) Bdf {
        return .{ .function = f, .device = self.device, .bus = self.bus };
    }

    /// The header-type multifunction bit is only meaningful on function-0
    /// reads.
    pub fn isFunction0(self: Bdf) bool {
        return self.function == 0;
    }

    /// 8-bit "DF" key — device and function packed into the same byte
    /// pattern PCIe uses inside one bus.
    pub fn df(self: Bdf) u8 {
        return @truncate(@as(u16, @bitCast(self)));
    }

    /// Raw 16-bit packed encoding. Matches PCIe Requester ID layout.
    pub fn asU16(self: Bdf) u16 {
        return @bitCast(self);
    }

    /// Writes "bb:dd.f" using zero-padded lowercase hex; segment-less
    /// counterpart to `Sbdf.format`.
    pub fn format(self: Bdf, writer: *std.Io.Writer) !void {
        try writer.print(
            "{x:0>2}:{x:0>2}.{d}",
            .{ self.bus, @as(u8, self.device), @as(u8, self.function) },
        );
    }

    comptime {
        std.debug.assert(@sizeOf(Bdf) == 2);
        std.debug.assert(@bitSizeOf(Bdf) == 16);
        std.debug.assert(@bitOffsetOf(Bdf, "function") == 0);
        std.debug.assert(@bitOffsetOf(Bdf, "device") == 3);
        std.debug.assert(@bitOffsetOf(Bdf, "bus") == 8);
    }
};

pub const Sbdf = packed struct(u32) {
    bdf: Bdf,
    segment: SegmentId,

    pub const Error = Bdf.Error;

    pub fn of(comptime s: u16, comptime b: u8, comptime d: u5, comptime f: u3) Sbdf {
        return .{
            .bdf = Bdf.of(b, d, f),
            .segment = SegmentId.of(s),
        };
    }

    pub fn init(segment: SegmentId, bdf: Bdf) Sbdf {
        return .{ .bdf = bdf, .segment = segment };
    }

    pub fn from(s: u16, b: u8, d: u8, f: u8) Error!Sbdf {
        return .{
            .bdf = try Bdf.from(b, d, f),
            .segment = SegmentId.from(s),
        };
    }

    /// Parses exactly "ssss:bb:dd.f". Non-allocating; malformed syntax or out-of-range
    /// BDF fields return `error.InvalidIdentifier`.
    pub fn parse(text: []const u8) Error!Sbdf {
        if (text.len != 12) return error.InvalidIdentifier;
        if (text[4] != ':') return error.InvalidIdentifier;

        const segment = SegmentId.from(try parseFixedHex(u16, text[0..4], 4));
        const bdf = try Bdf.parse(text[5..12]);
        return Sbdf.init(segment, bdf);
    }

    pub fn eql(a: Sbdf, b: Sbdf) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }

    /// Total ordering: segment-major, Bdf-minor.
    pub fn lessThan(a: Sbdf, b: Sbdf) bool {
        return @as(u32, @bitCast(a)) < @as(u32, @bitCast(b));
    }

    pub fn function0(self: Sbdf) Sbdf {
        return .{ .bdf = self.bdf.function0(), .segment = self.segment };
    }

    /// Raw 32-bit packed encoding (`segment | bus | device | function`).
    /// Matches the IOMMU source-id form used by Intel VT-d, AMD-Vi, and
    /// the Linux PCI subsystem.
    pub fn asU32(self: Sbdf) u32 {
        return @bitCast(self);
    }

    /// Writes "ssss:bb:dd.f" using zero-padded lowercase hex, matching
    /// the conventional `lspci -D` rendering.
    pub fn format(self: Sbdf, writer: *std.Io.Writer) !void {
        try writer.print(
            "{x:0>4}:{x:0>2}:{x:0>2}.{d}",
            .{
                self.segment.value,
                self.bdf.bus,
                @as(u8, self.bdf.device),
                @as(u8, self.bdf.function),
            },
        );
    }

    comptime {
        std.debug.assert(@sizeOf(Sbdf) == 4);
        std.debug.assert(@bitSizeOf(Sbdf) == 32);
        std.debug.assert(@bitOffsetOf(Sbdf, "bdf") == 0);
        std.debug.assert(@bitOffsetOf(Sbdf, "segment") == 16);
    }
};

/// Bytes from a segment's ECAM base to the start of `bdf`'s 4 KiB
/// configuration window. Caller must have already validated bus
/// containment via `inSegmentRange`.
pub fn busRelativeOffset(bdf: Bdf, bus_start: u8) u32 {
    std.debug.assert(bdf.bus >= bus_start);

    const result = (@as(u32, bdf.bus - bus_start) << 20) |
        (@as(u32, bdf.device) << 15) |
        (@as(u32, bdf.function) << 12);
    std.debug.assert(result <= 0x0FFF_F000);

    return result;
}

/// Bytes from a segment's ECAM base to a specific register inside
/// `bdf`'s configuration window. `register` is `0..=0xFFF`.
pub fn ecamOffset(bdf: Bdf, bus_start: u8, register: u12) u32 {
    const result = busRelativeOffset(bdf, bus_start) | @as(u32, register);
    std.debug.assert((result & 0xFFF) == @as(u32, register));

    return result;
}

/// True when `bdf.bus` lies inside `[bus_start, bus_end]` inclusive.
pub fn inSegmentRange(bdf: Bdf, bus_start: u8, bus_end: u8) bool {
    return bdf.bus >= bus_start and bdf.bus <= bus_end;
}

fn parseFixedHex(comptime T: type, text: []const u8, comptime width: usize) Bdf.Error!T {
    std.debug.assert(text.len == width);
    std.debug.assert(width <= @divExact(@bitSizeOf(T), 4));

    var value: T = 0;
    for (text) |byte| {
        const nibble = parseHexNibble(byte) orelse return error.InvalidIdentifier;
        value = (value << 4) | @as(T, nibble);
    }
    return value;
}

fn parseHexNibble(byte: u8) ?u4 {
    return switch (byte) {
        '0'...'9' => @intCast(byte - '0'),
        'a'...'f' => @intCast(byte - 'a' + 10),
        'A'...'F' => @intCast(byte - 'A' + 10),
        else => null,
    };
}
