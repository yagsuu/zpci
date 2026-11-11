//! BAR decoding and sizing.

const std = @import("std");

const stdx = @import("stdx");
const pci_config = @import("config");
const core = @import("core");

const IoRegister = core.bar.Io;
const MemoryRegister = core.bar.Memory;
const Memory64 = core.bar.Memory64;
const Space = core.bar.Space;

const ConfigSpace = pci_config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Function = pci_config.Function;
const Format = core.header.Format;
const Offset = core.Offset;
const HeaderType = core.header.Type;
const Command = core.header.Command.Word;

pub const Error = ConfigError || error{
    MalformedBar,
    ProgrammingPartial,
};

pub const Bar = struct {
    index: usize,
    type: Type,

    pub const Type = union(enum) {
        none,
        io: Io,
        memory: Memory,
    };

    pub const Io = struct {
        base: u32,
        size: ?u32 = null,
    };

    pub const Memory = struct {
        base: u64,
        size: ?u64 = null,
        width: Width,
        prefetchable: bool,

        pub const Width = enum {
            bits_32,
            bits_64,
        };
    };

    pub fn numSlots(self: Bar) usize {
        return switch (self.type) {
            .none, .io => 1,
            .memory => |memory| switch (memory.width) {
                .bits_32 => 1,
                .bits_64 => 2,
            },
        };
    }
};

pub const Ref = struct {
    function: Function,
    index: usize,

    pub fn from(function: Function, index: usize) Ref {
        std.debug.assert(index < core.header.type0.num_bar_slots);

        return .{
            .function = function,
            .index = index,
        };
    }
};

/// Borrowed BAR set for one config-space function.
pub const Bars = struct {
    function: Function,
    format: Format,

    pub const Result = stdx.collections.List.Static(Bar, core.header.type0.num_bar_slots);

    pub fn from(function: Function, format: Format) Bars {
        return .{
            .function = function,
            .format = format,
        };
    }

    pub fn tryFrom(function: Function) ConfigError!?Bars {
        const word = HeaderType.from(try function.typeByte());
        return switch (word.format) {
            0x00 => Bars.from(function, .type0),
            0x01 => Bars.from(function, .type1),
            else => null,
        };
    }

    pub fn numSlots(self: Bars) usize {
        return switch (self.format) {
            .type0 => core.header.type0.num_bar_slots,
            .type1 => core.header.type1.num_bar_slots,
        };
    }

    pub fn iterator(self: Bars) Iterator {
        return .{ .bars = self, .index = 0 };
    }

    pub fn decode(self: Bars, index: usize) Error!Bar {
        std.debug.assert(index < self.numSlots());

        const lo = try self.read(offset(index));
        const memory = MemoryRegister.from(lo);

        if (lo == 0) {
            return .{ .index = index, .type = .none };
        }

        const io = IoRegister.from(lo);
        if (io.space == .io) {
            if (io._rsvd_1) {
                return error.MalformedBar;
            }

            return .{
                .index = index,
                .type = .{ .io = .{ .base = io.base() } },
            };
        }

        return switch (memory.type) {
            .bits_32 => .{
                .index = index,
                .type = .{ .memory = .{
                    .base = memory.base(),
                    .width = .bits_32,
                    .prefetchable = memory.prefetchable,
                } },
            },
            .bits_64 => blk: {
                if (index + 1 >= self.numSlots()) {
                    return error.MalformedBar;
                }

                const hi = try self.read(offset(index + 1));

                break :blk .{
                    .index = index,
                    .type = .{ .memory = .{
                        .base = Memory64.from(lo, hi).base(),
                        .width = .bits_64,
                        .prefetchable = memory.prefetchable,
                    } },
                };
            },
            else => error.MalformedBar,
        };
    }

    pub fn probe(self: Bars, index: usize) Error!Bar {
        std.debug.assert(index < self.numSlots());

        const saved_cmd = try self.function.command();
        var sizing = try SizingProbe.tryFrom(self, index, saved_cmd);

        const attempt: Error!RawBar = attempt: {
            self.function.setCommand(sizing.command) catch |err| break :attempt err;
            break :attempt sizing.execute();
        };

        const restored = self.function.setCommand(saved_cmd) catch error.ProgrammingPartial;

        const raw = try attempt;
        try restored;

        return sizing.bar(raw);
    }

    pub fn probeAll(self: Bars) Error!Result {
        const saved_cmd = try self.function.command();

        var cmd = saved_cmd;
        cmd.io_enable = false;
        cmd.mem_enable = false;

        try self.function.setCommand(cmd);

        const attempt = self.probeBatch(cmd);
        const restored = self.function.setCommand(saved_cmd) catch error.ProgrammingPartial;

        const result = try attempt;
        try restored;
        return result;
    }

    fn probeBatch(self: Bars, command: Command) Error!Result {
        var result = Result.init();
        var index: usize = 0;

        while (index < self.numSlots()) {
            var sizing = try SizingProbe.tryFrom(self, index, command);
            const raw = try sizing.execute();
            const entry = sizing.bar(raw);

            result.appendAssumeCapacity(entry);
            index += entry.numSlots();
        }

        return result;
    }

    fn offset(index: usize) Offset(u32) {
        std.debug.assert(index <= core.header.type0.num_bar_slots);
        return Offset(u32).from(core.header.offsets.bar_base + core.bar.stride * index);
    }

    fn read(self: Bars, position: Offset(u32)) ConfigError!u32 {
        return self.function.read(position);
    }

    fn write(self: Bars, position: Offset(u32), value: u32) ConfigError!void {
        return self.function.write(position, value);
    }
};

pub const Iterator = struct {
    bars: Bars,
    index: usize,

    pub fn next(self: *Iterator) Error!?Bar {
        if (self.index >= self.bars.numSlots()) {
            return null;
        }

        const entry = try self.bars.decode(self.index);
        self.index += entry.numSlots();

        return entry;
    }
};

const RawBar = struct {
    lo: u32 = 0,
    hi: u32 = 0,
};

const SizingProbe = struct {
    bars: Bars,
    offset: struct {
        lo: Offset(u32),
        hi: ?Offset(u32) = null,
    },
    index: usize,
    saved: RawBar,
    space: Space,
    command: Command,
    written: u2 = 0,

    fn tryFrom(bars: Bars, index: usize, command: Command) Error!SizingProbe {
        std.debug.assert(index < bars.numSlots());

        const lo_offset = Bars.offset(index);
        const saved_lo = try bars.read(lo_offset);
        const io = IoRegister.from(saved_lo);

        var cmd = command;
        var hi_offset: ?Offset(u32) = null;
        var saved_hi: u32 = 0;

        if (io.space == .io) {
            if (io._rsvd_1) {
                return error.MalformedBar;
            }

            cmd.io_enable = false;
        } else {
            switch (MemoryRegister.from(saved_lo).type) {
                .bits_32 => {},
                .bits_64 => {
                    if (index + 1 >= bars.numSlots()) {
                        return error.MalformedBar;
                    }

                    hi_offset = Bars.offset(index + 1);
                    saved_hi = try bars.read(hi_offset.?);
                },
                else => return error.MalformedBar,
            }

            cmd.mem_enable = false;
        }

        return .{
            .bars = bars,
            .index = index,
            .offset = .{ .lo = lo_offset, .hi = hi_offset },
            .saved = .{ .lo = saved_lo, .hi = saved_hi },
            .space = io.space,
            .command = cmd,
        };
    }

    fn execute(self: *SizingProbe) Error!RawBar {
        const attempt = self.run();
        const restored = self.restore();

        const raw = try attempt;
        try restored;
        return raw;
    }

    fn run(self: *SizingProbe) ConfigError!RawBar {
        switch (self.space) {
            .io => std.debug.assert(!self.command.io_enable),
            .mem => std.debug.assert(!self.command.mem_enable),
        }

        try self.bars.write(self.offset.lo, std.math.maxInt(u32));
        self.written |= 0b01;

        if (self.offset.hi) |hi_offset| {
            try self.bars.write(hi_offset, std.math.maxInt(u32));
            self.written |= 0b10;
        }

        const lo = try self.bars.read(self.offset.lo);
        const hi = if (self.offset.hi) |hi_offset|
            try self.bars.read(hi_offset)
        else
            0;

        return .{ .lo = lo, .hi = hi };
    }

    fn restore(self: *SizingProbe) error{ProgrammingPartial}!void {
        var result: error{ProgrammingPartial}!void = {};

        if (self.written & 0b01 != 0) {
            self.bars.write(self.offset.lo, self.saved.lo) catch {
                result = error.ProgrammingPartial;
            };
        }

        if (self.written & 0b10 != 0) {
            self.bars.write(self.offset.hi.?, self.saved.hi) catch {
                result = error.ProgrammingPartial;
            };
        }

        return result;
    }

    fn bar(self: SizingProbe, probed: RawBar) Bar {
        if (probed.lo == 0) {
            return .{ .index = self.index, .type = .none };
        }

        return switch (self.space) {
            .io => blk: {
                const mask = IoRegister.from(probed.lo).base();
                if (mask == 0) {
                    break :blk .{ .index = self.index, .type = .none };
                }

                break :blk .{
                    .index = self.index,
                    .type = .{ .io = .{
                        .base = IoRegister.from(self.saved.lo).base(),
                        .size = ~mask +% 1,
                    } },
                };
            },
            .mem => {
                if (self.offset.hi != null) {
                    return .{
                        .index = self.index,
                        .type = .{ .memory = .{
                            .base = Memory64.from(self.saved.lo, self.saved.hi).base(),
                            .size = ~Memory64.from(probed.lo, probed.hi).base() +% 1,
                            .width = .bits_64,
                            .prefetchable = MemoryRegister.from(self.saved.lo).prefetchable,
                        } },
                    };
                }

                return .{
                    .index = self.index,
                    .type = .{ .memory = .{
                        .base = MemoryRegister.from(self.saved.lo).base(),
                        .size = @as(u64, ~MemoryRegister.from(probed.lo).base()) + 1,
                        .width = .bits_32,
                        .prefetchable = MemoryRegister.from(self.saved.lo).prefetchable,
                    } },
                };
            },
        };
    }
};

pub const unit = struct {
    const testing = std.testing;

    const num_bar_slots: usize = core.header.type0.num_bar_slots;
    const pcie_window_size: usize = core.config.extended_size;

    const BarWidth = Bar.Memory.Width;
    const BarType = Bar.Type;
    const Sbdf = core.Sbdf;

    const ExpectedIo = struct {
        index: usize,
        base: u32,
        size: ?u32,
    };

    const ExpectedMemory = struct {
        index: usize,
        num_slots: usize,
        base: u64,
        size: ?u64,
        width: BarWidth,
        prefetchable: bool,
    };

    const Write = struct {
        offset: usize,
        value: u32,
    };

    const ProbeConfig = struct {
        sbdf: Sbdf = Sbdf.from(.from(0), 0, 1, 0),
        bytes: [pcie_window_size]u8 = @splat(0),
        probe_values: [num_bar_slots]u32 = @splat(0),
        probe_active: [num_bar_slots]bool = @splat(false),
        read_count: usize = 0,
        write_count: usize = 0,
        command_writes: [8]u16 = @splat(0),
        command_write_count: usize = 0,
        fail_restore_offset: ?usize = null,
        fail_read_offset: ?usize = null,
        fail_probe_read_offset: ?usize = null,
        fail_command_value: ?u16 = null,
        writes: [32]Write = undefined,

        fn from(format: Format) ProbeConfig {
            var self: ProbeConfig = .{};
            self.setCommand(0);
            self.bytes[offset.type] = switch (format) {
                .type0 => 0x00,
                .type1 => 0x01,
            };

            return self;
        }

        fn config(self: *ProbeConfig) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn setCommand(self: *ProbeConfig, raw: u16) void {
            store16(&self.bytes, offset.command, raw);
        }

        fn command(self: *const ProbeConfig) u16 {
            return load16(&self.bytes, offset.command);
        }

        fn setBar(self: *ProbeConfig, index: usize, raw: u32) void {
            store32(&self.bytes, barOffset(index), raw);
        }

        fn bar(self: *const ProbeConfig, index: usize) u32 {
            return load32(&self.bytes, barOffset(index));
        }

        fn setProbe(self: *ProbeConfig, index: usize, raw: u32) void {
            self.probe_values[index] = raw;
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u8 {
            const self: *ProbeConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;
            return self.bytes[byte_offset];
        }

        fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *ProbeConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;
            return load16(&self.bytes, byte_offset);
        }

        fn read32(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u32 {
            const self: *ProbeConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;

            if (self.fail_read_offset == byte_offset) {
                return error.OutOfBounds;
            }

            if (barIndex(byte_offset)) |index| {
                if (self.probe_active[index]) {
                    if (self.fail_probe_read_offset == byte_offset) {
                        return error.OutOfBounds;
                    }
                    return self.probe_values[index];
                }
            }

            return load32(&self.bytes, byte_offset);
        }

        fn write8(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u8) ConfigError!void {
            const self: *ProbeConfig = @ptrCast(@alignCast(context));
            self.write_count += 1;
            self.bytes[byte_offset] = value;
        }

        fn write16(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *ProbeConfig = @ptrCast(@alignCast(context));
            self.writes[self.write_count] = .{ .offset = byte_offset, .value = value };
            self.write_count += 1;

            if (byte_offset == offset.command) {
                self.command_writes[self.command_write_count] = value;
                self.command_write_count += 1;
                if (self.fail_command_value == value) {
                    return error.UnsupportedAccessWidth;
                }
            }

            store16(&self.bytes, byte_offset, value);
        }

        fn write32(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u32) ConfigError!void {
            const self: *ProbeConfig = @ptrCast(@alignCast(context));
            self.writes[self.write_count] = .{ .offset = byte_offset, .value = value };
            self.write_count += 1;

            if (barIndex(byte_offset)) |index| {
                if (value == 0xFFFF_FFFF) {
                    self.probe_active[index] = true;
                    return;
                }

                const failing_restore = self.fail_restore_offset == byte_offset and self.probe_active[index];
                if (failing_restore) {
                    return error.UnsupportedAccessWidth;
                }

                self.probe_active[index] = false;
            }

            store32(&self.bytes, byte_offset, value);
        }
    };

    const offset = struct {
        const command: usize = 0x04;
        const @"type": usize = 0x0E;
        const bars: usize = 0x10;
    };

    test "Bars.tryFrom selects BAR slots by header format" {
        var endpoint = ProbeConfig.from(.type0);
        var bridge = ProbeConfig.from(.type1);

        const endpoint_bars = (try Bars.tryFrom(Function.from(endpoint.config(), endpoint.sbdf))).?;
        const bridge_bars = (try Bars.tryFrom(Function.from(bridge.config(), bridge.sbdf))).?;

        try testing.expectEqual(Format.type0, endpoint_bars.format);
        try testing.expectEqual(@as(usize, 6), endpoint_bars.numSlots());
        try testing.expectEqual(Format.type1, bridge_bars.format);
        try testing.expectEqual(@as(usize, 2), bridge_bars.numSlots());
    }

    test "decode decodes none, IO, 32-bit memory, and 64-bit memory BARs" {
        var backend = ProbeConfig.from(.type0);
        backend.setBar(0, 0x0000_0000);
        backend.setBar(1, 0x0000_C001);
        backend.setBar(2, 0x8000_1008);
        backend.setBar(3, 0x0000_200C);
        backend.setBar(4, 0x1234_5670);
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        try expectNone(try bars.decode(0), 0);
        try expectIo(try bars.decode(1), .{ .index = 1, .base = 0x0000_C000, .size = null });
        try expectMemory(try bars.decode(2), .{
            .index = 2,
            .num_slots = 1,
            .base = 0x0000_0000_8000_1000,
            .size = null,
            .width = .bits_32,
            .prefetchable = true,
        });
        try expectMemory(try bars.decode(3), .{
            .index = 3,
            .num_slots = 2,
            .base = 0x1234_5670_0000_2000,
            .size = null,
            .width = .bits_64,
            .prefetchable = true,
        });
    }

    test "iterator advances past the high slot of a 64-bit BAR" {
        var backend = ProbeConfig.from(.type0);
        backend.setBar(0, 0x0000_1004);
        backend.setBar(1, 0x0000_0000);
        backend.setBar(2, 0x0000_2000);
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        var it = bars.iterator();
        try expectMemory((try it.next()).?, .{
            .index = 0,
            .num_slots = 2,
            .base = 0x0000_0000_0000_1000,
            .size = null,
            .width = .bits_64,
            .prefetchable = false,
        });
        try expectMemory((try it.next()).?, .{
            .index = 2,
            .num_slots = 1,
            .base = 0x0000_0000_0000_2000,
            .size = null,
            .width = .bits_32,
            .prefetchable = false,
        });
        try expectNone((try it.next()).?, 3);
        try expectNone((try it.next()).?, 4);
        try expectNone((try it.next()).?, 5);

        try testing.expectEqual(@as(?Bar, null), try it.next());
    }

    test "reserved and incomplete BAR encodings are rejected" {
        const cases = [_]struct {
            name: []const u8,
            format: Format = .type0,
            index: usize,
            bars: [num_bar_slots]u32,
        }{
            .{ .name = "memory type 0b01", .index = 0, .bars = .{ 0x0000_0002, 0, 0, 0, 0, 0 } },
            .{ .name = "memory type 0b11", .index = 0, .bars = .{ 0x0000_0006, 0, 0, 0, 0, 0 } },
            .{ .name = "IO reserved bit", .index = 0, .bars = .{ 0x0000_0003, 0, 0, 0, 0, 0 } },
            .{ .name = "64-bit low in last slot", .index = 5, .bars = .{ 0, 0, 0, 0, 0, 0x0000_0004 } },
            .{ .name = "bridge 64-bit low in last slot", .format = .type1, .index = 1, .bars = .{ 0, 0x0000_0004, 0, 0, 0, 0 } },
        };

        for (cases) |case| {
            var backend = ProbeConfig.from(case.format);
            for (case.bars, 0..) |raw, index| {
                backend.setBar(index, raw);
            }
            const bars = Bars.from(Function.from(backend.config(), backend.sbdf), case.format);
            if (case.index == bars.numSlots() - 1) {
                backend.fail_read_offset = barOffset(case.index + 1);
            }

            errdefer std.debug.print("case: {s}\n", .{case.name});

            try testing.expectError(error.MalformedBar, bars.decode(case.index));
            try testing.expectEqual(@as(usize, 1), backend.read_count);
        }
    }

    test "64-bit high address bits do not affect following BAR boundaries" {
        for ([_]u32{ 1, 4, 0xF, 0x1234_567F, 0xFFFF_FFFE }) |high| {
            var backend = ProbeConfig.from(.type0);
            backend.setBar(0, 0x2004);
            backend.setBar(1, high);
            backend.setBar(2, 0x8000_1008);
            backend.setProbe(0, 0xFFE0_0004);
            backend.setProbe(1, 0xFFFF_FFFF);
            const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);
            const base = (@as(u64, high) << 32) | 0x2000;

            try testing.expectEqual(base, (try bars.decode(0)).type.memory.base);
            try testing.expectEqual(@as(?u64, null), (try bars.decode(0)).type.memory.size);
            try testing.expectEqual(@as(u64, 0x8000_1000), (try bars.decode(2)).type.memory.base);
            var iterator = bars.iterator();

            try testing.expectEqual(@as(usize, 0), (try iterator.next()).?.index);
            try testing.expectEqual(@as(usize, 2), (try iterator.next()).?.index);

            const sized = try bars.probe(0);

            try testing.expectEqual(base, sized.type.memory.base);
            try testing.expectEqual(@as(?u64, 0x20_0000), sized.type.memory.size);
            try testing.expectEqual(high, backend.bar(1));
        }
    }

    test "32-bit memory probing represents the full four GiB size" {
        var backend = ProbeConfig.from(.type0);
        backend.setBar(0, 8);
        backend.setProbe(0, 8);
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        try testing.expectEqual(@as(?u64, null), (try bars.decode(0)).type.memory.size);
        try testing.expectEqual(@as(?u64, 0x1_0000_0000), (try bars.probe(0)).type.memory.size);
        try testing.expectEqual(@as(u32, 8), backend.bar(0));
    }

    test "IO probing preserves its largest nonzero power-of-two mask and zero-mask handling" {
        var backend = ProbeConfig.from(.type0);
        backend.setBar(0, 0xC001);
        backend.setProbe(0, 0x8000_0001);
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        try testing.expectEqual(@as(?u32, 0x8000_0000), (try bars.probe(0)).type.io.size);
        backend.setProbe(0, 1);
        try expectNone(try bars.probe(0), 0);
    }

    test "probe probes IO BAR with IO decode disabled, then restores BAR and Command" {
        var backend = ProbeConfig.from(.type0);
        backend.setCommand(0x0557);
        backend.setBar(0, 0x0000_C001);
        backend.setProbe(0, 0xFFFF_FF01);
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        try expectIo(try bars.probe(0), .{ .index = 0, .base = 0x0000_C000, .size = 0x100 });

        try testing.expectEqual(@as(u32, 0x0000_C001), backend.bar(0));
        try expectCommandWrites(&backend, &.{ 0x0556, 0x0557 });
    }

    test "probe probes 32-bit memory BAR with memory decode disabled, then restores BAR and Command" {
        var backend = ProbeConfig.from(.type0);
        backend.setCommand(0x0557);
        backend.setBar(0, 0x8000_1008);
        backend.setProbe(0, 0xFFFF_F000);
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        try expectMemory(try bars.probe(0), .{
            .index = 0,
            .num_slots = 1,
            .base = 0x0000_0000_8000_1000,
            .size = 0x1000,
            .width = .bits_32,
            .prefetchable = true,
        });
        try testing.expectEqual(@as(u32, 0x8000_1008), backend.bar(0));
        try expectCommandWrites(&backend, &.{ 0x0555, 0x0557 });
    }

    test "probe probes 64-bit memory BAR with memory decode disabled and restores both slots" {
        var backend = ProbeConfig.from(.type0);
        backend.setCommand(0x0557);
        backend.setBar(0, 0x0000_2004);
        backend.setBar(1, 0x1234_5670);
        backend.setProbe(0, 0xFFE0_0004);
        backend.setProbe(1, 0xFFFF_FFFF);
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        try expectMemory(try bars.probe(0), .{
            .index = 0,
            .num_slots = 2,
            .base = 0x1234_5670_0000_2000,
            .size = 0x0020_0000,
            .width = .bits_64,
            .prefetchable = false,
        });
        try testing.expectEqual(@as(u32, 0x0000_2004), backend.bar(0));
        try testing.expectEqual(@as(u32, 0x1234_5670), backend.bar(1));
        try expectCommandWrites(&backend, &.{ 0x0555, 0x0557 });
    }

    test "probeAll probes every BAR under one decode-disable window and returns compact entries" {
        var backend = ProbeConfig.from(.type0);
        backend.setCommand(0x0557);
        backend.setBar(0, 0x0000_C001);
        backend.setProbe(0, 0xFFFF_FF01);
        backend.setBar(1, 0x0000_2004);
        backend.setBar(2, 0x1234_5670);
        backend.setProbe(1, 0xFFE0_0004);
        backend.setProbe(2, 0xFFFF_FFFF);
        backend.setBar(3, 0x8000_1008);
        backend.setProbe(3, 0xFFFF_F000);
        backend.setBar(4, 0x0000_0000);
        backend.setProbe(4, 0x0000_0000);
        backend.setBar(5, 0x0000_D001);
        backend.setProbe(5, 0xFFFF_FC01);
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        const result = try bars.probeAll();
        const entries = result.asSlice();

        try testing.expectEqual(@as(usize, 5), entries.len);
        try expectIo(entries[0], .{ .index = 0, .base = 0x0000_C000, .size = 0x100 });
        try expectMemory(entries[1], .{
            .index = 1,
            .num_slots = 2,
            .base = 0x1234_5670_0000_2000,
            .size = 0x0020_0000,
            .width = .bits_64,
            .prefetchable = false,
        });
        try expectMemory(entries[2], .{
            .index = 3,
            .num_slots = 1,
            .base = 0x0000_0000_8000_1000,
            .size = 0x1000,
            .width = .bits_32,
            .prefetchable = true,
        });
        try expectNone(entries[3], 4);
        try expectIo(entries[4], .{ .index = 5, .base = 0x0000_D000, .size = 0x400 });

        try testing.expectEqual(@as(u32, 0x0000_C001), backend.bar(0));
        try testing.expectEqual(@as(u32, 0x0000_2004), backend.bar(1));
        try testing.expectEqual(@as(u32, 0x1234_5670), backend.bar(2));
        try testing.expectEqual(@as(u32, 0x8000_1008), backend.bar(3));
        try testing.expectEqual(@as(u32, 0x0000_0000), backend.bar(4));
        try testing.expectEqual(@as(u32, 0x0000_D001), backend.bar(5));
        try expectCommandWrites(&backend, &.{ 0x0554, 0x0557 });
    }

    test "failure: low BAR restore failure still restores high BAR and Command" {
        var backend = ProbeConfig.from(.type0);
        backend.setCommand(0x0557);
        backend.setBar(0, 0x0000_2004);
        backend.setBar(1, 0x1234_5670);
        backend.setProbe(0, 0xFFE0_0004);
        backend.setProbe(1, 0xFFFF_FFFF);
        backend.fail_restore_offset = offset.bars;
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        try testing.expectError(error.ProgrammingPartial, bars.probe(0));
        try expectCommandWrites(&backend, &.{ 0x0555, 0x0557 });

        try testing.expectEqual(@as(u16, 0x0557), backend.command());
        try testing.expectEqual(@as(u32, 0x1234_5670), backend.bar(1));
        try testing.expect(!backend.probe_active[1]);
        try expectWrites(&backend, &.{
            .{ .offset = offset.command, .value = 0x0555 },
            .{ .offset = offset.bars, .value = 0xFFFF_FFFF },
            .{ .offset = offset.bars + 4, .value = 0xFFFF_FFFF },
            .{ .offset = offset.bars, .value = 0x0000_2004 },
            .{ .offset = offset.bars + 4, .value = 0x1234_5670 },
            .{ .offset = offset.command, .value = 0x0557 },
        });
    }

    test "failure: primary probe error beats BAR and Command restore failures" {
        for ([_]bool{ false, true }) |batch| {
            var backend = ProbeConfig.from(.type0);
            backend.setCommand(0x0557);
            backend.setBar(0, 0x8000_1000);
            backend.fail_probe_read_offset = offset.bars;
            backend.fail_restore_offset = offset.bars;
            backend.fail_command_value = 0x0557;
            const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

            if (batch) {
                try testing.expectError(error.OutOfBounds, bars.probeAll());
            } else {
                try testing.expectError(error.OutOfBounds, bars.probe(0));
            }
            try expectWrites(&backend, &.{
                .{ .offset = offset.command, .value = if (batch) 0x0554 else 0x0555 },
                .{ .offset = offset.bars, .value = 0xFFFF_FFFF },
                .{ .offset = offset.bars, .value = 0x8000_1000 },
                .{ .offset = offset.command, .value = 0x0557 },
            });
        }
    }

    test "failure: Command disable failure restores Command only for single probe" {
        for ([_]bool{ false, true }) |batch| {
            var backend = ProbeConfig.from(.type0);
            backend.setCommand(0x0557);
            backend.setBar(0, 0x8000_1000);
            const disabled: u16 = if (batch) 0x0554 else 0x0555;
            backend.fail_command_value = disabled;
            const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

            if (batch) {
                try testing.expectError(error.UnsupportedAccessWidth, bars.probeAll());
                try expectWrites(&backend, &.{.{ .offset = offset.command, .value = disabled }});
            } else {
                try testing.expectError(error.UnsupportedAccessWidth, bars.probe(0));
                try expectWrites(&backend, &.{
                    .{ .offset = offset.command, .value = disabled },
                    .{ .offset = offset.command, .value = 0x0557 },
                });
            }
            try testing.expectEqual(@as(u32, 0x8000_1000), backend.bar(0));
            try testing.expectEqual(@as(u16, 0x0557), backend.command());
        }
    }

    test "failure: batch stops on BAR restore failure and restores Command" {
        var backend = ProbeConfig.from(.type0);
        backend.setCommand(0x0557);
        backend.setBar(0, 0x8000_1000);
        backend.setProbe(0, 0xFFFF_F000);
        backend.fail_restore_offset = offset.bars;
        const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type0);

        try testing.expectError(error.ProgrammingPartial, bars.probeAll());
        try expectWrites(&backend, &.{
            .{ .offset = offset.command, .value = 0x0554 },
            .{ .offset = offset.bars, .value = 0xFFFF_FFFF },
            .{ .offset = offset.bars, .value = 0x8000_1000 },
            .{ .offset = offset.command, .value = 0x0557 },
        });
    }

    test "failure: batch Command restore failure preserves initialization errors" {
        for ([_]bool{ false, true }) |malformed| {
            var backend = ProbeConfig.from(.type1);
            backend.setCommand(0x0557);
            backend.fail_command_value = 0x0557;
            if (malformed) {
                backend.setBar(0, 0x0000_0002);
            }
            const bars = Bars.from(Function.from(backend.config(), backend.sbdf), .type1);

            if (malformed) {
                try testing.expectError(error.MalformedBar, bars.probeAll());
                try expectWrites(&backend, &.{
                    .{ .offset = offset.command, .value = 0x0554 },
                    .{ .offset = offset.command, .value = 0x0557 },
                });
            } else {
                try testing.expectError(error.ProgrammingPartial, bars.probeAll());
                try expectWrites(&backend, &.{
                    .{ .offset = offset.command, .value = 0x0554 },
                    .{ .offset = offset.bars, .value = 0xFFFF_FFFF },
                    .{ .offset = offset.bars, .value = 0 },
                    .{ .offset = offset.bars + 4, .value = 0xFFFF_FFFF },
                    .{ .offset = offset.bars + 4, .value = 0 },
                    .{ .offset = offset.command, .value = 0x0557 },
                });
            }
        }
    }

    fn expectNone(entry: Bar, index: usize) !void {
        try testing.expectEqual(index, entry.index);
        try testing.expectEqual(@as(usize, 1), entry.numSlots());
        try testing.expectEqual(BarType.none, entry.type);
    }

    fn expectIo(entry: Bar, expected: ExpectedIo) !void {
        try testing.expectEqual(expected.index, entry.index);
        try testing.expectEqual(@as(usize, 1), entry.numSlots());
        switch (entry.type) {
            .io => |io| {
                try testing.expectEqual(expected.base, io.base);
                try testing.expectEqual(expected.size, io.size);
            },
            else => return error.TestExpectedEqual,
        }
    }

    fn expectMemory(entry: Bar, expected: ExpectedMemory) !void {
        try testing.expectEqual(expected.index, entry.index);
        try testing.expectEqual(expected.num_slots, entry.numSlots());
        switch (entry.type) {
            .memory => |memory| {
                try testing.expectEqual(expected.base, memory.base);
                try testing.expectEqual(expected.size, memory.size);
                try testing.expectEqual(expected.width, memory.width);
                try testing.expectEqual(expected.prefetchable, memory.prefetchable);
            },
            else => return error.TestExpectedEqual,
        }
    }

    fn expectCommandWrites(backend: *const ProbeConfig, expected: []const u16) !void {
        try testing.expectEqual(expected.len, backend.command_write_count);
        for (expected, 0..) |raw, index| {
            try testing.expectEqual(raw, backend.command_writes[index]);
        }
    }

    fn expectWrites(backend: *const ProbeConfig, expected: []const Write) !void {
        try testing.expectEqual(expected.len, backend.write_count);
        for (expected, backend.writes[0..backend.write_count]) |want, actual| {
            try testing.expectEqualDeep(want, actual);
        }
    }

    fn barOffset(index: usize) usize {
        return offset.bars + index * 4;
    }

    fn barIndex(byte_offset: usize) ?usize {
        if (byte_offset < offset.bars) {
            return null;
        }

        const delta = byte_offset - offset.bars;
        if (delta % 4 != 0) {
            return null;
        }

        const index = @divExact(delta, 4);
        if (index >= num_bar_slots) {
            return null;
        }

        return index;
    }

    fn load16(bytes: *const [pcie_window_size]u8, byte_offset: usize) u16 {
        const low = @as(u16, bytes[byte_offset]);
        const high = @as(u16, bytes[byte_offset + 1]) << 8;
        return high | low;
    }

    fn store16(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u16) void {
        bytes[byte_offset] = @truncate(value);
        bytes[byte_offset + 1] = @truncate(value >> 8);
    }

    fn load32(bytes: *const [pcie_window_size]u8, byte_offset: usize) u32 {
        const byte0 = @as(u32, bytes[byte_offset]);
        const byte1 = @as(u32, bytes[byte_offset + 1]) << 8;
        const byte2 = @as(u32, bytes[byte_offset + 2]) << 16;
        const byte3 = @as(u32, bytes[byte_offset + 3]) << 24;
        return byte3 | byte2 | byte1 | byte0;
    }

    fn store32(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u32) void {
        bytes[byte_offset] = @truncate(value);
        bytes[byte_offset + 1] = @truncate(value >> 8);
        bytes[byte_offset + 2] = @truncate(value >> 16);
        bytes[byte_offset + 3] = @truncate(value >> 24);
    }
};

test {
    _ = unit;
}
