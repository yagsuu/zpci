const stdx = @import("stdx");
const core = @import("core");

const SegmentId = core.SegmentId;
const Sbdf = core.Sbdf;
const BusRange = stdx.ranges.InclusiveRange(core.bus.Index);

pub const Segment = struct {
    segment: SegmentId,
    buses: BusRange,

    pub fn contains(self: Segment, sbdf: Sbdf) bool {
        return self.segment == sbdf.segment and
            self.buses.isValid() and self.buses.contains(sbdf.bdf.bus);
    }
};

pub const unit = struct {
    const testing = @import("std").testing;

    test "Segment contains only matching SBDFs inside valid buses" {
        const segment: Segment = .{
            .segment = .from(3),
            .buses = .of(0x20, 0x2F),
        };

        try testing.expect(segment.contains(Sbdf.from(.from(3), 0x20, 0, 0)));
        try testing.expect(segment.contains(Sbdf.from(.from(3), 0x2F, 31, 7)));
        try testing.expect(!segment.contains(Sbdf.from(.from(3), 0x1F, 0, 0)));
        try testing.expect(!segment.contains(Sbdf.from(.from(3), 0x30, 0, 0)));
        try testing.expect(!segment.contains(Sbdf.from(.from(4), 0x20, 0, 0)));

        const invalid: Segment = .{
            .segment = .from(3),
            .buses = .{ .start = 0x30, .end = 0x2F },
        };

        try testing.expect(!invalid.contains(Sbdf.from(.from(3), 0x2F, 0, 0)));
        try testing.expect(!invalid.contains(Sbdf.from(.from(3), 0x30, 0, 0)));
    }
};
