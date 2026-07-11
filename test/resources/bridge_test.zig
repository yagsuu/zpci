//! Tests for docs/specs/resources/bridge.md.

const std = @import("std");

const zpci = @import("zpci");

const bridge = zpci.resources.bridge;
const Assignment = bridge.Assignment;
const EncodedWindow = bridge.EncodedWindow;
const Function = zpci.config.Function;
const ConfigSpace = zpci.config.ConfigSpace;
const Kind = bridge.Kind;
const Requirement = bridge.Requirement;
const Sbdf = zpci.core.Sbdf;
const Source = bridge.Source;

const bridge_io_alignment: u64 = 0x1000;
const bridge_memory_alignment: u64 = 0x10_0000;

test "unit: aggregateWindows maps child kinds to ordered bridge requirements" {
    // Mix all resource classes and assert the three bridge windows are emitted in fixed offset order.
    const function = testFunction(1);
    const children = [_]Requirement{
        childRequirement(function, .mmio64_pref, 0x20_0000, 0x20_0000),
        childRequirement(function, .io, 0x1000, 0x1000),
        childRequirement(function, .mmio64, 0x20_0000, 0x20_0000),
        childRequirement(function, .mmio32_pref, 0x10_0000, 0x10_0000),
    };

    var out: [3]Requirement = undefined;
    const windows = try bridge.aggregateWindows(function, &children, &out);

    try std.testing.expectEqual(@as(usize, 3), windows.len);
    try expectBridgeRequirement(function, windows[0], .io, .io, 0x1000, bridge_io_alignment);
    try expectBridgeRequirement(function, windows[1], .memory, .mmio32, 0x20_0000, 0x20_0000);
    try expectBridgeRequirement(function, windows[2], .prefetchable_memory, .mmio32_pref, 0x40_0000, 0x20_0000);
}

test "unit: aggregateWindows keeps all-64-bit prefetchable bucket 64-bit" {
    // Feed only 64-bit prefetchable descendants so a stray 32-bit downgrade is visible.
    const function = testFunction(2);
    const children = [_]Requirement{
        childRequirement(function, .mmio64_pref, 0x10_0000, 0x10_0000),
        childRequirement(function, .mmio64_pref, 0x20_0000, 0x20_0000),
    };

    var out: [1]Requirement = undefined;
    const windows = try bridge.aggregateWindows(function, &children, &out);

    try std.testing.expectEqual(@as(usize, 1), windows.len);
    try expectBridgeRequirement(function, windows[0], .prefetchable_memory, .mmio64_pref, 0x40_0000, 0x20_0000);
}

test "unit: aggregateWindows rejects short scratch without modifying it" {
    // Require three output slots while providing two, then prove scratch is untouched.
    const function = testFunction(3);
    const children = [_]Requirement{
        childRequirement(function, .io, 0x1000, 0x1000),
        childRequirement(function, .mmio32, 0x10_0000, 0x10_0000),
        childRequirement(function, .mmio64_pref, 0x10_0000, 0x10_0000),
    };
    const sentinel = childRequirement(function, .mmio32, 0x4000, 0x4000);
    var out = [_]Requirement{ sentinel, sentinel };

    try std.testing.expectError(error.StorageExhausted, bridge.aggregateWindows(function, &children, &out));
    try expectSameRequirement(sentinel, out[0]);
    try expectSameRequirement(sentinel, out[1]);

    var none: [0]Requirement = .{};
    try std.testing.expectError(error.StorageExhausted, bridge.aggregateWindows(function, children[0..1], &none));
}

test "unit: aggregateWindows sorts by descending alignment and skips zero-sized children" {
    // Compare the packed size against the known optimum for the spec's descending-alignment greedy order.
    const function = testFunction(4);
    const children = [_]Requirement{
        childRequirement(function, .io, 0x1000, 0x1000),
        childRequirement(function, .io, 0x10_0000, 0x10_0000),
        childRequirement(function, .io, 0, 0x1000),
        childRequirement(function, .io, 0x4000, 0x4000),
    };

    var first_out: [1]Requirement = undefined;
    var second_out: [1]Requirement = undefined;
    const first = try bridge.aggregateWindows(function, &children, &first_out);
    const second = try bridge.aggregateWindows(function, &children, &second_out);

    try std.testing.expectEqual(@as(usize, 1), first.len);
    try expectBridgeRequirement(function, first[0], .io, .io, 0x20_0000, 0x10_0000);
    try expectSameRequirement(first[0], second[0]);
}

test "unit: aggregateWindows raises bridge granularity above tiny child alignment" {
    // Use a 512-byte IO child to verify the aggregate alignment and size are raised to 4 KiB.
    const function = testFunction(5);
    const children = [_]Requirement{childRequirement(function, .io, 0x200, 0x200)};

    var out: [1]Requirement = undefined;
    const windows = try bridge.aggregateWindows(function, &children, &out);

    try expectBridgeRequirement(function, windows[0], .io, .io, bridge_io_alignment, bridge_io_alignment);
}

test "unit: aggregateWindows returns an empty borrowed prefix for no live children" {
    // Include only a zero-sized child so the defensive skip path produces no bridge windows.
    const function = testFunction(6);
    const children = [_]Requirement{childRequirement(function, .mmio32, 0, 0x1000)};

    var out: [1]Requirement = undefined;
    const windows = try bridge.aggregateWindows(function, &children, &out);

    try std.testing.expectEqual(@as(usize, 0), windows.len);
}

test "unit: encodeWindow emits canonical disabled encodings for zero-sized windows" {
    // Drive all three bridge-window kinds with zero size so base-minus-one underflow cannot masquerade as a range.
    const function = testFunction(7);

    try expectIoEncoding(
        try bridge.encodeWindow(windowAssignment(function, .io, .io, 0, 0, bridge_io_alignment)),
        .{ .base_lo = 0xF0, .limit_lo = 0, .base_upper = 0, .limit_upper = 0, .is_32bit = false },
    );
    try expectMemoryEncoding(
        try bridge.encodeWindow(windowAssignment(function, .memory, .mmio32, 0, 0, bridge_memory_alignment)),
        .{ .base = 0xFFF0, .limit = 0 },
    );
    try expectPrefetchable32Encoding(
        try bridge.encodeWindow(windowAssignment(
            function,
            .prefetchable_memory,
            .mmio32_pref,
            0,
            0,
            bridge_memory_alignment,
        )),
        .{ .base_lo = 0xFFF0, .limit_lo = 0 },
    );
}

test "unit: encodeWindow emits IO 16-bit and 32-bit wire fields" {
    // Check both the low-register type nibble and the upper-register behavior around the 64 KiB boundary.
    const function = testFunction(8);

    try expectIoEncoding(
        try bridge.encodeWindow(windowAssignment(function, .io, .io, 0x2000, 0x1000, bridge_io_alignment)),
        .{ .base_lo = 0x20, .limit_lo = 0x20, .base_upper = 0, .limit_upper = 0, .is_32bit = false },
    );
    try expectIoEncoding(
        try bridge.encodeWindow(windowAssignment(function, .io, .io, 0x0001_2000, 0x1000, bridge_io_alignment)),
        .{ .base_lo = 0x21, .limit_lo = 0x21, .base_upper = 0x0001, .limit_upper = 0x0001, .is_32bit = true },
    );
}

test "unit: encodeWindow emits memory and prefetchable wire fields" {
    // Cover 32-bit memory, 32-bit prefetchable, and 64-bit prefetchable encodings with nonzero ranges.
    const function = testFunction(9);

    try expectMemoryEncoding(
        try bridge.encodeWindow(windowAssignment(
            function,
            .memory,
            .mmio32,
            0x2000_0000,
            0x0010_0000,
            bridge_memory_alignment,
        )),
        .{ .base = 0x2000, .limit = 0x2000 },
    );
    try expectPrefetchable32Encoding(
        try bridge.encodeWindow(
            windowAssignment(
                function,
                .prefetchable_memory,
                .mmio32_pref,
                0xD000_0000,
                0x1000_0000,
                bridge_memory_alignment,
            ),
        ),
        .{ .base_lo = 0xD000, .limit_lo = 0xDFF0 },
    );
    try expectPrefetchable64Encoding(
        try bridge.encodeWindow(
            windowAssignment(
                function,
                .prefetchable_memory,
                .mmio64_pref,
                0x1_0000_0000,
                0x1000_0000,
                bridge_memory_alignment,
            ),
        ),
        .{ .base_lo = 0x0001, .limit_lo = 0x0FF1, .base_upper = 0x0000_0001, .limit_upper = 0x0000_0001 },
    );
}

test "unit: encodeWindow selects prefetchable width at the 4 GiB boundary" {
    // Keep one window ending exactly at 4 GiB and one crossing it so the comparison is off-by-one sensitive.
    const function = testFunction(10);

    try expectPrefetchable32Encoding(
        try bridge.encodeWindow(
            windowAssignment(
                function,
                .prefetchable_memory,
                .mmio64_pref,
                0xF000_0000,
                0x1000_0000,
                bridge_memory_alignment,
            ),
        ),
        .{ .base_lo = 0xF000, .limit_lo = 0xFFF0 },
    );
    try expectPrefetchable64Encoding(
        try bridge.encodeWindow(
            windowAssignment(
                function,
                .prefetchable_memory,
                .mmio64_pref,
                0xFFF0_0000,
                0x0020_0000,
                bridge_memory_alignment,
            ),
        ),
        .{ .base_lo = 0xFFF1, .limit_lo = 0x0001, .base_upper = 0x0000_0000, .limit_upper = 0x0000_0001 },
    );
}

test "unit: encodeWindow reports BridgeWindowUnencodable for overflowing placements" {
    // Exercise every typed failure branch: IO over 32 bits, memory over 32 bits, and u64 addition overflow.
    const function = testFunction(11);

    try std.testing.expectError(
        error.BridgeWindowUnencodable,
        bridge.encodeWindow(windowAssignment(function, .io, .io, 0x1_0000_0000, 0x1000, bridge_io_alignment)),
    );
    try std.testing.expectError(
        error.BridgeWindowUnencodable,
        bridge.encodeWindow(windowAssignment(
            function,
            .memory,
            .mmio32,
            0x1_0000_0000,
            0x10_0000,
            bridge_memory_alignment,
        )),
    );
    try std.testing.expectError(
        error.BridgeWindowUnencodable,
        bridge.encodeWindow(
            windowAssignment(
                function,
                .prefetchable_memory,
                .mmio64_pref,
                0xFFFF_FFFF_FFF0_0000,
                0x20_0000,
                bridge_memory_alignment,
            ),
        ),
    );
}

test "layout: EncodedWindow payload structs match the spec sizes" {
    // Assert the semantic payload sizes consumed by the future programming writer.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(EncodedWindow.IoEncoding));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(EncodedWindow.MemoryEncoding));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(EncodedWindow.Prefetchable32Encoding));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(EncodedWindow.Prefetchable64Encoding));
}

const ExpectedIo = struct {
    base_lo: u8,
    limit_lo: u8,
    base_upper: u16,
    limit_upper: u16,
    is_32bit: bool,
};

const ExpectedMemory = struct {
    base: u16,
    limit: u16,
};

const ExpectedPrefetchable32 = struct {
    base_lo: u16,
    limit_lo: u16,
};

const ExpectedPrefetchable64 = struct {
    base_lo: u16,
    limit_lo: u16,
    base_upper: u32,
    limit_upper: u32,
};

var fake_context: u8 = 0;

const fake_vtable: ConfigSpace.VTable = .{
    .read8 = fakeRead8,
    .read16 = fakeRead16,
    .read32 = fakeRead32,
    .write8 = fakeWrite8,
    .write16 = fakeWrite16,
    .write32 = fakeWrite32,
};

fn testFunction(comptime device: u5) Function {
    const config_space = ConfigSpace.init(@ptrCast(&fake_context), &fake_vtable);
    return Function.unchecked(config_space, Sbdf.of(0, 0, device, 0));
}

fn fakeRead8(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u8 {
    _ = context;
    _ = sbdf;
    _ = offset;
    return 0;
}

fn fakeRead16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u16 {
    _ = context;
    _ = sbdf;
    _ = offset;
    return 0;
}

fn fakeRead32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigSpace.Error!u32 {
    _ = context;
    _ = sbdf;
    _ = offset;
    return 0;
}

fn fakeWrite8(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u8) ConfigSpace.Error!void {
    _ = context;
    _ = sbdf;
    _ = offset;
    _ = value;
}

fn fakeWrite16(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u16) ConfigSpace.Error!void {
    _ = context;
    _ = sbdf;
    _ = offset;
    _ = value;
}

fn fakeWrite32(context: *anyopaque, sbdf: Sbdf, offset: usize, value: u32) ConfigSpace.Error!void {
    _ = context;
    _ = sbdf;
    _ = offset;
    _ = value;
}

fn childRequirement(function: Function, kind: Kind, size: u64, alignment: u64) Requirement {
    return .{
        .kind = kind,
        .size = size,
        .alignment = alignment,
        .source = .{ .endpoint_expansion_rom = function },
    };
}

fn windowAssignment(
    function: Function,
    window: Source.BridgeWindow,
    kind: Kind,
    base: u64,
    size: u64,
    alignment: u64,
) Assignment {
    return .{
        .requirement = .{
            .kind = kind,
            .size = size,
            .alignment = alignment,
            .source = .{ .bridge_window = .{ .function = function, .window = window } },
        },
        .pool = kind,
        .base = base,
    };
}

fn expectBridgeRequirement(
    function: Function,
    actual: Requirement,
    window: Source.BridgeWindow,
    kind: Kind,
    size: u64,
    alignment: u64,
) !void {
    try std.testing.expectEqual(kind, actual.kind);
    try std.testing.expectEqual(size, actual.size);
    try std.testing.expectEqual(alignment, actual.alignment);
    switch (actual.source) {
        .bridge_window => |source| {
            try std.testing.expectEqual(window, source.window);
            try expectSameFunction(function, source.function);
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectSameRequirement(expected: Requirement, actual: Requirement) !void {
    try std.testing.expectEqual(expected.kind, actual.kind);
    try std.testing.expectEqual(expected.size, actual.size);
    try std.testing.expectEqual(expected.alignment, actual.alignment);
    try std.testing.expectEqual(std.meta.activeTag(expected.source), std.meta.activeTag(actual.source));
    switch (expected.source) {
        .endpoint_expansion_rom => |function| try expectSameFunction(function, actual.source.endpoint_expansion_rom),
        .bridge_window => |source| {
            try std.testing.expectEqual(source.window, actual.source.bridge_window.window);
            try expectSameFunction(source.function, actual.source.bridge_window.function);
        },
        .endpoint_bar => |bar| {
            try std.testing.expectEqual(bar.index, actual.source.endpoint_bar.index);
            try expectSameFunction(bar.function, actual.source.endpoint_bar.function);
        },
    }
}

fn expectSameFunction(expected: Function, actual: Function) !void {
    try std.testing.expect(expected.sbdf.eql(actual.sbdf));
    try std.testing.expect(expected.config.context == actual.config.context);
    try std.testing.expect(expected.config.vtable == actual.config.vtable);
}

fn expectIoEncoding(actual: EncodedWindow, expected: ExpectedIo) !void {
    switch (actual) {
        .io => |io| {
            try std.testing.expectEqual(expected.base_lo, io.base_lo);
            try std.testing.expectEqual(expected.limit_lo, io.limit_lo);
            try std.testing.expectEqual(expected.base_upper, io.base_upper);
            try std.testing.expectEqual(expected.limit_upper, io.limit_upper);
            try std.testing.expectEqual(expected.is_32bit, io.is_32bit);
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectMemoryEncoding(actual: EncodedWindow, expected: ExpectedMemory) !void {
    switch (actual) {
        .memory => |memory| {
            try std.testing.expectEqual(expected.base, memory.base);
            try std.testing.expectEqual(expected.limit, memory.limit);
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectPrefetchable32Encoding(actual: EncodedWindow, expected: ExpectedPrefetchable32) !void {
    switch (actual) {
        .prefetchable_memory_32 => |prefetchable| {
            try std.testing.expectEqual(expected.base_lo, prefetchable.base_lo);
            try std.testing.expectEqual(expected.limit_lo, prefetchable.limit_lo);
        },
        else => return error.TestExpectedEqual,
    }
}

fn expectPrefetchable64Encoding(actual: EncodedWindow, expected: ExpectedPrefetchable64) !void {
    switch (actual) {
        .prefetchable_memory_64 => |prefetchable| {
            try std.testing.expectEqual(expected.base_lo, prefetchable.base_lo);
            try std.testing.expectEqual(expected.limit_lo, prefetchable.limit_lo);
            try std.testing.expectEqual(expected.base_upper, prefetchable.base_upper);
            try std.testing.expectEqual(expected.limit_upper, prefetchable.limit_upper);
        },
        else => return error.TestExpectedEqual,
    }
}
