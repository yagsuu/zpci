//! Type-1 bridge bus-number programming. Spec: docs/specs/resources/bus.md.

const std = @import("std");

const config = @import("../config.zig");

pub const BridgeIndex = u16;

pub const max_bridges: usize = std.math.maxInt(BridgeIndex);
pub const max_depth: u8 = 32;

pub const Bridge = struct {
    parent: ?BridgeIndex,
    function: config.Function,
};

pub const Input = struct {
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

/// Programs type-1 bus numbers from DFS numbering.
/// Allocation: none. I/O: bridge config reads and writes only.
/// Ordering: save all; write subordinates, primaries, then secondaries in reverse DFS.
/// Errors: failures roll back journaled writes; restore failure returns `ProgrammingPartial`.
/// Success invalidates caller-held handles below renumbered bridges.
pub fn commit(input: Input) Error!void {
    var committer = Committer{
        .input = input,
        .next_bus = input.root_primary_bus,
    };
    return committer.apply();
}

const Committer = struct {
    input: Input,
    planned: [max_bridges]BusNumbers = undefined,
    saved: [max_bridges]BusNumbers = undefined,
    written: [max_bridges]Written = @splat(.{}),
    visited: std.StaticBitSet(max_bridges) = std.StaticBitSet(max_bridges).initEmpty(),
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
        self.assertInput();
        try self.numberAll();
        try self.saveAll();

        for (commit_phases) |phase| {
            self.writePhase(phase) catch |err| return self.rollback(err);
        }
    }

    fn assertInput(self: *const Committer) void {
        std.debug.assert(self.input.bridges.len <= max_bridges);
        std.debug.assert(self.input.root_primary_bus <= self.input.bus_end);

        for (self.input.bridges, 0..) |bridge, index| {
            if (bridge.parent) |parent| {
                std.debug.assert(@as(usize, parent) < index);
            }
        }
    }

    fn numberAll(self: *Committer) Error!void {
        for (self.input.roots) |root| {
            const root_index = @as(usize, root);
            std.debug.assert(root_index < self.input.bridges.len);
            std.debug.assert(self.input.bridges[root_index].parent == null);
            _ = try self.numberSubtree(root_index, 1);
        }

        for (0..self.input.bridges.len) |index| std.debug.assert(self.visited.isSet(index));
    }

    fn numberSubtree(self: *Committer, index: usize, depth: u8) Error!usize {
        std.debug.assert(depth >= 1);
        std.debug.assert(depth <= max_depth);
        std.debug.assert(index < self.input.bridges.len);
        std.debug.assert(!self.visited.isSet(index));

        const bridge = self.input.bridges[index];
        if (self.next_bus == self.input.bus_end) return error.BusRangeExhausted;
        self.next_bus += 1;

        const secondary = self.next_bus;
        const primary = if (bridge.parent) |parent| blk: {
            const parent_index = @as(usize, parent);
            std.debug.assert(self.visited.isSet(parent_index));
            break :blk self.planned[parent_index].secondary;
        } else self.input.root_primary_bus;

        self.planned[index] = .{
            .primary = primary,
            .secondary = secondary,
            .subordinate = secondary,
        };
        self.visited.set(index);

        var next = index + 1;
        while (next < self.input.bridges.len) {
            const parent = self.input.bridges[next].parent orelse break;
            const parent_index = @as(usize, parent);
            if (parent_index < index) break;
            std.debug.assert(parent_index == index);

            next = try self.numberSubtree(next, depth + 1);
        }

        self.planned[index].subordinate = self.next_bus;
        return next;
    }

    fn saveAll(self: *Committer) Error!void {
        for (self.input.bridges, 0..) |bridge, index| {
            self.saved[index] = try BusNumbers.read(bridge.function);
        }
    }

    fn writePhase(self: *Committer, phase: Phase) Error!void {
        switch (phase.direction) {
            .forward => for (0..self.input.bridges.len) |index| {
                try self.writeReadback(index, phase.field, self.planned[index].get(phase.field));
            },
            .reverse => {
                var index = self.input.bridges.len;
                while (index > 0) {
                    index -= 1;
                    try self.writeReadback(index, phase.field, self.planned[index].get(phase.field));
                }
            },
        }
    }

    fn writeReadback(self: *Committer, index: usize, field: Field, value: u8) Error!void {
        const function = self.input.bridges[index].function;
        function.write8(field.offset(), value) catch return error.ProgrammingWriteFailed;
        self.written[index].set(field);

        const observed = function.read8(field.offset()) catch return error.ProgrammingWriteFailed;
        if (observed != value) return error.ProgrammingReadbackMismatch;
    }

    fn rollback(self: *Committer, original: Error) Error {
        for (rollback_phases) |phase| {
            self.restorePhase(phase) catch return error.ProgrammingPartial;
        }

        return original;
    }

    fn restorePhase(self: *Committer, phase: Phase) Error!void {
        switch (phase.direction) {
            .forward => for (0..self.input.bridges.len) |index| {
                if (self.written[index].isSet(phase.field)) try self.restore(index, phase.field);
            },
            .reverse => {
                var index = self.input.bridges.len;
                while (index > 0) {
                    index -= 1;
                    if (self.written[index].isSet(phase.field)) try self.restore(index, phase.field);
                }
            },
        }
    }

    fn restore(self: *Committer, index: usize, field: Field) Error!void {
        const function = self.input.bridges[index].function;
        const value = self.saved[index].get(field);
        function.write8(field.offset(), value) catch return error.ProgrammingPartial;

        const observed = function.read8(field.offset()) catch return error.ProgrammingPartial;
        if (observed != value) return error.ProgrammingPartial;
    }
};

const BusNumbers = struct {
    primary: u8,
    secondary: u8,
    subordinate: u8,

    fn read(function: config.Function) Error!BusNumbers {
        return .{
            .primary = function.read8(Field.primary.offset()) catch return error.ProgrammingWriteFailed,
            .secondary = function.read8(Field.secondary.offset()) catch return error.ProgrammingWriteFailed,
            .subordinate = function.read8(Field.subordinate.offset()) catch return error.ProgrammingWriteFailed,
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

    fn offset(self: Field) usize {
        return switch (self) {
            .primary => 0x18,
            .secondary => 0x19,
            .subordinate => 0x1A,
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
