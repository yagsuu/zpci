const std = @import("std");

const config = @import("config");
const core = @import("core");
const memory = @import("memory");

const standard = @import("standard.zig");

const msix = core.capabilities.msix;

const Rel16 = core.RelativeOffset(u16);
const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = standard.Entry;
const Registers = standard.Registers;

const Control = msix.Control.Word;
const ControlArgs = msix.Control.AssignArgs;
const TableEntry = msix.TableEntry;

const BarMemory = memory.BarMemory;
const BarMemoryError = BarMemory.Error;

pub const Error = standard.Error || error{MalformedField};

pub const Capability = struct {
    registers: Registers,

    pub fn tryFrom(function: Function, capability: Entry) Error!Capability {
        std.debug.assert(capability.id == msix.id);

        const registers = try Registers.tryFrom(function, capability.offset);
        if (!registers.contains(offsets.pba)) {
            return error.MalformedCapability;
        }

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const capability = try standard.find(function, msix.id) orelse return null;
        return try tryFrom(function, capability);
    }

    pub fn control(self: Capability) Error!Control {
        return msix.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) Error!void {
        const observed = try self.control();
        const updated = msix.Control.replace(observed, args);

        try self.registers.write(offsets.control, msix.Control.raw(updated));
    }

    pub fn numVectors(self: Capability) Error!u16 {
        return @as(u16, (try self.control()).table_size_minus_one) + 1;
    }

    pub fn table(self: Capability) Error!BarLocation {
        return BarLocation.tryFrom(try self.registers.read(offsets.table));
    }

    pub fn pba(self: Capability) Error!BarLocation {
        return BarLocation.tryFrom(try self.registers.read(offsets.pba));
    }
};

pub const BarLocation = struct {
    bar: u3,
    offset: u32,

    pub fn tryFrom(raw: u32) error{MalformedField}!BarLocation {
        const location = msix.BarLocation.from(raw);
        if (location.bir > 5) {
            return error.MalformedField;
        }

        return .{ .bar = location.bir, .offset = @as(u32, location.offset_shifted) << 3 };
    }
};

pub const Table = struct {
    memory: BarMemory,
    num_vectors: u16,

    const entry_size = @sizeOf(TableEntry);

    pub const Entry = struct {
        address: u64,
        data: u32,
        masked: bool,
    };

    pub const Args = struct {
        address: u64,
        data: u32,
    };

    pub const Error = BarMemoryError || error{OutOfBounds};

    pub fn from(bar_memory: BarMemory, num_vectors: u16) Table {
        std.debug.assert(num_vectors >= 1 and num_vectors <= msix.max_vectors);
        return .{ .memory = bar_memory, .num_vectors = num_vectors };
    }

    pub fn spanBytes(self: Table) usize {
        return @as(usize, self.num_vectors) * entry_size;
    }

    pub fn read(self: Table, index: u11) Table.Error!Table.Entry {
        const offset = try self.entryOffset(index);

        const lo = try self.memory.read32(offset + msix.table.offsets.address_lo);
        const hi = try self.memory.read32(offset + msix.table.offsets.address_hi);

        const data = try self.memory.read32(offset + msix.table.offsets.data);
        const vector_control = msix.VectorControl.from(try self.memory.read32(offset + msix.table.offsets.control));

        const address = (@as(u64, hi) << 32) | @as(u64, lo);

        return .{ .address = address, .data = data, .masked = vector_control.masked };
    }

    pub fn program(self: Table, index: u11, args: Args) Table.Error!void {
        const offset = try self.entryOffset(index);
        try self.programAt(offset, args);
    }

    pub fn programAll(self: Table, first_index: u11, entries: []const Args) Table.Error!void {
        if (entries.len == 0) {
            return;
        }

        const start = @as(usize, first_index);
        if (start >= self.num_vectors or entries.len > self.num_vectors - start) {
            return error.OutOfBounds;
        }

        const end = start + entries.len;
        if (end * entry_size > self.memory.len) {
            return error.BarMemoryOutOfBounds;
        }

        for (entries, 0..) |entry, i| {
            try self.programAt((start + i) * entry_size, entry);
        }
    }

    pub fn setMasked(self: Table, index: u11, masked: bool) Table.Error!void {
        const offset = (try self.entryOffset(index)) + msix.table.offsets.control;
        const observed = msix.VectorControl.from(try self.memory.read32(offset));
        const updated = msix.VectorControl.replace(observed, .{ .masked = masked });

        try self.memory.write32(offset, msix.VectorControl.raw(updated));
    }

    fn entryOffset(self: Table, index: u11) Table.Error!usize {
        if (index >= self.num_vectors) {
            return error.OutOfBounds;
        }

        const offset = @as(usize, index) * entry_size;
        if (offset + entry_size > self.memory.len) {
            return error.BarMemoryOutOfBounds;
        }

        return offset;
    }

    fn programAt(self: Table, offset: usize, args: Args) Table.Error!void {
        const lo: u32 = @truncate(args.address);
        const hi: u32 = @truncate(args.address >> 32);

        try self.memory.write32(offset + msix.table.offsets.address_lo, lo);
        try self.memory.write32(offset + msix.table.offsets.address_hi, hi);
        try self.memory.write32(offset + msix.table.offsets.data, args.data);
    }
};

pub const Pba = struct {
    memory: BarMemory,
    num_vectors: u16,

    const bits_per_dword = @bitSizeOf(u32);

    pub const Error = BarMemoryError || error{OutOfBounds};

    pub fn from(bar_memory: BarMemory, num_vectors: u16) Pba {
        std.debug.assert(num_vectors >= 1 and num_vectors <= msix.max_vectors);
        return .{ .memory = bar_memory, .num_vectors = num_vectors };
    }

    pub fn spanBytes(self: Pba) usize {
        const adjusted_size = @as(usize, self.num_vectors) + bits_per_dword - 1;
        return @divFloor(adjusted_size, bits_per_dword) * @sizeOf(u32);
    }

    pub fn pending(self: Pba, index: u11) Pba.Error!bool {
        if (index >= self.num_vectors) {
            return error.OutOfBounds;
        }

        const dword_index = @as(usize, index) / bits_per_dword;
        const shift: u5 = @intCast(index % bits_per_dword);
        const bits = try self.read(dword_index);

        return bits & (@as(u32, 1) << shift) != 0;
    }

    pub fn read(self: Pba, dword_index: usize) Pba.Error!u32 {
        if (dword_index >= @divExact(self.spanBytes(), @sizeOf(u32))) {
            return error.OutOfBounds;
        }

        return self.memory.read32(dword_index * @sizeOf(u32));
    }
};

pub const offsets = struct {
    pub const control = Rel16.from(msix.offsets.control);
    pub const table = Rel32.from(msix.offsets.table);
    pub const pba = Rel32.from(msix.offsets.pba);
};

pub const unit = struct {
    const testing = std.testing;

    const header = core.header;
    const type0 = core.header.type0;

    const pcie_window_size = core.config.extended_size;
    const test_sbdf = Sbdf.from(.from(0), 0, 0, 0);
    const cap_base: u8 = 0x40;

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Id = core.capabilities.standard.Id;
    const Sbdf = core.Sbdf;
    const LocationWord = msix.BarLocation.Word;

    const ConfigBackend = struct {
        bytes: []u8,
        op_count: usize = 0,
        write16_count: usize = 0,
        fail_next_write16: bool = false,
        mutate_failed_write: bool = false,

        fn from(bytes: []u8) ConfigBackend {
            std.debug.assert(bytes.len == pcie_window_size);
            return .{ .bytes = bytes };
        }

        fn config(self: *ConfigBackend) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn resetLog(self: *ConfigBackend) void {
            self.op_count = 0;
            self.write16_count = 0;
            self.fail_next_write16 = false;
            self.mutate_failed_write = false;
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
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.op_count += 1;

            return self.bytes[byte_offset];
        }

        fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.op_count += 1;

            return load16(self.bytes, byte_offset);
        }

        fn read32(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u32 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.op_count += 1;

            return load32(self.bytes, byte_offset);
        }

        fn write8(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u8) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.op_count += 1;
            self.bytes[byte_offset] = value;
        }

        fn write16(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.op_count += 1;
            self.write16_count += 1;

            if (self.fail_next_write16) {
                self.fail_next_write16 = false;

                if (self.mutate_failed_write) {
                    store16(self.bytes, byte_offset, value);
                }

                return error.UnsupportedAccessWidth;
            }

            store16(self.bytes, byte_offset, value);
        }

        fn write32(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u32) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.op_count += 1;
            store32(self.bytes, byte_offset, value);
        }
    };

    const BarOp = struct {
        kind: Kind,
        offset: usize,
        value: u32,

        const Kind = enum { read, write };
    };

    const BarBackend = struct {
        bytes: []u8,
        ops: [128]BarOp = undefined,
        op_count: usize = 0,
        read_count: usize = 0,
        write_count: usize = 0,
        fail_read_index: ?usize = null,
        fail_write_index: ?usize = null,
        mutate_failed_write: bool = false,

        fn from(bytes: []u8) BarBackend {
            return .{ .bytes = bytes };
        }

        fn accessor(self: *BarBackend) BarMemory {
            return BarMemory.from(@ptrCast(self), &vtable, self.bytes.len);
        }

        fn resetLog(self: *BarBackend) void {
            self.op_count = 0;
            self.read_count = 0;
            self.write_count = 0;
            self.fail_read_index = null;
            self.fail_write_index = null;
            self.mutate_failed_write = false;
        }

        fn append(self: *BarBackend, op: BarOp) void {
            std.debug.assert(self.op_count < self.ops.len);
            self.ops[self.op_count] = op;
            self.op_count += 1;
        }

        const vtable: BarMemory.VTable = .{
            .read32 = read32,
            .write32 = write32,
        };

        fn read32(context: *anyopaque, byte_offset: usize) BarMemoryError!u32 {
            const self: *BarBackend = @ptrCast(@alignCast(context));
            const index = self.read_count;
            self.read_count += 1;

            if (self.fail_read_index == index) {
                self.append(.{ .kind = .read, .offset = byte_offset, .value = 0 });
                return error.BarMemoryOutOfBounds;
            }

            const value = load32(self.bytes, byte_offset);

            self.append(.{ .kind = .read, .offset = byte_offset, .value = value });

            return value;
        }

        fn write32(context: *anyopaque, byte_offset: usize, value: u32) BarMemoryError!void {
            const self: *BarBackend = @ptrCast(@alignCast(context));
            const index = self.write_count;
            self.write_count += 1;
            self.append(.{ .kind = .write, .offset = byte_offset, .value = value });

            if (self.fail_write_index == index) {
                if (self.mutate_failed_write) {
                    store32(self.bytes, byte_offset, value);
                }

                return error.BarMemoryOutOfBounds;
            }

            store32(self.bytes, byte_offset, value);
        }
    };

    const MsixSeed = struct {
        control: Control = .{},
        table: LocationWord = .{},
        pba: LocationWord = .{},
    };

    test "Table and PBA accessors decode independent BIR values" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{
            .table = .{ .bir = 4, .offset_shifted = 0x1000 >> 3 },
            .pba = .{ .bir = 5, .offset_shifted = 0x2000 >> 3 },
        });

        var backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&backend);

        try expectLocation(try capability.table(), 4, 0x1000);
        try expectLocation(try capability.pba(), 5, 0x2000);
    }

    test "vector counts determine explicit Table and PBA spans without I/O" {
        const cases = [_]struct { count: u16, table_span: usize, pba_span: usize }{
            .{ .count = 1, .table_span = 16, .pba_span = 4 },
            .{ .count = 32, .table_span = 512, .pba_span = 4 },
            .{ .count = 33, .table_span = 528, .pba_span = 8 },
            .{ .count = 2048, .table_span = 32768, .pba_span = 256 },
        };

        for (cases) |case| {
            var bytes: [pcie_window_size]u8 = @splat(0);
            seedMsixCapability(&bytes, .{ .control = .{ .table_size_minus_one = @intCast(case.count - 1) } });
            var bar_bytes: [0]u8 = .{};

            var backend = ConfigBackend.from(&bytes);
            const capability = try tryCapability(&backend);
            var bar_backend = BarBackend.from(&bar_bytes);

            const count = try capability.numVectors();
            try testing.expectEqual(case.count, count);

            backend.resetLog();

            try testing.expectEqual(case.table_span, Table.from(bar_backend.accessor(), count).spanBytes());
            try testing.expectEqual(case.pba_span, Pba.from(bar_backend.accessor(), count).spanBytes());
            try testing.expectEqual(@as(usize, 0), backend.op_count);
            try testing.expectEqual(@as(usize, 0), bar_backend.op_count);
        }
    }

    test "Table and PBA access validate BIR independently" {
        for ([_]u3{ 6, 7 }) |reserved_bir| {
            var table_bytes: [pcie_window_size]u8 = @splat(0);
            seedMsixCapability(&table_bytes, .{ .table = .{ .bir = reserved_bir } });

            var table_backend = ConfigBackend.from(&table_bytes);
            const invalid_table = try tryCapability(&table_backend);

            try testing.expectError(error.MalformedField, invalid_table.table());
            try expectLocation(try invalid_table.pba(), 0, 0);

            var pba_bytes: [pcie_window_size]u8 = @splat(0);
            seedMsixCapability(&pba_bytes, .{ .pba = .{ .bir = reserved_bir } });

            var pba_backend = ConfigBackend.from(&pba_bytes);
            const invalid_pba = try tryCapability(&pba_backend);

            try testing.expectError(error.MalformedField, invalid_pba.pba());
            try expectLocation(try invalid_pba.table(), 0, 0);
        }
    }

    test "find reports present, absent, and malformed traversal results" {
        var present_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&present_bytes, 0x40);
        seedCapability(&present_bytes, 0x40, 0x09, 0x80);
        seedCapability(&present_bytes, 0x80, @backingInt(msix.id), 0);
        seedMsixPayload(&present_bytes, 0x80, .{ .control = .{ .table_size_minus_one = 3 } });

        var present_backend = ConfigBackend.from(&present_bytes);

        const present = (try Capability.find(functionFor(&present_backend))).?;

        try testing.expectEqual(@as(u8, 0x80), present.registers.base);
        try testing.expectEqual(@as(u11, 3), (try present.control()).table_size_minus_one);

        var no_list_bytes: [pcie_window_size]u8 = @splat(0);
        no_list_bytes[type0.offsets.cap_ptr] = cap_base;
        seedCapability(&no_list_bytes, cap_base, @backingInt(msix.id), 0);
        seedMsixPayload(&no_list_bytes, cap_base, .{});

        var no_list_backend = ConfigBackend.from(&no_list_bytes);

        try testing.expectEqual(@as(?Capability, null), try Capability.find(functionFor(&no_list_backend)));

        var absent_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&absent_bytes, 0x40);
        seedCapability(&absent_bytes, 0x40, @backingInt(Id.msi), 0x44);
        seedCapability(&absent_bytes, 0x44, @backingInt(Id.pcie), 0);

        var absent_backend = ConfigBackend.from(&absent_bytes);

        try testing.expectEqual(@as(?Capability, null), try Capability.find(functionFor(&absent_backend)));

        var cycle_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&cycle_bytes, 0x40);
        seedCapability(&cycle_bytes, 0x40, 0x09, 0x44);
        seedCapability(&cycle_bytes, 0x44, @backingInt(Id.msi), 0x40);

        var cycle_backend = ConfigBackend.from(&cycle_bytes);

        try testing.expectError(error.MalformedCapability, Capability.find(functionFor(&cycle_backend)));
    }

    test "live config reads leave caller-owned snapshots independent" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{
            .control = .{ .table_size_minus_one = 7 },
            .table = .{ .bir = 1, .offset_shifted = 0x100 >> 3 },
            .pba = .{ .bir = 1, .offset_shifted = 0x200 >> 3 },
        });

        var backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&backend);
        const saved_control = try capability.control();
        const saved_table = try capability.table();
        const saved_pba = try capability.pba();

        store16(&bytes, cap_base + msix.offsets.control, 0xD7FF);
        store32(&bytes, cap_base + msix.offsets.table, locationRaw(4, 0x300));
        store32(&bytes, cap_base + msix.offsets.pba, locationRaw(5, 0x400));

        const word = try capability.control();

        try testing.expectEqual(@as(u11, 0x7FF), word.table_size_minus_one);
        try testing.expect(word.enable);
        try testing.expect(word.function_mask);

        try testing.expectEqual(@as(u11, 7), saved_control.table_size_minus_one);
        try expectLocation(saved_table, 1, 0x100);
        try expectLocation(saved_pba, 1, 0x200);
        try expectLocation(try capability.table(), 4, 0x300);
        try expectLocation(try capability.pba(), 5, 0x400);
    }

    test "explicit memory counts remain independent of live config" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .control = .{ .table_size_minus_one = 31 } });
        var bar_bytes: [0]u8 = .{};

        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const count = try capability.numVectors();

        var bar_backend = BarBackend.from(&bar_bytes);
        const table = Table.from(bar_backend.accessor(), count);
        const pba = Pba.from(bar_backend.accessor(), count);

        config_backend.resetLog();
        store16(&bytes, cap_base + msix.offsets.control, 0x7FF);

        try testing.expectEqual(@as(usize, 512), table.spanBytes());
        try testing.expectEqual(@as(usize, 4), pba.spanBytes());
        try testing.expectEqual(@as(usize, 0), config_backend.op_count);
        try testing.expectEqual(@as(usize, 0), bar_backend.op_count);
    }

    test "Table reads reconstruct addresses data and mask state" {
        var bytes: [32]u8 = @splat(0);
        seedEntry(&bytes, 1, .{
            .address = 0x0123_4567_89AB_CDEF,
            .data = 0xCAFE_BABE,
            .vector_control = 0xFFFF_FFFF,
        });

        var backend = BarBackend.from(&bytes);
        const table = Table.from(backend.accessor(), 2);

        const entry = try table.read(1);
        try expectVectorEntry(entry, .{
            .address = 0x0123_4567_89AB_CDEF,
            .data = 0xCAFE_BABE,
            .masked = true,
        });
    }

    test "PBA selects bits across dword boundaries" {
        var bytes: [8]u8 = @splat(0);
        store32(&bytes, 0, 0x8000_0000);
        store32(&bytes, 4, 0x21);

        var backend = BarBackend.from(&bytes);
        const pba = Pba.from(backend.accessor(), 64);

        try testing.expect(!try pba.pending(30));
        try testing.expect(try pba.pending(31));
        try testing.expect(try pba.pending(32));
        try testing.expect(!try pba.pending(36));
        try testing.expect(try pba.pending(37));
        try testing.expectEqual(@as(u32, 0x21), try pba.read(1));
    }

    test "logical bounds reject Table and PBA access before I/O" {
        var bytes: [528]u8 = @splat(0);

        var backend = BarBackend.from(&bytes);
        const table = Table.from(backend.accessor(), 32);
        const pba = Pba.from(backend.accessor(), 32);

        try testing.expectError(error.OutOfBounds, table.read(32));
        try testing.expectError(error.OutOfBounds, table.program(32, .{ .address = 0, .data = 0 }));
        try testing.expectError(error.OutOfBounds, table.setMasked(32, true));
        try testing.expectError(error.OutOfBounds, pba.pending(32));
        try testing.expectError(error.OutOfBounds, pba.read(1));
        try testing.expectError(error.OutOfBounds, pba.read(std.math.maxInt(usize)));
        try testing.expectEqual(@as(usize, 0), backend.op_count);
    }

    test "backing memory bounds reject valid logical indices before I/O" {
        var table_bytes: [31]u8 = @splat(0);

        var table_backend = BarBackend.from(&table_bytes);
        const table = Table.from(table_backend.accessor(), 2);

        try testing.expectError(error.BarMemoryOutOfBounds, table.read(1));
        try testing.expectError(error.BarMemoryOutOfBounds, table.program(1, .{ .address = 0, .data = 0 }));
        try testing.expectError(error.BarMemoryOutOfBounds, table.setMasked(1, true));
        try testing.expectEqual(@as(usize, 0), table_backend.op_count);

        var pba_bytes: [4]u8 = @splat(0);

        var pba_backend = BarBackend.from(&pba_bytes);
        const pba = Pba.from(pba_backend.accessor(), 64);

        try testing.expectError(error.BarMemoryOutOfBounds, pba.read(1));
        try testing.expectError(error.BarMemoryOutOfBounds, pba.pending(32));
        try testing.expectEqual(@as(usize, 0), pba_backend.op_count);
    }

    test "updateControl preserves live fields and propagates write errors" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .control = msix.Control.from(0x6923) });

        var backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&backend);

        backend.resetLog();

        try capability.updateControl(.{ .enable = true });
        try expectMessageControlRaw(&bytes, msix.Control.from(0xE923));
        try testing.expectEqual(@as(usize, 1), backend.write16_count);
        try testing.expectEqual(@as(usize, 2), backend.op_count);

        store16(&bytes, cap_base + msix.offsets.control, 0x9800);

        try capability.updateControl(.{ .function_mask = true });
        try expectMessageControlRaw(&bytes, msix.Control.from(0xD800));

        for ([_]bool{ false, true }) |mutate| {
            backend.resetLog();
            backend.fail_next_write16 = true;
            backend.mutate_failed_write = mutate;

            try testing.expectError(error.UnsupportedAccessWidth, capability.updateControl(.{ .enable = false }));
            try testing.expectEqual(@as(usize, 1), backend.write16_count);
            try testing.expectEqual(@as(usize, 2), backend.op_count);
            try testing.expectEqual(!mutate, msix.Control.from(load16(&bytes, cap_base + msix.offsets.control)).enable);
        }
    }

    test "program writes only payload and masking is independent" {
        var bytes: [32]u8 = @splat(0xA4);
        var backend = BarBackend.from(&bytes);
        const table = Table.from(backend.accessor(), 2);

        try table.program(1, .{ .address = 0x0123_4567_89AB_CDEF, .data = 0xCAFE_BABE });
        try testing.expectEqual(@as(usize, 3), backend.op_count);
        try expectBarOp(backend.ops[0], .write, 16, 0x89AB_CDEF);
        try expectBarOp(backend.ops[1], .write, 20, 0x0123_4567);
        try expectBarOp(backend.ops[2], .write, 24, 0xCAFE_BABE);
        try expectDword(&bytes, 28, 0xA4A4_A4A4);

        backend.resetLog();

        try table.setMasked(1, true);
        try testing.expectEqual(@as(usize, 2), backend.op_count);
        try expectBarOp(backend.ops[0], .read, 28, 0xA4A4_A4A4);
        try expectBarOp(backend.ops[1], .write, 28, 0xA4A4_A4A5);

        backend.resetLog();

        try table.program(1, .{ .address = 0, .data = 0 });
        try testing.expectEqual(@as(usize, 3), backend.op_count);
        try expectDword(&bytes, 28, 0xA4A4_A4A5);
        try expectDword(&bytes, 12, 0xA4A4_A4A4);

        backend.resetLog();

        try table.setMasked(1, false);
        try testing.expectEqual(@as(usize, 2), backend.op_count);
        try expectDword(&bytes, 28, 0xA4A4_A4A4);
    }

    test "program stops at each failed write without reads or rollback" {
        for (0..3) |failed| {
            for ([_]bool{ false, true }) |mutate| {
                var bytes: [16]u8 = @splat(0xA5);
                var expected = bytes;
                const values = [_]u32{ 0x89AB_CDEF, 0x0123_4567, 0xCAFE_BABE };

                for (0..failed + @intFromBool(mutate)) |i| {
                    store32(&expected, i * 4, values[i]);
                }

                var backend = BarBackend.from(&bytes);
                backend.fail_write_index = failed;
                backend.mutate_failed_write = mutate;
                backend.fail_read_index = 0;

                try testing.expectError(error.BarMemoryOutOfBounds, Table.from(backend.accessor(), 1).program(
                    0,
                    .{ .address = 0x0123_4567_89AB_CDEF, .data = 0xCAFE_BABE },
                ));
                try testing.expectEqual(@as(usize, 0), backend.read_count);

                for (0..failed + 1) |i| {
                    try expectBarOp(backend.ops[i], .write, i * 4, values[i]);
                }

                try testing.expectEqual(failed + 1, backend.op_count);
                try testing.expectEqualSlices(u8, &expected, &bytes);
            }
        }
    }

    test "programAll prevalidates range and backing extent without I/O" {
        const args = [_]Table.Args{
            .{ .address = 1, .data = 2 },
            .{ .address = 3, .data = 4 },
        };
        var bytes: [31]u8 = @splat(0);

        var backend = BarBackend.from(&bytes);
        const table = Table.from(backend.accessor(), 2);

        try table.programAll(2047, &.{});
        try testing.expectError(error.OutOfBounds, table.programAll(1, &args));
        try testing.expectError(error.OutOfBounds, table.programAll(2, args[0..1]));
        try testing.expectError(error.BarMemoryOutOfBounds, table.programAll(0, &args));
        try testing.expectError(error.BarMemoryOutOfBounds, table.program(1, args[0]));
        try testing.expectError(error.BarMemoryOutOfBounds, table.setMasked(1, true));
        try testing.expectEqual(@as(usize, 0), backend.op_count);
    }

    test "programAll writes ordered payloads and preserves vector controls" {
        const args = [_]Table.Args{
            .{ .address = 1, .data = 2 },
            .{ .address = 3, .data = 4 },
        };
        var complete_bytes: [32]u8 = @splat(0xA5);

        var complete_backend = BarBackend.from(&complete_bytes);
        const table = Table.from(complete_backend.accessor(), 2);

        try table.programAll(0, &args);
        try testing.expectEqual(@as(usize, 6), complete_backend.op_count);
        try expectBarOp(complete_backend.ops[0], .write, 0, 1);
        try expectBarOp(complete_backend.ops[1], .write, 4, 0);
        try expectBarOp(complete_backend.ops[2], .write, 8, 2);
        try expectBarOp(complete_backend.ops[3], .write, 16, 3);
        try expectBarOp(complete_backend.ops[4], .write, 20, 0);
        try expectBarOp(complete_backend.ops[5], .write, 24, 4);
        try expectDword(&complete_bytes, 12, 0xA5A5_A5A5);
        try expectDword(&complete_bytes, 28, 0xA5A5_A5A5);
    }

    test "programAll retains earlier payloads and stops at a partial entry" {
        for ([_]bool{ false, true }) |mutate| {
            var bytes: [48]u8 = @splat(0xA5);
            var expected = bytes;
            store32(&expected, 0, 1);
            store32(&expected, 4, 2);
            store32(&expected, 8, 3);
            store32(&expected, 16, 4);

            if (mutate) {
                store32(&expected, 20, 5);
            }

            const args = [_]Table.Args{
                .{ .address = 0x0000_0002_0000_0001, .data = 3 },
                .{ .address = 0x0000_0005_0000_0004, .data = 6 },
                .{ .address = 7, .data = 8 },
            };

            var backend = BarBackend.from(&bytes);
            const table = Table.from(backend.accessor(), 3);
            backend.fail_write_index = 4;
            backend.mutate_failed_write = mutate;

            try testing.expectError(error.BarMemoryOutOfBounds, table.programAll(0, &args));
            try testing.expectEqual(@as(usize, 5), backend.op_count);
            try testing.expectEqual(@as(usize, 0), backend.read_count);
            try expectBarOp(backend.ops[0], .write, 0, 1);
            try expectBarOp(backend.ops[1], .write, 4, 2);
            try expectBarOp(backend.ops[2], .write, 8, 3);
            try expectBarOp(backend.ops[3], .write, 16, 4);
            try expectBarOp(backend.ops[4], .write, 20, 5);
            try testing.expectEqualSlices(u8, &expected, &bytes);
        }
    }

    test "setMasked stops at a failed read without writing" {
        var bytes: [16]u8 = @splat(0xA4);

        var backend = BarBackend.from(&bytes);
        const table = Table.from(backend.accessor(), 1);
        backend.fail_read_index = 0;

        try testing.expectError(error.BarMemoryOutOfBounds, table.setMasked(0, true));
        try testing.expectEqual(@as(usize, 1), backend.op_count);
        try expectBarOp(backend.ops[0], .read, 12, 0);
        try expectDword(&bytes, 12, 0xA4A4_A4A4);
    }

    test "setMasked propagates write failures without recovery" {
        for ([_]bool{ false, true }) |mutate| {
            var bytes: [16]u8 = @splat(0xA4);

            var backend = BarBackend.from(&bytes);
            const table = Table.from(backend.accessor(), 1);
            backend.fail_write_index = 0;
            backend.mutate_failed_write = mutate;

            try testing.expectError(error.BarMemoryOutOfBounds, table.setMasked(0, true));
            try testing.expectEqual(@as(usize, 2), backend.op_count);
            try expectBarOp(backend.ops[0], .read, 12, 0xA4A4_A4A4);
            try expectBarOp(backend.ops[1], .write, 12, 0xA4A4_A4A5);
            try expectDword(&bytes, 12, if (mutate) 0xA4A4_A4A5 else 0xA4A4_A4A4);
        }
    }

    test "MSI-X capability extent stays in conventional config space" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixPayload(&bytes, 0xF4, .{
            .table = .{ .bir = 2, .offset_shifted = 0x1000 >> 3 },
            .pba = .{ .bir = 3, .offset_shifted = 0x2000 >> 3 },
        });

        var backend = ConfigBackend.from(&bytes);
        const valid = try Capability.tryFrom(functionFor(&backend), .{ .id = .msix, .offset = 0xF4 });

        try expectLocation(try valid.table(), 2, 0x1000);
        try expectLocation(try valid.pba(), 3, 0x2000);

        backend.resetLog();

        try testing.expectError(error.MalformedCapability, Capability.tryFrom(functionFor(&backend), .{ .id = .msix, .offset = 0xF8 }));
        try testing.expectEqual(@as(usize, 0), backend.op_count);
    }

    fn functionFor(backend: *ConfigBackend) Function {
        return Function.from(backend.config(), test_sbdf);
    }

    fn tryCapability(backend: *ConfigBackend) !Capability {
        return Capability.tryFrom(functionFor(backend), .{ .id = msix.id, .offset = cap_base });
    }

    fn seedMsixCapability(bytes: []u8, options: MsixSeed) void {
        seedHead(bytes, cap_base);
        seedCapability(bytes, cap_base, @backingInt(msix.id), 0);
        seedMsixPayload(bytes, cap_base, options);
    }

    fn seedMsixPayload(bytes: []u8, base: u8, options: MsixSeed) void {
        store16(bytes, @as(usize, base) + msix.offsets.control, msix.Control.raw(options.control));
        store32(bytes, @as(usize, base) + msix.offsets.table, msix.BarLocation.raw(options.table));
        store32(bytes, @as(usize, base) + msix.offsets.pba, msix.BarLocation.raw(options.pba));
    }

    fn seedHead(bytes: []u8, head: u8) void {
        store16(bytes, type0.offsets.status, header.Status.raw(.{ .cap_list = true }));
        bytes[type0.offsets.cap_ptr] = head;
    }

    fn seedCapability(bytes: []u8, base: u8, id: u8, next: u8) void {
        bytes[base] = id;
        bytes[@as(usize, base) + 1] = next;
    }

    fn seedEntry(bytes: []u8, index: usize, fields: struct {
        address: u64,
        data: u32,
        vector_control: u32,
    }) void {
        const base = index * @sizeOf(TableEntry);

        store32(bytes, base + @offsetOf(TableEntry, "address_lo"), @truncate(fields.address));
        store32(bytes, base + @offsetOf(TableEntry, "address_hi"), @truncate(fields.address >> 32));
        store32(bytes, base + @offsetOf(TableEntry, "data"), fields.data);
        store32(bytes, base + @offsetOf(TableEntry, "control"), fields.vector_control);
    }

    fn locationRaw(bir: u3, base_offset: u32) u32 {
        return msix.BarLocation.raw(.{ .bir = bir, .offset_shifted = @intCast(base_offset >> 3) });
    }

    fn expectLocation(actual: BarLocation, bir: u3, base_offset: u32) !void {
        try testing.expectEqual(bir, actual.bar);
        try testing.expectEqual(base_offset, actual.offset);
    }

    fn expectVectorEntry(actual: Table.Entry, expected: Table.Entry) !void {
        try testing.expectEqual(expected.address, actual.address);
        try testing.expectEqual(expected.data, actual.data);
        try testing.expectEqual(expected.masked, actual.masked);
    }

    fn expectMessageControlRaw(bytes: []const u8, expected: Control) !void {
        try testing.expectEqual(
            msix.Control.raw(expected),
            load16(bytes, cap_base + msix.offsets.control),
        );
    }

    fn expectDword(bytes: []const u8, byte_offset: usize, expected: u32) !void {
        try testing.expectEqual(expected, load32(bytes, byte_offset));
    }

    fn expectBarOp(actual: BarOp, kind: BarOp.Kind, byte_offset: usize, value: u32) !void {
        try testing.expectEqual(kind, actual.kind);
        try testing.expectEqual(byte_offset, actual.offset);
        try testing.expectEqual(value, actual.value);
    }

    fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
    }

    fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], value, .little);
    }

    fn load16(bytes: []const u8, byte_offset: usize) u16 {
        return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
    }

    fn load32(bytes: []const u8, byte_offset: usize) u32 {
        return std.mem.readInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], .little);
    }
};
