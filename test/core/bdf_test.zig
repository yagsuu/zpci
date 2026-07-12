//! Tests for docs/specs/core/bdf.md.

const std = @import("std");

const pci = @import("pci");

const Bdf = pci.core.Bdf;
const Sbdf = pci.core.Sbdf;
const SegmentId = pci.core.SegmentId;

test "layout: Bdf is packed struct(u16) with LSB-first PCIe Requester ID layout" {
    // Guard the wire-compatible requester-id layout consumed by packing, sorting, and ECAM math.
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Bdf));
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(Bdf));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Bdf, "function"));
    try std.testing.expectEqual(@as(comptime_int, 3), @bitOffsetOf(Bdf, "device"));
    try std.testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(Bdf, "bus"));
}

test "layout: Sbdf is packed struct(u32) with bdf in low half and segment in high half" {
    // Preserve the IOMMU-style source-id layout used by raw SBDF encoding and ordering.
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Sbdf));
    try std.testing.expectEqual(@as(comptime_int, 32), @bitSizeOf(Sbdf));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Sbdf, "bdf"));
    try std.testing.expectEqual(@as(comptime_int, 16), @bitOffsetOf(Sbdf, "segment"));
}

test "unit: Bdf.of encodes fields at PCIe Requester ID bit offsets" {
    // Use maximum device/function subfields to catch bit shifts or field-order regressions.
    const x = Bdf.of(0x12, 0x1F, 0x07);

    try std.testing.expectEqual(@as(u8, 0x12), x.bus);
    try std.testing.expectEqual(@as(u5, 0x1F), x.device);
    try std.testing.expectEqual(@as(u3, 0x07), x.function);
    try std.testing.expectEqual(@as(u16, 0x12FF), x.asU16());
}

test "unit: Bdf.from rejects out-of-range device or function bytes" {
    // Probe just-past-bound and large invalid bytes while accepting the highest legal BDF.
    try std.testing.expectError(error.InvalidIdentifier, Bdf.from(0, 32, 0));
    try std.testing.expectError(error.InvalidIdentifier, Bdf.from(0, 0, 8));
    try std.testing.expectError(error.InvalidIdentifier, Bdf.from(0, 255, 0));
    try std.testing.expectError(error.InvalidIdentifier, Bdf.from(0, 0, 255));

    const ok = try Bdf.from(0xFF, 31, 7);
    try std.testing.expect(ok.eql(Bdf.of(0xFF, 31, 7)));
}

test "unit: Bdf.from accepts both endpoints of the bus byte" {
    // Bus-range containment belongs to segments, so BDF construction must preserve 0 and 0xFF.
    try std.testing.expect((try Bdf.from(0, 0, 0)).eql(Bdf.of(0, 0, 0)));
    try std.testing.expect((try Bdf.from(0xFF, 0, 0)).eql(Bdf.of(0xFF, 0, 0)));
}

test "unit: Bdf.eql compares the entire packed address identity" {
    // Flip function, device, and bus independently so equality cannot ignore any subfield.
    try std.testing.expect(Bdf.of(1, 2, 3).eql(Bdf.of(1, 2, 3)));
    try std.testing.expect(!Bdf.of(1, 2, 3).eql(Bdf.of(1, 2, 4)));
    try std.testing.expect(!Bdf.of(1, 2, 3).eql(Bdf.of(1, 3, 3)));
    try std.testing.expect(!Bdf.of(1, 2, 3).eql(Bdf.of(2, 2, 3)));
}

test "unit: Bdf.lessThan yields bus-major, device-minor, function-least order" {
    // Check each rollover boundary used by conventional-bus enumeration order.
    try std.testing.expect(Bdf.of(0, 0, 0).lessThan(Bdf.of(0, 0, 1)));
    try std.testing.expect(Bdf.of(0, 0, 7).lessThan(Bdf.of(0, 1, 0)));
    try std.testing.expect(Bdf.of(0, 31, 7).lessThan(Bdf.of(1, 0, 0)));
    try std.testing.expect(!Bdf.of(1, 0, 0).lessThan(Bdf.of(0, 31, 7)));
    try std.testing.expect(!Bdf.of(1, 0, 0).lessThan(Bdf.of(1, 0, 0)));
}

test "unit: Bdf multifunction helpers preserve bus and device while selecting functions" {
    // Derive function 0 and another function from one address to defend multifunction probing helpers.
    const orig = Bdf.of(0x03, 5, 4);
    const f0 = orig.function0();

    try std.testing.expectEqual(@as(u3, 0), f0.function);
    try std.testing.expectEqual(@as(u5, 5), f0.device);
    try std.testing.expectEqual(@as(u8, 0x03), f0.bus);
    try std.testing.expect(f0.isFunction0());
    try std.testing.expect(!orig.isFunction0());
    try std.testing.expect(orig.withFunction(2).eql(Bdf.of(0x03, 5, 2)));
}

test "unit: Bdf.df packs device and function into the low requester-id byte" {
    // Exercise all-one and all-zero DF fields so masks and shifts are both covered.
    const x = Bdf.of(0x10, 0x1F, 0x07);
    try std.testing.expectEqual(@as(u8, 0xFF), x.df());

    const zero = Bdf.of(0x10, 0, 0);
    try std.testing.expectEqual(@as(u8, 0x00), zero.df());
}

test "unit: Sbdf.of packs segment into the high half of the source id" {
    // Combine a nonzero segment and BDF to catch swapped halves or lost low-half bits.
    const x = Sbdf.of(0xBEEF, 0x12, 0x03, 0x02);

    try std.testing.expectEqual(@as(u16, 0xBEEF), x.segment.value);
    try std.testing.expectEqual(@as(u8, 0x12), x.bdf.bus);
    try std.testing.expectEqual(@as(u32, 0xBEEF_121A), x.asU32());
}

test "unit: Sbdf.eql compares both segment and BDF halves" {
    // Match a runtime-paired address, then vary segment and function independently.
    const bdf = Bdf.of(0x40, 4, 0);
    const a = Sbdf.of(1, 0x40, 4, 0);

    try std.testing.expect(a.eql(Sbdf.init(SegmentId.of(1), bdf)));
    try std.testing.expect(!a.eql(Sbdf.of(2, 0x40, 4, 0)));
    try std.testing.expect(!a.eql(Sbdf.of(1, 0x40, 4, 1)));
}

test "unit: Sbdf.from propagates Bdf.from validation and preserves valid endpoints" {
    // Invalid device/function bytes must map to InvalidIdentifier; max legal SBDF encodes to all ones.
    try std.testing.expectError(error.InvalidIdentifier, Sbdf.from(0, 0, 32, 0));
    try std.testing.expectError(error.InvalidIdentifier, Sbdf.from(0, 0, 0, 8));
    try std.testing.expect((try Sbdf.from(0, 0, 0, 0)).eql(Sbdf.of(0, 0, 0, 0)));
    try std.testing.expectEqual(
        @as(u32, 0xFFFF_FFFF),
        (try Sbdf.from(0xFFFF, 0xFF, 31, 7)).asU32(),
    );
}

test "unit: Sbdf.lessThan is segment-major, then BDF-minor" {
    // Check segment rollover before low-half BDF ordering so source-id sorting stays stable.
    const a = Sbdf.of(0, 0xFF, 31, 7);
    const b = Sbdf.of(1, 0, 0, 0);
    try std.testing.expect(a.lessThan(b));
    try std.testing.expect(!b.lessThan(a));

    const c = Sbdf.of(0, 0, 0, 0);
    const d = Sbdf.of(0, 0, 0, 1);
    try std.testing.expect(c.lessThan(d));
}

test "unit: Sbdf.function0 preserves segment, bus, and device" {
    // Multifunction discovery must normalize only the function subfield within one segment.
    const s = Sbdf.of(3, 0x10, 5, 4);
    const f0 = s.function0();

    try std.testing.expectEqual(@as(u16, 3), f0.segment.value);
    try std.testing.expectEqual(@as(u8, 0x10), f0.bdf.bus);
    try std.testing.expectEqual(@as(u5, 5), f0.bdf.device);
    try std.testing.expectEqual(@as(u3, 0), f0.bdf.function);
}

test "unit: Sbdf.format writes fixed-width lspci-style ssss:bb:dd.f" {
    // Render lower bound, upper bound, and mixed values to verify fixed width, zero-padding, and lowercase hex.
    var buf: [64]u8 = undefined;

    const rendered_min = try std.fmt.bufPrint(&buf, "{f}", .{Sbdf.of(0, 0, 0, 0)});
    try std.testing.expectEqual(@as(usize, 12), rendered_min.len);
    try std.testing.expectEqualStrings("0000:00:00.0", rendered_min);

    const rendered_max = try std.fmt.bufPrint(&buf, "{f}", .{Sbdf.of(0xFFFF, 0xFF, 0x1F, 7)});
    try std.testing.expectEqual(@as(usize, 12), rendered_max.len);
    try std.testing.expectEqualStrings("ffff:ff:1f.7", rendered_max);

    const rendered_mixed = try std.fmt.bufPrint(&buf, "{f}", .{Sbdf.of(0xABCD, 0x12, 3, 4)});
    try std.testing.expectEqual(@as(usize, 12), rendered_mixed.len);
    try std.testing.expectEqualStrings("abcd:12:03.4", rendered_mixed);
}

test "unit: Bdf.format writes fixed-width bb:dd.f without a segment" {
    // Render lower bound, upper bound, and mixed values to verify fixed width, zero-padding, and lowercase hex.
    var buf: [16]u8 = undefined;

    const rendered_min = try std.fmt.bufPrint(&buf, "{f}", .{Bdf.of(0, 0, 0)});
    try std.testing.expectEqual(@as(usize, 7), rendered_min.len);
    try std.testing.expectEqualStrings("00:00.0", rendered_min);

    const rendered_max = try std.fmt.bufPrint(&buf, "{f}", .{Bdf.of(0xFF, 0x1F, 7)});
    try std.testing.expectEqual(@as(usize, 7), rendered_max.len);
    try std.testing.expectEqualStrings("ff:1f.7", rendered_max);

    const rendered_mixed = try std.fmt.bufPrint(&buf, "{f}", .{Bdf.of(0x10, 5, 6)});
    try std.testing.expectEqual(@as(usize, 7), rendered_mixed.len);
    try std.testing.expectEqualStrings("10:05.6", rendered_mixed);
}

test "unit: Bdf.parse accepts exact lspci-style segment-less addresses" {
    // Decode lower and upper bounds plus uppercase hex to cover fixed-width fields and digit case.
    try std.testing.expect((try Bdf.parse("00:00.0")).eql(Bdf.of(0, 0, 0)));
    try std.testing.expect((try Bdf.parse("ff:1f.7")).eql(Bdf.of(0xFF, 0x1F, 7)));
    try std.testing.expect((try Bdf.parse("AB:0C.6")).eql(Bdf.of(0xAB, 0x0C, 6)));
}

test "unit: Bdf.parse rejects malformed syntax and out-of-range fields" {
    // Feed one representative per rejected contract: width, delimiter, digit class, range, padding, and prefix.
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
        try std.testing.expectError(error.InvalidIdentifier, Bdf.parse(text));
    }
}

test "unit: Sbdf.parse accepts exact lspci-style domain addresses" {
    // Decode segment and nested BDF bounds plus uppercase hex to cover every fixed-width field.
    try std.testing.expect((try Sbdf.parse("0000:00:00.0")).eql(Sbdf.of(0, 0, 0, 0)));
    try std.testing.expect((try Sbdf.parse("ffff:ff:1f.7")).eql(Sbdf.of(0xFFFF, 0xFF, 0x1F, 7)));
    try std.testing.expect((try Sbdf.parse("ABCD:12:03.4")).eql(Sbdf.of(0xABCD, 0x12, 3, 4)));
}

test "unit: Sbdf.parse rejects malformed syntax and invalid nested BDF" {
    // Feed one representative per rejected contract at the segment and BDF layers.
    const invalid = [_][]const u8{
        "000:00:00.0",
        "0000-00:00.0",
        "gggg:00:00.0",
        "0000:00:20.0",
        "0000:00:00.8",
        "0000:00:00.0 ",
    };

    for (invalid) |text| {
        try std.testing.expectError(error.InvalidIdentifier, Sbdf.parse(text));
    }
}

test "unit: Bdf and Sbdf parse format output exactly" {
    // Round-trip formatter output through the strict parsers to guard the inverse contract.
    var bdf_buf: [16]u8 = undefined;
    const bdf = Bdf.of(0x7A, 0x0B, 5);
    const bdf_text = try std.fmt.bufPrint(&bdf_buf, "{f}", .{bdf});
    try std.testing.expect((try Bdf.parse(bdf_text)).eql(bdf));

    var sbdf_buf: [32]u8 = undefined;
    const sbdf = Sbdf.of(0xFEDC, 0x7A, 0x0B, 5);
    const sbdf_text = try std.fmt.bufPrint(&sbdf_buf, "{f}", .{sbdf});
    try std.testing.expect((try Sbdf.parse(sbdf_text)).eql(sbdf));
}
