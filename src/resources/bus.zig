//! Bridge bus-number programming.

const std = @import("std");

const cfg = @import("config");
const core = @import("core");
const header = @import("header");

const type1 = header.type1;

const VisitedSet = std.StaticBitSet(max_bridges);
const Function = cfg.Function;
const Offset = core.Offset;

pub const BridgeIndex = u16;

pub const max_bridges: usize = std.math.maxInt(BridgeIndex);
pub const max_depth: u8 = 32;

pub const Bridge = struct {
    parent: ?BridgeIndex,
    function: Function,
};

pub const Args = struct {
    bridges: []const Bridge,
    roots: []const BridgeIndex,
    root_primary_bus: u8,
    bus_end: u8,
};

pub const Error = error{
    BusRangeExhausted,
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};

/// Saves all bridges, then writes subordinate, primary and secondary numbers in reverse DFS order.
/// Failed rollback returns `ProgrammingPartial`; success invalidates handles below renumbered bridges.
pub fn commit(args: Args) Error!void {
    var committer = Committer{
        .args = args,
        .next_bus = args.root_primary_bus,
    };

    return committer.apply();
}

const Committer = struct {
    args: Args,
    planned: [max_bridges]BusNumbers = undefined,
    saved: [max_bridges]BusNumbers = undefined,
    written: [max_bridges]Written = @splat(.{}),
    visited: VisitedSet = VisitedSet.initEmpty(),
    next_bus: u8,

    const commit_phases = [_]Phase{
        .{ .field = .subordinate, .direction = .forward },
        .{ .field = .primary, .direction = .forward },
        .{ .field = .secondary, .direction = .reverse },
    };

    const rollback_phases = [_]Phase{
        .{ .field = .secondary, .direction = .forward },
        .{ .field = .primary, .direction = .reverse },
        .{ .field = .subordinate, .direction = .reverse },
    };

    fn apply(self: *Committer) Error!void {
        self.assertArgs();

        try self.assignNumbers();
        try self.save();

        for (commit_phases) |phase| {
            self.writePhase(phase) catch |err| return self.rollback(err);
        }
    }

    fn assertArgs(self: *const Committer) void {
        std.debug.assert(self.args.bridges.len <= max_bridges);
        std.debug.assert(self.args.root_primary_bus <= self.args.bus_end);

        for (self.args.bridges, 0..) |bridge, index| {
            if (bridge.parent) |parent| {
                std.debug.assert(@as(usize, parent) < index);
            }
        }
    }

    fn assignNumbers(self: *Committer) Error!void {
        for (self.args.roots) |root| {
            const root_index = @as(usize, root);
            std.debug.assert(root_index < self.args.bridges.len);
            std.debug.assert(self.args.bridges[root_index].parent == null);

            _ = try self.assignSubtree(root_index, 1);
        }

        for (0..self.args.bridges.len) |index| {
            std.debug.assert(self.visited.isSet(index));
        }
    }

    fn assignSubtree(self: *Committer, index: usize, depth: u8) Error!usize {
        std.debug.assert(depth >= 1);
        std.debug.assert(depth <= max_depth);
        std.debug.assert(index < self.args.bridges.len);
        std.debug.assert(!self.visited.isSet(index));

        const bridge = self.args.bridges[index];
        if (self.next_bus == self.args.bus_end) {
            return error.BusRangeExhausted;
        }

        self.next_bus += 1;

        const secondary = self.next_bus;
        const primary = if (bridge.parent) |parent| blk: {
            const parent_index = @as(usize, parent);
            std.debug.assert(self.visited.isSet(parent_index));
            break :blk self.planned[parent_index].secondary;
        } else self.args.root_primary_bus;

        self.planned[index] = .{
            .primary = primary,
            .secondary = secondary,
            .subordinate = secondary,
        };
        self.visited.set(index);

        var next = index + 1;
        while (next < self.args.bridges.len) {
            const parent = self.args.bridges[next].parent orelse break;
            const parent_index = @as(usize, parent);
            if (parent_index < index) {
                break;
            }

            std.debug.assert(parent_index == index);

            next = try self.assignSubtree(next, depth + 1);
        }

        self.planned[index].subordinate = self.next_bus;

        return next;
    }

    fn save(self: *Committer) Error!void {
        for (self.args.bridges, 0..) |bridge, index| {
            self.saved[index] = try BusNumbers.read(bridge.function);
        }
    }

    fn writePhase(self: *Committer, phase: Phase) Error!void {
        switch (phase.direction) {
            .forward => {
                for (0..self.args.bridges.len) |index| {
                    try self.writeReadback(index, phase.field, self.planned[index].get(phase.field));
                }
            },
            .reverse => {
                var index = self.args.bridges.len;
                while (index > 0) {
                    index -= 1;

                    try self.writeReadback(index, phase.field, self.planned[index].get(phase.field));
                }
            },
        }
    }

    fn writeReadback(self: *Committer, index: usize, field: Field, value: u8) Error!void {
        const function = self.args.bridges[index].function;
        function.write(field.offset(), value) catch return error.ProgrammingWriteFailed;

        self.written[index].set(field);

        const observed = function.read(field.offset()) catch return error.ProgrammingWriteFailed;
        if (observed != value) {
            return error.ProgrammingReadbackMismatch;
        }
    }

    fn rollback(self: *Committer, original: Error) Error {
        for (rollback_phases) |phase| {
            self.restorePhase(phase) catch return error.ProgrammingPartial;
        }

        return original;
    }

    fn restorePhase(self: *Committer, phase: Phase) Error!void {
        switch (phase.direction) {
            .forward => {
                for (0..self.args.bridges.len) |index| {
                    if (self.written[index].isSet(phase.field)) {
                        try self.restore(index, phase.field);
                    }
                }
            },
            .reverse => {
                var index = self.args.bridges.len;
                while (index > 0) {
                    index -= 1;

                    if (self.written[index].isSet(phase.field)) {
                        try self.restore(index, phase.field);
                    }
                }
            },
        }
    }

    fn restore(self: *Committer, index: usize, field: Field) Error!void {
        const function = self.args.bridges[index].function;
        const value = self.saved[index].get(field);

        function.write(field.offset(), value) catch return error.ProgrammingPartial;

        const observed = function.read(field.offset()) catch return error.ProgrammingPartial;
        if (observed != value) {
            return error.ProgrammingPartial;
        }
    }
};

const BusNumbers = struct {
    primary: u8,
    secondary: u8,
    subordinate: u8,

    fn read(function: Function) Error!BusNumbers {
        return .{
            .primary = function.read(Field.primary.offset()) catch return error.ProgrammingWriteFailed,
            .secondary = function.read(Field.secondary.offset()) catch return error.ProgrammingWriteFailed,
            .subordinate = function.read(Field.subordinate.offset()) catch return error.ProgrammingWriteFailed,
        };
    }

    fn get(self: BusNumbers, field: Field) u8 {
        return switch (field) {
            .primary => self.primary,
            .secondary => self.secondary,
            .subordinate => self.subordinate,
        };
    }
};

const Written = struct {
    primary: bool = false,
    secondary: bool = false,
    subordinate: bool = false,

    fn set(self: *Written, field: Field) void {
        switch (field) {
            .primary => self.primary = true,
            .secondary => self.secondary = true,
            .subordinate => self.subordinate = true,
        }
    }

    fn isSet(self: Written, field: Field) bool {
        return switch (field) {
            .primary => self.primary,
            .secondary => self.secondary,
            .subordinate => self.subordinate,
        };
    }
};

const Field = enum {
    primary,
    secondary,
    subordinate,

    fn offset(self: Field) Offset(u8) {
        return switch (self) {
            .primary => type1.offsets.primary_bus,
            .secondary => type1.offsets.secondary_bus,
            .subordinate => type1.offsets.subordinate_bus,
        };
    }
};

const Direction = enum {
    forward,
    reverse,
};

const Phase = struct {
    field: Field,
    direction: Direction,
};

pub const unit = struct {
    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;
    const offset_primary: usize = 0x18;
    const offset_secondary: usize = 0x19;
    const offset_subordinate: usize = 0x1A;
    const offset_command: usize = 0x04;

    const ConfigSpace = cfg.ConfigSpace;
    const ConfigError = ConfigSpace.Error;

    const Sbdf = core.Sbdf;

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

        fn from(options: Options) !ForestFixture {
            std.debug.assert(options.count <= 8);

            var fixture = ForestFixture{
                .bytes = @splat(@splat(0)),
                .entries = undefined,
                .sbdfs = undefined,
                .count = options.count,
            };

            for (0..fixture.entries.len) |index| {
                const device: u5 = @intCast(index + 1);
                fixture.sbdfs[index] = Sbdf.from(.from(0), 0, device, 0);
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

        fn from(entries: []Entry) LoggedConfig {
            for (entries) |entry| {
                std.debug.assert(entry.bytes.len == pcie_window_size);
            }

            return .{ .entries = entries };
        }

        fn config(self: *LoggedConfig) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn function(self: *LoggedConfig, sbdf: Sbdf) Function {
            return Function.from(self.config(), sbdf);
        }

        fn functionBytes(self: *LoggedConfig, sbdf: Sbdf) ?[]u8 {
            for (self.entries) |entry| {
                if (entry.sbdf.eql(sbdf)) {
                    return entry.bytes;
                }
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

        fn read8(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigError!u8 {
            const self: *LoggedConfig = @ptrCast(@alignCast(context));
            const ordinal = self.record(.{
                .operation = .read8,
                .sbdf = sbdf,
                .offset = byte_offset,
                .value = 0,
            });

            if (self.fail_on == ordinal) {
                return error.UnsupportedAccessWidth;
            }

            const bytes = self.functionBytes(sbdf) orelse return 0xFF;
            var value = bytes[byte_offset];

            if (self.corrupt_on) |corruption| {
                if (corruption.operation == ordinal) {
                    value = corruption.value;
                }
            }

            self.log[ordinal - 1].value = value;
            return value;
        }

        fn write8(
            context: *anyopaque,
            sbdf: Sbdf,
            byte_offset: usize,
            value: u8,
        ) ConfigError!void {
            const self: *LoggedConfig = @ptrCast(@alignCast(context));
            const ordinal = self.record(.{
                .operation = .write8,
                .sbdf = sbdf,
                .offset = byte_offset,
                .value = value,
            });

            if (self.fail_on == ordinal) {
                return error.UnsupportedAccessWidth;
            }

            const bytes = self.functionBytes(sbdf) orelse return;
            bytes[byte_offset] = value;
        }

        fn read16Unsupported(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u16 {
            return error.UnsupportedAccessWidth;
        }

        fn read32Unsupported(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u32 {
            return error.UnsupportedAccessWidth;
        }

        fn write16Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write32Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }
    };

    test "commit accepts empty roots without config-space access" {
        try commit(.{
            .bridges = &.{},
            .roots = &.{},
            .root_primary_bus = 0,
            .bus_end = 0,
        });
    }

    test "DFS numbering covers nested, sibling, and multiple root bridges" {
        var fixture = try ForestFixture.from(.{ .count = 6 });
        seedBus(&fixture.bytes[0], 0xA0, 0xA1, 0xA2);
        seedBus(&fixture.bytes[1], 0xB0, 0xB1, 0xB2);
        seedBus(&fixture.bytes[2], 0xC0, 0xC1, 0xC2);
        seedBus(&fixture.bytes[3], 0xD0, 0xD1, 0xD2);
        seedBus(&fixture.bytes[4], 0xE0, 0xE1, 0xE2);
        seedBus(&fixture.bytes[5], 0xF0, 0xF1, 0xF2);
        var backend = LoggedConfig.from(fixture.boundEntries());
        const bridges = [_]Bridge{
            bridge(null, backend.function(fixture.sbdfs[0])),
            bridge(0, backend.function(fixture.sbdfs[1])),
            bridge(1, backend.function(fixture.sbdfs[2])),
            bridge(0, backend.function(fixture.sbdfs[3])),
            bridge(null, backend.function(fixture.sbdfs[4])),
            bridge(4, backend.function(fixture.sbdfs[5])),
        };
        const roots = [_]BridgeIndex{ 0, 4 };

        try commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0, .bus_end = 10 });

        try expectBus(&fixture.bytes[0], .{ .primary = 0, .secondary = 1, .subordinate = 4 });
        try expectBus(&fixture.bytes[1], .{ .primary = 1, .secondary = 2, .subordinate = 3 });
        try expectBus(&fixture.bytes[2], .{ .primary = 2, .secondary = 3, .subordinate = 3 });
        try expectBus(&fixture.bytes[3], .{ .primary = 1, .secondary = 4, .subordinate = 4 });
        try expectBus(&fixture.bytes[4], .{ .primary = 0, .secondary = 5, .subordinate = 6 });
        try expectBus(&fixture.bytes[5], .{ .primary = 5, .secondary = 6, .subordinate = 6 });
    }

    test "bus range exhaustion returns before hardware writes" {
        var fixture = try ForestFixture.from(.{ .count = 1 });
        seedBus(&fixture.bytes[0], 0x12, 0x34, 0x56);
        var before = fixture.bytes[0];
        var backend = LoggedConfig.from(fixture.boundEntries());
        const bridges = [_]Bridge{bridge(null, backend.function(fixture.sbdfs[0]))};
        const roots = [_]BridgeIndex{0};

        try testing.expectError(
            error.BusRangeExhausted,
            commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 5, .bus_end = 5 }),
        );

        try testing.expectEqualSlices(u8, &before, &fixture.bytes[0]);
        try testing.expectEqual(@as(usize, 0), backend.log_len);
    }

    test "single bridge save write and readback order is subordinate primary secondary" {
        var fixture = try ForestFixture.from(.{ .count = 1 });
        seedBus(&fixture.bytes[0], 0xAA, 0xBB, 0xCC);
        var backend = LoggedConfig.from(fixture.boundEntries());
        const sbdf = fixture.sbdfs[0];
        const bridges = [_]Bridge{bridge(null, backend.function(sbdf))};
        const roots = [_]BridgeIndex{0};

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

    test "nested commit defers parent secondary until child writes complete" {
        var fixture = try ForestFixture.from(.{ .count = 2 });
        seedBus(&fixture.bytes[0], 0xA0, 0xA1, 0xA2);
        seedBus(&fixture.bytes[1], 0xB0, 0xB1, 0xB2);
        var backend = LoggedConfig.from(fixture.boundEntries());
        const parent = fixture.sbdfs[0];
        const child = fixture.sbdfs[1];
        const bridges = [_]Bridge{
            bridge(null, backend.function(parent)),
            bridge(0, backend.function(child)),
        };
        const roots = [_]BridgeIndex{0};

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

    test "readback mismatch rolls back the failing bridge" {
        var fixture = try ForestFixture.from(.{ .count = 1 });
        seedBus(&fixture.bytes[0], 0xAA, 0xBB, 0xCC);
        var backend = LoggedConfig.from(fixture.boundEntries());
        const primary_readback = 7;
        backend.corrupt_on = .{ .operation = primary_readback, .value = 0xFF };
        const sbdf = fixture.sbdfs[0];
        const bridges = [_]Bridge{bridge(null, backend.function(sbdf))};
        const roots = [_]BridgeIndex{0};

        try testing.expectError(
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

    test "injected write failure maps to ProgrammingWriteFailed after rollback" {
        var fixture = try ForestFixture.from(.{ .count = 1 });
        seedBus(&fixture.bytes[0], 0xAA, 0xBB, 0xCC);
        var backend = LoggedConfig.from(fixture.boundEntries());
        const secondary_write = 8;
        backend.fail_on = secondary_write;
        const sbdf = fixture.sbdfs[0];
        const bridges = [_]Bridge{bridge(null, backend.function(sbdf))};
        const roots = [_]BridgeIndex{0};

        try testing.expectError(
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

    test "rollback restore failure returns ProgrammingPartial and aborts further restores" {
        var fixture = try ForestFixture.from(.{ .count = 1 });
        seedBus(&fixture.bytes[0], 0xAA, 0xBB, 0xCC);
        var backend = LoggedConfig.from(fixture.boundEntries());
        const secondary_readback = 9;
        backend.corrupt_on = .{ .operation = secondary_readback, .value = 0xEE };
        const rollback_secondary_write = 10;
        backend.fail_on = rollback_secondary_write;
        const sbdf = fixture.sbdfs[0];
        const bridges = [_]Bridge{bridge(null, backend.function(sbdf))};
        const roots = [_]BridgeIndex{0};

        try testing.expectError(
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

    test "bridge failure rolls back all journaled writes and skips later phases" {
        var fixture = try ForestFixture.from(.{ .count = 3 });
        seedBus(&fixture.bytes[0], 0x10, 0x20, 0x30);
        seedBus(&fixture.bytes[1], 0x40, 0x50, 0x60);
        seedBus(&fixture.bytes[2], 0x70, 0x80, 0x90);
        var backend = LoggedConfig.from(fixture.boundEntries());
        const third_subordinate_readback = 15;
        backend.fail_on = third_subordinate_readback;
        const bridges = [_]Bridge{
            bridge(null, backend.function(fixture.sbdfs[0])),
            bridge(null, backend.function(fixture.sbdfs[1])),
            bridge(null, backend.function(fixture.sbdfs[2])),
        };
        const roots = [_]BridgeIndex{ 0, 1, 2 };

        try testing.expectError(
            error.ProgrammingWriteFailed,
            commit(.{ .bridges = &bridges, .roots = &roots, .root_primary_bus = 0, .bus_end = 5 }),
        );

        try expectBus(&fixture.bytes[0], .{ .primary = 0x10, .secondary = 0x20, .subordinate = 0x30 });
        try expectBus(&fixture.bytes[1], .{ .primary = 0x40, .secondary = 0x50, .subordinate = 0x60 });
        try expectBus(&fixture.bytes[2], .{ .primary = 0x70, .secondary = 0x80, .subordinate = 0x90 });
    }

    fn bridge(parent: ?BridgeIndex, function: Function) Bridge {
        return .{ .parent = parent, .function = function };
    }

    fn seedBus(bytes: []u8, primary: u8, secondary: u8, subordinate: u8) void {
        bytes[offset_primary] = primary;
        bytes[offset_secondary] = secondary;
        bytes[offset_subordinate] = subordinate;
    }

    fn expectBus(bytes: []const u8, expected: ExpectedBus) !void {
        try testing.expectEqual(expected.primary, bytes[offset_primary]);
        try testing.expectEqual(expected.secondary, bytes[offset_secondary]);
        try testing.expectEqual(expected.subordinate, bytes[offset_subordinate]);
    }

    fn read(sbdf: Sbdf, byte_offset: usize, value: u8) LoggedConfig.Access {
        return .{ .operation = .read8, .sbdf = sbdf, .offset = byte_offset, .value = value };
    }

    fn write(sbdf: Sbdf, byte_offset: usize, value: u8) LoggedConfig.Access {
        return .{ .operation = .write8, .sbdf = sbdf, .offset = byte_offset, .value = value };
    }

    fn expectLog(backend: *const LoggedConfig, expected: []const LoggedConfig.Access) !void {
        try testing.expectEqual(expected.len, backend.log_len);

        for (expected, backend.log[0..backend.log_len]) |want, got| {
            try testing.expectEqual(want.operation, got.operation);
            try testing.expect(want.sbdf.eql(got.sbdf));
            try testing.expectEqual(want.offset, got.offset);
            try testing.expectEqual(want.value, got.value);
        }
    }

    fn expectNoOffset(backend: *const LoggedConfig, byte_offset: usize) !void {
        for (backend.log[0..backend.log_len]) |access| {
            try testing.expect(access.offset != byte_offset);
        }
    }

    fn expectNoAccess(backend: *const LoggedConfig, sbdf: Sbdf) !void {
        for (backend.log[0..backend.log_len]) |access| {
            try testing.expect(!access.sbdf.eql(sbdf));
        }
    }
};
