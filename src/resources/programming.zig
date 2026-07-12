//! Resource assignment programming. Spec: docs/specs/resources/programming.md.

const std = @import("std");

const assignment = @import("assignment.zig");
const bar = @import("../bar.zig");
const bridge = @import("bridge.zig");
const config = @import("../config.zig");
const model = @import("model.zig");
const type0 = @import("../header/type0.zig");
const type1 = @import("../header/type1.zig");

pub const Assignment = model.Assignment;
pub const Error = error{
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};
pub const Plan = assignment.Plan;

const Function = config.Function;
const HeaderKind = config.HeaderKind;
const Kind = model.Kind;
const Source = model.Source;

const offset = struct {
    const command: usize = 0x04;

    const bars: usize = 0x10;
    const type0_rom: usize = 0x30;
    const type1_rom: usize = 0x38;

    const io_base: usize = 0x1C;
    const io_limit: usize = 0x1D;
    const io_base_upper: usize = 0x30;
    const io_limit_upper: usize = 0x32;

    const memory_base: usize = 0x20;
    const memory_limit: usize = 0x22;

    const prefetchable_base: usize = 0x24;
    const prefetchable_limit: usize = 0x26;
    const prefetchable_base_upper: usize = 0x28;
    const prefetchable_limit_upper: usize = 0x2C;
};

const command_decode_mask: u16 = 0x0003;
const command_compare_mask: u16 = 0x0547;
const max_records: usize = bar.max_entries * 2 + 1 + 10;

/// Commits assignment-plan base and bridge-window registers to config space.
/// Allocation: none. Waiting: none. Bounds: one pass, fixed stack state.
/// Ordering: per function, save, disable decode, write, restore decode.
/// Errors: rollback failure returns `ProgrammingPartial`; state may be partial.
pub fn commit(plan: Plan) Error!void {
    var driver = Commit.init(plan.assignments);
    try driver.apply();
}

const Commit = struct {
    assignments: []const Assignment,
    next_index: usize = 0,
    function: Function = undefined,
    group: []const Assignment = &.{},
    header_kind: HeaderKind = undefined,
    save_frame: CommitSave = .{},
    journal: CommitJournal = .{},

    const WriteCommand = struct {
        value: u16,
        access_error: Error,
        mismatch_error: Error,
    };

    const Write8 = struct {
        offset: usize,
        value: u8,
        saved: u8,
    };

    const Write16 = struct {
        offset: usize,
        value: u16,
        saved: u16,
    };

    const Write32 = struct {
        offset: usize,
        value: u32,
        saved: u32,
    };

    fn init(assignments: []const Assignment) Commit {
        return .{ .assignments = assignments };
    }

    fn apply(self: *Commit) Error!void {
        while (self.nextGroup()) {
            try self.applyGroup();
        }
    }

    fn nextGroup(self: *Commit) bool {
        if (self.next_index == self.assignments.len) return false;

        const start = self.next_index;
        const function = self.assignments[start].function();
        var end = start + 1;

        while (end < self.assignments.len and function.eq(
            self.assignments[end].function(),
        )) : (end += 1) {}

        self.function = function;
        self.group = self.assignments[start..end];
        self.header_kind = undefined;
        self.save_frame.reset();
        self.journal.reset();
        self.next_index = end;

        return true;
    }

    fn applyGroup(self: *Commit) Error!void {
        self.header_kind = self.function.headerKind() catch return error.ProgrammingWriteFailed;
        self.assertShape();

        try self.save();
        try self.disableDecode();

        self.writePhase() catch |err| return self.rollback(err);
        self.restoreDecode() catch |err| return self.rollback(err);
    }

    fn assertShape(self: *const Commit) void {
        var seen_bars: [bar.max_entries]bool = @splat(false);
        var seen_windows = WindowSet{};
        var seen_rom = false;

        for (self.group) |item| {
            std.debug.assert(self.function.eq(item.function()));

            switch (item.requirement.source) {
                .endpoint_bar => |source| {
                    std.debug.assert(source.index < self.barCount());
                    std.debug.assert(!seen_bars[source.index]);

                    seen_bars[source.index] = true;
                },
                .endpoint_expansion_rom => {
                    std.debug.assert(!seen_rom);
                    seen_rom = true;
                },
                .bridge_window => |source| {
                    std.debug.assert(self.header_kind == .type1);
                    seen_windows.mark(source.window);
                },
            }
        }
    }

    fn save(self: *Commit) Error!void {
        try self.save_frame.captureCommand(self.function);
        try self.saveBars();
        try self.saveRom();
        try self.saveWindows();
    }

    fn saveBars(self: *Commit) Error!void {
        var index: usize = 0;
        while (index < self.barCount()) : (index += 1) {
            const item = self.barAssignment(index) orelse continue;
            const base = barOffset(index);
            try self.save_frame.capture32(self.function, base);

            if (is64(item.requirement.kind)) {
                try self.save_frame.capture32(self.function, base + 4);
            }
        }
    }

    fn saveRom(self: *Commit) Error!void {
        if (self.romAssignment()) |_| {
            try self.save_frame.capture32(self.function, self.romOffset());
        }
    }

    fn saveWindows(self: *Commit) Error!void {
        if (self.windowAssignment(.io)) |item| {
            _ = bridge.encodeWindow(item) catch return error.ProgrammingWriteFailed;
            try self.saveIoWindow();
        }

        if (self.windowAssignment(.memory)) |_| {
            try self.save_frame.capture16(self.function, offset.memory_base);
            try self.save_frame.capture16(self.function, offset.memory_limit);
        }

        if (self.windowAssignment(.prefetchable_memory)) |item| {
            const encoded = bridge.encodeWindow(item) catch return error.ProgrammingWriteFailed;
            try self.savePrefetchableWindow(encoded);
        }
    }

    fn saveIoWindow(self: *Commit) Error!void {
        try self.save_frame.capture8(self.function, offset.io_base);
        try self.save_frame.capture8(self.function, offset.io_limit);
        try self.save_frame.capture16(self.function, offset.io_base_upper);
        try self.save_frame.capture16(self.function, offset.io_limit_upper);
    }

    fn savePrefetchableWindow(self: *Commit, encoded: bridge.EncodedWindow) Error!void {
        switch (encoded) {
            .prefetchable_memory_32, .prefetchable_memory_64 => {
                try self.save_frame.capture16(self.function, offset.prefetchable_base);
                try self.save_frame.capture16(self.function, offset.prefetchable_limit);
                try self.save_frame.capture32(self.function, offset.prefetchable_base_upper);
                try self.save_frame.capture32(self.function, offset.prefetchable_limit_upper);
            },
            else => unreachable,
        }
    }

    fn disableDecode(self: *Commit) Error!void {
        const disabled = self.save_frame.saved_command & ~command_decode_mask;
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
        while (index < self.barCount()) : (index += 1) {
            const item = self.barAssignment(index) orelse continue;
            const base = barOffset(index);
            const saved_low = self.save_frame.saved32(base);
            const low_mask: u32 = if (saved_low & 0x1 == 0) 0x0000_000F else 0x0000_0003;
            const preserved_type = saved_low & low_mask;
            const encoded_base = @as(u32, @truncate(item.base)) & ~low_mask;
            const new_low = preserved_type | encoded_base;

            try self.writeReadback32(.{
                .offset = base,
                .value = new_low,
                .saved = saved_low,
            });

            if (is64(item.requirement.kind)) try self.writeBarHigh(base + 4, item.base);
        }
    }

    fn writeBarHigh(self: *Commit, high_offset: usize, base: u64) Error!void {
        const saved_high = self.save_frame.saved32(high_offset);
        const new_high: u32 = @truncate(base >> 32);
        try self.writeReadback32(.{
            .offset = high_offset,
            .value = new_high,
            .saved = saved_high,
        });
    }

    fn writeRom(self: *Commit) Error!void {
        const item = self.romAssignment() orelse return;

        const rom_offset = self.romOffset();
        const saved_rom = self.save_frame.saved32(rom_offset);
        const preserved_enable = saved_rom & 0x0000_0001;
        const encoded_base = @as(u32, @truncate(item.base)) & 0xFFFF_F800;
        const new_rom = preserved_enable | encoded_base;

        try self.writeReadback32(.{
            .offset = rom_offset,
            .value = new_rom,
            .saved = saved_rom,
        });
    }

    fn writeWindows(self: *Commit) Error!void {
        if (self.windowAssignment(.io)) |item| {
            const encoded = bridge.encodeWindow(item) catch return error.ProgrammingWriteFailed;
            try self.writeIoWindow(encoded.io);
        }

        if (self.windowAssignment(.memory)) |item| {
            const encoded = bridge.encodeWindow(item) catch return error.ProgrammingWriteFailed;
            try self.writeMemoryWindow(encoded.memory);
        }

        if (self.windowAssignment(.prefetchable_memory)) |item| {
            const encoded = bridge.encodeWindow(item) catch return error.ProgrammingWriteFailed;
            try self.writePrefetchableWindow(encoded);
        }
    }

    fn writeIoWindow(self: *Commit, io: bridge.EncodedWindow.IoEncoding) Error!void {
        try self.writeReadback8(.{
            .offset = offset.io_base,
            .value = io.base_lo,
            .saved = self.save_frame.saved8(offset.io_base),
        });
        try self.writeReadback8(.{
            .offset = offset.io_limit,
            .value = io.limit_lo,
            .saved = self.save_frame.saved8(offset.io_limit),
        });
        try self.writeReadback16(.{
            .offset = offset.io_base_upper,
            .value = io.base_upper,
            .saved = self.save_frame.saved16(offset.io_base_upper),
        });
        try self.writeReadback16(.{
            .offset = offset.io_limit_upper,
            .value = io.limit_upper,
            .saved = self.save_frame.saved16(offset.io_limit_upper),
        });
    }

    fn writeMemoryWindow(self: *Commit, memory: bridge.EncodedWindow.MemoryEncoding) Error!void {
        try self.writeReadback16(.{
            .offset = offset.memory_base,
            .value = memory.base,
            .saved = self.save_frame.saved16(offset.memory_base),
        });
        try self.writeReadback16(.{
            .offset = offset.memory_limit,
            .value = memory.limit,
            .saved = self.save_frame.saved16(offset.memory_limit),
        });
    }

    fn writePrefetchableWindow(self: *Commit, encoded: bridge.EncodedWindow) Error!void {
        switch (encoded) {
            .prefetchable_memory_32 => |prefetchable| {
                const saved_base = self.save_frame.saved16(offset.prefetchable_base);
                const saved_limit = self.save_frame.saved16(offset.prefetchable_limit);
                const saved_base_upper = self.save_frame.saved32(offset.prefetchable_base_upper);
                const saved_limit_upper = self.save_frame.saved32(offset.prefetchable_limit_upper);

                try self.writeReadback16(.{
                    .offset = offset.prefetchable_base,
                    .value = prefetchable.base_lo,
                    .saved = saved_base,
                });
                try self.writeReadback16(.{
                    .offset = offset.prefetchable_limit,
                    .value = prefetchable.limit_lo,
                    .saved = saved_limit,
                });
                try self.writeReadback32(.{
                    .offset = offset.prefetchable_base_upper,
                    .value = 0,
                    .saved = saved_base_upper,
                });
                try self.writeReadback32(.{
                    .offset = offset.prefetchable_limit_upper,
                    .value = 0,
                    .saved = saved_limit_upper,
                });
            },
            .prefetchable_memory_64 => |prefetchable| {
                const saved_base = self.save_frame.saved16(offset.prefetchable_base);
                const saved_limit = self.save_frame.saved16(offset.prefetchable_limit);
                const saved_base_upper = self.save_frame.saved32(offset.prefetchable_base_upper);
                const saved_limit_upper = self.save_frame.saved32(offset.prefetchable_limit_upper);

                try self.writeReadback16(.{
                    .offset = offset.prefetchable_base,
                    .value = prefetchable.base_lo,
                    .saved = saved_base,
                });
                try self.writeReadback16(.{
                    .offset = offset.prefetchable_limit,
                    .value = prefetchable.limit_lo,
                    .saved = saved_limit,
                });
                try self.writeReadback32(.{
                    .offset = offset.prefetchable_base_upper,
                    .value = prefetchable.base_upper,
                    .saved = saved_base_upper,
                });
                try self.writeReadback32(.{
                    .offset = offset.prefetchable_limit_upper,
                    .value = prefetchable.limit_upper,
                    .saved = saved_limit_upper,
                });
            },
            else => unreachable,
        }
    }

    fn rollback(self: *Commit, original: Error) Error {
        self.journal.rollback(self.function) catch return error.ProgrammingPartial;
        self.restoreCommandPartial() catch return error.ProgrammingPartial;
        return original;
    }

    fn restoreDecode(self: *Commit) Error!void {
        try self.writeReadbackCommand(.{
            .value = self.save_frame.saved_command,
            .access_error = error.ProgrammingWriteFailed,
            .mismatch_error = error.ProgrammingReadbackMismatch,
        });
    }

    fn restoreCommandPartial(self: *Commit) Error!void {
        try self.writeReadbackCommand(.{
            .value = self.save_frame.saved_command,
            .access_error = error.ProgrammingPartial,
            .mismatch_error = error.ProgrammingPartial,
        });
    }

    fn writeReadbackCommand(self: *Commit, write: WriteCommand) Error!void {
        self.function.write16(offset.command, write.value) catch
            return write.access_error;

        const readback = self.function.read16(offset.command) catch
            return write.access_error;

        const current_decode = readback & command_compare_mask;
        const requested_decode = write.value & command_compare_mask;
        if (current_decode != requested_decode) return write.mismatch_error;
    }

    fn writeReadback8(self: *Commit, write: Write8) Error!void {
        self.function.write8(write.offset, write.value) catch
            return error.ProgrammingWriteFailed;

        self.journal.push(.{ .byte = .{ .offset = write.offset, .value = write.saved } });

        const readback = self.function.read8(write.offset) catch
            return error.ProgrammingWriteFailed;
        if (readback != write.value) return error.ProgrammingReadbackMismatch;
    }

    fn writeReadback16(self: *Commit, write: Write16) Error!void {
        self.function.write16(write.offset, write.value) catch
            return error.ProgrammingWriteFailed;

        self.journal.push(.{ .word16 = .{ .offset = write.offset, .value = write.saved } });

        const readback = self.function.read16(write.offset) catch
            return error.ProgrammingWriteFailed;
        if (readback != write.value) return error.ProgrammingReadbackMismatch;
    }

    fn writeReadback32(self: *Commit, write: Write32) Error!void {
        self.function.write32(write.offset, write.value) catch
            return error.ProgrammingWriteFailed;

        self.journal.push(.{ .word32 = .{ .offset = write.offset, .value = write.saved } });

        const readback = self.function.read32(write.offset) catch
            return error.ProgrammingWriteFailed;
        if (readback != write.value) return error.ProgrammingReadbackMismatch;
    }

    fn barAssignment(self: *const Commit, index: usize) ?Assignment {
        for (self.group) |item| {
            switch (item.requirement.source) {
                .endpoint_bar => |source| if (source.index == index) return item,
                else => {},
            }
        }

        return null;
    }

    fn romAssignment(self: *const Commit) ?Assignment {
        for (self.group) |item| {
            if (item.requirement.source == .endpoint_expansion_rom) return item;
        }

        return null;
    }

    fn windowAssignment(self: *const Commit, window: Source.BridgeWindow) ?Assignment {
        for (self.group) |item| {
            switch (item.requirement.source) {
                .bridge_window => |source| if (source.window == window) return item,
                else => {},
            }
        }

        return null;
    }

    fn barCount(self: *const Commit) usize {
        return switch (self.header_kind) {
            .type0 => type0.bar_count,
            .type1 => type1.bridge_bar_count,
        };
    }

    fn romOffset(self: *const Commit) usize {
        return switch (self.header_kind) {
            .type0 => offset.type0_rom,
            .type1 => offset.type1_rom,
        };
    }
};

const CommitSave = struct {
    saved_command: u16 = 0,
    records: [max_records]Record = undefined,
    len: usize = 0,

    fn reset(self: *CommitSave) void {
        self.saved_command = 0;
        self.len = 0;
    }

    fn captureCommand(self: *CommitSave, function: Function) Error!void {
        self.saved_command = function.read16(offset.command) catch
            return error.ProgrammingWriteFailed;
    }

    fn capture8(
        self: *CommitSave,
        function: Function,
        record_offset: usize,
    ) Error!void {
        const value = function.read8(record_offset) catch
            return error.ProgrammingWriteFailed;

        self.insert(.{ .byte = .{ .offset = record_offset, .value = value } });
    }

    fn capture16(
        self: *CommitSave,
        function: Function,
        record_offset: usize,
    ) Error!void {
        const value = function.read16(record_offset) catch
            return error.ProgrammingWriteFailed;

        self.insert(.{ .word16 = .{ .offset = record_offset, .value = value } });
    }

    fn capture32(
        self: *CommitSave,
        function: Function,
        record_offset: usize,
    ) Error!void {
        const value = function.read32(record_offset) catch
            return error.ProgrammingWriteFailed;

        self.insert(.{ .word32 = .{ .offset = record_offset, .value = value } });
    }

    fn saved8(self: *const CommitSave, record_offset: usize) u8 {
        for (self.records[0..self.len]) |entry| {
            if (entry == .byte and entry.byte.offset == record_offset) {
                return entry.byte.value;
            }
        }

        unreachable;
    }

    fn saved16(self: *const CommitSave, record_offset: usize) u16 {
        for (self.records[0..self.len]) |entry| {
            if (entry == .word16 and entry.word16.offset == record_offset) {
                return entry.word16.value;
            }
        }

        unreachable;
    }

    fn saved32(self: *const CommitSave, record_offset: usize) u32 {
        for (self.records[0..self.len]) |entry| {
            if (entry == .word32 and entry.word32.offset == record_offset) {
                return entry.word32.value;
            }
        }

        unreachable;
    }

    fn insert(self: *CommitSave, record: Record) void {
        std.debug.assert(self.len < self.records.len);
        std.debug.assert(!self.contains(record));

        self.records[self.len] = record;
        self.len += 1;
    }

    fn contains(self: *const CommitSave, record: Record) bool {
        for (self.records[0..self.len]) |entry| {
            if (entry.matchesLocation(.{ .other = record })) return true;
        }

        return false;
    }
};

const CommitJournal = struct {
    records: [max_records]Record = undefined,
    len: usize = 0,

    fn reset(self: *CommitJournal) void {
        self.len = 0;
    }

    fn rollback(self: *CommitJournal, function: Function) Error!void {
        while (self.len > 0) {
            self.len -= 1;
            try self.records[self.len].restorePartial(function);
        }
    }

    fn push(self: *CommitJournal, record: Record) void {
        std.debug.assert(self.len < self.records.len);
        self.records[self.len] = record;
        self.len += 1;
    }
};

const WindowSet = struct {
    io: bool = false,
    memory: bool = false,
    prefetchable_memory: bool = false,

    fn mark(self: *WindowSet, window: Source.BridgeWindow) void {
        const slot = switch (window) {
            .io => &self.io,
            .memory => &self.memory,
            .prefetchable_memory => &self.prefetchable_memory,
        };
        std.debug.assert(!slot.*);
        slot.* = true;
    }
};

const Record = union(enum) {
    byte: struct {
        offset: usize,
        value: u8,
    },
    word16: struct {
        offset: usize,
        value: u16,
    },
    word32: struct {
        offset: usize,
        value: u32,
    },

    fn matchesLocation(self: Record, options: struct { other: Record }) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(options.other)) return false;
        return switch (self) {
            .byte => |entry| entry.offset == options.other.byte.offset,
            .word16 => |entry| entry.offset == options.other.word16.offset,
            .word32 => |entry| entry.offset == options.other.word32.offset,
        };
    }

    fn restorePartial(self: Record, function: Function) Error!void {
        switch (self) {
            .byte => |entry| {
                function.write8(entry.offset, entry.value) catch
                    return error.ProgrammingPartial;

                const readback = function.read8(entry.offset) catch
                    return error.ProgrammingPartial;

                if (readback != entry.value) return error.ProgrammingPartial;
            },
            .word16 => |entry| {
                function.write16(entry.offset, entry.value) catch
                    return error.ProgrammingPartial;

                const readback = function.read16(entry.offset) catch
                    return error.ProgrammingPartial;

                if (readback != entry.value) return error.ProgrammingPartial;
            },
            .word32 => |entry| {
                function.write32(entry.offset, entry.value) catch
                    return error.ProgrammingPartial;

                const readback = function.read32(entry.offset) catch
                    return error.ProgrammingPartial;

                if (readback != entry.value) return error.ProgrammingPartial;
            },
        }
    }
};

fn barOffset(index: usize) usize {
    std.debug.assert(index < bar.max_entries);
    return offset.bars + 4 * index;
}

fn is64(kind: Kind) bool {
    return kind == .mmio64 or kind == .mmio64_pref;
}
