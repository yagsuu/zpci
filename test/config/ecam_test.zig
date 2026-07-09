//! Tests for docs/specs/config/ecam.md.

const std = @import("std");

const stdx = @import("stdx");
const zpci = @import("zpci");

const ConfigSpace = zpci.config.ConfigSpace;
const Ecam = zpci.config.Ecam;
const Sbdf = zpci.core.Sbdf;
const Segment = zpci.config.Segment;
const SegmentId = zpci.core.SegmentId;
const VirtAddr = stdx.addr.VirtAddr;

fn backingBase(bytes: []u8) VirtAddr {
    return VirtAddr.fromInt(@intFromPtr(bytes.ptr));
}

fn ecamWindowOffset(sbdf: Sbdf, bus_start: u8) usize {
    return (@as(usize, sbdf.bdf.bus - bus_start) << 20) |
        (@as(usize, sbdf.bdf.device) << 15) |
        (@as(usize, sbdf.bdf.function) << 12);
}

test "unit: Segment validates ranges and contains only matching SBDFs inside its buses" {
    const base = VirtAddr.fromInt(0x1000);
    const segment = Segment{
        .segment = SegmentId.from(3),
        .base = base,
        .bus_start = 0x20,
        .bus_end = 0x2F,
    };

    try segment.validate();
    try std.testing.expect(segment.contains(Sbdf.of(3, 0x20, 0, 0)));
    try std.testing.expect(segment.contains(Sbdf.of(3, 0x2F, 31, 7)));
    try std.testing.expect(!segment.contains(Sbdf.of(3, 0x1F, 0, 0)));
    try std.testing.expect(!segment.contains(Sbdf.of(3, 0x30, 0, 0)));
    try std.testing.expect(!segment.contains(Sbdf.of(4, 0x20, 0, 0)));

    const invalid = Segment{
        .segment = SegmentId.from(3),
        .base = base,
        .bus_start = 0x30,
        .bus_end = 0x2F,
    };
    try std.testing.expectError(error.InvalidBusRange, invalid.validate());
}

test "unit: Segment.whole covers every bus for the selected segment" {
    const whole = Segment.whole(SegmentId.from(7), VirtAddr.fromInt(0x2000));

    try std.testing.expect(whole.segment.eql(SegmentId.from(7)));
    try std.testing.expectEqual(@as(u8, 0), whole.bus_start);
    try std.testing.expectEqual(@as(u8, 0xFF), whole.bus_end);
    try std.testing.expect(whole.contains(Sbdf.of(7, 0, 0, 0)));
    try std.testing.expect(whole.contains(Sbdf.of(7, 0xFF, 31, 7)));
    try std.testing.expect(!whole.contains(Sbdf.of(8, 0x80, 0, 0)));
}

test "malformed: Ecam.from rejects empty invalid and duplicate segment tables" {
    const base = VirtAddr.fromInt(0x3000);
    const empty: [0]Segment = .{};
    try std.testing.expectError(error.NoSegments, Ecam.from(&empty));

    var invalid = [_]Segment{.{
        .segment = SegmentId.from(1),
        .base = base,
        .bus_start = 2,
        .bus_end = 1,
    }};
    try std.testing.expectError(error.InvalidBusRange, Ecam.from(&invalid));

    var duplicate = [_]Segment{
        .{ .segment = SegmentId.from(2), .base = base, .bus_start = 0, .bus_end = 3 },
        .{ .segment = SegmentId.from(2), .base = base, .bus_start = 4, .bus_end = 7 },
    };
    try std.testing.expectError(error.DuplicateSegment, Ecam.from(&duplicate));
}

test "unit: Ecam.find matches segment id without applying bus containment" {
    const base = VirtAddr.fromInt(0x4000);
    var segments = [_]Segment{
        .{ .segment = SegmentId.from(3), .base = base, .bus_start = 0x20, .bus_end = 0x2F },
        .{ .segment = SegmentId.from(4), .base = base, .bus_start = 0x00, .bus_end = 0x0F },
    };
    const ecam = try Ecam.from(&segments);

    const outside_bus = ecam.find(Sbdf.of(3, 0x10, 0, 0)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(outside_bus.segment.eql(SegmentId.from(3)));
    try std.testing.expectEqual(@as(u8, 0x20), outside_bus.bus_start);
    try std.testing.expectEqual(@as(?*const Segment, null), ecam.find(Sbdf.of(5, 0x20, 0, 0)));
}

test "unit: ConfigSpace accesses use bus-relative ECAM addresses for nonzero bus_start" {
    const ecam_len = 6 * 1024 * 1024;
    const backing = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(u32)), ecam_len);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0);

    const bus_start: u8 = 4;
    const sbdf = Sbdf.of(9, 5, 2, 3);
    const window = ecamWindowOffset(sbdf, bus_start);
    var segments = [_]Segment{.{
        .segment = SegmentId.from(9),
        .base = backingBase(backing),
        .bus_start = bus_start,
        .bus_end = 8,
    }};
    var ecam = try Ecam.from(&segments);
    const config = ecam.configSpace();

    try config.write8(sbdf, 0x24, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x5A), backing[window + 0x24]);

    try config.write16(sbdf, 0x26, 0xBEEF);
    try std.testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE }, backing[window + 0x26 .. window + 0x28]);

    try config.write32(sbdf, 0x28, 0xCAFE_BABE);
    try std.testing.expectEqualSlices(u8, &.{ 0xBE, 0xBA, 0xFE, 0xCA }, backing[window + 0x28 .. window + 0x2C]);

    @memset(backing, 0);
    backing[window + 0x30] = 0xA5;
    backing[window + 0x32] = 0x34;
    backing[window + 0x33] = 0x12;
    backing[window + 0x34] = 0x78;
    backing[window + 0x35] = 0x56;
    backing[window + 0x36] = 0x34;
    backing[window + 0x37] = 0x12;

    try std.testing.expectEqual(@as(u8, 0xA5), try config.read8(sbdf, 0x30));
    try std.testing.expectEqual(@as(u16, 0x1234), try config.read16(sbdf, 0x32));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try config.read32(sbdf, 0x34));
}

test "malformed: ConfigSpace reports OutOfBounds for unknown segments and buses outside the matched segment" {
    var backing: [0x1000]u8 align(4) = @splat(0);
    var segments = [_]Segment{.{
        .segment = SegmentId.from(1),
        .base = backingBase(&backing),
        .bus_start = 0x10,
        .bus_end = 0x1F,
    }};
    var ecam = try Ecam.from(&segments);
    const config = ecam.configSpace();

    try std.testing.expectError(error.OutOfBounds, config.read8(Sbdf.of(2, 0x10, 0, 0), 0));
    try std.testing.expectError(error.OutOfBounds, config.read32(Sbdf.of(1, 0x20, 0, 0), 0));
    try std.testing.expectError(error.OutOfBounds, config.write16(Sbdf.of(1, 0x0F, 0, 0), 0, 0xFFFF));
    try std.testing.expectError(error.OutOfBounds, config.write8(Sbdf.of(1, 0x10, 0, 0), 0x1000, 0));
}
