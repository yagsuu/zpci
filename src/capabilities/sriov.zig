const std = @import("std");
const stdx = @import("stdx");

const bar = @import("bar");
const config = @import("config");
const core = @import("core");

const extended = @import("extended.zig");
const sriov = core.capabilities.sriov;

const Rel8 = core.RelativeOffset(u8);
const Rel16 = core.RelativeOffset(u16);
const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = extended.Entry;
const Registers = extended.Registers;

const Sbdf = core.Sbdf;
const Bdf = core.Bdf;
const DeviceId = core.DeviceId;
const Capabilities = sriov.Capabilities.Word;
const Control = sriov.Control.Word;
const Status = sriov.Status.Word;

const Bar = bar.Bar;
const Memory = core.bar.Memory;
const Memory64 = core.bar.Memory64;

const slots = sriov.num_bar_slots;

pub const Error = extended.Error || error{
    InvalidValue,
    ActiveVfs,
    MalformedBar,
    BusRangeExhausted,
    ProgrammingReadbackMismatch,
    ProgrammingPartial,
};

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, entry: Entry) Error!Capability {
        std.debug.assert(entry.id == sriov.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        if (!registers.contains(offsets.migration_array)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const entry = (try extended.find(function, sriov.id)) orelse return null;
        return try Capability.tryFrom(function, entry);
    }

    pub fn capabilities(self: Capability) Error!Capabilities {
        return sriov.Capabilities.from(try self.registers.read(offsets.capabilities));
    }

    pub fn control(self: Capability) Error!Control {
        return sriov.Control.from(try self.registers.read(offsets.control));
    }

    pub fn status(self: Capability) Error!Status {
        return sriov.Status.from(try self.registers.read(offsets.status));
    }

    pub fn ackStatus(self: Capability, observed: Status, comptime fields: anytype) Error!void {
        return self.registers.write(offsets.status, sriov.Status.ack(observed, fields));
    }

    pub fn initialVfs(self: Capability) Error!u16 {
        return self.registers.read(offsets.initial_vfs);
    }

    pub fn totalVfs(self: Capability) Error!u16 {
        return self.registers.read(offsets.total_vfs);
    }

    pub fn numVfs(self: Capability) Error!u16 {
        return self.registers.read(offsets.num_vfs);
    }

    pub fn setNumVfs(self: Capability, count: u16) Error!void {
        if ((try self.control()).vf_enable) {
            return error.ActiveVfs;
        }

        if (count > try self.totalVfs()) {
            return error.InvalidValue;
        }

        return self.writeNumVfs(count);
    }

    pub fn deviceId(self: Capability) Error!DeviceId {
        return .from(try self.registers.read(offsets.vf_device_id));
    }

    pub fn supportedPageSizes(self: Capability) Error!PageSizes {
        return .from(try self.registers.read(offsets.supported_page_sizes));
    }

    pub fn systemPageSize(self: Capability) Error!PageSize {
        const raw = try self.registers.read(offsets.system_page_size);
        if (raw == 0 or !std.math.isPowerOfTwo(raw)) {
            return error.InvalidValue;
        }

        return .from(@intCast(@ctz(raw)));
    }

    pub fn setPageSize(self: Capability, size: PageSize) Error!void {
        if ((try self.control()).vf_enable) {
            return error.ActiveVfs;
        }

        if (!(try self.supportedPageSizes()).supports(size)) {
            return error.InvalidValue;
        }

        try self.registers.write(offsets.system_page_size, size.mask());
        if (try self.registers.read(offsets.system_page_size) != size.mask()) {
            return error.ProgrammingReadbackMismatch;
        }
    }

    pub fn routing(self: Capability) Error!Routing {
        const count = try self.numVfs();
        if (count > try self.totalVfs()) {
            return error.InvalidValue;
        }

        return Routing.tryFrom(.{
            .pf = self.registers.function.sbdf,
            .num_vfs = count,
            .first = try self.registers.read(offsets.first_vf_offset),
            .stride = try self.registers.read(offsets.vf_stride),
        });
    }

    pub fn bars(self: Capability) Bars {
        return .{ .registers = self.registers };
    }

    pub fn enable(self: Capability) Error!void {
        const observed = try self.control();
        if (observed.vf_enable) {
            return error.ActiveVfs;
        }

        const route = try self.routing();
        if (route.num_vfs == 0) {
            return error.InvalidValue;
        }

        const page = try self.systemPageSize();
        if (!(try self.supportedPageSizes()).supports(page)) {
            return error.InvalidValue;
        }

        const updated = sriov.Control.replace(observed, .{ .vf_enable = true });
        return self.registers.write(offsets.control, sriov.Control.raw(updated));
    }

    pub fn disable(self: Capability) Error!void {
        const observed = try self.control();
        const updated = sriov.Control.replace(observed, .{ .vf_enable = false, .vf_mem_enable = false });

        return self.registers.write(offsets.control, sriov.Control.raw(updated));
    }

    pub fn setMemoryEnabled(self: Capability, enabled: bool) Error!void {
        const observed = try self.control();
        const updated = sriov.Control.replace(observed, .{ .vf_mem_enable = enabled });

        return self.registers.write(offsets.control, sriov.Control.raw(updated));
    }

    pub fn setAriHierarchy(self: Capability, enabled: bool) Error!void {
        const observed = try self.control();
        if (observed.vf_enable) {
            return error.ActiveVfs;
        }

        const updated = sriov.Control.replace(observed, .{ .ari_hierarchy = enabled });
        const raw = sriov.Control.raw(updated);

        if (raw == sriov.Control.raw(observed)) {
            return;
        }

        try self.registers.write(offsets.control, raw);
        if (try self.registers.read(offsets.control) != raw) {
            return error.ProgrammingReadbackMismatch;
        }
    }

    pub fn reserveBuses(self: Capability, capacity: u16) Error!u8 {
        if ((try self.control()).vf_enable) {
            return error.ActiveVfs;
        }

        const result = self.probeBuses(capacity);
        self.writeNumVfs(0) catch return error.ProgrammingPartial;
        return result;
    }

    fn probeBuses(self: Capability, capacity: u16) Error!u8 {
        try self.writeNumVfs(0);

        if (capacity > try self.totalVfs()) {
            return error.InvalidValue;
        }

        const bdf = self.registers.function.sbdf.bdf;

        var highest = bdf.bus;
        var count: u32 = 1;
        while (count <= capacity) : (count += 1) {
            try self.writeNumVfs(@intCast(count));

            const offset = try self.registers.read(offsets.first_vf_offset);
            const stride = try self.registers.read(offsets.vf_stride);

            if (offset == 0 or (count > 1 and stride == 0)) {
                return error.InvalidValue;
            }

            const last = @as(u64, bdf.raw()) + offset + @as(u64, stride) * (count - 1);
            if (last > std.math.maxInt(u16)) {
                return error.BusRangeExhausted;
            }

            const bus: u8 = @intCast(last >> 8);
            if (bus < bdf.bus) {
                return error.BusRangeExhausted;
            }

            highest = @max(highest, bus);
        }

        return highest;
    }

    fn writeNumVfs(self: Capability, count: u16) Error!void {
        try self.registers.write(offsets.num_vfs, count);
        if (try self.registers.read(offsets.num_vfs) != count) {
            return error.ProgrammingReadbackMismatch;
        }
    }
};

pub const PageSize = enum(u5) {
    size_4k = 0,
    size_8k = 1,
    size_16k = 2,
    size_32k = 3,
    size_64k = 4,
    size_256k = 6,
    size_1m = 8,
    size_4m = 10,
    _,

    pub fn from(index: u5) PageSize {
        return @fromBackingInt(index);
    }

    pub fn bytes(self: PageSize) u64 {
        return @as(u64, 1) << (@as(u6, @backingInt(self)) + 12);
    }

    pub fn mask(self: PageSize) u32 {
        return @as(u32, 1) << @backingInt(self);
    }
};

pub const PageSizes = packed struct(u32) {
    bits: u32,

    pub fn from(bits: u32) PageSizes {
        return .{ .bits = bits };
    }

    pub fn raw(self: PageSizes) u32 {
        return self.bits;
    }

    pub fn supports(self: PageSizes, size: PageSize) bool {
        return self.bits & size.mask() != 0;
    }
};

pub const Routing = struct {
    pf: Sbdf,
    num_vfs: u16,
    first: u16,
    stride: u16,

    pub const Args = struct {
        pf: Sbdf,
        num_vfs: u16,
        first: u16,
        stride: u16,
    };

    pub fn tryFrom(args: Args) Error!Routing {
        const result: Routing = .{
            .pf = args.pf,
            .num_vfs = args.num_vfs,
            .first = args.first,
            .stride = args.stride,
        };

        if (args.num_vfs != 0) {
            if (args.first == 0 or (args.num_vfs > 1 and args.stride == 0)) {
                return error.InvalidValue;
            }

            _ = try result.vf(args.num_vfs - 1);
        }

        return result;
    }

    pub fn vf(self: Routing, index: u16) Error!Sbdf {
        if (index >= self.num_vfs) {
            return error.OutOfBounds;
        }

        const raw = @as(u64, self.pf.bdf.raw()) + self.first + @as(u64, self.stride) * index;
        if (raw > std.math.maxInt(u16)) {
            return error.BusRangeExhausted;
        }

        return .fromBdf(self.pf.segment, @as(Bdf, @bitCast(@as(u16, @intCast(raw)))));
    }
};

pub const BarRef = struct {
    bars: Bars,
    index: usize,

    pub fn from(bars: Bars, index: usize) BarRef {
        std.debug.assert(index < bars.numSlots());

        return .{ .bars = bars, .index = index };
    }
};

pub const Bars = struct {
    registers: Registers,

    pub const Result = stdx.collections.List.Static(Bar, slots);

    pub fn numSlots(_: Bars) usize {
        return slots;
    }

    pub fn offset(index: usize) Rel32 {
        std.debug.assert(index < slots);
        return Rel32.from(core.capabilities.sriov.offsets.vf_bar0 + core.bar.stride * index);
    }

    pub fn read(self: Bars, index: usize) Error!u32 {
        return self.registers.read(offset(index));
    }

    pub fn write(self: Bars, index: usize, value: u32) Error!void {
        try self.requireDisabled();

        try self.registers.write(offset(index), value);
    }

    pub fn iterator(self: Bars) BarIterator {
        return .{ .bars = self };
    }

    pub fn decode(self: Bars, index: usize) Error!Bar {
        const lo = try self.read(index);
        const wide = try isWide(lo, index);

        if (lo == 0) {
            return .{ .index = index, .type = .none };
        }

        const hi = if (wide) try self.read(index + 1) else 0;
        return entry(index, lo, hi, wide, null);
    }

    pub fn probe(self: Bars, index: usize) Error!Bar {
        try self.requireDisabled();

        const lo = try self.read(index);
        const wide = try isWide(lo, index);
        const hi = if (wide) try self.read(index + 1) else 0;

        var attempted_hi = false;
        const attempt: Error!RawBar = attempt: {
            self.registers.write(offset(index), std.math.maxInt(u32)) catch |err| {
                break :attempt err;
            };

            if (wide) {
                attempted_hi = true;
                self.registers.write(offset(index + 1), std.math.maxInt(u32)) catch |err| {
                    break :attempt err;
                };
            }

            break :attempt .{
                .lo = self.read(index) catch |err| break :attempt err,
                .hi = if (wide) self.read(index + 1) catch |err| break :attempt err else 0,
            };
        };

        var restored = true;
        self.registers.write(offset(index), lo) catch {
            restored = false;
        };

        if (attempted_hi) {
            self.registers.write(offset(index + 1), hi) catch {
                restored = false;
            };
        }

        if (!restored) {
            return error.ProgrammingPartial;
        }

        const raw = try attempt;
        if (raw.lo == 0 and raw.hi == 0 and lo == 0) {
            return .{ .index = index, .type = .none };
        }

        if (raw.lo & 0xF != lo & 0xF) {
            return error.MalformedBar;
        }

        const mask: u64 = if (wide) Memory64.from(raw.lo, raw.hi).base() else Memory.from(raw.lo).base();
        const size = if (wide) ~mask +% 1 else @as(u64, ~@as(u32, @intCast(mask))) + 1;

        if (size < 4096 or !std.math.isPowerOfTwo(size)) {
            return error.MalformedBar;
        }

        return entry(index, lo, hi, wide, size);
    }

    pub fn probeAll(self: Bars) Error!Result {
        try self.requireDisabled();

        var result = Result.init();
        var index: usize = 0;

        while (index < slots) {
            const value = try self.probe(index);
            result.appendAssumeCapacity(value);
            index += value.numSlots();
        }

        return result;
    }

    fn requireDisabled(self: Bars) Error!void {
        const capability: Capability = .{ .registers = self.registers };
        if ((try capability.control()).vf_enable) {
            return error.ActiveVfs;
        }
    }

    fn isWide(lo: u32, index: usize) Error!bool {
        const memory = Memory.from(lo);
        if (memory.space != .mem) {
            return error.MalformedBar;
        }

        return switch (memory.type) {
            .bits_32 => false,
            .bits_64 => if (index + 1 < slots) true else error.MalformedBar,
            else => error.MalformedBar,
        };
    }

    fn entry(index: usize, lo: u32, hi: u32, wide: bool, size: ?u64) Bar {
        const memory = Memory.from(lo);

        return .{
            .index = index,
            .type = .{ .memory = .{
                .base = if (wide) Memory64.from(lo, hi).base() else memory.base(),
                .size = size,
                .width = if (wide) .bits_64 else .bits_32,
                .prefetchable = memory.prefetchable,
            } },
        };
    }
};

pub const BarIterator = struct {
    bars: Bars,
    index: usize = 0,

    pub fn next(self: *BarIterator) Error!?Bar {
        if (self.index == slots) {
            return null;
        }

        const value = try self.bars.decode(self.index);
        self.index += value.numSlots();

        return value;
    }
};

const RawBar = struct {
    lo: u32,
    hi: u32,
};

pub const offsets = struct {
    pub const capabilities = Rel32.from(sriov.offsets.capabilities);
    pub const control = Rel16.from(sriov.offsets.control);
    pub const status = Rel16.from(sriov.offsets.status);
    pub const initial_vfs = Rel16.from(sriov.offsets.initial_vfs);
    pub const total_vfs = Rel16.from(sriov.offsets.total_vfs);
    pub const num_vfs = Rel16.from(sriov.offsets.num_vfs);
    pub const function_dependency = Rel8.from(sriov.offsets.function_dependency);
    pub const first_vf_offset = Rel16.from(sriov.offsets.first_vf_offset);
    pub const vf_stride = Rel16.from(sriov.offsets.vf_stride);
    pub const vf_device_id = Rel16.from(sriov.offsets.vf_device_id);
    pub const supported_page_sizes = Rel32.from(sriov.offsets.supported_page_sizes);
    pub const system_page_size = Rel32.from(sriov.offsets.system_page_size);
    pub const vf_bar0 = Rel32.from(sriov.offsets.vf_bar0);
    pub const vf_bar1 = Rel32.from(sriov.offsets.vf_bar1);
    pub const vf_bar2 = Rel32.from(sriov.offsets.vf_bar2);
    pub const vf_bar3 = Rel32.from(sriov.offsets.vf_bar3);
    pub const vf_bar4 = Rel32.from(sriov.offsets.vf_bar4);
    pub const vf_bar5 = Rel32.from(sriov.offsets.vf_bar5);
    pub const migration_array = Rel32.from(sriov.offsets.migration_array);
};

pub const unit = struct {
    const testing = std.testing;

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;

    const base: u16 = 0x100;
    const first = @as(usize, base) + sriov.offsets.vf_bar0;

    const Backend = struct {
        control: u16 = 0,
        total: u16 = 3,
        num: u16 = 0xFFFF,
        supported_pages: u32 = 0xFFFF_FFFF,
        page: u32 = 1,
        page_writes: usize = 0,
        page_invalidations: usize = 0,
        bar_address: u32 = 0xA000_0000,
        quiet: bool = false,
        quiet_accesses: usize = 0,
        vf_requests: usize = 0,
        fail_after_disable: bool = false,
        fail_after_enable: bool = false,
        block_active_reads: bool = false,
        active_reads: usize = 0,
        first: [4]u16 = .{ 0, 0x400, 1, 1 },
        stride: [4]u16 = .{ 0, 0, 1, 1 },
        writes: [16]u16 = @splat(0),
        write_count: usize = 0,
        num_reads: usize = 0,
        fail_write: ?usize = null,
        fail_num_read: ?usize = null,
        reject_write: ?usize = null,
        fail_offset: bool = false,
        fail_total: bool = false,
        bus: u8 = 2,
        device: u5 = 0,
        function: u3 = 0,

        fn capability(self: *Backend) Capability {
            return .{ .registers = .{
                .function = Function.from(ConfigSpace.from(self, &vtable), Sbdf.from(core.SegmentId.from(0), self.bus, self.device, self.function)),
                .base = base,
            } };
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(context: *anyopaque, sbdf: Sbdf, _: usize) ConfigError!u8 {
            const self: *Backend = @ptrCast(@alignCast(context));
            if (!sbdf.eql(self.capability().registers.function.sbdf)) {
                self.vf_requests += 1;
                return error.OutOfBounds;
            }

            return error.UnsupportedAccessWidth;
        }

        fn read32(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u32 {
            const self: *Backend = @ptrCast(@alignCast(context));
            if (!sbdf.eql(self.capability().registers.function.sbdf)) {
                self.vf_requests += 1;
                return error.OutOfBounds;
            }

            if (self.quiet) {
                self.quiet_accesses += 1;
                return error.OutOfBounds;
            }

            return switch (offset - base) {
                0 => 0x0001_0010,
                sriov.offsets.capabilities => 0x4,
                sriov.offsets.supported_page_sizes => self.supported_pages,
                sriov.offsets.system_page_size => self.page,
                else => error.UnsupportedAccessWidth,
            };
        }

        fn read16(context: *anyopaque, sbdf: Sbdf, offset: usize) ConfigError!u16 {
            const self: *Backend = @ptrCast(@alignCast(context));
            if (!sbdf.eql(self.capability().registers.function.sbdf)) {
                self.vf_requests += 1;
                return error.OutOfBounds;
            }

            if (self.block_active_reads and self.control & 1 != 0) {
                self.active_reads += 1;
                return error.OutOfBounds;
            }

            if (self.quiet) {
                self.quiet_accesses += 1;
                return error.OutOfBounds;
            }

            switch (offset - base) {
                sriov.offsets.control => return self.control,
                sriov.offsets.status => return 0,
                sriov.offsets.initial_vfs => return self.total,
                sriov.offsets.vf_device_id => return 0xABCD,
                sriov.offsets.total_vfs => {
                    if (self.fail_total) {
                        return error.OutOfBounds;
                    }

                    return self.total;
                },
                sriov.offsets.num_vfs => {
                    self.num_reads += 1;
                    if (self.fail_num_read == self.num_reads) {
                        return error.OutOfBounds;
                    }

                    return self.num;
                },
                sriov.offsets.first_vf_offset => {
                    if (self.fail_offset) {
                        return error.OutOfBounds;
                    }

                    return self.first[@min(self.num, 3)];
                },
                sriov.offsets.vf_stride => return self.stride[@min(self.num, 3)],
                else => return error.UnsupportedAccessWidth,
            }
        }

        fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write32(context: *anyopaque, _: Sbdf, offset: usize, value: u32) ConfigError!void {
            const self: *Backend = @ptrCast(@alignCast(context));
            if (self.quiet) {
                self.quiet_accesses += 1;
                return error.OutOfBounds;
            }

            if (offset != base + sriov.offsets.system_page_size) {
                return error.UnsupportedAccessWidth;
            }

            self.page_writes += 1;
            self.page = value;
            self.page_invalidations += 1;
            self.bar_address = 0xFFFF_FFFF;
        }

        fn write16(context: *anyopaque, _: Sbdf, offset: usize, value: u16) ConfigError!void {
            const self: *Backend = @ptrCast(@alignCast(context));
            if (self.quiet) {
                self.quiet_accesses += 1;
                return error.OutOfBounds;
            }

            self.write_count += 1;
            if (self.write_count <= self.writes.len) {
                self.writes[self.write_count - 1] = value;
            }
            if (self.fail_write == self.write_count) {
                return error.OutOfBounds;
            }

            if (self.reject_write == self.write_count) {
                return;
            }

            switch (offset - base) {
                sriov.offsets.control => {
                    const was_enabled = self.control & 1 != 0;
                    self.control = value;

                    if (!was_enabled and value & 1 != 0 and self.fail_after_enable) {
                        return error.OutOfBounds;
                    }

                    if (was_enabled and value & 1 == 0) {
                        self.quiet = true;
                        if (self.fail_after_disable) {
                            return error.OutOfBounds;
                        }
                    }
                },
                sriov.offsets.num_vfs => self.num = value,
                else => return error.UnsupportedAccessWidth,
            }
        }
    };

    const BarBackend = struct {
        values: [slots]u32 = @splat(0),
        masks: [slots]u32 = @splat(0),
        probing: [slots]bool = @splat(false),
        control: u16 = 0x18,
        page_sensitive: bool = false,
        page_size: u32 = 1,
        writes: usize = 0,
        fail_write: ?usize = null,
        fail_restore: ?usize = null,
        fail_read: ?usize = null,
        log: [32]usize = undefined,

        fn bars(self: *BarBackend) Bars {
            return .{ .registers = .{
                .function = Function.from(ConfigSpace.from(self, &vtable), Sbdf.from(.from(0), 0, 0, 0)),
                .base = base,
            } };
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
            return error.UnsupportedAccessWidth;
        }

        fn write8(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write16(_: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn read16(context: *anyopaque, _: Sbdf, position: usize) ConfigError!u16 {
            const self: *BarBackend = @ptrCast(@alignCast(context));
            if (position != base + core.capabilities.sriov.offsets.control) {
                return error.UnsupportedAccessWidth;
            }

            return self.control;
        }

        fn read32(context: *anyopaque, _: Sbdf, position: usize) ConfigError!u32 {
            const self: *BarBackend = @ptrCast(@alignCast(context));
            if (position == base + core.capabilities.sriov.offsets.supported_page_sizes) {
                return 0x11;
            }

            if (position == base + core.capabilities.sriov.offsets.system_page_size) {
                return self.page_size;
            }

            const index = (position - first) / 4;
            if (self.probing[index]) {
                if (self.fail_read == index) {
                    return error.OutOfBounds;
                }

                if (self.page_sensitive and index == 0) {
                    return (if (self.page_size == 1) @as(u32, 0xFFFF_F000) else @as(u32, 0xFFFF_0000)) |
                        (self.values[0] & 0xF);
                }

                return self.masks[index];
            }

            return self.values[index];
        }

        fn write32(context: *anyopaque, _: Sbdf, position: usize, value: u32) ConfigError!void {
            const self: *BarBackend = @ptrCast(@alignCast(context));
            if (position == base + core.capabilities.sriov.offsets.system_page_size) {
                self.page_size = value;
                if (self.page_sensitive) {
                    self.values[0] &= 0xF;
                }

                return;
            }

            const index = (position - first) / 4;
            self.log[self.writes] = index;
            self.writes += 1;
            self.probing[index] = value == std.math.maxInt(u32);
            if (!self.probing[index]) {
                self.values[index] = value;
            }

            if (self.fail_write == self.writes or
                (self.fail_restore == index and !self.probing[index]))
            {
                return error.OutOfBounds;
            }
        }
    };

    test "SR-IOV discovery validates the complete capability extent" {
        var backend: Backend = .{};
        try testing.expect((try Capability.find(backend.capability().registers.function)) != null);
        try testing.expectError(error.MalformedCapability, Capability.tryFrom(backend.capability().registers.function, .{ .id = .sriov, .version = 1, .offset = 0xFE0 }));
    }

    test "SR-IOV probes all counts and reserves the nonmonotonic maximum" {
        var backend: Backend = .{};
        try testing.expectEqual(@as(u8, 6), try backend.capability().reserveBuses(3));
        try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, 0 }, backend.writes[0..backend.write_count]);
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV zero capacity normalizes undefined NumVFs without consulting InitialVFs" {
        var backend: Backend = .{};
        try testing.expectEqual(@as(u8, 2), try backend.capability().reserveBuses(0));
        try testing.expectEqualSlices(u16, &.{ 0, 0 }, backend.writes[0..backend.write_count]);
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV supports the full u16 VF count without loop overflow" {
        var backend: Backend = .{
            .bus = 0,
            .total = 65535,
            .first = .{ 0, 1, 1, 1 },
            .stride = .{ 0, 0, 1, 1 },
        };

        try testing.expectEqual(@as(u8, 255), try backend.capability().reserveBuses(65535));
        try testing.expectEqual(@as(usize, 65537), backend.write_count);
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV active VFs reject reservation and hierarchy changes without writes" {
        var backend: Backend = .{ .control = 1 };
        try testing.expectError(error.ActiveVfs, backend.capability().reserveBuses(0));
        try testing.expectError(error.ActiveVfs, backend.capability().setAriHierarchy(true));
        try testing.expectEqual(@as(usize, 0), backend.write_count);
        try testing.expectEqual(@as(u16, 0xFFFF), backend.num);
    }

    test "SR-IOV rejects counts beyond TotalVFs and clears NumVFs" {
        var backend: Backend = .{};
        try testing.expectError(error.InvalidValue, backend.capability().reserveBuses(4));
        try testing.expectEqual(@as(u16, 0), backend.num);
        try testing.expectEqualSlices(u16, &.{ 0, 0 }, backend.writes[0..backend.write_count]);
    }

    test "SR-IOV validates offsets and multi-VF stride after each count" {
        var zero_offset: Backend = .{ .first = .{ 0, 0, 1, 1 } };
        try testing.expectError(error.InvalidValue, zero_offset.capability().reserveBuses(1));
        try testing.expectEqual(@as(u16, 0), zero_offset.num);

        var zero_stride: Backend = .{ .stride = .{ 0, 0, 0, 1 } };
        try testing.expectError(error.InvalidValue, zero_stride.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), zero_stride.num);
    }

    test "SR-IOV RID includes device and function and accepts the final RID" {
        var backend: Backend = .{ .bus = 255, .device = 31, .function = 6, .first = .{ 0, 1, 1, 1 } };
        try testing.expectEqual(@as(u8, 255), try backend.capability().reserveBuses(1));
        try testing.expectError(error.BusRangeExhausted, backend.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV widened RID arithmetic rejects very large spans" {
        var backend: Backend = .{ .first = .{ 0, 1, 1, 1 }, .stride = .{ 0, 0, 0xFFFF, 0xFFFF } };
        try testing.expectError(error.BusRangeExhausted, backend.capability().reserveBuses(3));
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "SR-IOV preserves primary read and write errors after successful cleanup" {
        var offset_failure: Backend = .{ .fail_offset = true };
        try testing.expectError(error.OutOfBounds, offset_failure.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), offset_failure.num);

        var total_failure: Backend = .{ .fail_total = true };
        try testing.expectError(error.OutOfBounds, total_failure.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), total_failure.num);

        var write_failure: Backend = .{ .fail_write = 2 };
        try testing.expectError(error.OutOfBounds, write_failure.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), write_failure.num);

        var initial_failure: Backend = .{ .fail_write = 1 };
        try testing.expectError(error.OutOfBounds, initial_failure.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), initial_failure.num);
    }

    test "SR-IOV detects rejected writes and cleans up failed readbacks" {
        var rejected: Backend = .{ .reject_write = 2 };
        try testing.expectError(error.ProgrammingReadbackMismatch, rejected.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), rejected.num);

        var failed_read: Backend = .{ .fail_num_read = 2 };
        try testing.expectError(error.OutOfBounds, failed_read.capability().reserveBuses(2));
        try testing.expectEqual(@as(u16, 0), failed_read.num);
    }

    test "SR-IOV cleanup failure takes precedence over primary errors and success" {
        var failed_write: Backend = .{ .fail_offset = true, .fail_write = 3 };
        try testing.expectError(error.ProgrammingPartial, failed_write.capability().reserveBuses(1));

        var failed_read: Backend = .{ .fail_offset = true, .fail_num_read = 3 };
        try testing.expectError(error.ProgrammingPartial, failed_read.capability().reserveBuses(1));

        var rejected: Backend = .{ .reject_write = 3 };
        try testing.expectError(error.ProgrammingPartial, rejected.capability().reserveBuses(1));

        var success: Backend = .{ .fail_write = 3 };
        try testing.expectError(error.ProgrammingPartial, success.capability().reserveBuses(1));
    }

    test "SR-IOV hierarchy updates preserve all unrelated control bits" {
        var backend: Backend = .{ .control = 0xA06E };
        try backend.capability().setAriHierarchy(true);
        try testing.expectEqual(@as(u16, 0xA07E), backend.control);
        try backend.capability().setAriHierarchy(false);
        try testing.expectEqual(@as(u16, 0xA06E), backend.control);

        const writes = backend.write_count;
        try backend.capability().setAriHierarchy(false);
        try testing.expectEqual(writes, backend.write_count);

        var rejected: Backend = .{ .reject_write = 1 };
        try testing.expectError(error.ProgrammingReadbackMismatch, rejected.capability().setAriHierarchy(true));
    }

    test "VF page selection validates support and invalidates BAR addresses before reprobe" {
        var backend: Backend = .{ .supported_pages = 0x11 };
        const cap = backend.capability();

        try cap.setPageSize(.size_64k);
        try testing.expectEqual(@as(u32, 0x10), backend.page);
        try testing.expectEqual(PageSize.size_64k, try cap.systemPageSize());
        try testing.expectEqual(@as(u64, 65536), (try cap.systemPageSize()).bytes());
        try testing.expectEqual(@as(u32, 0xFFFF_FFFF), backend.bar_address);

        try testing.expectError(error.InvalidValue, cap.setPageSize(.size_8k));
        try testing.expectEqual(@as(usize, 1), backend.page_writes);

        backend.control = 1;
        try testing.expectError(error.ActiveVfs, cap.setPageSize(.size_4k));
        try testing.expectEqual(@as(usize, 1), backend.page_writes);

        backend.control = 0;
        for ([_]u32{ 0, 3 }) |raw| {
            backend.page = raw;
            try testing.expectError(error.InvalidValue, cap.systemPageSize());
        }

        try testing.expectEqual(@as(u64, 1) << 43, PageSize.from(31).bytes());
        try testing.expect(PageSizes.from(0x8000_0000).supports(.from(31)));
    }

    test "selected VF count refreshes geometry across device and bus boundaries" {
        var backend: Backend = .{ .device = 31, .function = 7 };
        const cap = backend.capability();

        try cap.setNumVfs(1);
        const one = try cap.routing();
        try testing.expectEqual(@as(u16, 0x06FF), (try one.vf(0)).bdf.raw());

        try cap.setNumVfs(3);
        const three = try cap.routing();

        try testing.expectEqual(@as(u16, 0x0300), (try three.vf(0)).bdf.raw());
        try testing.expectEqual(@as(u16, 0x0302), (try three.vf(2)).bdf.raw());
        try testing.expectEqual(cap.registers.function.sbdf.segment, (try three.vf(2)).segment);
        try testing.expectError(error.OutOfBounds, three.vf(3));
        try testing.expectError(error.InvalidValue, cap.setNumVfs(4));

        backend.control = 1;

        const writes = backend.write_count;
        try testing.expectError(error.ActiveVfs, cap.setNumVfs(1));
        try testing.expectEqual(writes, backend.write_count);
    }

    test "VF routing rejects malformed and overflowing geometry" {
        const pf = Sbdf.from(.from(7), 255, 31, 6);
        const last = try Routing.tryFrom(.{ .pf = pf, .num_vfs = 1, .first = 1, .stride = 0 });

        try testing.expectEqual(@as(u16, 0xFFFF), (try last.vf(0)).bdf.raw());
        try testing.expectError(error.BusRangeExhausted, Routing.tryFrom(.{ .pf = pf, .num_vfs = 2, .first = 1, .stride = 1 }));
        try testing.expectError(error.InvalidValue, Routing.tryFrom(.{ .pf = pf, .num_vfs = 1, .first = 0, .stride = 1 }));
        try testing.expectError(error.InvalidValue, Routing.tryFrom(.{ .pf = pf, .num_vfs = 2, .first = 1, .stride = 0 }));

        const empty = try Routing.tryFrom(.{ .pf = pf, .num_vfs = 0, .first = 0, .stride = 0 });
        try testing.expectError(error.OutOfBounds, empty.vf(0));
    }

    test "VF reactivation refreshes count-dependent routing after disable completion" {
        var backend: Backend = .{ .control = 0xA070, .device = 31, .function = 7 };
        const cap = backend.capability();

        try cap.setNumVfs(1);

        const first_route = try cap.routing();
        try cap.setMemoryEnabled(true);
        try cap.enable();

        try testing.expectEqual(@as(u16, 0xA079), backend.control);
        try testing.expectEqual(@as(usize, 0), backend.vf_requests);
        try testing.expectError(error.ActiveVfs, cap.enable());
        try testing.expectEqual(@as(u16, 0x06FF), (try first_route.vf(0)).bdf.raw());

        const writes = backend.write_count;
        try cap.disable();
        try testing.expectEqual(@as(u16, 0xA070), backend.control);
        try testing.expect(backend.quiet);
        try testing.expectEqual(@as(usize, 0), backend.quiet_accesses);
        try testing.expectEqual(writes + 1, backend.write_count);
        try testing.expectEqual(@as(u16, 1), backend.num);

        backend.quiet = false;
        try cap.setNumVfs(3);

        const next_route = try cap.routing();

        try cap.setMemoryEnabled(true);
        try cap.enable();

        try testing.expectEqual(@as(u16, 0xA079), backend.control);
        try testing.expectEqual(@as(u16, 0x0300), (try next_route.vf(0)).bdf.raw());
        try testing.expectEqual(@as(u16, 0x0302), (try next_route.vf(2)).bdf.raw());
        try testing.expectError(error.OutOfBounds, first_route.vf(1));
        try testing.expectEqual(@as(u32, 0xA000_0000), backend.bar_address);
        try testing.expectEqual(@as(usize, 0), backend.page_writes);
        try testing.expectEqual(@as(usize, 0), backend.vf_requests);
        try testing.expectEqual(@as(usize, 0), backend.quiet_accesses);

        try cap.disable();

        try testing.expect(backend.quiet);
        try testing.expectEqual(@as(usize, 0), backend.quiet_accesses);

        backend.quiet = false;
        try cap.setNumVfs(0);
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "failed enable can activate VFs without implicit readback or teardown" {
        var backend: Backend = .{
            .control = 0xA078,
            .num = 3,
            .fail_after_enable = true,
            .block_active_reads = true,
        };
        const cap = backend.capability();

        try testing.expectError(error.OutOfBounds, cap.enable());
        try testing.expectEqual(@as(u16, 0xA079), backend.control);
        try testing.expectEqual(@as(u16, 3), backend.num);
        try testing.expectEqual(@as(usize, 1), backend.write_count);
        try testing.expectEqual(@as(usize, 0), backend.active_reads);
        try testing.expectEqual(@as(usize, 0), backend.vf_requests);
        try testing.expect(!backend.quiet);

        backend.block_active_reads = false;

        try cap.disable();

        try testing.expect(backend.quiet);
        try testing.expectEqual(@as(u16, 0xA070), backend.control);
        try testing.expectEqual(@as(usize, 0), backend.quiet_accesses);
        try testing.expectEqual(@as(usize, 2), backend.write_count);

        backend.quiet = false;
        try cap.setNumVfs(0);
        try testing.expectEqual(@as(u16, 0), backend.num);
    }

    test "failed disable can enter the quiet period without any cleanup access" {
        var backend: Backend = .{ .control = 0xA079, .num = 3, .fail_after_disable = true };

        try testing.expectError(error.OutOfBounds, backend.capability().disable());
        try testing.expect(backend.quiet);
        try testing.expectEqual(@as(u16, 0xA070), backend.control);
        try testing.expectEqual(@as(u16, 3), backend.num);
        try testing.expectEqual(@as(usize, 0), backend.quiet_accesses);
        try testing.expectEqual(@as(usize, 1), backend.write_count);
    }

    test "VF activation rejects invalid preparation without enabling VFs" {
        var backend: Backend = .{ .num = 0 };
        const cap = backend.capability();

        try testing.expectError(error.InvalidValue, cap.enable());

        backend.num = 4;

        try testing.expectError(error.InvalidValue, cap.enable());

        backend.num = 3;
        backend.page = 3;

        try testing.expectError(error.InvalidValue, cap.enable());

        backend.page = 1;
        backend.supported_pages = 0;

        try testing.expectError(error.InvalidValue, cap.enable());
        try testing.expectEqual(@as(usize, 0), backend.write_count);
        try testing.expectEqual(@as(usize, 0), backend.vf_requests);
    }

    test "VF memory32 and memory64 probes restore slots and preserve control" {
        var backend: BarBackend = .{
            .values = .{ 0x8000_0008, 0x4000_000C, 2, 0, 0, 0 },
            .masks = .{ 0xFFFF_E008, 0xFFFF_C00C, 0xFFFF_FFFF, 0, 0, 0 },
        };

        const saved = backend.values;
        const bars = backend.bars();

        const small = try bars.probe(0);
        try testing.expectEqual(@as(?u64, 8192), small.type.memory.size);
        try testing.expectEqual(Bar.Memory.Width.bits_32, small.type.memory.width);

        const wide = try bars.probe(1);
        try testing.expectEqual(@as(?u64, 16384), wide.type.memory.size);
        try testing.expectEqual(@as(u64, 0x2_4000_0000), wide.type.memory.base);
        try testing.expect(wide.type.memory.prefetchable);
        try testing.expectEqualSlices(u32, &saved, &backend.values);
        try testing.expectEqual(@as(u16, 0x18), backend.control);
        try testing.expectEqual(@as(u32, saved[0]), try bars.read(0));

        const reference = BarRef.from(bars, 1);
        try testing.expectEqual(@as(usize, 1), reference.index);
    }

    test "VF BAR batch and iterator skip high words and retain absent slots" {
        var backend: BarBackend = .{
            .values = .{ 4, 1, 0, 0, 0, 0 },
            .masks = .{ 0xFFFF_F004, 0xFFFF_FFFF, 0, 0, 0, 0 },
        };

        const bars = backend.bars();
        var iter = bars.iterator();
        try testing.expectEqual(@as(usize, 2), (try iter.next()).?.numSlots());

        var count: usize = 1;

        while (try iter.next()) |_| {
            count += 1;
        }

        try testing.expectEqual(@as(usize, 5), count);

        const result = try bars.probeAll();
        const entries = result.slice();

        try testing.expectEqual(@as(usize, 5), entries.len);
        try testing.expectEqual(@as(usize, 0), entries[0].index);
        try testing.expectEqual(@as(?u64, 4096), entries[0].type.memory.size);
        try testing.expectEqual(Bar.Memory.Width.bits_64, entries[0].type.memory.width);

        for (entries[1..], 2..) |value, index| {
            try testing.expectEqual(index, value.index);
            try testing.expect(value.type == .none);
        }

        try testing.expectEqual(@as(usize, 12), backend.writes);
        try testing.expect((try bars.probe(2)).type == .none);
    }

    test "VF BAR full memory32 aperture uses u64 size" {
        var backend: BarBackend = .{
            .values = .{ 8, 0, 0, 0, 0, 0 },
            .masks = .{ 8, 0, 0, 0, 0, 0 },
        };
        try testing.expectEqual(@as(?u64, 0x1_0000_0000), (try backend.bars().probe(0)).type.memory.size);
    }

    test "VF memory64 sizing supports apertures larger than four GiB" {
        var backend: BarBackend = .{
            .values = .{ 4, 2, 0, 0, 0, 0 },
            .masks = .{ 4, 0xFFFF_FFFE, 0, 0, 0, 0 },
        };

        const value = try backend.bars().probe(0);
        try testing.expectEqual(@as(?u64, 0x2_0000_0000), value.type.memory.size);
        try testing.expectEqual(Bar.Memory.Width.bits_64, value.type.memory.width);
    }

    test "VF BAR probes use the selected page size and never restore preselection addresses" {
        var backend: BarBackend = .{
            .page_sensitive = true,
            .values = .{ 0x8000_0008, 0, 0, 0, 0, 0 },
        };

        const bars = backend.bars();
        const capability: Capability = .{ .registers = bars.registers };

        const small = try bars.probe(0);
        try testing.expectEqual(@as(?u64, 4096), small.type.memory.size);
        try testing.expectEqual(@as(u32, 0x8000_0008), backend.values[0]);

        try capability.setPageSize(.size_64k);
        try testing.expectEqual(@as(u32, 8), backend.values[0]);

        const large = try bars.probe(0);
        try testing.expectEqual(@as(?u64, 65536), large.type.memory.size);
        try testing.expectEqual(@as(u64, 0), large.type.memory.base);
        try testing.expectEqual(@as(u32, 8), backend.values[0]);
        try testing.expectEqual(@as(u32, 0x10), backend.page_size);
        try testing.expectEqual(@as(u16, 0x18), backend.control);
    }

    test "VF BAR malformed encodings and sizing masks are rejected" {
        for ([_]u32{ 1, 2, 6 }) |raw| {
            var backend: BarBackend = .{};
            backend.values[0] = raw;
            try testing.expectError(error.MalformedBar, backend.bars().decode(0));
            try testing.expectError(error.MalformedBar, backend.bars().probe(0));
            try testing.expectEqual(@as(usize, 0), backend.writes);
        }

        var backend: BarBackend = .{};
        backend.values[5] = 4;

        try testing.expectError(error.MalformedBar, backend.bars().probe(5));

        for ([_]u32{ 0xFFFF_D000, 0xFFFF_FF00, 0xFFFF_F001 }) |mask| {
            backend.masks[0] = mask;
            try testing.expectError(error.MalformedBar, backend.bars().probe(0));
        }

        backend.values[0] = 4;
        backend.masks[0] = 4;

        try testing.expectError(error.MalformedBar, backend.bars().probe(0));
    }

    test "VF BAR probing and raw writes reject active VFs before writing" {
        var backend: BarBackend = .{ .control = 1 };
        const bars = backend.bars();

        try testing.expectError(error.ActiveVfs, bars.probe(0));
        try testing.expectError(error.ActiveVfs, bars.probeAll());
        try testing.expectError(error.ActiveVfs, bars.write(0, 0x1000));
        try testing.expectEqual(@as(usize, 0), backend.writes);

        backend.control = 0x18;
        try bars.write(0, 0x2000);

        try testing.expectEqual(@as(u32, 0x2000), try bars.read(0));
    }

    test "VF BAR failed writes and reads restore all attempted slots" {
        for ([_]?usize{ 1, 2, null }) |failure| {
            var backend: BarBackend = .{
                .values = .{ 0x4000_0004, 2, 0, 0, 0, 0 },
                .masks = .{ 0xFFFF_F004, 0xFFFF_FFFF, 0, 0, 0, 0 },
                .fail_write = failure,
                .fail_read = if (failure == null) 1 else null,
            };
            const saved = backend.values;

            try testing.expectError(error.OutOfBounds, backend.bars().probe(0));
            try testing.expectEqualSlices(u32, &saved, &backend.values);
            try testing.expect(!backend.probing[0] and !backend.probing[1]);
            try testing.expectEqual(if (failure == 1) @as(usize, 2) else @as(usize, 4), backend.writes);
        }
    }

    test "VF BAR restore failure overrides probe failure and attempts both restores" {
        var backend: BarBackend = .{
            .values = .{ 4, 1, 0, 0, 0, 0 },
            .fail_read = 0,
            .fail_restore = 0,
        };

        try testing.expectError(error.ProgrammingPartial, backend.bars().probe(0));
        try testing.expectEqualSlices(usize, &.{ 0, 1, 0, 1 }, backend.log[0..backend.writes]);
        try testing.expect(!backend.probing[1]);
    }
};
