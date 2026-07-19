//! BAR decode and sizing. Spec: docs/specs/bar.md.

const std = @import("std");

const config = @import("config.zig");
const header = @import("header.zig");

const ConfigSpace = config.ConfigSpace;
const Function = config.Function;

/// Upper bound on BAR entries for every supported header layout.
pub const max_entries: usize = 6;

/// Header layout that determines how many BAR slots a function exposes.
pub const Layout = enum {
    type0,
    type1,
};

/// Bit encodings in a BAR low dword.
pub const raw = struct {
    pub const io_space: u32 = 1 << 0;
    pub const io_reserved: u32 = 1 << 1;
    pub const memory_type_mask: u32 = 0b11 << 1;
    pub const memory_type_32: u32 = 0b00 << 1;
    pub const memory_type_64: u32 = 0b10 << 1;
    pub const prefetchable: u32 = 1 << 3;
    pub const io_address_mask: u32 = 0xFFFF_FFFC;
    pub const memory_address_mask: u32 = 0xFFFF_FFF0;
};

/// BAR decode and sizing errors.
pub const Error = ConfigSpace.Error || error{
    MalformedBar,
    ProgrammingPartial,
    StorageExhausted,
};

/// Decoded BAR kind.
pub const Kind = union(enum) {
    none,
    io: Io,
    memory: Memory,

    pub const Io = struct {
        base: u32,
        size: u32,
    };

    pub const Memory = struct {
        base: u64,
        size: u64,
        width: Width,
        prefetchable: bool,
    };

    pub const Width = enum {
        bits_32,
        bits_64,
    };
};

/// One decoded BAR low slot.
pub const Entry = struct {
    index: usize,
    slot_count: usize,
    kind: Kind,
};

/// Borrowed reference to a BAR low slot for downstream programming.
pub const BarRef = struct {
    function: Function,
    index: usize,

    /// Construct a pure BAR location handle; performs no config I/O.
    pub fn init(function: Function, index: usize) BarRef {
        std.debug.assert(index < max_entries);
        return .{ .function = function, .index = index };
    }
};

/// Borrowed BAR view over one config-space function.
pub const View = struct {
    function: Function,
    layout: Layout,

    /// Construct a view without config I/O.
    pub fn init(function: Function, layout: Layout) View {
        return .{ .function = function, .layout = layout };
    }

    /// Effects: reads header type and constructs the matching BAR view when supported.
    pub fn detect(function: Function) ConfigSpace.Error!?View {
        const header_type = try header.common.View.init(function).headerTypeByte();
        return switch (header_type & 0x7F) {
            0x00 => View.init(function, .type0),
            0x01 => View.init(function, .type1),
            else => null,
        };
    }

    /// Return the BAR slot count for this view's header layout.
    pub fn count(self: View) usize {
        return barCount(self.layout);
    }

    /// Returns: iterator over low slots in ascending order; high halves are skipped.
    pub fn iterator(self: View) Iterator {
        return .{ .view = self, .index = 0 };
    }

    /// Effects: reads one low BAR dword and, for 64-bit BARs, one high dword.
    /// Requirements: `index` names a low slot; high-half access is a programmer error.
    /// Errors: propagates config reads and reports `MalformedBar` for invalid encodings.
    pub fn get(self: View, index: usize) Error!Entry {
        std.debug.assert(index < self.count());
        try self.assertLowSlot(index);

        const low = try self.readBar(index);
        const bar = RawBar{
            .low = low,
            .high = if (isMemory64Low(low)) try self.readBar(index + 1) else 0,
        };

        return decodeEntry(self.layout, index, bar);
    }

    /// Effects: disables the matching decode bit, writes all-ones, reads size, and restores.
    /// Requirements: caller provides exclusive access to this function while probing.
    /// Errors: probe+restore failure returns the probe error; restore-only failure is `ProgrammingPartial`.
    pub fn size(self: View, index: usize) Error!Entry {
        std.debug.assert(index < self.count());
        try self.assertLowSlot(index);

        const common = header.common.View.init(self.function);
        const command_before = try common.command();
        var probe = try SizingProbe.init(self, index, command_before);

        const attempt: ProbeOutcome = attempt: {
            common.setCommand(probe.command) catch |err| break :attempt .{ .failed = err };
            break :attempt probe.size();
        };

        var restore_failed = probe.restore();
        common.setCommand(command_before) catch {
            restore_failed = true;
        };

        return probe.complete(attempt, restore_failed);
    }

    /// Effects: disables IO and memory decode once, probes every BAR, then restores.
    /// Requirements: caller provides `scratch.len >= count()` and exclusive function access.
    /// Errors: probe+restore failure returns the probe error; restore-only failure is `ProgrammingPartial`.
    pub fn sizeAll(self: View, scratch: []Entry) Error![]Entry {
        if (scratch.len < self.count()) return error.StorageExhausted;

        const common = header.common.View.init(self.function);
        const command_before = try common.command();
        var command_disabled = command_before;
        command_disabled.io_space = false;
        command_disabled.memory_space = false;

        try common.setCommand(command_disabled);

        var index: usize = 0;
        var out_len: usize = 0;
        const batch: BatchOutcome = batch: {
            while (index < self.count()) {
                var probe = SizingProbe.init(self, index, command_disabled) catch |err| {
                    break :batch .{ .failed = err };
                };
                const attempt = probe.size();
                const restore_failed = probe.restore();
                const entry = probe.complete(attempt, restore_failed) catch |err| {
                    break :batch .{ .failed = err };
                };

                scratch[out_len] = entry;
                out_len += 1;
                index += entry.slot_count;
            }

            break :batch .success;
        };

        common.setCommand(command_before) catch {
            switch (batch) {
                .success => return error.ProgrammingPartial,
                .failed => {},
            }
        };

        switch (batch) {
            .failed => |err| return err,
            .success => return scratch[0..out_len],
        }
    }

    fn assertLowSlot(self: View, index: usize) ConfigSpace.Error!void {
        if (index == 0) return;

        const previous_low = try self.readBar(index - 1);
        std.debug.assert(!isMemory64Low(previous_low));
    }

    fn readBar(self: View, index: usize) ConfigSpace.Error!u32 {
        return self.function.read32(barOffset(index));
    }

    fn writeBar(self: View, index: usize, value: u32) ConfigSpace.Error!void {
        return self.function.write32(barOffset(index), value);
    }
};

/// Iterator over live BAR decode results.
pub const Iterator = struct {
    view: View,
    index: usize,

    /// Effects: reads config space for the next low slot and advances by `slot_count`.
    pub fn next(self: *Iterator) Error!?Entry {
        if (self.index >= self.view.count()) return null;

        const entry = try self.view.get(self.index);
        self.index += entry.slot_count;
        return entry;
    }
};

const RawBar = struct {
    low: u32 = 0,
    high: u32 = 0,
};

const ProbeOutcome = union(enum) {
    failed: Error,
    probed: RawBar,
};

const BatchOutcome = union(enum) {
    failed: Error,
    success,
};

const WrittenSlots = struct {
    low: bool = false,
    high: bool = false,
};

const SizingProbe = struct {
    view: View,
    index: usize,
    saved_low: u32,
    saved_high: u32 = 0,
    slot_count: usize,
    space: Space,
    command: header.Command,
    written: WrittenSlots = .{},

    const Space = enum {
        io,
        memory,
    };

    fn init(view: View, index: usize, command: header.Command) Error!SizingProbe {
        std.debug.assert(index < view.count());

        const saved_low = try view.readBar(index);

        if (saved_low & raw.io_space != 0) {
            if (saved_low & raw.io_reserved != 0) return error.MalformedBar;
            return SizingProbe.initIo(view, index, saved_low, command);
        }

        return switch (saved_low & raw.memory_type_mask) {
            raw.memory_type_32 => SizingProbe.initMemory32(view, index, saved_low, command),
            raw.memory_type_64 => blk: {
                if (index + 1 >= view.count()) return error.MalformedBar;

                const saved_high = try view.readBar(index + 1);
                if (saved_high & 0xF != 0) return error.MalformedBar;

                const saved = RawBar{ .low = saved_low, .high = saved_high };
                break :blk SizingProbe.initMemory64(view, index, saved, command);
            },
            else => error.MalformedBar,
        };
    }

    fn initIo(view: View, index: usize, saved_low: u32, command: header.Command) SizingProbe {
        var probe_command = command;
        probe_command.io_space = false;

        return .{
            .view = view,
            .index = index,
            .saved_low = saved_low,
            .slot_count = 1,
            .space = .io,
            .command = probe_command,
        };
    }

    fn initMemory32(view: View, index: usize, saved_low: u32, command: header.Command) SizingProbe {
        var probe_command = command;
        probe_command.memory_space = false;

        return .{
            .view = view,
            .index = index,
            .saved_low = saved_low,
            .slot_count = 1,
            .space = .memory,
            .command = probe_command,
        };
    }

    fn initMemory64(view: View, index: usize, saved: RawBar, command: header.Command) SizingProbe {
        var probe_command = command;
        probe_command.memory_space = false;

        return .{
            .view = view,
            .index = index,
            .saved_low = saved.low,
            .saved_high = saved.high,
            .slot_count = 2,
            .space = .memory,
            .command = probe_command,
        };
    }

    fn size(self: *SizingProbe) ProbeOutcome {
        self.assertDecodeDisabled();

        self.view.writeBar(self.index, std.math.maxInt(u32)) catch |err| return .{ .failed = err };
        self.written.low = true;

        if (self.slot_count == 2) {
            self.view.writeBar(self.index + 1, std.math.maxInt(u32)) catch |err| {
                return .{ .failed = err };
            };
            self.written.high = true;
        }

        const low = self.view.readBar(self.index) catch |err| return .{ .failed = err };
        const high = if (self.slot_count == 2)
            self.view.readBar(self.index + 1) catch |err| return .{ .failed = err }
        else
            0;

        return .{ .probed = .{ .low = low, .high = high } };
    }

    fn restore(self: *SizingProbe) bool {
        var failed = false;

        if (self.written.low) self.view.writeBar(self.index, self.saved_low) catch {
            failed = true;
        };

        if (self.written.high) self.view.writeBar(self.index + 1, self.saved_high) catch {
            failed = true;
        };

        return failed;
    }

    fn complete(self: SizingProbe, attempt: ProbeOutcome, restore_failed: bool) Error!Entry {
        switch (attempt) {
            .failed => |err| return err,
            .probed => |probed| {
                if (restore_failed) return error.ProgrammingPartial;
                return self.entry(probed);
            },
        }
    }

    fn assertDecodeDisabled(self: SizingProbe) void {
        switch (self.space) {
            .io => std.debug.assert(!self.command.io_space),
            .memory => std.debug.assert(!self.command.memory_space),
        }
    }

    fn entry(self: SizingProbe, probed: RawBar) Entry {
        if (probed.low == 0) return .{ .index = self.index, .slot_count = 1, .kind = .none };

        return switch (self.space) {
            .io => blk: {
                const mask = probed.low & raw.io_address_mask;
                if (mask == 0) break :blk .{ .index = self.index, .slot_count = 1, .kind = .none };

                break :blk .{
                    .index = self.index,
                    .slot_count = 1,
                    .kind = .{ .io = .{
                        .base = ioBase(self.saved_low),
                        .size = ~mask +% 1,
                    } },
                };
            },
            .memory => if (self.slot_count == 2) .{
                .index = self.index,
                .slot_count = 2,
                .kind = .{ .memory = .{
                    .base = memoryBase64(.{ .low = self.saved_low, .high = self.saved_high }),
                    .size = memorySize64(probed),
                    .width = .bits_64,
                    .prefetchable = isPrefetchable(self.saved_low),
                } },
            } else .{
                .index = self.index,
                .slot_count = 1,
                .kind = .{ .memory = .{
                    .base = memoryBase32(self.saved_low),
                    .size = memorySize32(probed.low),
                    .width = .bits_32,
                    .prefetchable = isPrefetchable(self.saved_low),
                } },
            },
        };
    }
};

fn barCount(layout: Layout) usize {
    return switch (layout) {
        .type0 => header.type0.bar_count,
        .type1 => header.type1.bridge_bar_count,
    };
}

fn barOffset(index: usize) usize {
    return header.type0.register.bar_base + header.type0.register.bar_stride * index;
}

fn isMemory64Low(low: u32) bool {
    const implemented = low != 0;
    const memory = low & raw.io_space == 0;
    const width_64 = low & raw.memory_type_mask == raw.memory_type_64;
    return implemented and memory and width_64;
}

fn decodeEntry(layout: Layout, index: usize, bar: RawBar) Error!Entry {
    if (bar.low == 0) return .{ .index = index, .slot_count = 1, .kind = .none };

    if (bar.low & raw.io_space != 0) {
        if (bar.low & raw.io_reserved != 0) return error.MalformedBar;
        return .{
            .index = index,
            .slot_count = 1,
            .kind = .{ .io = .{ .base = ioBase(bar.low), .size = 0 } },
        };
    }

    return switch (bar.low & raw.memory_type_mask) {
        raw.memory_type_32 => .{
            .index = index,
            .slot_count = 1,
            .kind = .{ .memory = .{
                .base = memoryBase32(bar.low),
                .size = 0,
                .width = .bits_32,
                .prefetchable = isPrefetchable(bar.low),
            } },
        },
        raw.memory_type_64 => blk: {
            if (index + 1 >= barCount(layout)) return error.MalformedBar;
            if (bar.high & 0xF != 0) return error.MalformedBar;

            break :blk .{
                .index = index,
                .slot_count = 2,
                .kind = .{ .memory = .{
                    .base = memoryBase64(bar),
                    .size = 0,
                    .width = .bits_64,
                    .prefetchable = isPrefetchable(bar.low),
                } },
            };
        },
        else => error.MalformedBar,
    };
}

fn ioBase(low: u32) u32 {
    return low & raw.io_address_mask;
}

fn memoryBase32(low: u32) u64 {
    return @as(u64, low & raw.memory_address_mask);
}

fn memoryBase64(bar: RawBar) u64 {
    const low_base = memoryBase32(bar.low);
    const high_base = @as(u64, bar.high) << 32;
    return high_base | low_base;
}

fn memorySize32(probed_low: u32) u64 {
    const mask = probed_low & raw.memory_address_mask;
    return @as(u64, ~mask +% 1);
}

fn memorySize64(probed: RawBar) u64 {
    const low_mask = @as(u64, probed.low & raw.memory_address_mask);
    const high_mask = @as(u64, probed.high) << 32;
    const mask = high_mask | low_mask;
    return ~mask +% 1;
}

fn isPrefetchable(low: u32) bool {
    return low & raw.prefetchable != 0;
}

comptime {
    std.debug.assert(max_entries == header.type0.bar_count);
    std.debug.assert(max_entries >= header.type1.bridge_bar_count);
}
