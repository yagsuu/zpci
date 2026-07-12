//! Tests for docs/specs/resources/programming.md.

const std = @import("std");

const stdx = @import("stdx");

const zpci = @import("zpci");

const Assignment = zpci.resources.programming.Assignment;
const ConfigSpace = zpci.config.ConfigSpace;
const Function = zpci.config.Function;
const Kind = zpci.resources.model.Kind;
const Plan = zpci.resources.programming.Plan;
const Requirement = zpci.resources.model.Requirement;
const Sbdf = zpci.core.Sbdf;
const Source = zpci.resources.model.Source;

const bar = zpci.bar;
const command_all: u16 = 0xFFFF;
const function_window_size: usize = 0x1000;
const offset = struct {
    const command: usize = 0x04;
    const header_type: usize = 0x0E;
    const bar0: usize = 0x10;
    const bar1: usize = 0x14;
    const io_base: usize = 0x1C;
    const io_limit: usize = 0x1D;
    const memory_base: usize = 0x20;
    const memory_limit: usize = 0x22;
    const prefetchable_base: usize = 0x24;
    const prefetchable_limit: usize = 0x26;
    const prefetchable_base_upper: usize = 0x28;
    const prefetchable_limit_upper: usize = 0x2C;
    const type0_rom: usize = 0x30;
    const io_base_upper: usize = 0x30;
    const io_limit_upper: usize = 0x32;
    const type1_rom: usize = 0x38;
};

const commit = zpci.resources.programming.commit;

test "unit: empty plan performs no config-space access" {
    // Commit an empty assignment slice to cover the no-access fast path.
    try commit(.{ .assignments = &.{} });
}

test "unit: endpoint mixed BARs and ROM follow save disable write restore order" {
    // Use a byte-backed endpoint to verify BAR/ROM ordering and readbacks.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&bytes, .type0, command_all);
    store32(&bytes, offset.bar0, 0x0000_0000);
    store32(&bytes, offset.bar1, 0x0000_0003);
    store32(&bytes, offset.type0_rom, 0x0000_07FF);
    var backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
    const function = backend.function(sbdf(0));
    const assignments = [_]Assignment{
        assignmentFor(barRequirement(function, 1, .io, .{ .size = 0x100, .alignment = 0x100 }), .io, 0x1000),
        assignmentFor(romRequirement(function, .{ .size = 0x800, .alignment = 0x800 }), .mmio32, 0x9000_0000),
        assignmentFor(
            barRequirement(function, 0, .mmio32, .{ .size = 0x1000, .alignment = 0x1000 }),
            .mmio32,
            0x8000_1000,
        ),
    };

    try commit(.{ .assignments = &assignments });

    try std.testing.expectEqual(@as(u16, command_all), load16(&bytes, offset.command));
    try std.testing.expectEqual(@as(u32, 0x8000_1000), load32(&bytes, offset.bar0));
    try std.testing.expectEqual(@as(u32, 0x0000_1003), load32(&bytes, offset.bar1));
    try std.testing.expectEqual(@as(u32, 0x9000_0001), load32(&bytes, offset.type0_rom));
    try expectLog(&backend, &.{
        read(.read8, 0, offset.header_type, 0x00),
        read(.read16, 0, offset.command, command_all),
        read(.read32, 0, offset.bar0, 0x0000_0000),
        read(.read32, 0, offset.bar1, 0x0000_0003),
        read(.read32, 0, offset.type0_rom, 0x0000_07FF),
        write(.write16, 0, offset.command, 0xFFFC),
        read(.read16, 0, offset.command, 0xFFFC),
        write(.write32, 0, offset.bar0, 0x8000_1000),
        read(.read32, 0, offset.bar0, 0x8000_1000),
        write(.write32, 0, offset.bar1, 0x0000_1003),
        read(.read32, 0, offset.bar1, 0x0000_1003),
        write(.write32, 0, offset.type0_rom, 0x9000_0001),
        read(.read32, 0, offset.type0_rom, 0x9000_0001),
        write(.write16, 0, offset.command, command_all),
        read(.read16, 0, offset.command, command_all),
    });
}

test "unit: 64-bit BAR writes high dword and preserves saved low type bits" {
    // Program a 64-bit BAR through a 32-bit pool to verify wire width comes from the requirement.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&bytes, .type0, command_all);
    store32(&bytes, offset.bar0, 0x0000_000C);
    store32(&bytes, offset.bar1, 0xCAFE_BABE);
    var backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
    const function = backend.function(sbdf(0));
    const assignments = [_]Assignment{
        assignmentFor(
            barRequirement(function, 0, .mmio64_pref, .{ .size = 0x2000, .alignment = 0x2000 }),
            .mmio32_pref,
            0x1_2345_0000,
        ),
    };

    try commit(.{ .assignments = &assignments });

    try std.testing.expectEqual(@as(u32, 0x2345_000C), load32(&bytes, offset.bar0));
    try std.testing.expectEqual(@as(u32, 0x0000_0001), load32(&bytes, offset.bar1));
}

test "unit: bridge BAR and windows write in fixed order and zero stale upper registers" {
    // Shuffle bridge assignments and assert the full save/write/readback trace stays deterministic.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&bytes, .type1, command_all);
    store32(&bytes, offset.bar0, 0x0000_0000);
    store16(&bytes, offset.io_base_upper, 0xAAAA);
    store16(&bytes, offset.io_limit_upper, 0xBBBB);
    store32(&bytes, offset.prefetchable_base_upper, 0xCCCC_CCCC);
    store32(&bytes, offset.prefetchable_limit_upper, 0xDDDD_DDDD);
    var backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
    const function = backend.function(sbdf(0));
    const assignments = [_]Assignment{
        assignmentFor(
            windowRequirement(
                function,
                .prefetchable_memory,
                .mmio32_pref,
                .{ .size = 0x100000, .alignment = 0x100000 },
            ),
            .mmio32_pref,
            0x9000_0000,
        ),
        assignmentFor(
            windowRequirement(function, .io, .io, .{ .size = 0x1000, .alignment = 0x1000 }),
            .io,
            0x2000,
        ),
        assignmentFor(
            barRequirement(function, 0, .mmio32, .{ .size = 0x1000, .alignment = 0x1000 }),
            .mmio32,
            0x8000_0000,
        ),
        assignmentFor(
            windowRequirement(
                function,
                .memory,
                .mmio32,
                .{ .size = 0x100000, .alignment = 0x100000 },
            ),
            .mmio32,
            0x8000_0000,
        ),
    };

    try commit(.{ .assignments = &assignments });

    try std.testing.expectEqual(@as(u16, 0), load16(&bytes, offset.io_base_upper));
    try std.testing.expectEqual(@as(u16, 0), load16(&bytes, offset.io_limit_upper));
    try std.testing.expectEqual(@as(u32, 0), load32(&bytes, offset.prefetchable_base_upper));
    try std.testing.expectEqual(@as(u32, 0), load32(&bytes, offset.prefetchable_limit_upper));
    try expectBridgeBarWindowLog(&backend);
}

test "unit: prefetchable 64-bit bridge window writes real upper dwords" {
    // Program a 64-bit prefetchable window to verify non-zero upper dword writes.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&bytes, .type1, command_all);
    var backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
    const function = backend.function(sbdf(0));
    const assignments = [_]Assignment{
        assignmentFor(
            windowRequirement(
                function,
                .prefetchable_memory,
                .mmio64_pref,
                .{ .size = 0x100000, .alignment = 0x100000 },
            ),
            .mmio64_pref,
            0x1_0000_0000,
        ),
    };

    try commit(.{ .assignments = &assignments });

    try std.testing.expectEqual(@as(u16, 0x0001), load16(&bytes, offset.prefetchable_base));
    try std.testing.expectEqual(@as(u16, 0x0001), load16(&bytes, offset.prefetchable_limit));
    try std.testing.expectEqual(@as(u32, 0x0000_0001), load32(&bytes, offset.prefetchable_base_upper));
    try std.testing.expectEqual(@as(u32, 0x0000_0001), load32(&bytes, offset.prefetchable_limit_upper));
}

test "unit: save failure and disable mismatch stop before base writes" {
    // Inject save and disable-readback failures to prove no base register is written.
    var save_bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&save_bytes, .type0, command_all);
    var save_backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &save_bytes }});
    save_backend.fail_on = 2;
    const save_plan = oneBarPlan(save_backend.function(sbdf(0)), .mmio32, 0x8000_0000);

    try std.testing.expectError(error.ProgrammingWriteFailed, commit(save_plan));
    try std.testing.expectEqual(@as(usize, 2), save_backend.log_len);
    try expectNoWrites(&save_backend);

    var mismatch_bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&mismatch_bytes, .type0, command_all);
    store32(&mismatch_bytes, offset.bar0, 0);
    var mismatch_backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &mismatch_bytes }});
    mismatch_backend.corrupt_on = .{ .operation = 5, .value = 0 };
    const mismatch_plan = oneBarPlan(mismatch_backend.function(sbdf(0)), .mmio32, 0x8000_0000);

    try std.testing.expectError(error.ProgrammingReadbackMismatch, commit(mismatch_plan));
    try std.testing.expectEqual(@as(u32, 0), load32(&mismatch_bytes, offset.bar0));
}

test "unit: BAR failure rolls back journaled writes and restores Command" {
    // Fail the second BAR write and assert the first BAR plus Command are restored.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&bytes, .type0, command_all);
    store32(&bytes, offset.bar0, 0x0000_0000);
    store32(&bytes, offset.bar1, 0x0000_0000);
    var backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
    backend.fail_on = 9;
    const function = backend.function(sbdf(0));
    const assignments = [_]Assignment{
        assignmentFor(
            barRequirement(function, 0, .mmio32, .{ .size = 0x1000, .alignment = 0x1000 }),
            .mmio32,
            0x8000_0000,
        ),
        assignmentFor(
            barRequirement(function, 1, .mmio32, .{ .size = 0x1000, .alignment = 0x1000 }),
            .mmio32,
            0x8000_1000,
        ),
    };

    try std.testing.expectError(error.ProgrammingWriteFailed, commit(.{ .assignments = &assignments }));

    try std.testing.expectEqual(@as(u16, command_all), load16(&bytes, offset.command));
    try std.testing.expectEqual(@as(u32, 0), load32(&bytes, offset.bar0));
    try std.testing.expectEqual(@as(u32, 0), load32(&bytes, offset.bar1));
    try expectLogTail(&backend, &.{
        write(.write32, 0, offset.bar0, 0),
        read(.read32, 0, offset.bar0, 0),
        write(.write16, 0, offset.command, command_all),
        read(.read16, 0, offset.command, command_all),
    });
}

test "unit: restore-decode failure rolls back bases and returns original error" {
    // Fail restore-decode write/readback after BAR success to verify rollback semantics.
    var write_bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&write_bytes, .type0, command_all);
    store32(&write_bytes, offset.bar0, 0x0000_0000);
    var write_backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &write_bytes }});
    write_backend.fail_on = 8;
    const write_plan = oneBarPlan(write_backend.function(sbdf(0)), .mmio32, 0x8000_0000);

    try std.testing.expectError(error.ProgrammingWriteFailed, commit(write_plan));
    try std.testing.expectEqual(@as(u16, command_all), load16(&write_bytes, offset.command));
    try std.testing.expectEqual(@as(u32, 0), load32(&write_bytes, offset.bar0));
    try expectLogTail(&write_backend, &.{
        write(.write32, 0, offset.bar0, 0),
        read(.read32, 0, offset.bar0, 0),
        write(.write16, 0, offset.command, command_all),
        read(.read16, 0, offset.command, command_all),
    });

    var mismatch_bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&mismatch_bytes, .type0, command_all);
    store32(&mismatch_bytes, offset.bar0, 0x0000_0000);
    var mismatch_backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &mismatch_bytes }});
    mismatch_backend.corrupt_on = .{ .operation = 9, .value = 0 };
    const mismatch_plan = oneBarPlan(mismatch_backend.function(sbdf(0)), .mmio32, 0x8000_0000);

    try std.testing.expectError(error.ProgrammingReadbackMismatch, commit(mismatch_plan));
    try std.testing.expectEqual(@as(u16, command_all), load16(&mismatch_bytes, offset.command));
    try std.testing.expectEqual(@as(u32, 0), load32(&mismatch_bytes, offset.bar0));
}

test "unit: rollback restore failure returns ProgrammingPartial and aborts further restores" {
    // Corrupt rollback readback to prove partial restore aborts further rollback.
    var bytes: [function_window_size]u8 = @splat(0);
    seedHeader(&bytes, .type0, command_all);
    store32(&bytes, offset.bar0, 0x0000_0000);
    var backend = LoggedConfig.init(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
    backend.corrupt_on = .{ .operation = 7, .value = 0xFFFF_FFFF };
    backend.fail_on = 8;
    const plan = oneBarPlan(backend.function(sbdf(0)), .mmio32, 0x8000_0000);

    try std.testing.expectError(error.ProgrammingPartial, commit(plan));

    try std.testing.expectEqual(@as(u32, 0x8000_0000), load32(&bytes, offset.bar0));
    try std.testing.expectEqual(@as(usize, 8), backend.log_len);
}

test "unit: multi-function failure leaves prior committed and later untouched" {
    // Fail the middle function to verify prior commit and later non-access boundaries.
    var bytes0: [function_window_size]u8 = @splat(0);
    var bytes1: [function_window_size]u8 = @splat(0);
    var bytes2: [function_window_size]u8 = @splat(0);
    seedHeader(&bytes0, .type0, command_all);
    seedHeader(&bytes1, .type0, command_all);
    seedHeader(&bytes2, .type0, command_all);
    var entries = [_]LoggedConfig.Entry{
        .{ .sbdf = sbdf(0), .bytes = &bytes0 },
        .{ .sbdf = sbdf(1), .bytes = &bytes1 },
        .{ .sbdf = sbdf(2), .bytes = &bytes2 },
    };
    var backend = LoggedConfig.init(&entries);
    backend.corrupt_on = .{ .operation = 16, .value = 0xFFFF_FFFF };
    const assignments = [_]Assignment{
        assignmentFor(
            barRequirement(backend.function(sbdf(0)), 0, .mmio32, .{ .size = 0x1000, .alignment = 0x1000 }),
            .mmio32,
            0x8000_0000,
        ),
        assignmentFor(
            barRequirement(backend.function(sbdf(1)), 0, .mmio32, .{ .size = 0x1000, .alignment = 0x1000 }),
            .mmio32,
            0x9000_0000,
        ),
        assignmentFor(
            barRequirement(backend.function(sbdf(2)), 0, .mmio32, .{ .size = 0x1000, .alignment = 0x1000 }),
            .mmio32,
            0xA000_0000,
        ),
    };

    try std.testing.expectError(error.ProgrammingReadbackMismatch, commit(.{ .assignments = &assignments }));

    try std.testing.expectEqual(@as(u32, 0x8000_0000), load32(&bytes0, offset.bar0));
    try std.testing.expectEqual(@as(u32, 0), load32(&bytes1, offset.bar0));
    try std.testing.expectEqual(@as(u32, 0), load32(&bytes2, offset.bar0));
    try expectNoAccess(&backend, sbdf(2));
}

const HeaderKind = enum { type0, type1 };

const RequirementShape = struct {
    size: u64,
    alignment: u64,
};

const LoggedConfig = struct {
    entries: []const Entry,
    log: [512]Access = undefined,
    log_len: usize = 0,
    fail_on: ?usize = null,
    corrupt_on: ?Corruption = null,

    const Entry = struct {
        sbdf: Sbdf,
        bytes: []u8,
    };

    const Operation = enum {
        read8,
        read16,
        read32,
        write8,
        write16,
        write32,
    };

    const Access = struct {
        operation: Operation,
        sbdf: Sbdf,
        offset: usize,
        value: u64,
    };

    const Corruption = struct {
        operation: usize,
        value: u64,
    };

    fn init(entries: []const Entry) LoggedConfig {
        for (entries) |entry| std.debug.assert(entry.bytes.len == function_window_size);
        return .{ .entries = entries };
    }

    fn configSpace(self: *LoggedConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    fn function(self: *LoggedConfig, target: Sbdf) Function {
        return Function.unchecked(self.configSpace(), target);
    }

    fn bytesFor(self: *LoggedConfig, target: Sbdf) ?[]u8 {
        for (self.entries) |entry| {
            if (entry.sbdf.eql(target)) return entry.bytes;
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
        .read16 = read16,
        .read32 = read32,
        .write8 = write8,
        .write16 = write16,
        .write32 = write32,
    };

    fn read8(context: *anyopaque, target: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        const self: *LoggedConfig = @ptrCast(@alignCast(context));
        const ordinal = self.record(.{ .operation = .read8, .sbdf = target, .offset = byte_offset, .value = 0 });
        if (self.fail_on == ordinal) return error.UnsupportedAccessWidth;

        var value = self.bytesFor(target).?[byte_offset];
        if (self.corrupt_on) |corruption| {
            if (corruption.operation == ordinal) value = @truncate(corruption.value);
        }

        self.log[ordinal - 1].value = value;
        return value;
    }

    fn read16(context: *anyopaque, target: Sbdf, byte_offset: usize) ConfigSpace.Error!u16 {
        const self: *LoggedConfig = @ptrCast(@alignCast(context));
        const ordinal = self.record(.{ .operation = .read16, .sbdf = target, .offset = byte_offset, .value = 0 });
        if (self.fail_on == ordinal) return error.UnsupportedAccessWidth;

        var value = load16(self.bytesFor(target).?, byte_offset);
        if (self.corrupt_on) |corruption| {
            if (corruption.operation == ordinal) value = @truncate(corruption.value);
        }

        self.log[ordinal - 1].value = value;
        return value;
    }

    fn read32(context: *anyopaque, target: Sbdf, byte_offset: usize) ConfigSpace.Error!u32 {
        const self: *LoggedConfig = @ptrCast(@alignCast(context));
        const ordinal = self.record(.{ .operation = .read32, .sbdf = target, .offset = byte_offset, .value = 0 });
        if (self.fail_on == ordinal) return error.UnsupportedAccessWidth;

        var value = load32(self.bytesFor(target).?, byte_offset);
        if (self.corrupt_on) |corruption| {
            if (corruption.operation == ordinal) value = @truncate(corruption.value);
        }

        self.log[ordinal - 1].value = value;
        return value;
    }

    fn write8(context: *anyopaque, target: Sbdf, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        const self: *LoggedConfig = @ptrCast(@alignCast(context));
        const ordinal = self.record(.{ .operation = .write8, .sbdf = target, .offset = byte_offset, .value = value });
        if (self.fail_on == ordinal) return error.UnsupportedAccessWidth;
        self.bytesFor(target).?[byte_offset] = value;
    }

    fn write16(context: *anyopaque, target: Sbdf, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        const self: *LoggedConfig = @ptrCast(@alignCast(context));
        const ordinal = self.record(.{ .operation = .write16, .sbdf = target, .offset = byte_offset, .value = value });
        if (self.fail_on == ordinal) return error.UnsupportedAccessWidth;
        store16(self.bytesFor(target).?, byte_offset, value);
    }

    fn write32(context: *anyopaque, target: Sbdf, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        const self: *LoggedConfig = @ptrCast(@alignCast(context));
        const ordinal = self.record(.{ .operation = .write32, .sbdf = target, .offset = byte_offset, .value = value });
        if (self.fail_on == ordinal) return error.UnsupportedAccessWidth;
        store32(self.bytesFor(target).?, byte_offset, value);
    }
};

fn oneBarPlan(function: Function, kind: Kind, base: u64) Plan {
    const static = struct {
        var assignments: [1]Assignment = undefined;
    };
    static.assignments[0] = assignmentFor(
        barRequirement(function, 0, kind, .{ .size = 0x1000, .alignment = 0x1000 }),
        kind,
        base,
    );
    return .{ .assignments = &static.assignments };
}

fn assignmentFor(requirement: Requirement, pool: Kind, base: u64) Assignment {
    return .{ .requirement = requirement, .pool = pool, .base = base };
}

fn barRequirement(function: Function, index: usize, kind: Kind, shape: RequirementShape) Requirement {
    return .{
        .kind = kind,
        .size = shape.size,
        .alignment = shape.alignment,
        .source = .{ .endpoint_bar = bar.BarRef.init(function, index) },
    };
}

fn romRequirement(function: Function, shape: RequirementShape) Requirement {
    return .{
        .kind = .mmio32,
        .size = shape.size,
        .alignment = shape.alignment,
        .source = .{ .endpoint_expansion_rom = function },
    };
}

fn windowRequirement(
    function: Function,
    window: Source.BridgeWindow,
    kind: Kind,
    shape: RequirementShape,
) Requirement {
    return .{
        .kind = kind,
        .size = shape.size,
        .alignment = shape.alignment,
        .source = .{ .bridge_window = .{ .function = function, .window = window } },
    };
}

fn seedHeader(bytes: []u8, kind: HeaderKind, command: u16) void {
    bytes[offset.header_type] = switch (kind) {
        .type0 => 0x00,
        .type1 => 0x01,
    };
    store16(bytes, offset.command, command);
}

fn sbdf(comptime device: u5) Sbdf {
    return Sbdf.of(0, 0, device, 0);
}

fn read(operation: LoggedConfig.Operation, comptime device: u5, byte_offset: usize, value: u64) LoggedConfig.Access {
    return .{ .operation = operation, .sbdf = sbdf(device), .offset = byte_offset, .value = value };
}

fn write(operation: LoggedConfig.Operation, comptime device: u5, byte_offset: usize, value: u64) LoggedConfig.Access {
    return .{ .operation = operation, .sbdf = sbdf(device), .offset = byte_offset, .value = value };
}

fn expectBridgeBarWindowLog(backend: *const LoggedConfig) !void {
    try expectLog(backend, &.{
        read(.read8, 0, offset.header_type, 0x01),
        read(.read16, 0, offset.command, command_all),
        read(.read32, 0, offset.bar0, 0),
        read(.read8, 0, offset.io_base, 0),
        read(.read8, 0, offset.io_limit, 0),
        read(.read16, 0, offset.io_base_upper, 0xAAAA),
        read(.read16, 0, offset.io_limit_upper, 0xBBBB),
        read(.read16, 0, offset.memory_base, 0),
        read(.read16, 0, offset.memory_limit, 0),
        read(.read16, 0, offset.prefetchable_base, 0),
        read(.read16, 0, offset.prefetchable_limit, 0),
        read(.read32, 0, offset.prefetchable_base_upper, 0xCCCC_CCCC),
        read(.read32, 0, offset.prefetchable_limit_upper, 0xDDDD_DDDD),
        write(.write16, 0, offset.command, 0xFFFC),
        read(.read16, 0, offset.command, 0xFFFC),
        write(.write32, 0, offset.bar0, 0x8000_0000),
        read(.read32, 0, offset.bar0, 0x8000_0000),
        write(.write8, 0, offset.io_base, 0x20),
        read(.read8, 0, offset.io_base, 0x20),
        write(.write8, 0, offset.io_limit, 0x20),
        read(.read8, 0, offset.io_limit, 0x20),
        write(.write16, 0, offset.io_base_upper, 0),
        read(.read16, 0, offset.io_base_upper, 0),
        write(.write16, 0, offset.io_limit_upper, 0),
        read(.read16, 0, offset.io_limit_upper, 0),
        write(.write16, 0, offset.memory_base, 0x8000),
        read(.read16, 0, offset.memory_base, 0x8000),
        write(.write16, 0, offset.memory_limit, 0x8000),
        read(.read16, 0, offset.memory_limit, 0x8000),
        write(.write16, 0, offset.prefetchable_base, 0x9000),
        read(.read16, 0, offset.prefetchable_base, 0x9000),
        write(.write16, 0, offset.prefetchable_limit, 0x9000),
        read(.read16, 0, offset.prefetchable_limit, 0x9000),
        write(.write32, 0, offset.prefetchable_base_upper, 0),
        read(.read32, 0, offset.prefetchable_base_upper, 0),
        write(.write32, 0, offset.prefetchable_limit_upper, 0),
        read(.read32, 0, offset.prefetchable_limit_upper, 0),
        write(.write16, 0, offset.command, command_all),
        read(.read16, 0, offset.command, command_all),
    });
}

fn expectLog(backend: *const LoggedConfig, expected: []const LoggedConfig.Access) !void {
    try std.testing.expectEqual(expected.len, backend.log_len);
    for (expected, backend.log[0..backend.log_len]) |want, got| try expectAccess(want, got);
}

fn expectLogTail(backend: *const LoggedConfig, expected: []const LoggedConfig.Access) !void {
    try std.testing.expect(backend.log_len >= expected.len);
    const tail = backend.log[backend.log_len - expected.len .. backend.log_len];
    for (expected, tail) |want, got| try expectAccess(want, got);
}

fn expectNoWrites(backend: *const LoggedConfig) !void {
    for (backend.log[0..backend.log_len]) |access| {
        switch (access.operation) {
            .write8, .write16, .write32 => return error.TestExpectedEqual,
            else => {},
        }
    }
}

fn expectNoAccess(backend: *const LoggedConfig, target: Sbdf) !void {
    for (backend.log[0..backend.log_len]) |access| try std.testing.expect(!access.sbdf.eql(target));
}

fn expectAccess(expected: LoggedConfig.Access, actual: LoggedConfig.Access) !void {
    try std.testing.expectEqual(expected.operation, actual.operation);
    try std.testing.expect(expected.sbdf.eql(actual.sbdf));
    try std.testing.expectEqual(expected.offset, actual.offset);
    try std.testing.expectEqual(expected.value, actual.value);
}

fn load16(bytes: []const u8, byte_offset: usize) u16 {
    return (stdx.bytes.load(stdx.layout.Le(u16), bytes, byte_offset) catch unreachable).native();
}

fn load32(bytes: []const u8, byte_offset: usize) u32 {
    return (stdx.bytes.load(stdx.layout.Le(u32), bytes, byte_offset) catch unreachable).native();
}

fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
    const encoded = stdx.layout.Le(u16).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u16), bytes, byte_offset, encoded) catch unreachable;
}

fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
    const encoded = stdx.layout.Le(u32).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u32), bytes, byte_offset, encoded) catch unreachable;
}
