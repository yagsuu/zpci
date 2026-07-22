//! Tests for docs/specs/resources/model.md.

const std = @import("std");

const pci = @import("pci");

const Aperture = pci.resources.Aperture;
const Assignment = pci.resources.Assignment;
const Entry = pci.bar.Entry;
const Function = pci.config.Function;
const Kind = pci.resources.Kind;
const Requirement = pci.resources.Requirement;
const HostBridgeApertures = pci.resources.HostBridgeApertures;
const Sbdf = pci.core.Sbdf;
const TestConfigSpace = pci.testing.config.TestConfigSpace;

const eligiblePools = pci.resources.eligiblePools;
const pcie_window_size: usize = 0x1000;

test "unit: eligiblePools implements the resource-kind truth table" {
    // Drive every requirement kind against every pool so one flipped eligibility bit is visible.
    const cases = [_]struct {
        name: []const u8,
        kind: Kind,
        expected: ExpectedEligible,
    }{
        .{ .name = "io", .kind = .io, .expected = .{ .io = true } },
        .{ .name = "mmio32", .kind = .mmio32, .expected = .{ .mmio32 = true } },
        .{
            .name = "mmio32 prefetchable",
            .kind = .mmio32_pref,
            .expected = .{ .mmio32 = true, .mmio32_pref = true },
        },
        .{
            .name = "mmio64",
            .kind = .mmio64,
            .expected = .{ .mmio32 = true, .mmio64 = true },
        },
        .{
            .name = "mmio64 prefetchable",
            .kind = .mmio64_pref,
            .expected = .{
                .mmio32 = true,
                .mmio32_pref = true,
                .mmio64 = true,
                .mmio64_pref = true,
            },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try expectEligible(eligiblePools(case.kind), case.expected);
    }
}

test "unit: Aperture absent and range expose half-open containment" {
    // Compare empty and non-empty apertures at their lower bound, exact end, and just outside.
    const absent = Aperture.absent(.io);
    try std.testing.expectEqual(Kind.io, absent.kind);
    try std.testing.expectEqual(@as(u64, 0), absent.base);
    try std.testing.expectEqual(@as(u64, 0), absent.size);
    try std.testing.expect(absent.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), absent.end());
    try std.testing.expect(!absent.contains(0, 0));

    const window = Aperture.range(.mmio32, 0x1000, 0x3000);
    try std.testing.expectEqual(Kind.mmio32, window.kind);
    try std.testing.expectEqual(@as(u64, 0x1000), window.base);
    try std.testing.expectEqual(@as(u64, 0x3000), window.size);
    try std.testing.expect(!window.isEmpty());
    try std.testing.expectEqual(@as(u64, 0x4000), window.end());
    try std.testing.expect(window.contains(0x1000, 0));
    try std.testing.expect(window.contains(0x1000, 1));
    try std.testing.expect(window.contains(0x3000, 0x1000));
    try std.testing.expect(!window.contains(0x0FFF, 1));
    try std.testing.expect(!window.contains(0x3001, 0x1000));
}

test "unit: Aperture containment rejects overflowing requested ranges" {
    // Place a request near maxInt(u64) so a missing overflow guard would wrap into the window.
    const max = std.math.maxInt(u64);
    const window = Aperture.range(.mmio64, max - 0x100, 0x100);

    try std.testing.expect(window.contains(max - 0x80, 0x80));
    try std.testing.expect(!window.contains(max - 0x10, 0x20));
}

test "unit: Aperture allocate consumes alignment padding and consecutive ranges" {
    // Start unaligned, then consume the exact remainder so both cursor movement and padding accounting are visible.
    var window = Aperture.range(.mmio32_pref, 0x1001, 0x2FFF);

    try std.testing.expectEqual(@as(?u64, 0x2000), window.allocate(0x800, 0x1000));
    try std.testing.expectEqual(Kind.mmio32_pref, window.kind);
    try std.testing.expectEqual(@as(u64, 0x2800), window.base);
    try std.testing.expectEqual(@as(u64, 0x1800), window.size);

    try std.testing.expectEqual(@as(?u64, 0x2800), window.allocate(0x1800, 0x800));
    try std.testing.expectEqual(@as(u64, 0x4000), window.base);
    try std.testing.expectEqual(@as(u64, 0), window.size);
    try std.testing.expect(window.isEmpty());
}

test "unit: Aperture allocate failure leaves the aperture unchanged" {
    // Exercise each runtime failure path: empty, too small, alignment overflow, and allocation-end overflow.
    var empty = Aperture.absent(.io);
    try std.testing.expectEqual(@as(?u64, null), empty.allocate(1, 1));
    try std.testing.expectEqual(@as(u64, 0), empty.base);
    try std.testing.expectEqual(@as(u64, 0), empty.size);

    var too_small = Aperture.range(.mmio32, 0x1000, 0x100);
    try std.testing.expectEqual(@as(?u64, null), too_small.allocate(0x101, 1));
    try std.testing.expectEqual(@as(u64, 0x1000), too_small.base);
    try std.testing.expectEqual(@as(u64, 0x100), too_small.size);

    const max = std.math.maxInt(u64);
    var alignment_overflow = Aperture.range(.mmio64, max - 0x7F, 0x7F);
    try std.testing.expectEqual(@as(?u64, null), alignment_overflow.allocate(1, 0x100));
    try std.testing.expectEqual(max - 0x7F, alignment_overflow.base);
    try std.testing.expectEqual(@as(u64, 0x7F), alignment_overflow.size);

    var end_overflow = Aperture.range(.mmio64_pref, max - 0x100, 0x100);
    try std.testing.expectEqual(@as(?u64, null), end_overflow.allocate(0x200, 1));
    try std.testing.expectEqual(max - 0x100, end_overflow.base);
    try std.testing.expectEqual(@as(u64, 0x100), end_overflow.size);
}

test "unit: HostBridgeApertures.get selects the aperture for each resource kind" {
    // Use distinct ranges in every field so a wrong switch arm returns observable wrong bounds.
    const apertures = HostBridgeApertures{
        .io = .range(.io, 0x0010, 0x10),
        .mmio32 = .range(.mmio32, 0x1000, 0x20),
        .mmio32_pref = .range(.mmio32_pref, 0x2000, 0x30),
        .mmio64 = .range(.mmio64, 0x1_0000_0000, 0x40),
        .mmio64_pref = .range(.mmio64_pref, 0x2_0000_0000, 0x50),
    };
    const cases = [_]struct {
        kind: Kind,
        base: u64,
        size: u64,
    }{
        .{ .kind = .io, .base = 0x0010, .size = 0x10 },
        .{ .kind = .mmio32, .base = 0x1000, .size = 0x20 },
        .{ .kind = .mmio32_pref, .base = 0x2000, .size = 0x30 },
        .{ .kind = .mmio64, .base = 0x1_0000_0000, .size = 0x40 },
        .{ .kind = .mmio64_pref, .base = 0x2_0000_0000, .size = 0x50 },
    };

    for (cases) |case| {
        const aperture = apertures.get(case.kind);

        try std.testing.expectEqual(case.kind, aperture.kind);
        try std.testing.expectEqual(case.base, aperture.base);
        try std.testing.expectEqual(case.size, aperture.size);
    }
}

test "unit: Requirement.fromBar drops absent and zero-sized BARs" {
    // Feed the null-producing BAR shapes so unimplemented or pathological probe results do not allocate resources.
    var bytes: [pcie_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 1, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    try std.testing.expectEqual(@as(?Requirement, null), Requirement.fromBar(function, noneEntry(0)));
    try std.testing.expectEqual(@as(?Requirement, null), Requirement.fromBar(function, ioEntry(1, 0)));
    try std.testing.expectEqual(
        @as(?Requirement, null),
        Requirement.fromBar(function, memoryEntry(2, 0, .bits_32, false)),
    );
}

test "unit: Requirement.fromBar maps IO and memory BAR variants" {
    // Table-drive non-null BAR kinds and assert kind, natural alignment, and BAR source identity.
    var bytes: [pcie_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 2, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);
    const cases = [_]struct {
        name: []const u8,
        entry: Entry,
        expected: ExpectedBarRequirement,
    }{
        .{
            .name = "io",
            .entry = ioEntry(0, 0x100),
            .expected = .{ .kind = .io, .size = 0x100, .index = 0 },
        },
        .{
            .name = "32-bit non-prefetchable memory",
            .entry = memoryEntry(1, 0x1000, .bits_32, false),
            .expected = .{ .kind = .mmio32, .size = 0x1000, .index = 1 },
        },
        .{
            .name = "32-bit prefetchable memory",
            .entry = memoryEntry(2, 0x2000, .bits_32, true),
            .expected = .{ .kind = .mmio32_pref, .size = 0x2000, .index = 2 },
        },
        .{
            .name = "64-bit non-prefetchable memory",
            .entry = memoryEntry(3, 0x4000, .bits_64, false),
            .expected = .{ .kind = .mmio64, .size = 0x4000, .index = 3 },
        },
        .{
            .name = "64-bit prefetchable memory",
            .entry = memoryEntry(4, 0x8000, .bits_64, true),
            .expected = .{ .kind = .mmio64_pref, .size = 0x8000, .index = 4 },
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try expectBarRequirement(function, Requirement.fromBar(function, case.entry).?, case.expected);
    }
}

test "unit: Requirement.fromExpansionRom maps nonzero ROM size to MMIO32" {
    // Convert zero and nonzero ROM probe sizes so only real ROM apertures become requirements.
    var bytes: [pcie_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 3, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);

    try std.testing.expectEqual(@as(?Requirement, null), Requirement.fromExpansionRom(function, 0));

    const requirement = Requirement.fromExpansionRom(function, 0x20_0000).?;
    try std.testing.expectEqual(Kind.mmio32, requirement.kind);
    try std.testing.expectEqual(@as(u64, 0x20_0000), requirement.size);
    try std.testing.expectEqual(@as(u64, 0x20_0000), requirement.alignment);

    switch (requirement.source) {
        .endpoint_expansion_rom => |source_function| try std.testing.expect(function.eq(source_function)),
        else => return error.TestExpectedEqual,
    }
}

test "unit: Requirement.fromBarSlice preserves BAR order and rejects short output" {
    // Mix skipped and kept entries to prove compaction is stable and capacity is checked up front.
    var bytes: [pcie_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 4, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);
    const entries = [_]Entry{
        noneEntry(0),
        ioEntry(1, 0x100),
        memoryEntry(2, 0x2000, .bits_64, false),
        memoryEntry(4, 0, .bits_32, true),
        memoryEntry(5, 0x1000, .bits_32, true),
    };

    var requirements: [3]Requirement = undefined;
    const written = try Requirement.fromBarSlice(function, &entries, &requirements);

    try std.testing.expectEqual(@as(usize, 3), written.len);
    try expectBarRequirement(function, written[0], .{ .kind = .io, .size = 0x100, .index = 1 });
    try expectBarRequirement(function, written[1], .{ .kind = .mmio64, .size = 0x2000, .index = 2 });
    try expectBarRequirement(function, written[2], .{ .kind = .mmio32_pref, .size = 0x1000, .index = 5 });

    var short: [2]Requirement = undefined;
    try std.testing.expectError(error.StorageExhausted, Requirement.fromBarSlice(function, &entries, &short));
}

test "unit: Assignment function returns the owner for every source kind" {
    // Cover all requirement-source variants so grouping code can call the owning Assignment method.
    var bytes: [pcie_window_size]u8 = @splat(0);
    const sbdf = Sbdf.of(0, 0, 5, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const function = Function.unchecked(backend.configSpace(), sbdf);
    const assignments = [_]Assignment{
        .{
            .requirement = Requirement.fromBar(function, ioEntry(0, 0x100)).?,
            .pool = .io,
            .base = 0x1000,
        },
        .{
            .requirement = Requirement.fromExpansionRom(function, 0x2000).?,
            .pool = .mmio32,
            .base = 0x8000_0000,
        },
        .{
            .requirement = .{
                .kind = .mmio64,
                .size = 0x10_0000,
                .alignment = 0x10_0000,
                .source = .{
                    .bridge_window = .{
                        .function = function,
                        .window = .memory,
                    },
                },
            },
            .pool = .mmio64,
            .base = 0x1_0000_0000,
        },
    };

    for (assignments) |assignment| {
        try std.testing.expect(function.eq(assignment.function()));
    }
}

const ExpectedEligible = struct {
    io: bool = false,
    mmio32: bool = false,
    mmio32_pref: bool = false,
    mmio64: bool = false,
    mmio64_pref: bool = false,
};

const ExpectedBarRequirement = struct {
    kind: Kind,
    size: u64,
    index: usize,
};

fn expectEligible(actual: pci.resources.EligibleSet, expected: ExpectedEligible) !void {
    try std.testing.expectEqual(expected.io, actual.has(.io));
    try std.testing.expectEqual(expected.mmio32, actual.has(.mmio32));
    try std.testing.expectEqual(expected.mmio32_pref, actual.has(.mmio32_pref));
    try std.testing.expectEqual(expected.mmio64, actual.has(.mmio64));
    try std.testing.expectEqual(expected.mmio64_pref, actual.has(.mmio64_pref));
}

fn expectBarRequirement(function: Function, requirement: Requirement, expected: ExpectedBarRequirement) !void {
    try std.testing.expectEqual(expected.kind, requirement.kind);
    try std.testing.expectEqual(expected.size, requirement.size);
    try std.testing.expectEqual(expected.size, requirement.alignment);

    switch (requirement.source) {
        .endpoint_bar => |source| {
            try std.testing.expectEqual(expected.index, source.index);
            try std.testing.expect(function.eq(source.function));
        },
        else => return error.TestExpectedEqual,
    }
}

fn noneEntry(index: usize) Entry {
    return .{
        .index = index,
        .slot_count = 1,
        .kind = .none,
    };
}

fn ioEntry(index: usize, size: u32) Entry {
    return .{
        .index = index,
        .slot_count = 1,
        .kind = .{ .io = .{ .base = 0x0000_C000, .size = size } },
    };
}

fn memoryEntry(index: usize, size: u64, width: pci.bar.Kind.Width, prefetchable: bool) Entry {
    return .{
        .index = index,
        .slot_count = switch (width) {
            .bits_32 => 1,
            .bits_64 => 2,
        },
        .kind = .{
            .memory = .{
                .base = 0x8000_0000,
                .size = size,
                .width = width,
                .prefetchable = prefetchable,
            },
        },
    };
}
