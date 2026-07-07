//! Tests for docs/specs/core/bdf.md.

const std = @import("std");

const zpci = @import("zpci");

const Bdf = zpci.core.Bdf;
const Sbdf = zpci.core.Sbdf;
const SegmentId = zpci.core.SegmentId;

test "layout: Bdf is packed struct(u16) with LSB-first PCIe Requester ID layout" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Bdf));
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(Bdf));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Bdf, "function"));
    try std.testing.expectEqual(@as(comptime_int, 3), @bitOffsetOf(Bdf, "device"));
    try std.testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(Bdf, "bus"));
}

test "layout: Sbdf is packed struct(u32) with bdf in low half, segment in high half" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Sbdf));
    try std.testing.expectEqual(@as(comptime_int, 32), @bitSizeOf(Sbdf));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Sbdf, "bdf"));
    try std.testing.expectEqual(@as(comptime_int, 16), @bitOffsetOf(Sbdf, "segment"));
}

test "unit: Bdf.of encodes fields at the PCIe-mandated bit offsets" {
    const x = Bdf.of(0x12, 0x1F, 0x07);
    try std.testing.expectEqual(@as(u8, 0x12), x.bus);
    try std.testing.expectEqual(@as(u5, 0x1F), x.device);
    try std.testing.expectEqual(@as(u3, 0x07), x.function);

    // Raw u16: bus in high byte, device in bits 7..3, function in bits 2..0.
    // Expected: (0x12 << 8) | (0x1F << 3) | 0x07 = 0x12FF.
    try std.testing.expectEqual(@as(u16, 0x12FF), x.asU16());
}

test "unit: Bdf.from rejects out-of-range device or function" {
    try std.testing.expectError(error.InvalidIdentifier, Bdf.from(0, 32, 0));
    try std.testing.expectError(error.InvalidIdentifier, Bdf.from(0, 0, 8));
    try std.testing.expectError(error.InvalidIdentifier, Bdf.from(0, 255, 0));
    try std.testing.expectError(error.InvalidIdentifier, Bdf.from(0, 0, 255));

    const ok = try Bdf.from(0xFF, 31, 7);
    try std.testing.expect(ok.eql(Bdf.of(0xFF, 31, 7)));
}

test "unit: Bdf.from accepts the full u8 range for bus" {
    _ = try Bdf.from(0, 0, 0);
    _ = try Bdf.from(0xFF, 0, 0);
}

test "unit: Bdf.eql compares packed encoding" {
    try std.testing.expect(Bdf.of(1, 2, 3).eql(Bdf.of(1, 2, 3)));
    try std.testing.expect(!Bdf.of(1, 2, 3).eql(Bdf.of(1, 2, 4)));
    try std.testing.expect(!Bdf.of(1, 2, 3).eql(Bdf.of(1, 3, 3)));
    try std.testing.expect(!Bdf.of(1, 2, 3).eql(Bdf.of(2, 2, 3)));
}

test "unit: Bdf.lessThan yields bus-major, device-minor, function-least" {
    try std.testing.expect(Bdf.of(0, 0, 0).lessThan(Bdf.of(0, 0, 1)));
    try std.testing.expect(Bdf.of(0, 0, 7).lessThan(Bdf.of(0, 1, 0)));
    try std.testing.expect(Bdf.of(0, 31, 7).lessThan(Bdf.of(1, 0, 0)));
    try std.testing.expect(!Bdf.of(1, 0, 0).lessThan(Bdf.of(0, 31, 7)));
    try std.testing.expect(!Bdf.of(1, 0, 0).lessThan(Bdf.of(1, 0, 0)));
}

test "unit: Bdf multifunction helpers" {
    const orig = Bdf.of(0x03, 5, 4);
    const f0 = orig.function0();

    try std.testing.expectEqual(@as(u3, 0), f0.function);
    try std.testing.expectEqual(@as(u5, 5), f0.device);
    try std.testing.expectEqual(@as(u8, 0x03), f0.bus);
    try std.testing.expect(f0.isFunction0());
    try std.testing.expect(!orig.isFunction0());

    try std.testing.expect(orig.withFunction(2).eql(Bdf.of(0x03, 5, 2)));
}

test "unit: Bdf.df packs device and function into one byte" {
    const x = Bdf.of(0x10, 0x1F, 0x07);
    // Low byte of the u16 encoding: (device << 3) | function = 0xFF.
    try std.testing.expectEqual(@as(u8, 0xFF), x.df());

    const zero = Bdf.of(0x10, 0, 0);
    try std.testing.expectEqual(@as(u8, 0x00), zero.df());
}

test "unit: Sbdf.of packs segment into the high half" {
    const x = Sbdf.of(0xBEEF, 0x12, 0x03, 0x02);
    try std.testing.expectEqual(@as(u16, 0xBEEF), x.segment.value);
    try std.testing.expectEqual(@as(u8, 0x12), x.bdf.bus);

    // Full u32: segment | bus | device | function.
    // (0xBEEF << 16) | (0x12 << 8) | (0x03 << 3) | 0x02 = 0xBEEF_121A.
    try std.testing.expectEqual(@as(u32, 0xBEEF_121A), x.asU32());
}

test "unit: Sbdf.init pairs a SegmentId with an existing Bdf" {
    const bdf = Bdf.of(0x40, 4, 0);
    const s = Sbdf.init(SegmentId.of(1), bdf);
    try std.testing.expect(s.bdf.eql(bdf));
    try std.testing.expectEqual(@as(u16, 1), s.segment.value);
}

test "unit: Sbdf.from propagates Bdf.from's InvalidIdentifier" {
    try std.testing.expectError(error.InvalidIdentifier, Sbdf.from(0, 0, 32, 0));
    try std.testing.expectError(error.InvalidIdentifier, Sbdf.from(0, 0, 0, 8));
    _ = try Sbdf.from(0, 0, 0, 0);
    _ = try Sbdf.from(0xFFFF, 0xFF, 31, 7);
}

test "unit: Sbdf.lessThan is segment-major, Bdf-minor" {
    const a = Sbdf.of(0, 0xFF, 31, 7);
    const b = Sbdf.of(1, 0, 0, 0);
    try std.testing.expect(a.lessThan(b));
    try std.testing.expect(!b.lessThan(a));

    const c = Sbdf.of(0, 0, 0, 0);
    const d = Sbdf.of(0, 0, 0, 1);
    try std.testing.expect(c.lessThan(d));
}

test "unit: Sbdf.function0 preserves segment and (bus, device)" {
    const s = Sbdf.of(3, 0x10, 5, 4);
    const f0 = s.function0();
    try std.testing.expectEqual(@as(u16, 3), f0.segment.value);
    try std.testing.expectEqual(@as(u8, 0x10), f0.bdf.bus);
    try std.testing.expectEqual(@as(u5, 5), f0.bdf.device);
    try std.testing.expectEqual(@as(u3, 0), f0.bdf.function);
}

test "unit: Sbdf.format writes lspci-style ssss:bb:dd.f" {
    var buf: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{Sbdf.of(0, 0, 1, 0)});
    try std.testing.expectEqualStrings("0000:00:01.0", rendered);

    const rendered2 = try std.fmt.bufPrint(&buf, "{f}", .{Sbdf.of(0xABCD, 0x12, 3, 4)});
    try std.testing.expectEqualStrings("abcd:12:03.4", rendered2);
}

test "unit: Bdf.format writes bb:dd.f without segment" {
    var buf: [16]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{f}", .{Bdf.of(0x10, 5, 6)});
    try std.testing.expectEqualStrings("10:05.6", rendered);
}
