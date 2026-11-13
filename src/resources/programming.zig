//! Resource programming.

const std = @import("std");

const cfg = @import("config");
const core = @import("core");
const header = @import("header");

const bridge = @import("bridge.zig");
const model = @import("model.zig");

const type0 = header.type0;
const type1 = header.type1;

const Function = cfg.Function;
const Offset = core.Offset;
const HeaderFormat = core.header.Format;
const ExpansionRom = core.header.ExpansionRom;
const IoBar = core.bar.Io;
const MemoryBar = core.bar.Memory;
const Encoding = core.bridge.Encoding;
const IoRegisters = core.bridge.Io;
const MemoryRegisters = core.bridge.Memory;
const WindowType = core.bridge.Type;
const Type0 = header.Type0;
const Type1 = header.Type1;
const Assignment = model.Assignment;
const Type = model.Type;

const num_bar_slots = core.header.type0.num_bar_slots;

const command_decode_mask: u16 = 0x0003;
const command_compare_mask: u16 = 0x0547;
const max_records: usize = num_bar_slots * 2 + 1 + 10;

pub const Error = error{
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};

/// Saves, disables decode, programs, then restores each function.
/// Failed rollback returns `ProgrammingPartial` and may leave hardware partially programmed.
pub fn commit(assignments: []const Assignment) Error!void {
    var driver = Commit.from(assignments);
    try driver.apply();
}

const Commit = struct {
    assignments: []const Assignment,
    next_index: usize = 0,
    function: Function = undefined,
    group: []const Assignment = &.{},
    format: HeaderFormat = undefined,
    snapshot: Snapshot = .{},
    journal: Journal = .{},
    bar_offsets: [num_bar_slots]Offset(u32) = undefined,

    fn from(assignments: []const Assignment) Commit {
        return .{ .assignments = assignments };
    }

    fn apply(self: *Commit) Error!void {
        while (self.nextGroup()) {
            try self.applyGroup();
        }
    }

    fn applyGroup(self: *Commit) Error!void {
        self.format = self.function.format() catch return error.ProgrammingWriteFailed;
        self.assertShape();

        try self.save();
        try self.disableDecode();

        self.writePhase() catch |err| return self.rollback(err);
        self.restoreDecode() catch |err| return self.rollback(err);
    }

    fn nextGroup(self: *Commit) bool {
        if (self.next_index == self.assignments.len) {
            return false;
        }

        const start = self.next_index;
        const function = self.assignments[start].function();
        var end = start + 1;
        while (end < self.assignments.len and function.eql(
            self.assignments[end].function(),
        )) : (end += 1) {}

        self.function = function;
        self.group = self.assignments[start..end];
        self.format = undefined;
        self.snapshot.reset();
        self.journal.reset();
        self.next_index = end;

        return true;
    }

    fn assertShape(self: *const Commit) void {
        var seen_bars: [num_bar_slots]bool = @splat(false);
        var seen_windows = WindowSet{};
        var seen_rom = false;

        for (self.group) |item| {
            std.debug.assert(self.function.eql(item.function()));

            switch (item.requirement.source) {
                .bar => |source| {
                    std.debug.assert(source.index < self.numBarSlots());
                    std.debug.assert(!seen_bars[source.index]);

                    seen_bars[source.index] = true;
                },
                .rom => {
                    std.debug.assert(!seen_rom);

                    seen_rom = true;
                },
                .bridge => |source| {
                    std.debug.assert(self.format == .type1);

                    seen_windows.mark(source.window);
                },
            }
        }
    }

    fn save(self: *Commit) Error!void {
        try self.snapshot.captureCommand(self.function);
        try self.saveBars();
        try self.saveRom();
        try self.saveWindows();
    }

    fn saveBars(self: *Commit) Error!void {
        var index: usize = 0;
        while (index < self.numBarSlots()) : (index += 1) {
            const item = self.barAssignment(index) orelse continue;
            const base = barOffset(index);
            self.bar_offsets[index] = base;
            try self.snapshot.capture(self.function, base);

            if (is64(item.requirement.type)) {
                const hi = barOffset(index + 1);
                self.bar_offsets[index + 1] = hi;
                try self.snapshot.capture(self.function, hi);
            }
        }
    }

    fn saveRom(self: *Commit) Error!void {
        if (self.romAssignment()) |_| {
            try self.snapshot.capture(self.function, self.romOffset());
        }
    }

    fn saveWindows(self: *Commit) Error!void {
        if (self.windowAssignment(.io)) |item| {
            _ = bridge.encode(item) catch return error.ProgrammingWriteFailed;
            try self.saveIoWindow();
        }

        if (self.windowAssignment(.mem)) |_| {
            try self.snapshot.capture(self.function, type1.offsets.mem_base);
            try self.snapshot.capture(self.function, type1.offsets.mem_limit);
        }

        if (self.windowAssignment(.mem_prefetch)) |item| {
            _ = bridge.encode(item) catch return error.ProgrammingWriteFailed;
            try self.savePrefetchWindow();
        }
    }

    fn saveIoWindow(self: *Commit) Error!void {
        try self.snapshot.capture(self.function, type1.offsets.io_base_lo);
        try self.snapshot.capture(self.function, type1.offsets.io_limit_lo);
        try self.snapshot.capture(self.function, type1.offsets.io_base_hi);
        try self.snapshot.capture(self.function, type1.offsets.io_limit_hi);
    }

    fn savePrefetchWindow(self: *Commit) Error!void {
        try self.snapshot.capture(self.function, type1.offsets.prefetch_base_lo);
        try self.snapshot.capture(self.function, type1.offsets.prefetch_limit_lo);
        try self.snapshot.capture(self.function, type1.offsets.prefetch_base_hi);
        try self.snapshot.capture(self.function, type1.offsets.prefetch_limit_hi);
    }

    fn disableDecode(self: *Commit) Error!void {
        const disabled = self.snapshot.command & ~command_decode_mask;
        try self.writeReadbackCommand(.{
            .value = disabled,
            .access_error = error.ProgrammingWriteFailed,
            .mismatch_error = error.ProgrammingReadbackMismatch,
        });
    }

    fn writePhase(self: *Commit) Error!void {
        try self.writeBars();
        try self.writeRom();
        try self.writeWindows();
    }

    fn writeBars(self: *Commit) Error!void {
        var index: usize = 0;
        while (index < self.numBarSlots()) : (index += 1) {
            const item = self.barAssignment(index) orelse continue;
            const base = self.bar_offsets[index];
            const saved_lo = self.snapshot.get(base);
            const io = IoBar.from(saved_lo);
            const address: u32 = @truncate(item.base);
            const new_lo = if (io.space == .io)
                io.withBase(address).raw()
            else
                MemoryBar.from(saved_lo).withBase(address).raw();

            try self.writeReadback(base, new_lo, saved_lo);

            if (is64(item.requirement.type)) {
                try self.writeBarHi(self.bar_offsets[index + 1], item.base);
            }
        }
    }

    fn writeBarHi(self: *Commit, hi_offset: Offset(u32), base: u64) Error!void {
        const saved_hi = self.snapshot.get(hi_offset);
        const new_hi: u32 = @truncate(base >> 32);

        try self.writeReadback(hi_offset, new_hi, saved_hi);
    }

    fn writeRom(self: *Commit) Error!void {
        const item = self.romAssignment() orelse return;

        const rom_offset = self.romOffset();
        const saved_rom = self.snapshot.get(rom_offset);
        const preserved_enable = saved_rom & ExpansionRom.mask(.{.enable});
        const encoded_base = @as(u32, @truncate(item.base)) & ExpansionRom.mask(.{.base_shifted});
        const new_rom = preserved_enable | encoded_base;

        try self.writeReadback(rom_offset, new_rom, saved_rom);
    }

    fn writeWindows(self: *Commit) Error!void {
        if (self.windowAssignment(.io)) |item| {
            const encoded = bridge.encode(item) catch return error.ProgrammingWriteFailed;
            try self.writeIoWindow(encoded.io);
        }

        if (self.windowAssignment(.mem)) |item| {
            const encoded = bridge.encode(item) catch return error.ProgrammingWriteFailed;
            try self.writeMemWindow(encoded.mem);
        }

        if (self.windowAssignment(.mem_prefetch)) |item| {
            const encoded = bridge.encode(item) catch return error.ProgrammingWriteFailed;
            try self.writePrefetchWindow(encoded);
        }
    }

    fn writeIoWindow(self: *Commit, io: IoRegisters) Error!void {
        try self.writeReadback(type1.offsets.io_base_lo, io.base_lo, self.snapshot.get(type1.offsets.io_base_lo));
        try self.writeReadback(type1.offsets.io_limit_lo, io.limit_lo, self.snapshot.get(type1.offsets.io_limit_lo));
        try self.writeReadback(type1.offsets.io_base_hi, io.base_hi, self.snapshot.get(type1.offsets.io_base_hi));
        try self.writeReadback(type1.offsets.io_limit_hi, io.limit_hi, self.snapshot.get(type1.offsets.io_limit_hi));
    }

    fn writeMemWindow(self: *Commit, memory: MemoryRegisters) Error!void {
        try self.writeReadback(type1.offsets.mem_base, memory.base, self.snapshot.get(type1.offsets.mem_base));
        try self.writeReadback(type1.offsets.mem_limit, memory.limit, self.snapshot.get(type1.offsets.mem_limit));
    }

    fn writePrefetchWindow(self: *Commit, encoded: Encoding) Error!void {
        const base_lo, const limit_lo, const base_hi, const limit_hi = switch (encoded) {
            .mem_prefetch_32 => |prefetchable| .{
                prefetchable.base_lo,
                prefetchable.limit_lo,
                @as(u32, 0),
                @as(u32, 0),
            },
            .mem_prefetch_64 => |prefetchable| .{
                prefetchable.base_lo,
                prefetchable.limit_lo,
                prefetchable.base_hi,
                prefetchable.limit_hi,
            },
            else => unreachable,
        };

        const saved_base_lo = self.snapshot.get(type1.offsets.prefetch_base_lo);
        const saved_limit_lo = self.snapshot.get(type1.offsets.prefetch_limit_lo);
        const saved_base_hi = self.snapshot.get(type1.offsets.prefetch_base_hi);
        const saved_limit_hi = self.snapshot.get(type1.offsets.prefetch_limit_hi);

        try self.writeReadback(type1.offsets.prefetch_base_lo, base_lo, saved_base_lo);
        try self.writeReadback(type1.offsets.prefetch_limit_lo, limit_lo, saved_limit_lo);
        try self.writeReadback(type1.offsets.prefetch_base_hi, base_hi, saved_base_hi);
        try self.writeReadback(type1.offsets.prefetch_limit_hi, limit_hi, saved_limit_hi);
    }

    fn restoreDecode(self: *Commit) Error!void {
        try self.writeReadbackCommand(.{
            .value = self.snapshot.command,
            .access_error = error.ProgrammingWriteFailed,
            .mismatch_error = error.ProgrammingReadbackMismatch,
        });
    }

    fn rollback(self: *Commit, original: Error) Error {
        self.journal.rollback(self.function) catch return error.ProgrammingPartial;
        self.restoreCommand() catch return error.ProgrammingPartial;

        return original;
    }

    fn restoreCommand(self: *Commit) Error!void {
        try self.writeReadbackCommand(.{
            .value = self.snapshot.command,
            .access_error = error.ProgrammingPartial,
            .mismatch_error = error.ProgrammingPartial,
        });
    }

    const WriteCommand = struct {
        value: u16,
        access_error: Error,
        mismatch_error: Error,
    };

    fn writeReadbackCommand(self: *Commit, write: WriteCommand) Error!void {
        const command_offset = Function.offsets.command;

        self.function.write(command_offset, write.value) catch
            return write.access_error;

        const readback = self.function.read(command_offset) catch
            return write.access_error;
        const current_decode = readback & command_compare_mask;
        const requested_decode = write.value & command_compare_mask;
        if (current_decode != requested_decode) {
            return write.mismatch_error;
        }
    }

    fn writeReadback(
        self: *Commit,
        offset: anytype,
        value: @TypeOf(offset).Int,
        saved: @TypeOf(offset).Int,
    ) Error!void {
        self.function.write(offset, value) catch
            return error.ProgrammingWriteFailed;

        self.journal.push(Record.from(offset, saved));

        const readback = self.function.read(offset) catch
            return error.ProgrammingWriteFailed;
        if (readback != value) {
            return error.ProgrammingReadbackMismatch;
        }
    }

    fn barAssignment(self: *const Commit, index: usize) ?Assignment {
        for (self.group) |item| {
            switch (item.requirement.source) {
                .bar => |source| {
                    if (source.index == index) {
                        return item;
                    }
                },
                else => {},
            }
        }

        return null;
    }

    fn romAssignment(self: *const Commit) ?Assignment {
        for (self.group) |item| {
            if (item.requirement.source == .rom) {
                return item;
            }
        }

        return null;
    }

    fn windowAssignment(self: *const Commit, window: WindowType) ?Assignment {
        for (self.group) |item| {
            switch (item.requirement.source) {
                .bridge => |source| {
                    if (source.window == window) {
                        return item;
                    }
                },
                else => {},
            }
        }

        return null;
    }

    fn numBarSlots(self: *const Commit) usize {
        return switch (self.format) {
            .type0 => Type0.num_bar_slots,
            .type1 => Type1.num_bar_slots,
            else => unreachable,
        };
    }

    fn romOffset(self: *const Commit) Offset(u32) {
        return switch (self.format) {
            .type0 => type0.offsets.rom_base,
            .type1 => type1.offsets.rom_base,
            else => unreachable,
        };
    }

    fn barOffset(index: usize) Offset(u32) {
        std.debug.assert(index < num_bar_slots);
        return Offset(u32).from(core.header.type0.offsets.bar(index));
    }

    fn is64(resource_type: Type) bool {
        return resource_type == .mmio64 or resource_type == .mmio64_prefetch;
    }
};

const Snapshot = struct {
    command: u16 = 0,
    records: [max_records]Record = undefined,
    len: usize = 0,

    fn reset(self: *Snapshot) void {
        self.command = 0;
        self.len = 0;
    }

    fn captureCommand(self: *Snapshot, function: Function) Error!void {
        const command_offset = Function.offsets.command;

        self.command = function.read(command_offset) catch
            return error.ProgrammingWriteFailed;
    }

    fn capture(self: *Snapshot, function: Function, offset: anytype) Error!void {
        const value = function.read(offset) catch
            return error.ProgrammingWriteFailed;

        self.insert(Record.from(offset, value));
    }

    fn get(self: *const Snapshot, offset: anytype) @TypeOf(offset).Int {
        for (self.records[0..self.len]) |entry| {
            switch (entry) {
                inline else => |record| {
                    if (comptime @TypeOf(record.offset) == @TypeOf(offset)) {
                        if (record.offset == offset) {
                            return record.value;
                        }
                    }
                },
            }
        }

        unreachable;
    }

    fn insert(self: *Snapshot, record: Record) void {
        std.debug.assert(self.len < self.records.len);
        std.debug.assert(!self.contains(record));

        self.records[self.len] = record;
        self.len += 1;
    }

    fn contains(self: *const Snapshot, record: Record) bool {
        for (self.records[0..self.len]) |entry| {
            if (entry.sameLocation(record)) {
                return true;
            }
        }

        return false;
    }
};

const Journal = struct {
    records: [max_records]Record = undefined,
    len: usize = 0,

    fn reset(self: *Journal) void {
        self.len = 0;
    }

    fn rollback(self: *Journal, function: Function) Error!void {
        while (self.len > 0) {
            self.len -= 1;
            try self.records[self.len].restore(function);
        }
    }

    fn push(self: *Journal, record: Record) void {
        std.debug.assert(self.len < self.records.len);

        self.records[self.len] = record;
        self.len += 1;
    }
};

const WindowSet = struct {
    io: bool = false,
    mem: bool = false,
    mem_prefetch: bool = false,

    fn mark(self: *WindowSet, window: WindowType) void {
        const slot = switch (window) {
            .io => &self.io,
            .mem => &self.mem,
            .mem_prefetch => &self.mem_prefetch,
        };
        std.debug.assert(!slot.*);

        slot.* = true;
    }
};

const Record = union(enum) {
    byte: struct {
        offset: Offset(u8),
        value: u8,
    },
    word16: struct {
        offset: Offset(u16),
        value: u16,
    },
    word32: struct {
        offset: Offset(u32),
        value: u32,
    },

    fn from(offset: anytype, value: @TypeOf(offset).Int) Record {
        return switch (@TypeOf(offset)) {
            Offset(u8) => .{ .byte = .{ .offset = offset, .value = value } },
            Offset(u16) => .{ .word16 = .{ .offset = offset, .value = value } },
            Offset(u32) => .{ .word32 = .{ .offset = offset, .value = value } },
            else => @compileError("expected an absolute configuration offset"),
        };
    }

    fn sameLocation(self: Record, other: Record) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return false;
        }

        return switch (self) {
            .byte => |entry| entry.offset == other.byte.offset,
            .word16 => |entry| entry.offset == other.word16.offset,
            .word32 => |entry| entry.offset == other.word32.offset,
        };
    }

    fn restore(self: Record, function: Function) Error!void {
        switch (self) {
            inline else => |entry| {
                function.write(entry.offset, entry.value) catch
                    return error.ProgrammingPartial;

                const readback = function.read(entry.offset) catch
                    return error.ProgrammingPartial;
                if (readback != entry.value) {
                    return error.ProgrammingPartial;
                }
            },
        }
    }
};

pub const unit = struct {
    const bar = @import("bar");

    const testing = std.testing;

    const command_all: u16 = 0xFFFF;
    const pcie_window_size = core.config.extended_size;

    const ConfigSpace = cfg.ConfigSpace;
    const ConfigError = ConfigSpace.Error;

    const Requirement = model.Requirement;

    const Sbdf = core.Sbdf;

    const BarRef = bar.Ref;

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

        fn from(entries: []const Entry) LoggedConfig {
            for (entries) |entry| {
                std.debug.assert(entry.bytes.len == pcie_window_size);
            }

            return .{ .entries = entries };
        }

        fn config(self: *LoggedConfig) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn function(self: *LoggedConfig, target: Sbdf) Function {
            return Function.from(self.config(), target);
        }

        fn bytesFor(self: *LoggedConfig, target: Sbdf) ?[]u8 {
            for (self.entries) |entry| {
                if (entry.sbdf.eql(target)) {
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
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(context: *anyopaque, target: Sbdf, byte_offset: usize) ConfigError!u8 {
            const self: *LoggedConfig = @ptrCast(@alignCast(context));
            const ordinal = self.record(.{ .operation = .read8, .sbdf = target, .offset = byte_offset, .value = 0 });

            if (self.fail_on == ordinal) {
                return error.UnsupportedAccessWidth;
            }

            var value = self.bytesFor(target).?[byte_offset];

            if (self.corrupt_on) |corruption| {
                if (corruption.operation == ordinal) {
                    value = @truncate(corruption.value);
                }
            }

            self.log[ordinal - 1].value = value;
            return value;
        }

        fn read16(context: *anyopaque, target: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *LoggedConfig = @ptrCast(@alignCast(context));
            const ordinal = self.record(.{ .operation = .read16, .sbdf = target, .offset = byte_offset, .value = 0 });

            if (self.fail_on == ordinal) {
                return error.UnsupportedAccessWidth;
            }

            var value = load16(self.bytesFor(target).?, byte_offset);

            if (self.corrupt_on) |corruption| {
                if (corruption.operation == ordinal) {
                    value = @truncate(corruption.value);
                }
            }

            self.log[ordinal - 1].value = value;
            return value;
        }

        fn read32(context: *anyopaque, target: Sbdf, byte_offset: usize) ConfigError!u32 {
            const self: *LoggedConfig = @ptrCast(@alignCast(context));
            const ordinal = self.record(.{ .operation = .read32, .sbdf = target, .offset = byte_offset, .value = 0 });

            if (self.fail_on == ordinal) {
                return error.UnsupportedAccessWidth;
            }

            var value = load32(self.bytesFor(target).?, byte_offset);

            if (self.corrupt_on) |corruption| {
                if (corruption.operation == ordinal) {
                    value = @truncate(corruption.value);
                }
            }

            self.log[ordinal - 1].value = value;
            return value;
        }

        fn write8(context: *anyopaque, target: Sbdf, byte_offset: usize, value: u8) ConfigError!void {
            const self: *LoggedConfig = @ptrCast(@alignCast(context));
            const ordinal = self.record(.{ .operation = .write8, .sbdf = target, .offset = byte_offset, .value = value });

            if (self.fail_on == ordinal) {
                return error.UnsupportedAccessWidth;
            }

            self.bytesFor(target).?[byte_offset] = value;
        }

        fn write16(context: *anyopaque, target: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *LoggedConfig = @ptrCast(@alignCast(context));
            const ordinal = self.record(.{ .operation = .write16, .sbdf = target, .offset = byte_offset, .value = value });

            if (self.fail_on == ordinal) {
                return error.UnsupportedAccessWidth;
            }

            store16(self.bytesFor(target).?, byte_offset, value);
        }

        fn write32(context: *anyopaque, target: Sbdf, byte_offset: usize, value: u32) ConfigError!void {
            const self: *LoggedConfig = @ptrCast(@alignCast(context));
            const ordinal = self.record(.{ .operation = .write32, .sbdf = target, .offset = byte_offset, .value = value });

            if (self.fail_on == ordinal) {
                return error.UnsupportedAccessWidth;
            }

            store32(self.bytesFor(target).?, byte_offset, value);
        }
    };

    const offset = struct {
        const command: usize = 0x04;
        const @"type": usize = 0x0E;
        const bar0: usize = 0x10;
        const bar1: usize = 0x14;
        const io_base_lo: usize = 0x1C;
        const io_limit_lo: usize = 0x1D;
        const mem_base: usize = 0x20;
        const mem_limit: usize = 0x22;
        const prefetch_base_lo: usize = 0x24;
        const prefetch_limit_lo: usize = 0x26;
        const prefetch_base_hi: usize = 0x28;
        const prefetch_limit_hi: usize = 0x2C;
        const type0_rom: usize = 0x30;
        const io_base_hi: usize = 0x30;
        const io_limit_hi: usize = 0x32;
        const type1_rom: usize = 0x38;
    };

    test "endpoint mixed BARs and ROM follow save disable write restore order" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&bytes, .type0, command_all);
        store32(&bytes, offset.bar0, 0x0000_0000);
        store32(&bytes, offset.bar1, 0x0000_0003);
        store32(&bytes, offset.type0_rom, 0x0000_07FF);
        var backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
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

        try commit(&assignments);

        try testing.expectEqual(@as(u16, command_all), load16(&bytes, offset.command));
        try testing.expectEqual(@as(u32, 0x8000_1000), load32(&bytes, offset.bar0));
        try testing.expectEqual(@as(u32, 0x0000_1003), load32(&bytes, offset.bar1));
        try testing.expectEqual(@as(u32, 0x9000_0001), load32(&bytes, offset.type0_rom));
        try expectLog(&backend, &.{
            read(.read8, 0, offset.type, 0x00),
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

    test "64-bit BAR writes high dword and preserves saved low type bits" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&bytes, .type0, command_all);
        store32(&bytes, offset.bar0, 0x0000_000C);
        store32(&bytes, offset.bar1, 0xCAFE_BABE);
        var backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
        const function = backend.function(sbdf(0));
        const assignments = [_]Assignment{
            assignmentFor(
                barRequirement(function, 0, .mmio64_prefetch, .{ .size = 0x2000, .alignment = 0x2000 }),
                .mmio32_prefetch,
                0x1_2345_0000,
            ),
        };

        try commit(&assignments);

        try testing.expectEqual(@as(u32, 0x2345_000C), load32(&bytes, offset.bar0));
        try testing.expectEqual(@as(u32, 0x0000_0001), load32(&bytes, offset.bar1));
    }

    test "bridge BAR and windows write in fixed order and zero stale upper registers" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&bytes, .type1, command_all);
        store32(&bytes, offset.bar0, 0x0000_0000);
        store16(&bytes, offset.io_base_hi, 0xAAAA);
        store16(&bytes, offset.io_limit_hi, 0xBBBB);
        store32(&bytes, offset.prefetch_base_hi, 0xCCCC_CCCC);
        store32(&bytes, offset.prefetch_limit_hi, 0xDDDD_DDDD);
        var backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
        const function = backend.function(sbdf(0));
        const assignments = [_]Assignment{
            assignmentFor(
                windowRequirement(
                    function,
                    .mem_prefetch,
                    .mmio32_prefetch,
                    .{ .size = 0x100000, .alignment = 0x100000 },
                ),
                .mmio32_prefetch,
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
                    .mem,
                    .mmio32,
                    .{ .size = 0x100000, .alignment = 0x100000 },
                ),
                .mmio32,
                0x8000_0000,
            ),
        };

        try commit(&assignments);

        try testing.expectEqual(@as(u16, 0), load16(&bytes, offset.io_base_hi));
        try testing.expectEqual(@as(u16, 0), load16(&bytes, offset.io_limit_hi));
        try testing.expectEqual(@as(u32, 0), load32(&bytes, offset.prefetch_base_hi));
        try testing.expectEqual(@as(u32, 0), load32(&bytes, offset.prefetch_limit_hi));
        try expectBridgeBarWindowLog(&backend);
    }

    test "prefetchable 64-bit bridge window writes real upper dwords" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&bytes, .type1, command_all);
        var backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
        const function = backend.function(sbdf(0));
        const assignments = [_]Assignment{
            assignmentFor(
                windowRequirement(
                    function,
                    .mem_prefetch,
                    .mmio64_prefetch,
                    .{ .size = 0x100000, .alignment = 0x100000 },
                ),
                .mmio64_prefetch,
                0x1_0000_0000,
            ),
        };

        try commit(&assignments);

        try testing.expectEqual(@as(u16, 0x0001), load16(&bytes, offset.prefetch_base_lo));
        try testing.expectEqual(@as(u16, 0x0001), load16(&bytes, offset.prefetch_limit_lo));
        try testing.expectEqual(@as(u32, 0x0000_0001), load32(&bytes, offset.prefetch_base_hi));
        try testing.expectEqual(@as(u32, 0x0000_0001), load32(&bytes, offset.prefetch_limit_hi));
    }

    test "save failure and disable mismatch stop before base writes" {
        var save_bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&save_bytes, .type0, command_all);
        var save_backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &save_bytes }});
        const save_bar_read = 2;
        save_backend.fail_on = save_bar_read;
        const save_plan = oneBarAssignments(save_backend.function(sbdf(0)), .mmio32, 0x8000_0000);

        try testing.expectError(error.ProgrammingWriteFailed, commit(&save_plan));
        try testing.expectEqual(@as(usize, 2), save_backend.log_len);
        try expectNoWrites(&save_backend);

        var mismatch_bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&mismatch_bytes, .type0, command_all);
        store32(&mismatch_bytes, offset.bar0, 0);
        var mismatch_backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &mismatch_bytes }});
        const disable_command_readback = 5;
        mismatch_backend.corrupt_on = .{ .operation = disable_command_readback, .value = 0 };
        const mismatch_plan = oneBarAssignments(mismatch_backend.function(sbdf(0)), .mmio32, 0x8000_0000);

        try testing.expectError(error.ProgrammingReadbackMismatch, commit(&mismatch_plan));
        try testing.expectEqual(@as(u32, 0), load32(&mismatch_bytes, offset.bar0));
    }

    test "BAR failure rolls back journaled writes and restores Command" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&bytes, .type0, command_all);
        store32(&bytes, offset.bar0, 0x0000_0000);
        store32(&bytes, offset.bar1, 0x0000_0000);
        var backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
        const second_bar_write = 9;
        backend.fail_on = second_bar_write;
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

        try testing.expectError(error.ProgrammingWriteFailed, commit(&assignments));

        try testing.expectEqual(@as(u16, command_all), load16(&bytes, offset.command));
        try testing.expectEqual(@as(u32, 0), load32(&bytes, offset.bar0));
        try testing.expectEqual(@as(u32, 0), load32(&bytes, offset.bar1));
        try expectLogTail(&backend, &.{
            write(.write32, 0, offset.bar0, 0),
            read(.read32, 0, offset.bar0, 0),
            write(.write16, 0, offset.command, command_all),
            read(.read16, 0, offset.command, command_all),
        });
    }

    test "restore-decode failure rolls back bases and returns original error" {
        var write_bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&write_bytes, .type0, command_all);
        store32(&write_bytes, offset.bar0, 0x0000_0000);
        var write_backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &write_bytes }});
        const restore_command_write = 8;
        write_backend.fail_on = restore_command_write;
        const write_plan = oneBarAssignments(write_backend.function(sbdf(0)), .mmio32, 0x8000_0000);

        try testing.expectError(error.ProgrammingWriteFailed, commit(&write_plan));
        try testing.expectEqual(@as(u16, command_all), load16(&write_bytes, offset.command));
        try testing.expectEqual(@as(u32, 0), load32(&write_bytes, offset.bar0));
        try expectLogTail(&write_backend, &.{
            write(.write32, 0, offset.bar0, 0),
            read(.read32, 0, offset.bar0, 0),
            write(.write16, 0, offset.command, command_all),
            read(.read16, 0, offset.command, command_all),
        });

        var mismatch_bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&mismatch_bytes, .type0, command_all);
        store32(&mismatch_bytes, offset.bar0, 0x0000_0000);
        var mismatch_backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &mismatch_bytes }});
        const restore_command_readback = 9;
        mismatch_backend.corrupt_on = .{ .operation = restore_command_readback, .value = 0 };
        const mismatch_plan = oneBarAssignments(mismatch_backend.function(sbdf(0)), .mmio32, 0x8000_0000);

        try testing.expectError(error.ProgrammingReadbackMismatch, commit(&mismatch_plan));
        try testing.expectEqual(@as(u16, command_all), load16(&mismatch_bytes, offset.command));
        try testing.expectEqual(@as(u32, 0), load32(&mismatch_bytes, offset.bar0));
    }

    test "rollback restore failure returns ProgrammingPartial and aborts further restores" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedHeader(&bytes, .type0, command_all);
        store32(&bytes, offset.bar0, 0x0000_0000);
        var backend = LoggedConfig.from(&.{.{ .sbdf = sbdf(0), .bytes = &bytes }});
        const bar_readback = 7;
        backend.corrupt_on = .{ .operation = bar_readback, .value = 0xFFFF_FFFF };
        const rollback_bar_write = 8;
        backend.fail_on = rollback_bar_write;
        const plan = oneBarAssignments(backend.function(sbdf(0)), .mmio32, 0x8000_0000);

        try testing.expectError(error.ProgrammingPartial, commit(&plan));

        try testing.expectEqual(@as(u32, 0x8000_0000), load32(&bytes, offset.bar0));
        try testing.expectEqual(@as(usize, 8), backend.log_len);
    }

    test "multi-function failure leaves prior committed and later untouched" {
        var bytes0: [pcie_window_size]u8 = @splat(0);
        var bytes1: [pcie_window_size]u8 = @splat(0);
        var bytes2: [pcie_window_size]u8 = @splat(0);
        seedHeader(&bytes0, .type0, command_all);
        seedHeader(&bytes1, .type0, command_all);
        seedHeader(&bytes2, .type0, command_all);
        var entries = [_]LoggedConfig.Entry{
            .{ .sbdf = sbdf(0), .bytes = &bytes0 },
            .{ .sbdf = sbdf(1), .bytes = &bytes1 },
            .{ .sbdf = sbdf(2), .bytes = &bytes2 },
        };
        var backend = LoggedConfig.from(&entries);
        const second_function_bar_readback = 16;
        backend.corrupt_on = .{ .operation = second_function_bar_readback, .value = 0xFFFF_FFFF };
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

        try testing.expectError(error.ProgrammingReadbackMismatch, commit(&assignments));

        try testing.expectEqual(@as(u32, 0x8000_0000), load32(&bytes0, offset.bar0));
        try testing.expectEqual(@as(u32, 0), load32(&bytes1, offset.bar0));
        try testing.expectEqual(@as(u32, 0), load32(&bytes2, offset.bar0));
        try expectNoAccess(&backend, sbdf(2));
    }

    fn oneBarAssignments(function: Function, resource_type: Type, base: u64) [1]Assignment {
        return .{assignmentFor(
            barRequirement(function, 0, resource_type, .{ .size = 0x1000, .alignment = 0x1000 }),
            resource_type,
            base,
        )};
    }

    fn assignmentFor(requirement: Requirement, pool: Type, base: u64) Assignment {
        return .{ .requirement = requirement, .pool = pool, .base = base };
    }

    fn barRequirement(function: Function, index: usize, resource_type: Type, shape: RequirementShape) Requirement {
        return .{
            .type = resource_type,
            .size = shape.size,
            .alignment = shape.alignment,
            .source = .{ .bar = BarRef.from(function, index) },
        };
    }

    fn romRequirement(function: Function, shape: RequirementShape) Requirement {
        return .{
            .type = .mmio32,
            .size = shape.size,
            .alignment = shape.alignment,
            .source = .{ .rom = function },
        };
    }

    fn windowRequirement(
        function: Function,
        window: WindowType,
        resource_type: Type,
        shape: RequirementShape,
    ) Requirement {
        return .{
            .type = resource_type,
            .size = shape.size,
            .alignment = shape.alignment,
            .source = .{ .bridge = .{ .function = function, .window = window } },
        };
    }

    fn seedHeader(bytes: []u8, format: HeaderFormat, command: u16) void {
        bytes[offset.type] = @intFromEnum(format);
        store16(bytes, offset.command, command);
    }

    fn sbdf(device: u5) Sbdf {
        return Sbdf.from(.from(0), 0, device, 0);
    }

    fn read(operation: LoggedConfig.Operation, device: u5, byte_offset: usize, value: u64) LoggedConfig.Access {
        return .{ .operation = operation, .sbdf = sbdf(device), .offset = byte_offset, .value = value };
    }

    fn write(operation: LoggedConfig.Operation, device: u5, byte_offset: usize, value: u64) LoggedConfig.Access {
        return .{ .operation = operation, .sbdf = sbdf(device), .offset = byte_offset, .value = value };
    }

    fn expectBridgeBarWindowLog(backend: *const LoggedConfig) !void {
        try expectLog(backend, &.{
            read(.read8, 0, offset.type, 0x01),
            read(.read16, 0, offset.command, command_all),
            read(.read32, 0, offset.bar0, 0),
            read(.read8, 0, offset.io_base_lo, 0),
            read(.read8, 0, offset.io_limit_lo, 0),
            read(.read16, 0, offset.io_base_hi, 0xAAAA),
            read(.read16, 0, offset.io_limit_hi, 0xBBBB),
            read(.read16, 0, offset.mem_base, 0),
            read(.read16, 0, offset.mem_limit, 0),
            read(.read16, 0, offset.prefetch_base_lo, 0),
            read(.read16, 0, offset.prefetch_limit_lo, 0),
            read(.read32, 0, offset.prefetch_base_hi, 0xCCCC_CCCC),
            read(.read32, 0, offset.prefetch_limit_hi, 0xDDDD_DDDD),
            write(.write16, 0, offset.command, 0xFFFC),
            read(.read16, 0, offset.command, 0xFFFC),
            write(.write32, 0, offset.bar0, 0x8000_0000),
            read(.read32, 0, offset.bar0, 0x8000_0000),
            write(.write8, 0, offset.io_base_lo, 0x20),
            read(.read8, 0, offset.io_base_lo, 0x20),
            write(.write8, 0, offset.io_limit_lo, 0x20),
            read(.read8, 0, offset.io_limit_lo, 0x20),
            write(.write16, 0, offset.io_base_hi, 0),
            read(.read16, 0, offset.io_base_hi, 0),
            write(.write16, 0, offset.io_limit_hi, 0),
            read(.read16, 0, offset.io_limit_hi, 0),
            write(.write16, 0, offset.mem_base, 0x8000),
            read(.read16, 0, offset.mem_base, 0x8000),
            write(.write16, 0, offset.mem_limit, 0x8000),
            read(.read16, 0, offset.mem_limit, 0x8000),
            write(.write16, 0, offset.prefetch_base_lo, 0x9000),
            read(.read16, 0, offset.prefetch_base_lo, 0x9000),
            write(.write16, 0, offset.prefetch_limit_lo, 0x9000),
            read(.read16, 0, offset.prefetch_limit_lo, 0x9000),
            write(.write32, 0, offset.prefetch_base_hi, 0),
            read(.read32, 0, offset.prefetch_base_hi, 0),
            write(.write32, 0, offset.prefetch_limit_hi, 0),
            read(.read32, 0, offset.prefetch_limit_hi, 0),
            write(.write16, 0, offset.command, command_all),
            read(.read16, 0, offset.command, command_all),
        });
    }

    fn expectLog(backend: *const LoggedConfig, expected: []const LoggedConfig.Access) !void {
        try testing.expectEqual(expected.len, backend.log_len);

        for (expected, backend.log[0..backend.log_len]) |want, got| try expectAccess(want, got);
    }

    fn expectLogTail(backend: *const LoggedConfig, expected: []const LoggedConfig.Access) !void {
        try testing.expect(backend.log_len >= expected.len);

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
        for (backend.log[0..backend.log_len]) |access| try testing.expect(!access.sbdf.eql(target));
    }

    fn expectAccess(expected: LoggedConfig.Access, actual: LoggedConfig.Access) !void {
        try testing.expectEqual(expected.operation, actual.operation);
        try testing.expect(expected.sbdf.eql(actual.sbdf));
        try testing.expectEqual(expected.offset, actual.offset);
        try testing.expectEqual(expected.value, actual.value);
    }

    fn load16(bytes: []const u8, byte_offset: usize) u16 {
        return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
    }

    fn load32(bytes: []const u8, byte_offset: usize) u32 {
        return std.mem.readInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], .little);
    }

    fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
    }

    fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], value, .little);
    }
};
