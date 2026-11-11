//! Type-1 bridge header view.

const std = @import("std");

const config = @import("config");
const core = @import("core");

const windows = @import("windows.zig");

const ConfigSpace = config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Function = config.Function;
const Offset = core.Offset;

const VendorId = core.VendorId;
const DeviceId = core.DeviceId;
const RevisionId = core.RevisionId;
const ClassCode = core.ClassCode;

const Bist = core.header.Bist.Word;
const Command = core.header.Command.Word;
const Status = core.header.Status;
const StatusWord = Status.Word;
const BridgeControl = core.header.BridgeControl;
const BridgeControlWord = BridgeControl.Word;
const ExpansionRom = core.header.ExpansionRom;
const ExpansionRomWord = ExpansionRom.Word;
const Io = windows.Io;
const Memory = windows.Memory;
const WindowState = windows.State;
const IoRegisters = core.bridge.Io;
const MemoryRegisters = core.bridge.Memory;
const PrefetchRegisters = MemoryRegisters.Prefetch;
const IntrPin = core.header.IntrPin;

const type1 = core.header.type1;

pub const Type1 = struct {
    function: Function,

    pub const num_bar_slots = type1.num_bar_slots;

    pub const BusRange = struct {
        primary: u8,
        secondary: u8,
        subordinate: u8,

        pub fn isUnprogrammed(self: BusRange) bool {
            return self.secondary == 0;
        }

        pub fn forwards(self: BusRange, bus: u8) bool {
            return self.secondary != 0 and self.secondary <= bus and bus <= self.subordinate;
        }
    };

    pub fn from(function: Function) Type1 {
        return .{ .function = function };
    }

    pub fn busRange(self: Type1) ConfigError!BusRange {
        return .{
            .primary = try self.primaryBus(),
            .secondary = try self.secondaryBus(),
            .subordinate = try self.subordinateBus(),
        };
    }

    pub fn windows(self: Type1) ConfigError!WindowState {
        const io_base_lo = try self.ioBaseLo();
        const io_limit_lo = try self.ioLimitLo();
        const io_is_32bit = (io_base_lo & 0xF) == 1 and (io_limit_lo & 0xF) == 1;
        const io_base_hi = if (io_is_32bit) try self.ioBaseHi() else 0;
        const io_limit_hi = if (io_is_32bit) try self.ioLimitHi() else 0;

        const io = Io.decode(IoRegisters{
            .base_lo = io_base_lo,
            .limit_lo = io_limit_lo,
            .base_hi = io_base_hi,
            .limit_hi = io_limit_hi,
        });

        const mem_base = try self.memBase();
        const mem_limit = try self.memLimit();
        const memory = Memory.decode(MemoryRegisters{ .base = mem_base, .limit = mem_limit });

        const pref_base_lo = try self.prefetchBaseLo();
        const pref_limit_lo = try self.prefetchLimitLo();
        const pref_is_64bit = (pref_base_lo & 0xF) == 1 and (pref_limit_lo & 0xF) == 1;
        const pref_base_hi = if (pref_is_64bit) try self.prefetchBaseHi() else 0;
        const pref_limit_hi = if (pref_is_64bit) try self.prefetchLimitHi() else 0;

        const pref = Memory.Prefetch.decode(PrefetchRegisters{
            .base_lo = pref_base_lo,
            .limit_lo = pref_limit_lo,
            .base_hi = pref_base_hi,
            .limit_hi = pref_limit_hi,
        });

        return .{
            .io = io,
            .mem = memory,
            .mem_prefetch = pref,
        };
    }

    pub fn vendorId(self: Type1) ConfigError!VendorId {
        return self.function.vendorId();
    }

    pub fn deviceId(self: Type1) ConfigError!DeviceId {
        return self.function.deviceId();
    }

    pub fn revisionId(self: Type1) ConfigError!RevisionId {
        return self.function.revisionId();
    }

    pub fn classCode(self: Type1) ConfigError!ClassCode {
        return self.function.classCode();
    }

    pub fn command(self: Type1) ConfigError!Command {
        return self.function.command();
    }

    pub fn setCommand(self: Type1, value: Command) ConfigError!void {
        return self.function.setCommand(value);
    }

    pub fn status(self: Type1) ConfigError!StatusWord {
        return self.function.status();
    }

    pub fn clearStatusBits(self: Type1, bits: u16) ConfigError!void {
        return self.function.clearStatusBits(bits);
    }

    pub fn cacheLineSize(self: Type1) ConfigError!u8 {
        return self.function.cacheLineSize();
    }

    pub fn setCacheLineSize(self: Type1, value: u8) ConfigError!void {
        return self.function.setCacheLineSize(value);
    }

    pub fn latencyTimer(self: Type1) ConfigError!u8 {
        return self.function.latencyTimer();
    }

    pub fn setLatencyTimer(self: Type1, value: u8) ConfigError!void {
        return self.function.setLatencyTimer(value);
    }

    pub fn typeByte(self: Type1) ConfigError!u8 {
        return self.function.typeByte();
    }

    pub fn multifunction(self: Type1) ConfigError!bool {
        return self.function.multifunction();
    }

    pub fn bist(self: Type1) ConfigError!Bist {
        return self.function.bist();
    }

    pub fn setBist(self: Type1, value: Bist) ConfigError!void {
        return self.function.setBist(value);
    }

    pub fn rawBar(self: Type1, index: usize) ConfigError!u32 {
        std.debug.assert(index < num_bar_slots);
        return self.function.read(offsets.bar(index));
    }

    pub fn primaryBus(self: Type1) ConfigError!u8 {
        return self.function.read(offsets.primary_bus);
    }

    pub fn setPrimaryBus(self: Type1, value: u8) ConfigError!void {
        return self.function.write(offsets.primary_bus, value);
    }

    pub fn secondaryBus(self: Type1) ConfigError!u8 {
        return self.function.read(offsets.secondary_bus);
    }

    pub fn setSecondaryBus(self: Type1, value: u8) ConfigError!void {
        return self.function.write(offsets.secondary_bus, value);
    }

    pub fn subordinateBus(self: Type1) ConfigError!u8 {
        return self.function.read(offsets.subordinate_bus);
    }

    pub fn setSubordinateBus(self: Type1, value: u8) ConfigError!void {
        return self.function.write(offsets.subordinate_bus, value);
    }

    pub fn secondaryLatencyTimer(self: Type1) ConfigError!u8 {
        return self.function.read(offsets.secondary_latency_timer);
    }

    pub fn setSecondaryLatencyTimer(self: Type1, value: u8) ConfigError!void {
        return self.function.write(offsets.secondary_latency_timer, value);
    }

    pub fn ioBaseLo(self: Type1) ConfigError!u8 {
        return self.function.read(offsets.io_base_lo);
    }

    pub fn setIoBaseLo(self: Type1, value: u8) ConfigError!void {
        return self.function.write(offsets.io_base_lo, value);
    }

    pub fn ioLimitLo(self: Type1) ConfigError!u8 {
        return self.function.read(offsets.io_limit_lo);
    }

    pub fn setIoLimitLo(self: Type1, value: u8) ConfigError!void {
        return self.function.write(offsets.io_limit_lo, value);
    }

    pub fn ioBaseHi(self: Type1) ConfigError!u16 {
        return self.function.read(offsets.io_base_hi);
    }

    pub fn setIoBaseHi(self: Type1, value: u16) ConfigError!void {
        return self.function.write(offsets.io_base_hi, value);
    }

    pub fn ioLimitHi(self: Type1) ConfigError!u16 {
        return self.function.read(offsets.io_limit_hi);
    }

    pub fn setIoLimitHi(self: Type1, value: u16) ConfigError!void {
        return self.function.write(offsets.io_limit_hi, value);
    }

    pub fn secondaryStatus(self: Type1) ConfigError!StatusWord {
        const raw = try self.function.read(offsets.secondary_status);
        return Status.from(raw);
    }

    pub fn clearSecondaryStatus(self: Type1, bits: u16) ConfigError!void {
        return self.function.write(offsets.secondary_status, bits);
    }

    pub fn memBase(self: Type1) ConfigError!u16 {
        return self.function.read(offsets.mem_base);
    }

    pub fn setMemBase(self: Type1, value: u16) ConfigError!void {
        return self.function.write(offsets.mem_base, value);
    }

    pub fn memLimit(self: Type1) ConfigError!u16 {
        return self.function.read(offsets.mem_limit);
    }

    pub fn setMemLimit(self: Type1, value: u16) ConfigError!void {
        return self.function.write(offsets.mem_limit, value);
    }

    pub fn prefetchBaseLo(self: Type1) ConfigError!u16 {
        return self.function.read(offsets.prefetch_base_lo);
    }

    pub fn setPrefetchBaseLo(self: Type1, value: u16) ConfigError!void {
        return self.function.write(offsets.prefetch_base_lo, value);
    }

    pub fn prefetchLimitLo(self: Type1) ConfigError!u16 {
        return self.function.read(offsets.prefetch_limit_lo);
    }

    pub fn setPrefetchLimitLo(self: Type1, value: u16) ConfigError!void {
        return self.function.write(offsets.prefetch_limit_lo, value);
    }

    pub fn prefetchBaseHi(self: Type1) ConfigError!u32 {
        return self.function.read(offsets.prefetch_base_hi);
    }

    pub fn setPrefetchBaseHi(self: Type1, value: u32) ConfigError!void {
        return self.function.write(offsets.prefetch_base_hi, value);
    }

    pub fn prefetchLimitHi(self: Type1) ConfigError!u32 {
        return self.function.read(offsets.prefetch_limit_hi);
    }

    pub fn setPrefetchLimitHi(self: Type1, value: u32) ConfigError!void {
        return self.function.write(offsets.prefetch_limit_hi, value);
    }

    pub fn capPtr(self: Type1) ConfigError!u8 {
        return self.function.capPtr();
    }

    pub fn rom(self: Type1) ConfigError!ExpansionRomWord {
        return ExpansionRom.from(try self.function.read(offsets.rom_base));
    }

    pub fn setRom(self: Type1, value: ExpansionRomWord) ConfigError!void {
        return self.function.write(offsets.rom_base, ExpansionRom.raw(value));
    }

    pub fn intrLine(self: Type1) ConfigError!u8 {
        return self.function.intrLine();
    }

    pub fn setIntrLine(self: Type1, value: u8) ConfigError!void {
        return self.function.setIntrLine(value);
    }

    pub fn intrPin(self: Type1) (ConfigError || IntrPin.Error)!IntrPin {
        return IntrPin.tryFrom(try self.function.read(Function.offsets.intr_pin));
    }

    pub fn bridgeControl(self: Type1) ConfigError!BridgeControlWord {
        const raw = try self.function.read(offsets.bridge_control);
        return BridgeControl.from(raw);
    }

    pub fn setBridgeControl(self: Type1, value: BridgeControlWord) ConfigError!void {
        return self.function.write(offsets.bridge_control, BridgeControl.raw(value));
    }
};

pub const offsets = struct {
    pub const primary_bus = Offset(u8).from(type1.offsets.primary_bus);
    pub const secondary_bus = Offset(u8).from(type1.offsets.secondary_bus);
    pub const subordinate_bus = Offset(u8).from(type1.offsets.subordinate_bus);
    pub const secondary_latency_timer = Offset(u8).from(type1.offsets.secondary_latency_timer);
    pub const io_base_lo = Offset(u8).from(type1.offsets.io_base_lo);
    pub const io_limit_lo = Offset(u8).from(type1.offsets.io_limit_lo);
    pub const secondary_status = Offset(u16).from(type1.offsets.secondary_status);
    pub const mem_base = Offset(u16).from(type1.offsets.mem_base);
    pub const mem_limit = Offset(u16).from(type1.offsets.mem_limit);
    pub const prefetch_base_lo = Offset(u16).from(type1.offsets.prefetch_base_lo);
    pub const prefetch_limit_lo = Offset(u16).from(type1.offsets.prefetch_limit_lo);
    pub const prefetch_base_hi = Offset(u32).from(type1.offsets.prefetch_base_hi);
    pub const prefetch_limit_hi = Offset(u32).from(type1.offsets.prefetch_limit_hi);
    pub const io_base_hi = Offset(u16).from(type1.offsets.io_base_hi);
    pub const io_limit_hi = Offset(u16).from(type1.offsets.io_limit_hi);
    pub const rom_base = Offset(u32).from(type1.offsets.rom_base);
    pub const bridge_control = Offset(u16).from(type1.offsets.bridge_control);

    pub fn bar(index: usize) Offset(u32) {
        return .from(type1.offsets.bar(index));
    }
};

pub const unit = struct {
    const support = @import("testing");
    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;
    const test_sbdf = Sbdf.from(.from(0), 0, 0, 0);
    const num_bar_slots = Type1.num_bar_slots;

    const BusRange = Type1.BusRange;
    const Sbdf = core.Sbdf;
    const Width = Memory.Prefetch.Width;

    const TestConfigSpace = support.config.TestConfigSpace;

    const TraceConfig = struct {
        bytes: [pcie_window_size]u8 = @splat(0),
        reads: [10]u16 = undefined,
        widths: [10]u8 = undefined,
        count: usize = 0,
        fail_at: usize,

        fn view(self: *TraceConfig) Type1 {
            return Type1.from(Function.from(ConfigSpace.from(self, &vtable), test_sbdf));
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read(comptime T: type, context: *anyopaque, byte_offset: usize) ConfigError!T {
            const self: *TraceConfig = @ptrCast(@alignCast(context));
            const index = self.count;

            self.reads[index] = @intCast(byte_offset);
            self.widths[index] = @sizeOf(T);
            self.count += 1;

            if (index == self.fail_at) {
                return error.OutOfBounds;
            }

            return std.mem.readInt(T, self.bytes[byte_offset..][0..@sizeOf(T)], .little);
        }

        fn read8(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u8 {
            return read(u8, context, byte_offset);
        }

        fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u16 {
            return read(u16, context, byte_offset);
        }

        fn read32(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u32 {
            return read(u32, context, byte_offset);
        }

        fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            unreachable;
        }

        fn write16(_: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {
            unreachable;
        }

        fn write32(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            unreachable;
        }
    };

    const byte_offsets = struct {
        const bars: usize = 0x10;
        const primary_bus: usize = 0x18;
        const secondary_bus: usize = 0x19;
        const subordinate_bus: usize = 0x1A;
        const secondary_latency_timer: usize = 0x1B;
        const io_base_lo: usize = 0x1C;
        const io_limit_lo: usize = 0x1D;
        const secondary_status: usize = 0x1E;
        const mem_base: usize = 0x20;
        const mem_limit: usize = 0x22;
        const prefetch_base_lo: usize = 0x24;
        const prefetch_limit_lo: usize = 0x26;
        const prefetch_base_hi: usize = 0x28;
        const prefetch_limit_hi: usize = 0x2C;
        const io_base_hi: usize = 0x30;
        const io_limit_hi: usize = 0x32;
        const cap_ptr: usize = 0x34;
        const rom_base: usize = 0x38;
        const intr_line: usize = 0x3C;
        const intr_pin: usize = 0x3D;
        const bridge_control: usize = 0x3E;
    };

    test "BusRange reports unprogrammed and forwarded buses" {
        const reset = BusRange{ .primary = 0x00, .secondary = 0x00, .subordinate = 0x00 };
        const programmed = BusRange{ .primary = 0x01, .secondary = 0x20, .subordinate = 0x2F };

        try testing.expect(reset.isUnprogrammed());
        try testing.expect(!reset.forwards(0x00));

        try testing.expect(!programmed.isUnprogrammed());
        try testing.expect(!programmed.forwards(0x1F));
        try testing.expect(programmed.forwards(0x20));
        try testing.expect(programmed.forwards(0x2F));
        try testing.expect(!programmed.forwards(0x30));
    }

    test "Type1 busRange reads exact bus-number bytes" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        bytes[0x18] = 0x11;
        bytes[0x19] = 0x22;
        bytes[0x1A] = 0x33;

        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = Type1.from(Function.from(backend.config(), test_sbdf));

        const range = try view.busRange();

        try testing.expectEqual(@as(u8, 0x11), range.primary);
        try testing.expectEqual(@as(u8, 0x22), range.secondary);
        try testing.expectEqual(@as(u8, 0x33), range.subordinate);
    }

    test "Type1 windows reports disabled IO memory and prefetchable windows" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        bytes[0x1C] = 0xF0;
        bytes[0x1D] = 0x00;
        store16(&bytes, 0x20, 0x2000);
        store16(&bytes, 0x22, 0x1000);
        store16(&bytes, 0x24, 0x3000);
        store16(&bytes, 0x26, 0x2000);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = Type1.from(Function.from(backend.config(), test_sbdf));

        const state = try view.windows();

        try testing.expect(state.io.range == null);
        try testing.expect(state.mem.range == null);
        try testing.expect(state.mem_prefetch == null);
    }

    test "Type1 windows decodes enabled 32-bit IO memory and prefetchable windows" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        bytes[0x1C] = 0x21;
        bytes[0x1D] = 0x31;
        store16(&bytes, 0x30, 0x0001);
        store16(&bytes, 0x32, 0x0001);
        store16(&bytes, 0x20, 0x8010);
        store16(&bytes, 0x22, 0x8020);
        store16(&bytes, 0x24, 0x9000);
        store16(&bytes, 0x26, 0x9010);
        store32(&bytes, 0x28, 0xFFFF_FFFF);
        store32(&bytes, 0x2C, 0xFFFF_FFFF);

        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = Type1.from(Function.from(backend.config(), test_sbdf));

        const state = try view.windows();

        try testing.expectEqual(@as(u64, 0x0001_2000), state.io.range.?.start);
        try testing.expectEqual(@as(u64, 0x0001_3FFF), state.io.range.?.end);

        try testing.expectEqual(@as(u64, 0x8010_0000), state.mem.range.?.start);
        try testing.expectEqual(@as(u64, 0x802F_FFFF), state.mem.range.?.end);

        try testing.expectEqual(@as(u64, 0x9000_0000), state.mem_prefetch.?.range.start);
        try testing.expectEqual(@as(u64, 0x901F_FFFF), state.mem_prefetch.?.range.end);
        try testing.expectEqual(Width.mem32, state.mem_prefetch.?.width);
    }

    test "Type1 windows reconstructs 64-bit prefetchable windows" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        store16(&bytes, 0x24, 0x0011);
        store16(&bytes, 0x26, 0x0021);
        store32(&bytes, 0x28, 0x0000_0004);
        store32(&bytes, 0x2C, 0x0000_0005);

        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = Type1.from(Function.from(backend.config(), test_sbdf));

        const state = try view.windows();
        const pref = state.mem_prefetch.?;

        try testing.expectEqual(@as(u64, 0x0000_0004_0010_0000), pref.range.start);
        try testing.expectEqual(@as(u64, 0x0000_0005_002F_FFFF), pref.range.end);
        try testing.expectEqual(Width.mem64, pref.width);
        try testing.expect(pref.contains(0x0000_0004_0010_0000, 1));
        try testing.expect(pref.contains(0x0000_0005_0020_0000, 0x0010_0000));
        try testing.expect(!pref.contains(0x0000_0005_0020_0000, 0x0010_0001));
    }

    test "prefetchable width is independent of low addresses and inverted bounds are absent" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        store16(&bytes, 0x24, 0x1001);
        store16(&bytes, 0x26, 0x1001);

        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = Type1.from(Function.from(backend.config(), test_sbdf));

        const active = (try view.windows()).mem_prefetch.?;

        try testing.expectEqual(Width.mem64, active.width);
        try testing.expect(active.contains(0x1000_0000, 0x10_0000));

        store16(&bytes, 0x24, 0x2001);

        try testing.expect((try view.windows()).mem_prefetch == null);
    }

    test "Type1 windows reads both upper registers for full-u64 prefetchable range" {
        const after_window_reads = 10;
        var backend = TraceConfig{ .fail_at = after_window_reads };
        store16(&backend.bytes, 0x24, 0x0001);
        store16(&backend.bytes, 0x26, 0xFFF1);
        store32(&backend.bytes, 0x28, 0);
        store32(&backend.bytes, 0x2C, 0xFFFF_FFFF);

        const view = backend.view();
        const pref = (try view.windows()).mem_prefetch.?;

        try testing.expectEqual(Width.mem64, pref.width);
        try testing.expectEqual(@as(u64, 0), pref.range.start);
        try testing.expectEqual(std.math.maxInt(u64), pref.range.end);
        try testing.expectEqualSlices(u16, &.{ 0x1C, 0x1D, 0x20, 0x22, 0x24, 0x26, 0x28, 0x2C }, backend.reads[0..backend.count]);
        try testing.expectEqualSlices(u8, &.{ 1, 1, 2, 2, 2, 2, 4, 4 }, backend.widths[0..backend.count]);
    }

    test "Type1 inspection preserves access order and stops at each read failure" {
        const bus_offsets = [_]u16{ 0x18, 0x19, 0x1A };
        const window_offsets = [_]u16{ 0x1C, 0x1D, 0x30, 0x32, 0x20, 0x22, 0x24, 0x26, 0x28, 0x2C };
        const window_widths = [_]u8{ 1, 1, 2, 2, 2, 2, 2, 2, 4, 4 };

        for (0..bus_offsets.len + 1) |failure| {
            var backend = TraceConfig{ .fail_at = failure };
            const view = backend.view();

            if (failure < bus_offsets.len) {
                try testing.expectError(error.OutOfBounds, view.busRange());
            } else {
                _ = try view.busRange();
            }

            const count = @min(failure + 1, bus_offsets.len);

            try testing.expectEqualSlices(u16, bus_offsets[0..count], backend.reads[0..backend.count]);

            for (backend.widths[0..backend.count]) |width| {
                try testing.expectEqual(@as(u8, 1), width);
            }
        }

        for (0..window_offsets.len + 1) |failure| {
            var backend = TraceConfig{ .fail_at = failure };
            backend.bytes[0x1C] = 1;
            backend.bytes[0x1D] = 1;
            store16(&backend.bytes, 0x24, 1);
            store16(&backend.bytes, 0x26, 1);
            const view = backend.view();

            if (failure < window_offsets.len) {
                try testing.expectError(error.OutOfBounds, view.windows());
            } else {
                _ = try view.windows();
            }

            const count = @min(failure + 1, window_offsets.len);

            try testing.expectEqualSlices(u16, window_offsets[0..count], backend.reads[0..backend.count]);
            try testing.expectEqualSlices(u8, window_widths[0..count], backend.widths[0..backend.count]);
        }
    }

    test "Type1 windows gates IO and prefetchable upper reads and stops at each failure" {
        const modes = [_][2]u8{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 2 }, .{ 2, 1 }, .{ 2, 2 }, .{ 15, 15 }, .{ 1, 1 } };
        for (modes) |io_mode| {
            for (modes) |pref_mode| {
                const io_wide = io_mode[0] == 1 and io_mode[1] == 1;
                const pref_wide = pref_mode[0] == 1 and pref_mode[1] == 1;
                var expected_offsets: [10]u16 = undefined;
                var expected_widths: [10]u8 = undefined;
                var count: usize = 0;
                const offsets_in_order = [_]u16{ 0x1C, 0x1D, 0x30, 0x32, 0x20, 0x22, 0x24, 0x26, 0x28, 0x2C };
                const widths_in_order = [_]u8{ 1, 1, 2, 2, 2, 2, 2, 2, 4, 4 };

                for (offsets_in_order, widths_in_order, 0..) |offset, width, index| {
                    if ((index == 2 or index == 3) and !io_wide) {
                        continue;
                    }
                    if (index >= 8 and !pref_wide) {
                        continue;
                    }

                    expected_offsets[count] = offset;
                    expected_widths[count] = width;
                    count += 1;
                }

                for (0..count + 1) |failure| {
                    var backend = TraceConfig{ .fail_at = failure };
                    backend.bytes[0x1C] = io_mode[0];
                    backend.bytes[0x1D] = io_mode[1];
                    store16(&backend.bytes, 0x30, 2);
                    store16(&backend.bytes, 0x32, 3);
                    store16(&backend.bytes, 0x24, pref_mode[0]);
                    store16(&backend.bytes, 0x26, pref_mode[1]);
                    const view = backend.view();

                    if (failure < count) {
                        try testing.expectError(error.OutOfBounds, view.windows());
                    } else {
                        const state = try view.windows();
                        if (io_wide) {
                            try testing.expectEqual(@as(u64, 0x2_0000), state.io.range.?.start);
                            try testing.expectEqual(@as(u64, 0x3_0FFF), state.io.range.?.end);
                        } else if (io_mode[0] == 0 and io_mode[1] == 0) {
                            try testing.expectEqual(@as(u64, 0), state.io.range.?.start);
                            try testing.expectEqual(@as(u64, 0xFFF), state.io.range.?.end);
                        } else {
                            try testing.expectEqual(null, state.io.range);
                        }

                        if (pref_mode[0] == pref_mode[1] and pref_mode[0] <= 1) {
                            try testing.expectEqual(if (pref_wide) Width.mem64 else Width.mem32, state.mem_prefetch.?.width);
                        } else {
                            try testing.expectEqual(null, state.mem_prefetch);
                        }
                    }

                    const read_count = @min(failure + 1, count);

                    try testing.expectEqualSlices(u16, expected_offsets[0..read_count], backend.reads[0..backend.count]);
                    try testing.expectEqualSlices(u8, expected_widths[0..read_count], backend.widths[0..backend.count]);
                }
            }
        }
    }

    test "Type1 reads every type-1 bridge field from seeded config bytes" {
        const bars = [_]u32{ 0x1000_0004, 0x2000_0008 };
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedType1Header(&bytes, .{
            .bars = bars,
            .primary_bus = 0x01,
            .secondary_bus = 0x02,
            .subordinate_bus = 0x20,
            .secondary_latency_timer = 0x40,
            .io_base_lo = 0x51,
            .io_limit_lo = 0xF1,
            .secondary_status = 0xFDB8,
            .mem_base = 0x8000,
            .mem_limit = 0x8FFF,
            .prefetch_base_lo = 0x9001,
            .prefetch_limit_lo = 0x9FF1,
            .prefetch_base_hi = 0x0000_000A,
            .prefetch_limit_hi = 0x0000_000B,
            .io_base_hi = 0x1234,
            .io_limit_hi = 0x5678,
            .cap_ptr = 0xA0,
            .rom_base = 0xC000_0801,
            .intr_line = 0xFE,
            .intr_pin = 0x01,
            .bridge_control = 0xAD53,
        });
        const sbdf = Sbdf.from(.from(0), 0, 1, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const view = Type1.from(Function.from(backend.config(), sbdf));

        inline for (bars, 0..) |expected, index| {
            try testing.expectEqual(expected, try view.rawBar(index));
        }

        try testing.expectEqual(@as(u8, 0x01), try view.primaryBus());
        try testing.expectEqual(@as(u8, 0x02), try view.secondaryBus());
        try testing.expectEqual(@as(u8, 0x20), try view.subordinateBus());
        try testing.expectEqual(@as(u8, 0x40), try view.secondaryLatencyTimer());
        try testing.expectEqual(@as(u8, 0x51), try view.ioBaseLo());
        try testing.expectEqual(@as(u8, 0xF1), try view.ioLimitLo());
        try testing.expectEqual(@as(u16, 0xFDB8), Status.raw(try view.secondaryStatus()));
        try testing.expectEqual(@as(u16, 0x8000), try view.memBase());
        try testing.expectEqual(@as(u16, 0x8FFF), try view.memLimit());
        try testing.expectEqual(@as(u16, 0x9001), try view.prefetchBaseLo());
        try testing.expectEqual(@as(u16, 0x9FF1), try view.prefetchLimitLo());
        try testing.expectEqual(@as(u32, 0x0000_000A), try view.prefetchBaseHi());
        try testing.expectEqual(@as(u32, 0x0000_000B), try view.prefetchLimitHi());
        try testing.expectEqual(@as(u16, 0x1234), try view.ioBaseHi());
        try testing.expectEqual(@as(u16, 0x5678), try view.ioLimitHi());
        try testing.expectEqual(@as(u8, 0xA0), try view.capPtr());
        try testing.expectEqual(@as(u32, 0xC000_0801), ExpansionRom.raw(try view.rom()));
        try testing.expectEqual(@as(u8, 0xFE), try view.intrLine());
        try testing.expectEqual(IntrPin.inta, try view.intrPin());
        try testing.expectEqual(@as(u16, 0xAD53), BridgeControl.raw(try view.bridgeControl()));
    }

    test "Type1 writes exact type-1 bridge bytes" {
        var bytes: [pcie_window_size]u8 = @splat(0xA5);
        const sbdf = Sbdf.from(.from(0), 0, 2, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const view = Type1.from(Function.from(backend.config(), sbdf));

        try view.setPrimaryBus(0x11);

        try testing.expectEqual(@as(u8, 0x11), bytes[byte_offsets.primary_bus]);

        try view.setSecondaryBus(0x22);

        try testing.expectEqual(@as(u8, 0x22), bytes[byte_offsets.secondary_bus]);

        try view.setSubordinateBus(0x33);

        try testing.expectEqual(@as(u8, 0x33), bytes[byte_offsets.subordinate_bus]);

        try view.setSecondaryLatencyTimer(0x44);

        try testing.expectEqual(@as(u8, 0x44), bytes[byte_offsets.secondary_latency_timer]);

        try view.setIoBaseLo(0x55);

        try testing.expectEqual(@as(u8, 0x55), bytes[byte_offsets.io_base_lo]);

        try view.setIoLimitLo(0x66);

        try testing.expectEqual(@as(u8, 0x66), bytes[byte_offsets.io_limit_lo]);

        try view.setIoBaseHi(0x7788);

        try testing.expectEqual(@as(u8, 0x88), bytes[byte_offsets.io_base_hi]);
        try testing.expectEqual(@as(u8, 0x77), bytes[byte_offsets.io_base_hi + 1]);

        try view.setIoLimitHi(0x99AA);

        try testing.expectEqual(@as(u8, 0xAA), bytes[byte_offsets.io_limit_hi]);
        try testing.expectEqual(@as(u8, 0x99), bytes[byte_offsets.io_limit_hi + 1]);

        try view.setMemBase(0xBBCD);

        try testing.expectEqual(@as(u8, 0xCD), bytes[byte_offsets.mem_base]);
        try testing.expectEqual(@as(u8, 0xBB), bytes[byte_offsets.mem_base + 1]);

        try view.setMemLimit(0xDDEF);

        try testing.expectEqual(@as(u8, 0xEF), bytes[byte_offsets.mem_limit]);
        try testing.expectEqual(@as(u8, 0xDD), bytes[byte_offsets.mem_limit + 1]);

        try view.setPrefetchBaseLo(0x1357);

        try testing.expectEqual(@as(u8, 0x57), bytes[byte_offsets.prefetch_base_lo]);
        try testing.expectEqual(@as(u8, 0x13), bytes[byte_offsets.prefetch_base_lo + 1]);

        try view.setPrefetchLimitLo(0x2468);

        try testing.expectEqual(@as(u8, 0x68), bytes[byte_offsets.prefetch_limit_lo]);
        try testing.expectEqual(@as(u8, 0x24), bytes[byte_offsets.prefetch_limit_lo + 1]);

        try view.setPrefetchBaseHi(0x89AB_CDEF);

        try testing.expectEqual(@as(u8, 0xEF), bytes[byte_offsets.prefetch_base_hi]);
        try testing.expectEqual(@as(u8, 0xCD), bytes[byte_offsets.prefetch_base_hi + 1]);
        try testing.expectEqual(@as(u8, 0xAB), bytes[byte_offsets.prefetch_base_hi + 2]);
        try testing.expectEqual(@as(u8, 0x89), bytes[byte_offsets.prefetch_base_hi + 3]);

        try view.setPrefetchLimitHi(0x0123_4567);

        try testing.expectEqual(@as(u8, 0x67), bytes[byte_offsets.prefetch_limit_hi]);
        try testing.expectEqual(@as(u8, 0x45), bytes[byte_offsets.prefetch_limit_hi + 1]);
        try testing.expectEqual(@as(u8, 0x23), bytes[byte_offsets.prefetch_limit_hi + 2]);
        try testing.expectEqual(@as(u8, 0x01), bytes[byte_offsets.prefetch_limit_hi + 3]);

        try view.clearSecondaryStatus(Status.masks.w1c);

        try testing.expectEqual(@as(u8, 0x00), bytes[byte_offsets.secondary_status]);
        try testing.expectEqual(@as(u8, 0xF9), bytes[byte_offsets.secondary_status + 1]);

        try view.clearSecondaryStatus(0xFFFF);

        try testing.expectEqual(@as(u8, 0xFF), bytes[byte_offsets.secondary_status]);
        try testing.expectEqual(@as(u8, 0xFF), bytes[byte_offsets.secondary_status + 1]);

        try view.setIntrLine(0xEE);

        try testing.expectEqual(@as(u8, 0xEE), bytes[byte_offsets.intr_line]);

        try view.setRom(ExpansionRom.from(0x7654_3210));

        try testing.expectEqual(@as(u8, 0x10), bytes[byte_offsets.rom_base]);
        try testing.expectEqual(@as(u8, 0x32), bytes[byte_offsets.rom_base + 1]);
        try testing.expectEqual(@as(u8, 0x54), bytes[byte_offsets.rom_base + 2]);
        try testing.expectEqual(@as(u8, 0x76), bytes[byte_offsets.rom_base + 3]);

        try view.setBridgeControl(BridgeControl.from(0xAD53));

        try testing.expectEqual(@as(u8, 0x53), bytes[byte_offsets.bridge_control]);
        try testing.expectEqual(@as(u8, 0xAD), bytes[byte_offsets.bridge_control + 1]);
    }

    test "Type1 rejects reserved interrupt-pin bytes" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        bytes[0x3D] = 5;
        const sbdf = Sbdf.from(.from(0), 0, 5, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const view = Type1.from(Function.from(backend.config(), sbdf));

        try testing.expectError(error.MalformedField, view.intrPin());
    }

    fn store16(bytes: *[pcie_window_size]u8, offset: usize, value: u16) void {
        std.debug.assert(offset + 2 <= bytes.len);
        bytes[offset] = @truncate(value);
        bytes[offset + 1] = @truncate(value >> 8);
    }

    fn store32(bytes: *[pcie_window_size]u8, offset: usize, value: u32) void {
        std.debug.assert(offset + 4 <= bytes.len);
        bytes[offset] = @truncate(value);
        bytes[offset + 1] = @truncate(value >> 8);
        bytes[offset + 2] = @truncate(value >> 16);
        bytes[offset + 3] = @truncate(value >> 24);
    }

    fn seedType1Header(bytes: *[pcie_window_size]u8, fields: struct {
        bars: [num_bar_slots]u32,
        primary_bus: u8,
        secondary_bus: u8,
        subordinate_bus: u8,
        secondary_latency_timer: u8,
        io_base_lo: u8,
        io_limit_lo: u8,
        secondary_status: u16,
        mem_base: u16,
        mem_limit: u16,
        prefetch_base_lo: u16,
        prefetch_limit_lo: u16,
        prefetch_base_hi: u32,
        prefetch_limit_hi: u32,
        io_base_hi: u16,
        io_limit_hi: u16,
        cap_ptr: u8,
        rom_base: u32,
        intr_line: u8,
        intr_pin: u8,
        bridge_control: u16,
    }) void {
        bytes.* = @splat(0);
        bytes[0x0E] = 0x01;

        inline for (fields.bars, 0..) |raw, index| {
            store32(bytes, byte_offsets.bars + 4 * index, raw);
        }

        bytes[byte_offsets.primary_bus] = fields.primary_bus;
        bytes[byte_offsets.secondary_bus] = fields.secondary_bus;
        bytes[byte_offsets.subordinate_bus] = fields.subordinate_bus;
        bytes[byte_offsets.secondary_latency_timer] = fields.secondary_latency_timer;
        bytes[byte_offsets.io_base_lo] = fields.io_base_lo;
        bytes[byte_offsets.io_limit_lo] = fields.io_limit_lo;
        store16(bytes, byte_offsets.secondary_status, fields.secondary_status);
        store16(bytes, byte_offsets.mem_base, fields.mem_base);
        store16(bytes, byte_offsets.mem_limit, fields.mem_limit);
        store16(bytes, byte_offsets.prefetch_base_lo, fields.prefetch_base_lo);
        store16(bytes, byte_offsets.prefetch_limit_lo, fields.prefetch_limit_lo);
        store32(bytes, byte_offsets.prefetch_base_hi, fields.prefetch_base_hi);
        store32(bytes, byte_offsets.prefetch_limit_hi, fields.prefetch_limit_hi);
        store16(bytes, byte_offsets.io_base_hi, fields.io_base_hi);
        store16(bytes, byte_offsets.io_limit_hi, fields.io_limit_hi);
        bytes[byte_offsets.cap_ptr] = fields.cap_ptr;
        store32(bytes, byte_offsets.rom_base, fields.rom_base);
        bytes[byte_offsets.intr_line] = fields.intr_line;
        bytes[byte_offsets.intr_pin] = fields.intr_pin;
        store16(bytes, byte_offsets.bridge_control, fields.bridge_control);
    }
};
