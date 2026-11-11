//! Bus/device/function addresses.

const std = @import("std");

const ids = @import("ids.zig");

const SegmentId = ids.SegmentId;
const Writer = std.Io.Writer;
const BusIndex = bus.Index;
const DeviceIndex = device.Index;
const FunctionIndex = function.Index;

pub const bus = struct {
    pub const count: usize = @as(usize, 1) << @bitSizeOf(Index);

    pub const Index = u8;
};

pub const device = struct {
    pub const count: usize = @as(usize, 1) << @bitSizeOf(Index);

    pub const Index = u5;
};

pub const function = struct {
    pub const count: usize = @as(usize, 1) << @bitSizeOf(Index);

    pub const Index = u3;
};

pub const Bdf = packed struct(u16) {
    function: FunctionIndex,
    device: DeviceIndex,
    bus: BusIndex,

    pub const Error = error{InvalidIdentifier};

    pub fn from(b: BusIndex, d: DeviceIndex, f: FunctionIndex) Bdf {
        return .{
            .function = f,
            .device = d,
            .bus = b,
        };
    }

    pub fn raw(self: Bdf) u16 {
        return @bitCast(self);
    }

    /// PCIe device/function key: device[7:3], function[2:0].
    pub fn df(self: Bdf) u8 {
        return @truncate(self.raw());
    }

    pub fn withFunction(self: Bdf, f: FunctionIndex) Bdf {
        return .{ .function = f, .device = self.device, .bus = self.bus };
    }

    pub fn function0(self: Bdf) Bdf {
        return self.withFunction(0);
    }

    pub fn eql(a: Bdf, b: Bdf) bool {
        return a.raw() == b.raw();
    }

    pub fn lessThan(a: Bdf, b: Bdf) bool {
        return a.raw() < b.raw();
    }

    pub fn parse(text: []const u8) Error!Bdf {
        if (text.len != 7) {
            return error.InvalidIdentifier;
        }

        if (text[2] != ':' or text[5] != '.') {
            return error.InvalidIdentifier;
        }

        const bus_index = try parseFixedHex(u8, text[0..2], 2);
        const device_index = try parseFixedHex(u8, text[3..5], 2);
        const function_index = try parseFixedHex(u8, text[6..7], 1);

        if (device_index >= device.count or function_index >= function.count) {
            return error.InvalidIdentifier;
        }

        return Bdf.from(bus_index, @intCast(device_index), @intCast(function_index));
    }

    /// "bb:dd.f" with zero-padded lowercase hex.
    pub fn format(self: Bdf, writer: *Writer) !void {
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

    pub fn from(segment: SegmentId, bus_index: BusIndex, device_index: DeviceIndex, function_index: FunctionIndex) Sbdf {
        return .{
            .bdf = Bdf.from(bus_index, device_index, function_index),
            .segment = segment,
        };
    }

    pub fn fromBdf(segment: SegmentId, bdf: Bdf) Sbdf {
        return .{
            .bdf = bdf,
            .segment = segment,
        };
    }

    pub fn raw(self: Sbdf) u32 {
        return @bitCast(self);
    }

    pub fn function0(self: Sbdf) Sbdf {
        return .{ .bdf = self.bdf.function0(), .segment = self.segment };
    }

    pub fn eql(a: Sbdf, b: Sbdf) bool {
        return a.raw() == b.raw();
    }

    pub fn lessThan(a: Sbdf, b: Sbdf) bool {
        return a.raw() < b.raw();
    }

    /// Requires exactly "ssss:bb:dd.f"; invalid fields return `error.InvalidIdentifier`.
    pub fn parse(text: []const u8) Error!Sbdf {
        if (text.len != 12) {
            return error.InvalidIdentifier;
        }

        if (text[4] != ':') {
            return error.InvalidIdentifier;
        }

        const segment = SegmentId.from(try parseFixedHex(u16, text[0..4], 4));
        const bdf = try Bdf.parse(text[5..12]);

        return Sbdf.fromBdf(segment, bdf);
    }

    pub fn format(self: Sbdf, writer: *Writer) !void {
        try writer.print(
            "{x:0>4}:{f}",
            .{ @intFromEnum(self.segment), self.bdf },
        );
    }

    comptime {
        std.debug.assert(@sizeOf(Sbdf) == 4);
        std.debug.assert(@bitSizeOf(Sbdf) == 32);
        std.debug.assert(@bitOffsetOf(Sbdf, "bdf") == 0);
        std.debug.assert(@bitOffsetOf(Sbdf, "segment") == 16);
    }
};

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

pub const unit = struct {
    const testing = std.testing;

    test "Bdf.from encodes fields at PCIe Requester ID bit offsets" {
        const x = Bdf.from(0x12, 0x1F, 0x07);

        try testing.expectEqual(@as(u8, 0x12), x.bus);
        try testing.expectEqual(@as(u5, 0x1F), x.device);
        try testing.expectEqual(@as(u3, 0x07), x.function);
        try testing.expectEqual(@as(u16, 0x12FF), x.raw());
    }

    test "Bdf.eql compares the entire packed address identity" {
        try testing.expect(Bdf.from(1, 2, 3).eql(Bdf.from(1, 2, 3)));
        try testing.expect(!Bdf.from(1, 2, 3).eql(Bdf.from(1, 2, 4)));
        try testing.expect(!Bdf.from(1, 2, 3).eql(Bdf.from(1, 3, 3)));
        try testing.expect(!Bdf.from(1, 2, 3).eql(Bdf.from(2, 2, 3)));
    }

    test "Bdf.lessThan yields bus-major, device-minor, function-least order" {
        try testing.expect(Bdf.from(0, 0, 0).lessThan(Bdf.from(0, 0, 1)));
        try testing.expect(Bdf.from(0, 0, 7).lessThan(Bdf.from(0, 1, 0)));
        try testing.expect(Bdf.from(0, 31, 7).lessThan(Bdf.from(1, 0, 0)));
        try testing.expect(!Bdf.from(1, 0, 0).lessThan(Bdf.from(0, 31, 7)));
        try testing.expect(!Bdf.from(1, 0, 0).lessThan(Bdf.from(1, 0, 0)));
    }

    test "Bdf multifunction helpers preserve bus and device while selecting functions" {
        const orig = Bdf.from(0x03, 5, 4);
        const f0 = orig.function0();

        try testing.expectEqual(@as(u3, 0), f0.function);
        try testing.expectEqual(@as(u5, 5), f0.device);
        try testing.expectEqual(@as(u8, 0x03), f0.bus);
        try testing.expect(orig.withFunction(2).eql(Bdf.from(0x03, 5, 2)));
    }

    test "Bdf.df packs device and function into the low requester-id byte" {
        const x = Bdf.from(0x10, 0x1F, 0x07);

        try testing.expectEqual(@as(u8, 0xFF), x.df());

        const zero = Bdf.from(0x10, 0, 0);

        try testing.expectEqual(@as(u8, 0x00), zero.df());
    }

    test "Sbdf.from packs segment into the high half of the source id" {
        const x = Sbdf.from(.from(0xBEEF), 0x12, 0x03, 0x02);

        try testing.expectEqual(@as(u16, 0xBEEF), @intFromEnum(x.segment));
        try testing.expectEqual(@as(u8, 0x12), x.bdf.bus);
        try testing.expectEqual(@as(u32, 0xBEEF_121A), x.raw());
    }

    test "Sbdf.eql compares both segment and BDF halves" {
        const bdf = Bdf.from(0x40, 4, 0);
        const a = Sbdf.from(.from(1), 0x40, 4, 0);

        try testing.expect(a.eql(Sbdf.fromBdf(SegmentId.from(1), bdf)));
        try testing.expect(!a.eql(Sbdf.from(.from(2), 0x40, 4, 0)));
        try testing.expect(!a.eql(Sbdf.from(.from(1), 0x40, 4, 1)));
    }

    test "Sbdf.from preserves maximum address fields" {
        try testing.expectEqual(
            @as(u32, 0xFFFF_FFFF),
            Sbdf.from(.from(0xFFFF), 0xFF, 31, 7).raw(),
        );
    }

    test "Sbdf.lessThan is segment-major, then BDF-minor" {
        const a = Sbdf.from(.from(0), 0xFF, 31, 7);
        const b = Sbdf.from(.from(1), 0, 0, 0);

        try testing.expect(a.lessThan(b));
        try testing.expect(!b.lessThan(a));

        const c = Sbdf.from(.from(0), 0, 0, 0);
        const d = Sbdf.from(.from(0), 0, 0, 1);

        try testing.expect(c.lessThan(d));
    }

    test "Sbdf.function0 preserves segment, bus, and device" {
        const s = Sbdf.from(.from(3), 0x10, 5, 4);
        const f0 = s.function0();

        try testing.expectEqual(@as(u16, 3), @intFromEnum(f0.segment));
        try testing.expectEqual(@as(u8, 0x10), f0.bdf.bus);
        try testing.expectEqual(@as(u5, 5), f0.bdf.device);
        try testing.expectEqual(@as(u3, 0), f0.bdf.function);
    }

    test "Sbdf.format writes fixed-width lspci-style ssss:bb:dd.f" {
        var buf: [64]u8 = undefined;

        const rendered_min = try std.fmt.bufPrint(&buf, "{f}", .{Sbdf.from(.from(0), 0, 0, 0)});

        try testing.expectEqual(@as(usize, 12), rendered_min.len);
        try testing.expectEqualStrings("0000:00:00.0", rendered_min);

        const rendered_max = try std.fmt.bufPrint(&buf, "{f}", .{Sbdf.from(.from(0xFFFF), 0xFF, 0x1F, 7)});

        try testing.expectEqual(@as(usize, 12), rendered_max.len);
        try testing.expectEqualStrings("ffff:ff:1f.7", rendered_max);

        const rendered_mixed = try std.fmt.bufPrint(&buf, "{f}", .{Sbdf.from(.from(0xABCD), 0x12, 3, 4)});

        try testing.expectEqual(@as(usize, 12), rendered_mixed.len);
        try testing.expectEqualStrings("abcd:12:03.4", rendered_mixed);
    }

    test "Bdf.format writes fixed-width bb:dd.f without a segment" {
        var buf: [16]u8 = undefined;

        const rendered_min = try std.fmt.bufPrint(&buf, "{f}", .{Bdf.from(0, 0, 0)});

        try testing.expectEqual(@as(usize, 7), rendered_min.len);
        try testing.expectEqualStrings("00:00.0", rendered_min);

        const rendered_max = try std.fmt.bufPrint(&buf, "{f}", .{Bdf.from(0xFF, 0x1F, 7)});

        try testing.expectEqual(@as(usize, 7), rendered_max.len);
        try testing.expectEqualStrings("ff:1f.7", rendered_max);

        const rendered_mixed = try std.fmt.bufPrint(&buf, "{f}", .{Bdf.from(0x10, 5, 6)});

        try testing.expectEqual(@as(usize, 7), rendered_mixed.len);
        try testing.expectEqualStrings("10:05.6", rendered_mixed);
    }

    test "Bdf.parse accepts exact lspci-style segment-less addresses" {
        try testing.expect((try Bdf.parse("00:00.0")).eql(Bdf.from(0, 0, 0)));
        try testing.expect((try Bdf.parse("ff:1f.7")).eql(Bdf.from(0xFF, 0x1F, 7)));
        try testing.expect((try Bdf.parse("AB:0C.6")).eql(Bdf.from(0xAB, 0x0C, 6)));
    }

    test "Bdf.parse rejects malformed syntax and out-of-range fields" {
        const invalid = [_][]const u8{
            "0:00.0",
            "00:00.00",
            "00-00.0",
            "00:00:0",
            "gg:00.0",
            "00:20.0",
            "00:00.8",
            " 00:00.0",
            "0x00:00.0",
        };

        for (invalid) |text| {
            try testing.expectError(error.InvalidIdentifier, Bdf.parse(text));
        }
    }

    test "Sbdf.parse accepts exact lspci-style domain addresses" {
        try testing.expect((try Sbdf.parse("0000:00:00.0")).eql(Sbdf.from(.from(0), 0, 0, 0)));
        try testing.expect((try Sbdf.parse("ffff:ff:1f.7")).eql(Sbdf.from(.from(0xFFFF), 0xFF, 0x1F, 7)));
        try testing.expect((try Sbdf.parse("ABCD:12:03.4")).eql(Sbdf.from(.from(0xABCD), 0x12, 3, 4)));
    }

    test "Sbdf.parse rejects malformed syntax and invalid nested BDF" {
        const invalid = [_][]const u8{
            "000:00:00.0",
            "0000-00:00.0",
            "gggg:00:00.0",
            "0000:00:20.0",
            "0000:00:00.8",
            "0000:00:00.0 ",
        };

        for (invalid) |text| {
            try testing.expectError(error.InvalidIdentifier, Sbdf.parse(text));
        }
    }

    test "Bdf and Sbdf parse format output exactly" {
        var bdf_buf: [16]u8 = undefined;
        const bdf = Bdf.from(0x7A, 0x0B, 5);
        const bdf_text = try std.fmt.bufPrint(&bdf_buf, "{f}", .{bdf});

        try testing.expect((try Bdf.parse(bdf_text)).eql(bdf));

        var sbdf_buf: [32]u8 = undefined;
        const sbdf = Sbdf.from(.from(0xFEDC), 0x7A, 0x0B, 5);
        const sbdf_text = try std.fmt.bufPrint(&sbdf_buf, "{f}", .{sbdf});

        try testing.expect((try Sbdf.parse(sbdf_text)).eql(sbdf));
    }
};
