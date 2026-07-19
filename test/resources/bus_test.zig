//! Tests for docs/specs/resources/bus.md.

const std = @import("std");

const pci = @import("pci");

const bus = pci.resources.bus;
const Bridge = bus.Bridge;
const ConfigSpace = pci.config.ConfigSpace;
const Function = pci.config.Function;
const Sbdf = pci.core.Sbdf;

const commit = bus.commit;
const pcie_window_size: usize = 0x1000;
const offset_primary: usize = 0x18;
const offset_secondary: usize = 0x19;
const offset_subordinate: usize = 0x1A;
const offset_command: usize = 0x04;

test "unit: commit accepts empty roots without config-space access" {
    // Empty inputs exercise the smallest valid segment aperture and must not require a fake backend.
    try commit(.{
        .bridges = &.{},
        .roots = &.{},
        .root_primary_bus = 0,
        .bus_end = 0,
    });
}

test "unit: DFS numbering covers nested, sibling, and multiple root bridges" {
    // Program a preorder forest and compare every bus-number byte so traversal order errors are visible.
    var fixture = try ForestFixture.init(.{ .count = 6 });
    seedBus(&fixture.bytes[0], 0xA0, 0xA1, 0xA2);
    seedBus(&fixture.bytes[1], 0xB0, 0xB1, 0xB2);
    seedBus(&fixture.bytes[2], 0xC0, 0xC1, 0xC2);
    seedBus(&fixture.bytes[3], 0xD0, 0xD1, 0xD2);
    seedBus(&fixture.bytes[4], 0xE0, 0xE1, 0xE2);
    seedBus(&fixture.bytes[5], 0xF0, 0xF1, 0xF2);
    var backend = LoggedConfig.init(fixture.boundEntries());
    const bridges = [_]Bridge{
        bridge(null, backend.function(fixture.sbdfs[0])),
        bridge(0, backend.function(fixture.sbdfs[1])),
        bridge(1, backend.function(fixture.sbdfs[2])),
        bridge(0, backend.function(fixture.sbdfs[3])),
        bridge(null, backend.function(fixture.sbdfs[4])),
        bridge(4, backend.function(fixture.sbdfs[5])),
    };
    const roots = [_]bus.BridgeIndex{ 0, 4 };

    try commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0, .bus_end = 10 });

    try expectBus(&fixture.bytes[0], .{ .primary = 0, .secondary = 1, .subordinate = 4 });
    try expectBus(&fixture.bytes[1], .{ .primary = 1, .secondary = 2, .subordinate = 3 });
    try expectBus(&fixture.bytes[2], .{ .primary = 2, .secondary = 3, .subordinate = 3 });
    try expectBus(&fixture.bytes[3], .{ .primary = 1, .secondary = 4, .subordinate = 4 });
    try expectBus(&fixture.bytes[4], .{ .primary = 0, .secondary = 5, .subordinate = 6 });
    try expectBus(&fixture.bytes[5], .{ .primary = 5, .secondary = 6, .subordinate = 6 });
}

test "unit: bus range exhaustion returns before hardware writes" {
    // Exhaust the inclusive segment aperture before Phase 2 and prove the byte-backed config space is untouched.
    var fixture = try ForestFixture.init(.{ .count = 1 });
    seedBus(&fixture.bytes[0], 0x12, 0x34, 0x56);
    var before = fixture.bytes[0];
    var backend = LoggedConfig.init(fixture.boundEntries());
    const bridges = [_]Bridge{bridge(null, backend.function(fixture.sbdfs[0]))};
    const roots = [_]bus.BridgeIndex{0};

    try std.testing.expectError(
        error.BusRangeExhausted,
        commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 5, .bus_end = 5 }),
    );

    try std.testing.expectEqualSlices(u8, &before, &fixture.bytes[0]);
    try std.testing.expectEqual(@as(usize, 0), backend.log_len);
}

test "unit: single bridge save write and readback order is subordinate primary secondary" {
    // Compare the complete access trace so save order, write order, readbacks, and Command silence are observable.
    var fixture = try ForestFixture.init(.{ .count = 1 });
    seedBus(&fixture.bytes[0], 0xAA, 0xBB, 0xCC);
    var backend = LoggedConfig.init(fixture.boundEntries());
    const sbdf = fixture.sbdfs[0];
    const bridges = [_]Bridge{bridge(null, backend.function(sbdf))};
    const roots = [_]bus.BridgeIndex{0};

    try commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0x10, .bus_end = 0x20 });

    try expectBus(&fixture.bytes[0], .{ .primary = 0x10, .secondary = 0x11, .subordinate = 0x11 });
    try expectLog(&backend, &.{
        read(sbdf, offset_primary, 0xAA),
        read(sbdf, offset_secondary, 0xBB),
        read(sbdf, offset_subordinate, 0xCC),
        write(sbdf, offset_subordinate, 0x11),
        read(sbdf, offset_subordinate, 0x11),
        write(sbdf, offset_primary, 0x10),
        read(sbdf, offset_primary, 0x10),
        write(sbdf, offset_secondary, 0x11),
        read(sbdf, offset_secondary, 0x11),
    });
    try expectNoOffset(&backend, offset_command);
}

test "unit: nested commit defers parent secondary until child writes complete" {
    // Parent secondary changes can invalidate child handles, so children must finish before parents flip.
    var fixture = try ForestFixture.init(.{ .count = 2 });
    seedBus(&fixture.bytes[0], 0xA0, 0xA1, 0xA2);
    seedBus(&fixture.bytes[1], 0xB0, 0xB1, 0xB2);
    var backend = LoggedConfig.init(fixture.boundEntries());
    const parent = fixture.sbdfs[0];
    const child = fixture.sbdfs[1];
    const bridges = [_]Bridge{
        bridge(null, backend.function(parent)),
        bridge(0, backend.function(child)),
    };
    const roots = [_]bus.BridgeIndex{0};

    try commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0, .bus_end = 4 });

    try expectLog(&backend, &.{
        read(parent, offset_primary, 0xA0),
        read(parent, offset_secondary, 0xA1),
        read(parent, offset_subordinate, 0xA2),
        read(child, offset_primary, 0xB0),
        read(child, offset_secondary, 0xB1),
        read(child, offset_subordinate, 0xB2),
        write(parent, offset_subordinate, 0x02),
        read(parent, offset_subordinate, 0x02),
        write(child, offset_subordinate, 0x02),
        read(child, offset_subordinate, 0x02),
        write(parent, offset_primary, 0x00),
        read(parent, offset_primary, 0x00),
        write(child, offset_primary, 0x01),
        read(child, offset_primary, 0x01),
        write(child, offset_secondary, 0x02),
        read(child, offset_secondary, 0x02),
        write(parent, offset_secondary, 0x01),
        read(parent, offset_secondary, 0x01),
    });
}

test "unit: readback mismatch rolls back the failing bridge" {
    // Corrupt primary readback after subordinate committed and require reverse rollback of primary then subordinate.
    var fixture = try ForestFixture.init(.{ .count = 1 });
    seedBus(&fixture.bytes[0], 0xAA, 0xBB, 0xCC);
    var backend = LoggedConfig.init(fixture.boundEntries());
    backend.corrupt_on = .{ .operation = 7, .value = 0xFF };
    const sbdf = fixture.sbdfs[0];
    const bridges = [_]Bridge{bridge(null, backend.function(sbdf))};
    const roots = [_]bus.BridgeIndex{0};

    try std.testing.expectError(
        error.ProgrammingReadbackMismatch,
        commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0, .bus_end = 4 }),
    );

    try expectBus(&fixture.bytes[0], .{ .primary = 0xAA, .secondary = 0xBB, .subordinate = 0xCC });
    try expectLog(&backend, &.{
        read(sbdf, offset_primary, 0xAA),
        read(sbdf, offset_secondary, 0xBB),
        read(sbdf, offset_subordinate, 0xCC),
        write(sbdf, offset_subordinate, 0x01),
        read(sbdf, offset_subordinate, 0x01),
        write(sbdf, offset_primary, 0x00),
        read(sbdf, offset_primary, 0xFF),
        write(sbdf, offset_primary, 0xAA),
        read(sbdf, offset_primary, 0xAA),
        write(sbdf, offset_subordinate, 0xCC),
        read(sbdf, offset_subordinate, 0xCC),
    });
}

test "unit: injected write failure maps to ProgrammingWriteFailed after rollback" {
    // Fail the secondary write after subordinate and primary commit, then require both earlier writes restored.
    var fixture = try ForestFixture.init(.{ .count = 1 });
    seedBus(&fixture.bytes[0], 0xAA, 0xBB, 0xCC);
    var backend = LoggedConfig.init(fixture.boundEntries());
    backend.fail_on = 8;
    const sbdf = fixture.sbdfs[0];
    const bridges = [_]Bridge{bridge(null, backend.function(sbdf))};
    const roots = [_]bus.BridgeIndex{0};

    try std.testing.expectError(
        error.ProgrammingWriteFailed,
        commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0, .bus_end = 4 }),
    );

    try expectBus(&fixture.bytes[0], .{ .primary = 0xAA, .secondary = 0xBB, .subordinate = 0xCC });
    try expectLog(&backend, &.{
        read(sbdf, offset_primary, 0xAA),
        read(sbdf, offset_secondary, 0xBB),
        read(sbdf, offset_subordinate, 0xCC),
        write(sbdf, offset_subordinate, 0x01),
        read(sbdf, offset_subordinate, 0x01),
        write(sbdf, offset_primary, 0x00),
        read(sbdf, offset_primary, 0x00),
        write(sbdf, offset_secondary, 0x01),
        write(sbdf, offset_primary, 0xAA),
        read(sbdf, offset_primary, 0xAA),
        write(sbdf, offset_subordinate, 0xCC),
        read(sbdf, offset_subordinate, 0xCC),
    });
}

test "unit: rollback restore failure returns ProgrammingPartial and aborts further restores" {
    // Fail the first rollback write after a secondary readback mismatch so rollback must stop immediately.
    var fixture = try ForestFixture.init(.{ .count = 1 });
    seedBus(&fixture.bytes[0], 0xAA, 0xBB, 0xCC);
    var backend = LoggedConfig.init(fixture.boundEntries());
    backend.corrupt_on = .{ .operation = 9, .value = 0xEE };
    backend.fail_on = 10;
    const sbdf = fixture.sbdfs[0];
    const bridges = [_]Bridge{bridge(null, backend.function(sbdf))};
    const roots = [_]bus.BridgeIndex{0};

    try std.testing.expectError(
        error.ProgrammingPartial,
        commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0, .bus_end = 4 }),
    );

    try expectBus(&fixture.bytes[0], .{ .primary = 0, .secondary = 1, .subordinate = 1 });
    try expectLog(&backend, &.{
        read(sbdf, offset_primary, 0xAA),
        read(sbdf, offset_secondary, 0xBB),
        read(sbdf, offset_subordinate, 0xCC),
        write(sbdf, offset_subordinate, 0x01),
        read(sbdf, offset_subordinate, 0x01),
        write(sbdf, offset_primary, 0x00),
        read(sbdf, offset_primary, 0x00),
        write(sbdf, offset_secondary, 0x01),
        read(sbdf, offset_secondary, 0xEE),
        write(sbdf, offset_secondary, 0xBB),
    });
}

test "unit: bridge failure rolls back all journaled writes and skips later phases" {
    // Fail during the subordinate phase and require every subordinate write restored before returning.
    var fixture = try ForestFixture.init(.{ .count = 3 });
    seedBus(&fixture.bytes[0], 0x10, 0x20, 0x30);
    seedBus(&fixture.bytes[1], 0x40, 0x50, 0x60);
    seedBus(&fixture.bytes[2], 0x70, 0x80, 0x90);
    var backend = LoggedConfig.init(fixture.boundEntries());
    backend.fail_on = 15;
    const bridges = [_]Bridge{
        bridge(null, backend.function(fixture.sbdfs[0])),
        bridge(null, backend.function(fixture.sbdfs[1])),
        bridge(null, backend.function(fixture.sbdfs[2])),
    };
    const roots = [_]bus.BridgeIndex{ 0, 1, 2 };

    try std.testing.expectError(
        error.ProgrammingWriteFailed,
        commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0, .bus_end = 5 }),
    );

    try expectBus(&fixture.bytes[0], .{ .primary = 0x10, .secondary = 0x20, .subordinate = 0x30 });
    try expectBus(&fixture.bytes[1], .{ .primary = 0x40, .secondary = 0x50, .subordinate = 0x60 });
    try expectBus(&fixture.bytes[2], .{ .primary = 0x70, .secondary = 0x80, .subordinate = 0x90 });
}

const ExpectedBus = struct {
    primary: u8,
    secondary: u8,
    subordinate: u8,
};

const ForestFixture = struct {
    bytes: [8][pcie_window_size]u8,
    entries: [8]LoggedConfig.Entry,
    sbdfs: [8]Sbdf,
    count: usize,

    const Options = struct {
        count: usize,
    };

    fn init(options: Options) !ForestFixture {
        std.debug.assert(options.count <= 8);

        var fixture = ForestFixture{
            .bytes = @splat(@splat(0)),
            .entries = undefined,
            .sbdfs = undefined,
            .count = options.count,
        };

        for (0..fixture.entries.len) |index| {
            const device: u8 = @intCast(index + 1);
            fixture.sbdfs[index] = try Sbdf.from(0, 0, device, 0);
        }

        return fixture;
    }

    fn boundEntries(self: *ForestFixture) []LoggedConfig.Entry {
        for (0..self.count) |index| {
            self.entries[index] = .{ .sbdf = self.sbdfs[index], .bytes = &self.bytes[index] };
        }

        return self.entries[0..self.count];
    }
};

const LoggedConfig = struct {
    entries: []Entry,
    log: [128]Access = undefined,
    log_len: usize = 0,
    fail_on: ?usize = null,
    corrupt_on: ?Corruption = null,

    const Entry = struct {
        sbdf: Sbdf,
        bytes: []u8,
    };

    const Operation = enum {
        read8,
        write8,
    };

    const Access = struct {
        operation: Operation,
        sbdf: Sbdf,
        offset: usize,
        value: u8,
    };

    const Corruption = struct {
        operation: usize,
        value: u8,
    };

    fn init(entries: []Entry) LoggedConfig {
        for (entries) |entry| std.debug.assert(entry.bytes.len == pcie_window_size);
        return .{ .entries = entries };
    }

    fn configSpace(self: *LoggedConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    fn function(self: *LoggedConfig, sbdf: Sbdf) Function {
        return Function.unchecked(self.configSpace(), sbdf);
    }

    fn functionBytes(self: *LoggedConfig, sbdf: Sbdf) ?[]u8 {
        for (self.entries) |entry| {
            if (entry.sbdf.eql(sbdf)) return entry.bytes;
        }

        return null;
    }

    fn record(self: *LoggedConfig, access: Access) usize {
        std.debug.assert(self.log_len < self.log.len);
        self.log[self.log_len] = access;
        self.log_len += 1;
        return self.log_len;
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8,
        .read16 = read16Unsupported,
        .read32 = read32Unsupported,
        .write8 = write8,
        .write16 = write16Unsupported,
        .write32 = write32Unsupported,
    };

    fn read8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        const self: *LoggedConfig = @ptrCast(@alignCast(context));
        const ordinal = self.record(.{
            .operation = .read8,
            .sbdf = sbdf,
            .offset = byte_offset,
            .value = 0,
        });
        if (self.fail_on == ordinal) return error.UnsupportedAccessWidth;

        const bytes = self.functionBytes(sbdf) orelse return 0xFF;
        var value = bytes[byte_offset];
        if (self.corrupt_on) |corruption| {
            if (corruption.operation == ordinal) value = corruption.value;
        }
        self.log[ordinal - 1].value = value;
        return value;
    }

    fn write8(
        context: *anyopaque,
        sbdf: Sbdf,
        byte_offset: usize,
        value: u8,
    ) ConfigSpace.Error!void {
        const self: *LoggedConfig = @ptrCast(@alignCast(context));
        const ordinal = self.record(.{
            .operation = .write8,
            .sbdf = sbdf,
            .offset = byte_offset,
            .value = value,
        });
        if (self.fail_on == ordinal) return error.UnsupportedAccessWidth;

        const bytes = self.functionBytes(sbdf) orelse return;
        bytes[byte_offset] = value;
    }

    fn read16Unsupported(
        context: *anyopaque,
        sbdf: Sbdf,
        byte_offset: usize,
    ) ConfigSpace.Error!u16 {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        return error.UnsupportedAccessWidth;
    }

    fn read32Unsupported(
        context: *anyopaque,
        sbdf: Sbdf,
        byte_offset: usize,
    ) ConfigSpace.Error!u32 {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        return error.UnsupportedAccessWidth;
    }

    fn write16Unsupported(
        context: *anyopaque,
        sbdf: Sbdf,
        byte_offset: usize,
        value: u16,
    ) ConfigSpace.Error!void {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        _ = value;
        return error.UnsupportedAccessWidth;
    }

    fn write32Unsupported(
        context: *anyopaque,
        sbdf: Sbdf,
        byte_offset: usize,
        value: u32,
    ) ConfigSpace.Error!void {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        _ = value;
        return error.UnsupportedAccessWidth;
    }
};

fn bridge(parent: ?bus.BridgeIndex, function: Function) Bridge {
    return .{ .parent = parent, .function = function };
}

fn seedBus(bytes: []u8, primary: u8, secondary: u8, subordinate: u8) void {
    bytes[offset_primary] = primary;
    bytes[offset_secondary] = secondary;
    bytes[offset_subordinate] = subordinate;
}

fn expectBus(bytes: []const u8, expected: ExpectedBus) !void {
    try std.testing.expectEqual(expected.primary, bytes[offset_primary]);
    try std.testing.expectEqual(expected.secondary, bytes[offset_secondary]);
    try std.testing.expectEqual(expected.subordinate, bytes[offset_subordinate]);
}

fn read(sbdf: Sbdf, byte_offset: usize, value: u8) LoggedConfig.Access {
    return .{ .operation = .read8, .sbdf = sbdf, .offset = byte_offset, .value = value };
}

fn write(sbdf: Sbdf, byte_offset: usize, value: u8) LoggedConfig.Access {
    return .{ .operation = .write8, .sbdf = sbdf, .offset = byte_offset, .value = value };
}

fn expectLog(backend: *const LoggedConfig, expected: []const LoggedConfig.Access) !void {
    try std.testing.expectEqual(expected.len, backend.log_len);

    for (expected, backend.log[0..backend.log_len]) |want, got| {
        try std.testing.expectEqual(want.operation, got.operation);
        try std.testing.expect(want.sbdf.eql(got.sbdf));
        try std.testing.expectEqual(want.offset, got.offset);
        try std.testing.expectEqual(want.value, got.value);
    }
}

fn expectNoOffset(backend: *const LoggedConfig, byte_offset: usize) !void {
    for (backend.log[0..backend.log_len]) |access| {
        try std.testing.expect(access.offset != byte_offset);
    }
}

fn expectNoAccess(backend: *const LoggedConfig, sbdf: Sbdf) !void {
    for (backend.log[0..backend.log_len]) |access| {
        try std.testing.expect(!access.sbdf.eql(sbdf));
    }
}
