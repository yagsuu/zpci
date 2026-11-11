//! MSI-X capability and table programming.

const std = @import("std");

const pci_config = @import("config");
const core = @import("core");
const capabilities = @import("capabilities");
const memory = @import("memory");
const programming = @import("programming.zig");

const standard = capabilities.standard;
const msix = core.capabilities.msix;

const ConfigSpace = pci_config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Function = pci_config.Function;

const RelativeOffset = core.RelativeOffset;
const LocationRegister = msix.Location;
const TableRegister = msix.TableEntry;
const Control = msix.Control;
const VectorControl = msix.VectorControl;

const CapabilityEntry = standard.Entry;
const CapabilityIterator = standard.Iterator;
const CapabilityError = standard.Error;

const BarMemory = memory.BarMemory;
const BarMemoryError = BarMemory.Error;

pub const Capability = struct {
    function: Function,
    base: u8,

    pub const ReadError = error{
        MalformedCapability,
        MalformedField,
    } || ConfigError;

    pub const ProgramError = programming.Error;

    pub fn find(function: Function) ReadError!?Capability {
        var iterator = try CapabilityIterator.tryFrom(function);
        while (try iterator.next()) |capability| {
            if (capability.id == msix.id) {
                return try tryFrom(function, capability);
            }
        }

        return null;
    }

    pub fn tryFrom(function: Function, capability: CapabilityEntry) ReadError!Capability {
        std.debug.assert(capability.id == msix.id);

        const registers = try standard.Registers.tryFrom(function, capability.offset);
        if (!registers.contains(offsets.pba)) {
            return error.MalformedCapability;
        }

        _ = try Location.tryFrom(try registers.read(offsets.table));
        _ = try Location.tryFrom(try registers.read(offsets.pba));

        return .{
            .function = function,
            .base = capability.offset,
        };
    }

    pub fn control(self: Capability) ReadError!Control.Word {
        const registers = try standard.Registers.tryFrom(self.function, self.base);
        return Control.from(try registers.read(offsets.control));
    }

    pub fn tableLocation(self: Capability) ReadError!Location {
        const registers = try standard.Registers.tryFrom(self.function, self.base);
        return Location.tryFrom(try registers.read(offsets.table));
    }

    pub fn pbaLocation(self: Capability) ReadError!Location {
        const registers = try standard.Registers.tryFrom(self.function, self.base);
        return Location.tryFrom(try registers.read(offsets.pba));
    }

    pub fn enable(self: Capability) ProgramError!void {
        try self.updateControl(.{ .enable = true });
    }

    pub fn disable(self: Capability) ProgramError!void {
        try self.updateControl(.{ .enable = false });
    }

    pub fn setFunctionMask(self: Capability, masked: bool) ProgramError!void {
        try self.updateControl(.{ .function_mask = masked });
    }

    const ControlUpdate = union(enum) {
        enable: bool,
        function_mask: bool,
    };

    fn updateControl(self: Capability, update: ControlUpdate) ProgramError!void {
        const registers = standard.Registers.tryFrom(self.function, self.base) catch return error.ProgrammingWriteFailed;
        if (!registers.contains(offsets.pba)) {
            return error.ProgrammingWriteFailed;
        }

        var tx = ConfigTransaction.from(.{ .registers = registers });
        const saved = tx.read(u16, offsets.control) catch return error.ProgrammingWriteFailed;

        var word = Control.from(saved);
        switch (update) {
            .enable => |value| word.enable = value,
            .function_mask => |value| word.function_mask = value,
        }

        try tx.writeReadback(u16, offsets.control, Control.raw(word), saved);
    }
};

pub const Location = struct {
    bir: u3,
    offset: u32,

    pub fn tryFrom(raw: u32) error{MalformedField}!Location {
        const location = LocationRegister.from(raw);
        if (location.bir > 5) {
            return error.MalformedField;
        }

        return .{ .bir = location.bir, .offset = @as(u32, location.offset_shifted) << 3 };
    }
};

pub const Table = struct {
    memory: BarMemory,
    num_vectors: u16,

    const entry_size = @sizeOf(TableRegister);

    pub const Entry = struct {
        address: u64,
        data: u32,
        masked: bool,
    };

    pub const ReadError = error{InvalidRouting} || BarMemoryError;
    pub const ProgramError = error{ InvalidRouting, BarMemoryOutOfBounds, UnalignedAccess } || programming.Error;

    pub fn from(bar_memory: BarMemory, num_vectors: u16) Table {
        std.debug.assert(num_vectors >= 1 and num_vectors <= msix.max_vectors);
        return .{ .memory = bar_memory, .num_vectors = num_vectors };
    }

    pub fn spanBytes(self: Table) usize {
        return @as(usize, self.num_vectors) * entry_size;
    }

    pub fn read(self: Table, index: u11) ReadError!Entry {
        if (index >= self.num_vectors) {
            return error.InvalidRouting;
        }

        const offset = @as(usize, index) * entry_size;
        const vector_control_offset = offset + entry_offsets.control;

        if (!containsDword(self.memory.len, vector_control_offset)) {
            return error.BarMemoryOutOfBounds;
        }

        const address_lo = try self.memory.read32(offset + entry_offsets.address_lo);
        const address_hi = try self.memory.read32(offset + entry_offsets.address_hi);

        const data = try self.memory.read32(offset + entry_offsets.data);
        const vector_control = VectorControl.from(try self.memory.read32(offset + entry_offsets.control));

        const address = (@as(u64, address_hi) << 32) | @as(u64, address_lo);

        return .{ .address = address, .data = data, .masked = vector_control.masked };
    }

    pub fn program(
        self: Table,
        index: u11,
        entry: Entry,
    ) ProgramError!void {
        const offset = try self.entryOffset(index);
        try self.programAt(offset, entry);
    }

    pub fn programAll(
        self: Table,
        first_index: u11,
        entries: []const Entry,
    ) ProgramError!void {
        if (entries.len == 0) {
            return;
        }

        const max_additional_entries = std.math.maxInt(usize) - @as(usize, first_index);
        std.debug.assert(entries.len <= max_additional_entries);

        const start = @as(usize, first_index);
        const end = start + entries.len;
        if (end > self.num_vectors) {
            return error.InvalidRouting;
        }

        if (end * entry_size > self.memory.len) {
            return error.BarMemoryOutOfBounds;
        }

        for (entries, 0..) |entry, i| {
            try self.programAt((start + i) * entry_size, entry);
        }
    }

    pub fn setMasked(
        self: Table,
        index: u11,
        masked: bool,
    ) ProgramError!void {
        const offset = (try self.entryOffset(index)) + entry_offsets.control;

        var tx = TableTransaction.from(.{ .memory = self.memory });
        const saved = tx.read(u32, offset) catch return error.ProgrammingWriteFailed;

        var control = VectorControl.from(saved);
        control.masked = masked;

        try tx.writeReadback(u32, offset, VectorControl.raw(control), saved);
    }

    fn entryOffset(
        self: Table,
        index: u11,
    ) ProgramError!usize {
        if (index >= self.num_vectors) {
            return error.InvalidRouting;
        }

        const offset = @as(usize, index) * entry_size;
        if (!containsDword(self.memory.len, offset + entry_offsets.control)) {
            return error.BarMemoryOutOfBounds;
        }

        return offset;
    }

    fn programAt(
        self: Table,
        offset: usize,
        entry: Entry,
    ) ProgramError!void {
        var tx = TableTransaction.from(.{ .memory = self.memory });
        const saved = .{
            .address_lo = tx.read(u32, offset + entry_offsets.address_lo) catch return error.ProgrammingWriteFailed,
            .address_hi = tx.read(u32, offset + entry_offsets.address_hi) catch return error.ProgrammingWriteFailed,
            .data = tx.read(u32, offset + entry_offsets.data) catch return error.ProgrammingWriteFailed,
            .control = tx.read(u32, offset + entry_offsets.control) catch return error.ProgrammingWriteFailed,
        };

        var masked_control = VectorControl.from(saved.control);
        masked_control.masked = true;
        const masked_raw = VectorControl.raw(masked_control);

        var final_control = VectorControl.from(saved.control);
        final_control.masked = entry.masked;
        const final_raw = VectorControl.raw(final_control);

        const address_lo: u32 = @truncate(entry.address);
        const address_hi: u32 = @truncate(entry.address >> 32);

        try tx.writeReadback(u32, offset + entry_offsets.control, masked_raw, saved.control);

        try tx.writeReadback(u32, offset + entry_offsets.address_lo, address_lo, saved.address_lo);
        try tx.writeReadback(u32, offset + entry_offsets.address_hi, address_hi, saved.address_hi);
        try tx.writeReadback(u32, offset + entry_offsets.data, entry.data, saved.data);

        try tx.writeReadback(u32, offset + entry_offsets.control, final_raw, masked_raw);
    }

    fn containsDword(len_bytes: usize, offset: usize) bool {
        if (offset > len_bytes) {
            return false;
        }

        return @sizeOf(u32) <= len_bytes - offset;
    }

    const entry_offsets = struct {
        const address_lo = @offsetOf(TableRegister, "address_lo");
        const address_hi = @offsetOf(TableRegister, "address_hi");
        const data = @offsetOf(TableRegister, "data");
        const control = @offsetOf(TableRegister, "control");
    };
};

pub const Pba = struct {
    memory: BarMemory,
    num_vectors: u16,

    const bits_per_dword = @bitSizeOf(u32);

    pub const ReadError = error{InvalidRouting} || BarMemoryError;

    pub fn from(bar_memory: BarMemory, num_vectors: u16) Pba {
        std.debug.assert(num_vectors >= 1 and num_vectors <= msix.max_vectors);
        return .{ .memory = bar_memory, .num_vectors = num_vectors };
    }

    pub fn pending(
        self: Pba,
        index: u11,
    ) ReadError!bool {
        if (index >= self.num_vectors) {
            return error.InvalidRouting;
        }

        const dword_index = @divFloor(@as(usize, index), bits_per_dword);
        const bit_index = @mod(@as(usize, index), bits_per_dword);
        const bits = try self.read(dword_index);
        const shift: u5 = @intCast(bit_index);

        return bits & (@as(u32, 1) << shift) != 0;
    }

    pub fn read(self: Pba, dword_index: usize) ReadError!u32 {
        const offset = std.math.mul(usize, dword_index, @sizeOf(u32)) catch {
            return error.BarMemoryOutOfBounds;
        };

        const span = self.spanBytes();
        if (offset > span or @sizeOf(u32) > span - offset) {
            return error.BarMemoryOutOfBounds;
        }

        if (offset > self.memory.len or @sizeOf(u32) > self.memory.len - offset) {
            return error.BarMemoryOutOfBounds;
        }

        return self.memory.read32(offset);
    }

    pub fn spanBytes(self: Pba) usize {
        const adjusted_size = @as(usize, self.num_vectors) + bits_per_dword - 1;
        return @divFloor(adjusted_size, bits_per_dword) * @sizeOf(u32);
    }
};

pub const offsets = struct {
    pub const control = RelativeOffset(u16).from(msix.offsets.control);
    pub const table = RelativeOffset(u32).from(msix.offsets.table);
    pub const pba = RelativeOffset(u32).from(msix.offsets.pba);
};

const ConfigTarget = struct {
    registers: standard.Registers,

    pub const Offset16 = RelativeOffset(u16);

    pub fn read16(self: ConfigTarget, offset: Offset16) CapabilityError!u16 {
        return self.registers.read(offset);
    }

    pub fn write16(self: ConfigTarget, offset: Offset16, value: u16) CapabilityError!void {
        return self.registers.write(offset, value);
    }
};

const BarTarget = struct {
    memory: BarMemory,

    pub const Offset32 = usize;

    pub fn read32(self: BarTarget, offset: usize) BarMemoryError!u32 {
        return self.memory.read32(offset);
    }

    pub fn write32(self: BarTarget, offset: usize, value: u32) BarMemoryError!void {
        return self.memory.write32(offset, value);
    }
};

const ConfigTransaction = programming.Transaction(ConfigTarget, .{
    .capacity = 1,
    .word16 = true,
});

const TableTransaction = programming.Transaction(BarTarget, .{
    .capacity = 5,
    .word32 = true,
});

pub const unit = struct {
    const testing = std.testing;

    const pcie_window_size = core.config.extended_size;
    const test_sbdf = Sbdf.from(.from(0), 0, 0, 0);
    const cap_base: u8 = 0x40;

    const Id = core.capabilities.standard.Id;
    const Offset = core.Offset;
    const Sbdf = core.Sbdf;

    const TableEntry = msix.TableEntry;

    const ConfigBackend = struct {
        bytes: []u8,
        op_count: usize = 0,
        read16_count: usize = 0,
        write16_count: usize = 0,
        last_read16_offset: ?usize = null,
        fail_next_write16: bool = false,
        corrupt_readback16: ?u16 = null,

        fn from(bytes: []u8) ConfigBackend {
            std.debug.assert(bytes.len == pcie_window_size);
            return .{ .bytes = bytes };
        }

        fn config(self: *ConfigBackend) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn resetLog(self: *ConfigBackend) void {
            self.op_count = 0;
            self.read16_count = 0;
            self.write16_count = 0;
            self.last_read16_offset = null;
            self.fail_next_write16 = false;
            self.corrupt_readback16 = null;
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
            self.read16_count += 1;
            self.last_read16_offset = byte_offset;

            if (self.corrupt_readback16) |value| {
                if (self.write16_count > 0) {
                    self.corrupt_readback16 = null;
                    return value;
                }
            }

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
        corrupt_read_index: ?usize = null,
        corrupt_value: u32 = 0,

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
            self.corrupt_read_index = null;
            self.corrupt_value = 0;
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

            const value = if (self.corrupt_read_index == index)
                self.corrupt_value
            else
                load32(self.bytes, byte_offset);

            self.append(.{ .kind = .read, .offset = byte_offset, .value = value });
            return value;
        }

        fn write32(context: *anyopaque, byte_offset: usize, value: u32) BarMemoryError!void {
            const self: *BarBackend = @ptrCast(@alignCast(context));
            const index = self.write_count;
            self.write_count += 1;
            self.append(.{ .kind = .write, .offset = byte_offset, .value = value });

            if (self.fail_write_index == index) {
                return error.BarMemoryOutOfBounds;
            }

            store32(self.bytes, byte_offset, value);
        }
    };

    const MsixSeed = struct {
        table_size_minus_one: u11 = 0,
        reserved: u3 = 0,
        function_mask: bool = false,
        enable: bool = false,
        table_bir: u3 = 0,
        table_offset: u32 = 0,
        pba_bir: u3 = 0,
        pba_offset: u32 = 0,
    };

    const offset = struct {
        const status: usize = 0x06;
    };

    const status = struct {
        const cap_list: u16 = 1 << 4;
    };

    test "packed words match the MSI-X wire layout" {
        try testing.expectEqual(@as(usize, 2), @sizeOf(Control.Word));
        try testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(Control.Word));
        try testing.expectEqual(@as(usize, 4), @sizeOf(VectorControl.Word));
        try testing.expectEqual(@as(comptime_int, 32), @bitSizeOf(VectorControl.Word));

        const control = Control.from(0b11_101_00000000101);
        try testing.expectEqual(@as(u11, 5), control.table_size_minus_one);
        try testing.expectEqual(@as(u3, 0b101), control._rsvd_11);
        try testing.expect(control.function_mask);
        try testing.expect(control.enable);

        const vector_control = VectorControl.from(0xFFFF_FFFE);
        try testing.expect(!vector_control.masked);
        try testing.expectEqual(@as(u31, 0x7FFF_FFFF), vector_control._rsvd_1);
    }

    test "live locations and explicit spans" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{
            .table_size_minus_one = 32,
            .table_bir = 2,
            .table_offset = 0x180,
            .pba_bir = 2,
            .pba_offset = 0x280,
        });
        var backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&backend);

        try expectLocation(try capability.tableLocation(), 2, 0x180);
        try expectLocation(try capability.pbaLocation(), 2, 0x280);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;
        var bar_bytes: [0]u8 = .{};
        var bar_backend = BarBackend.from(&bar_bytes);
        try testing.expectEqual(@as(u16, 33), num_vectors);
        try testing.expectEqual(@as(usize, 8), Pba.from(bar_backend.accessor(), num_vectors).spanBytes());
    }

    test "tryFrom decodes independent Table and PBA BIR values" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{
            .table_size_minus_one = 0,
            .table_bir = 4,
            .table_offset = 0x1000,
            .pba_bir = 5,
            .pba_offset = 0x2000,
        });
        var backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&backend);

        try expectLocation(try capability.tableLocation(), 4, 0x1000);
        try expectLocation(try capability.pbaLocation(), 5, 0x2000);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;
        var bar_bytes: [0]u8 = .{};
        var bar_backend = BarBackend.from(&bar_bytes);
        try testing.expectEqual(@as(u16, 1), num_vectors);
        try testing.expectEqual(@as(usize, 16), Table.from(bar_backend.accessor(), num_vectors).spanBytes());
        try testing.expectEqual(@as(usize, 4), Pba.from(bar_backend.accessor(), num_vectors).spanBytes());
    }

    test "maximum table size produces maximum table and PBA spans" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .table_size_minus_one = 0x7FF });
        var backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&backend);

        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;
        var bar_bytes: [0]u8 = .{};
        var bar_backend = BarBackend.from(&bar_bytes);
        backend.resetLog();
        try testing.expectEqual(@as(u16, 2048), num_vectors);
        try testing.expectEqual(@as(usize, 2048 * 16), Table.from(bar_backend.accessor(), num_vectors).spanBytes());
        try testing.expectEqual(@as(usize, 256), Pba.from(bar_backend.accessor(), num_vectors).spanBytes());
        try testing.expectEqual(@as(usize, 0), backend.op_count);
        try testing.expectEqual(@as(usize, 0), bar_backend.op_count);
    }

    test "tryFrom rejects reserved Table and PBA BIR encodings" {
        inline for (.{ @as(u3, 6), @as(u3, 7) }) |reserved_bir| {
            var table_bytes: [pcie_window_size]u8 = @splat(0);
            seedMsixCapability(&table_bytes, .{ .table_bir = reserved_bir, .pba_bir = 0 });
            var table_backend = ConfigBackend.from(&table_bytes);
            try testing.expectError(error.MalformedField, tryCapability(&table_backend));

            var pba_bytes: [pcie_window_size]u8 = @splat(0);
            seedMsixCapability(&pba_bytes, .{ .table_bir = 0, .pba_bir = reserved_bir });
            var pba_backend = ConfigBackend.from(&pba_bytes);
            try testing.expectError(error.MalformedField, tryCapability(&pba_backend));
        }
    }

    test "find reports present, absent, and malformed traversal results" {
        var present_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&present_bytes, 0x40);
        seedCapability(&present_bytes, 0x40, 0x09, 0x80);
        seedCapability(&present_bytes, 0x80, @intFromEnum(msix.id), 0);
        seedMsixPayload(&present_bytes, 0x80, .{ .table_size_minus_one = 3 });
        var present_backend = ConfigBackend.from(&present_bytes);
        const present = (try Capability.find(functionFor(&present_backend))).?;

        try testing.expectEqual(@as(u8, 0x80), present.base);
        try testing.expectEqual(@as(u11, 3), (try present.control()).table_size_minus_one);

        var no_list_bytes: [pcie_window_size]u8 = @splat(0);
        no_list_bytes[core.header.type0.offsets.cap_ptr] = cap_base;
        seedCapability(&no_list_bytes, cap_base, @intFromEnum(msix.id), 0);
        seedMsixPayload(&no_list_bytes, cap_base, .{});
        var no_list_backend = ConfigBackend.from(&no_list_bytes);
        try testing.expectEqual(@as(?Capability, null), try Capability.find(functionFor(&no_list_backend)));

        var absent_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&absent_bytes, 0x40);
        seedCapability(&absent_bytes, 0x40, @intFromEnum(Id.msi), 0x44);
        seedCapability(&absent_bytes, 0x44, @intFromEnum(Id.pcie), 0);
        var absent_backend = ConfigBackend.from(&absent_bytes);
        try testing.expectEqual(@as(?Capability, null), try Capability.find(functionFor(&absent_backend)));

        var cycle_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&cycle_bytes, 0x40);
        seedCapability(&cycle_bytes, 0x40, 0x09, 0x44);
        seedCapability(&cycle_bytes, 0x44, @intFromEnum(Id.msi), 0x40);
        var cycle_backend = ConfigBackend.from(&cycle_bytes);
        try testing.expectError(error.MalformedCapability, Capability.find(functionFor(&cycle_backend)));
    }

    test "live config reads leave caller-owned snapshots independent" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{
            .table_size_minus_one = 7,
            .table_bir = 1,
            .table_offset = 0x100,
            .pba_bir = 1,
            .pba_offset = 0x200,
        });
        var backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&backend);
        const saved_control = try capability.control();
        const saved_table = try capability.tableLocation();
        const saved_pba = try capability.pbaLocation();
        backend.resetLog();

        store16(&bytes, cap_base + msix.offsets.control, messageControlRaw(.{
            .table_size_minus_one = 0x7FF,
            .reserved = 0b010,
            .function_mask = true,
            .enable = true,
        }));
        store32(&bytes, cap_base + msix.offsets.table, locationRaw(4, 0x300));
        store32(&bytes, cap_base + msix.offsets.pba, locationRaw(5, 0x400));

        const word = try capability.control();

        try testing.expectEqual(@as(u11, 0x7FF), word.table_size_minus_one);
        try testing.expect(word.enable);
        try testing.expect(word.function_mask);
        try testing.expectEqual(@as(usize, 1), backend.read16_count);
        try testing.expectEqual(@as(usize, cap_base + msix.offsets.control), backend.last_read16_offset.?);

        try testing.expectEqual(@as(u11, 7), saved_control.table_size_minus_one);
        try expectLocation(saved_table, 1, 0x100);
        try expectLocation(saved_pba, 1, 0x200);
        try expectLocation(try capability.tableLocation(), 4, 0x300);
        try expectLocation(try capability.pbaLocation(), 5, 0x400);
        inline for (.{ @as(u3, 6), @as(u3, 7) }) |bir| {
            store32(&bytes, cap_base + msix.offsets.table, locationRaw(bir, 0));
            store32(&bytes, cap_base + msix.offsets.pba, locationRaw(bir, 0));
            try testing.expectError(error.MalformedField, capability.tableLocation());
            try testing.expectError(error.MalformedField, capability.pbaLocation());
        }
    }

    test "explicit memory counts survive config changes and bound PBA words" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .table_size_minus_one = 31 });
        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;
        var table_bytes: [33 * @sizeOf(TableEntry)]u8 = @splat(0);
        var table_backend = BarBackend.from(&table_bytes);
        var pba_bytes: [8]u8 = @splat(0);
        store32(&pba_bytes, 0, 0x8000_0000);
        store32(&pba_bytes, 4, 1);
        var pba_backend = BarBackend.from(&pba_bytes);
        config_backend.resetLog();

        const table = Table.from(table_backend.accessor(), num_vectors);
        const pba = Pba.from(pba_backend.accessor(), num_vectors);
        const wider_pba = Pba.from(pba_backend.accessor(), num_vectors + 1);
        try testing.expectEqual(@as(usize, 0), config_backend.op_count);
        try testing.expectEqual(@as(usize, 0), table_backend.op_count);
        try testing.expectEqual(@as(usize, 0), pba_backend.op_count);
        store16(&bytes, cap_base + msix.offsets.control, messageControlRaw(.{ .table_size_minus_one = 0x7FF }));

        try testing.expectEqual(@as(usize, 32 * 16), table.spanBytes());
        try testing.expectEqual(@as(usize, 4), pba.spanBytes());
        try testing.expectEqual(@as(usize, 8), wider_pba.spanBytes());
        try testing.expectError(error.InvalidRouting, table.read(32));
        try testing.expectEqual(@as(usize, 0), table_backend.op_count);
        _ = try table.read(31);
        try testing.expect(try pba.pending(31));
        const pba_reads = pba_backend.op_count;
        try testing.expectError(error.InvalidRouting, pba.pending(32));
        try testing.expectError(error.BarMemoryOutOfBounds, pba.read(1));
        try testing.expectEqual(pba_reads, pba_backend.op_count);
        try testing.expect(try wider_pba.pending(32));
        try testing.expectEqual(@as(usize, 0), config_backend.op_count);
    }

    test "table and PBA reads reconstruct values and reject invalid bounds before I/O" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .table_size_minus_one = 63 });
        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;
        config_backend.resetLog();

        var table_bytes: [2 * @sizeOf(TableEntry)]u8 = @splat(0);
        store32(&table_bytes, 16 + @offsetOf(TableEntry, "address_lo"), 0x89AB_CDEF);
        store32(&table_bytes, 16 + @offsetOf(TableEntry, "address_hi"), 0x0123_4567);
        store32(&table_bytes, 16 + @offsetOf(TableEntry, "data"), 0xCAFE_BABE);
        store32(&table_bytes, 16 + @offsetOf(TableEntry, "control"), 0xFFFF_FFFF);
        var table_backend = BarBackend.from(&table_bytes);

        const read_entry = try Table.from(table_backend.accessor(), num_vectors).read(1);

        try expectVectorEntry(read_entry, .{
            .address = 0x0123_4567_89AB_CDEF,
            .data = 0xCAFE_BABE,
            .masked = true,
        });
        try testing.expectEqual(@as(usize, 0), config_backend.op_count);

        var pba_bytes: [8]u8 = @splat(0);
        store32(&pba_bytes, 4, @as(u32, 1) << 5);
        var pba_backend = BarBackend.from(&pba_bytes);
        try testing.expect(try Pba.from(pba_backend.accessor(), num_vectors).pending(37));
        try testing.expectEqual(@as(u32, 0x0000_0020), try Pba.from(pba_backend.accessor(), num_vectors).read(1));
        try testing.expectEqual(@as(usize, 0), config_backend.op_count);

        var short_table_bytes: [2 * @sizeOf(TableEntry) - 1]u8 = @splat(0);
        var short_table_backend = BarBackend.from(&short_table_bytes);
        try testing.expectError(error.BarMemoryOutOfBounds, Table.from(short_table_backend.accessor(), num_vectors).read(1));
        try testing.expectEqual(@as(usize, 0), short_table_backend.op_count);

        var small_pba_bytes: [4]u8 = @splat(0);
        var small_pba_backend = BarBackend.from(&small_pba_bytes);
        try testing.expectError(error.InvalidRouting, Pba.from(small_pba_backend.accessor(), num_vectors).pending(64));
        try testing.expectEqual(@as(usize, 0), small_pba_backend.op_count);

        try testing.expectError(error.BarMemoryOutOfBounds, Pba.from(small_pba_backend.accessor(), num_vectors).read(1));
        try testing.expectEqual(@as(usize, 0), small_pba_backend.op_count);
    }

    test "config writes preserve reserved bits and map write/readback failures" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{
            .table_size_minus_one = 0x123,
            .reserved = 0b101,
            .function_mask = true,
            .enable = false,
        });
        var backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&backend);
        backend.resetLog();

        try capability.enable();

        try expectMessageControlRaw(&bytes, .{
            .table_size_minus_one = 0x123,
            .reserved = 0b101,
            .function_mask = true,
            .enable = true,
        });
        try testing.expectEqual(@as(usize, 1), backend.write16_count);

        try capability.disable();

        try expectMessageControlRaw(&bytes, .{
            .table_size_minus_one = 0x123,
            .reserved = 0b101,
            .function_mask = true,
            .enable = false,
        });

        try capability.setFunctionMask(false);

        try expectMessageControlRaw(&bytes, .{
            .table_size_minus_one = 0x123,
            .reserved = 0b101,
            .function_mask = false,
            .enable = false,
        });

        store16(&bytes, cap_base + msix.offsets.control, messageControlRaw(.{ .enable = false }));
        backend.resetLog();
        backend.fail_next_write16 = true;

        try testing.expectError(error.ProgrammingWriteFailed, capability.enable());
        try testing.expectEqual(@as(usize, 1), backend.write16_count);
        try expectMessageControlRaw(&bytes, .{ .enable = false });

        backend.resetLog();
        backend.corrupt_readback16 = messageControlRaw(.{ .enable = false });

        try testing.expectError(error.ProgrammingReadbackMismatch, capability.enable());
        try expectMessageControlRaw(&bytes, .{ .enable = false });
        try testing.expectEqual(@as(usize, 2), backend.write16_count);
    }

    test "program self-masks, preserves reserved bits, and writes fields in order" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .table_size_minus_one = 3, .enable = true });
        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;
        config_backend.resetLog();

        var table_bytes: [4 * @sizeOf(TableEntry)]u8 = @splat(0);
        seedEntry(&table_bytes, 1, .{
            .address = 0x1111_2222_3333_4444,
            .data = 0x5555_AAAA,
            .vector_control = 0xA5A5_A5A4,
        });
        var table_backend = BarBackend.from(&table_bytes);

        try Table.from(table_backend.accessor(), num_vectors).program(1, .{
            .address = 0x0123_4567_89AB_CDEF,
            .data = 0xCAFE_BABE,
            .masked = false,
        });

        try testing.expectEqual(@as(usize, 0), config_backend.op_count);
        try expectDword(&table_bytes, 16 + @offsetOf(TableEntry, "address_lo"), 0x89AB_CDEF);
        try expectDword(&table_bytes, 16 + @offsetOf(TableEntry, "address_hi"), 0x0123_4567);
        try expectDword(&table_bytes, 16 + @offsetOf(TableEntry, "data"), 0xCAFE_BABE);
        try expectDword(&table_bytes, 16 + @offsetOf(TableEntry, "control"), 0xA5A5_A5A4);
        try expectBarOp(table_backend.ops[4], .write, 0x1C, 0xA5A5_A5A5);
        try expectBarOp(table_backend.ops[6], .write, 0x10, 0x89AB_CDEF);
        try expectBarOp(table_backend.ops[8], .write, 0x14, 0x0123_4567);
        try expectBarOp(table_backend.ops[10], .write, 0x18, 0xCAFE_BABE);
        try expectBarOp(table_backend.ops[12], .write, 0x1C, 0xA5A5_A5A4);
    }

    test "failure: program save read failures issue no writes" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .table_size_minus_one = 1 });
        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;

        var table_bytes: [2 * @sizeOf(TableEntry)]u8 = @splat(0x5A);
        const before = table_bytes;
        var table_backend = BarBackend.from(&table_bytes);
        const save_control_read = 0;
        table_backend.fail_read_index = save_control_read;

        try testing.expectError(error.ProgrammingWriteFailed, Table.from(table_backend.accessor(), num_vectors).program(
            0,
            .{ .address = 0, .data = 0, .masked = false },
        ));

        try testing.expectEqual(@as(usize, 0), table_backend.write_count);
        try testing.expectEqualSlices(u8, &before, &table_bytes);
    }

    test "failure: program rolls back a readback mismatch to the saved entry" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .table_size_minus_one = 1 });
        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;

        var table_bytes: [2 * @sizeOf(TableEntry)]u8 = @splat(0);
        seedEntry(&table_bytes, 0, .{
            .address = 0xAAAA_BBBB_CCCC_DDDD,
            .data = 0xEEEE_FFFF,
            .vector_control = 0x1357_2468,
        });
        const before = table_bytes;
        var table_backend = BarBackend.from(&table_bytes);
        const address_lo_readback = 5;
        table_backend.corrupt_read_index = address_lo_readback;
        table_backend.corrupt_value = 0;

        try testing.expectError(error.ProgrammingReadbackMismatch, Table.from(table_backend.accessor(), num_vectors).program(
            0,
            .{ .address = 0x0123_4567_89AB_CDEF, .data = 0xCAFE_BABE, .masked = false },
        ));

        try testing.expectEqualSlices(u8, &before, &table_bytes);
        try expectBarOp(table_backend.ops[8], .write, 0x00, 0xCCCC_DDDD);
        try expectBarOp(table_backend.ops[10], .write, 0x0C, 0x1357_2468);
    }

    test "failure: program stops rollback when restoring the address fails" {
        for ([_]enum { write, read }{ .write, .read }) |failure| {
            var table_bytes: [2 * @sizeOf(TableEntry)]u8 = @splat(0);
            seedEntry(&table_bytes, 0, .{
                .address = 0xAAAA_BBBB_CCCC_DDDD,
                .data = 0xEEEE_FFFF,
                .vector_control = 0x1357_2468,
            });
            var expected = table_bytes;
            store32(&expected, @offsetOf(TableEntry, "address_lo"), 0x89AB_CDEF);
            store32(&expected, @offsetOf(TableEntry, "control"), 0x1357_2469);
            if (failure == .write) {
                store32(&expected, @offsetOf(TableEntry, "address_hi"), 0x0123_4567);
            }

            var backend = BarBackend.from(&table_bytes);
            const address_hi_readback = 6;
            backend.corrupt_read_index = address_hi_readback;
            backend.corrupt_value = 0;
            const rollback_address_write = 3;
            const rollback_address_readback = 7;
            switch (failure) {
                .write => backend.fail_write_index = rollback_address_write,
                .read => backend.fail_read_index = rollback_address_readback,
            }

            try testing.expectError(error.ProgrammingPartial, Table.from(backend.accessor(), 2).program(
                0,
                .{ .address = 0x0123_4567_89AB_CDEF, .data = 0xCAFE_BABE, .masked = false },
            ));

            try testing.expectEqualSlices(u8, &expected, &table_bytes);
            try testing.expectEqual(@as(usize, 4), backend.write_count);
            try testing.expectEqual(@as(usize, if (failure == .write) 7 else 8), backend.read_count);
            try testing.expectEqual(@as(usize, if (failure == .write) 11 else 12), backend.op_count);
            try expectBarOp(backend.ops[8], .write, 0x04, 0x0123_4567);
            try expectBarOp(backend.ops[9], .read, 0x04, 0);
            try expectBarOp(backend.ops[10], .write, 0x04, 0xAAAA_BBBB);
            if (failure == .read) {
                try expectBarOp(backend.ops[11], .read, 0x04, 0);
            }
        }
    }

    test "programAll handles empty input, upfront bounds, and failure boundaries" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .table_size_minus_one = 2 });
        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;

        var empty_table_bytes: [3 * @sizeOf(TableEntry)]u8 = @splat(0);
        var empty_backend = BarBackend.from(&empty_table_bytes);
        try Table.from(empty_backend.accessor(), num_vectors).programAll(1, &.{});
        try testing.expectEqual(@as(usize, 0), empty_backend.op_count);

        try testing.expectError(error.InvalidRouting, Table.from(empty_backend.accessor(), num_vectors).programAll(
            2,
            &.{ .{ .address = 0, .data = 0, .masked = false }, .{ .address = 1, .data = 1, .masked = true } },
        ));
        try testing.expectEqual(@as(usize, 0), empty_backend.op_count);

        var short_table_bytes: [3 * @sizeOf(TableEntry) - 1]u8 = @splat(0);
        var short_backend = BarBackend.from(&short_table_bytes);
        try testing.expectError(error.BarMemoryOutOfBounds, Table.from(short_backend.accessor(), num_vectors).programAll(
            0,
            &.{
                .{ .address = 0, .data = 0, .masked = false },
                .{ .address = 1, .data = 1, .masked = true },
                .{ .address = 2, .data = 2, .masked = false },
            },
        ));
        try testing.expectEqual(@as(usize, 0), short_backend.op_count);

        var table_bytes: [3 * @sizeOf(TableEntry)]u8 = @splat(0);
        seedEntry(&table_bytes, 0, .{ .address = 0x10, .data = 0x10, .vector_control = 0x8000_0000 });
        seedEntry(&table_bytes, 1, .{ .address = 0x20, .data = 0x20, .vector_control = 0x4000_0001 });
        seedEntry(&table_bytes, 2, .{ .address = 0x30, .data = 0x30, .vector_control = 0x2000_0000 });
        const entry1_before = table_bytes[16..32].*;
        const entry2_before = table_bytes[32..48].*;
        var table_backend = BarBackend.from(&table_bytes);
        const second_entry_mask_readback = 14;
        table_backend.corrupt_read_index = second_entry_mask_readback;
        table_backend.corrupt_value = 0;
        const entries = [_]Table.Entry{
            .{ .address = 0xAAAA_BBBB_CCCC_DDDD, .data = 0x1111_1111, .masked = false },
            .{ .address = 0x0123_4567_89AB_CDEF, .data = 0x2222_2222, .masked = true },
            .{ .address = 0x9999_AAAA_BBBB_CCCC, .data = 0x3333_3333, .masked = false },
        };

        try testing.expectError(error.ProgrammingReadbackMismatch, Table.from(table_backend.accessor(), num_vectors).programAll(
            0,
            &entries,
        ));

        try expectDword(&table_bytes, @offsetOf(TableEntry, "address_lo"), 0xCCCC_DDDD);
        try expectDword(&table_bytes, @offsetOf(TableEntry, "address_hi"), 0xAAAA_BBBB);
        try expectDword(&table_bytes, @offsetOf(TableEntry, "data"), 0x1111_1111);
        try expectDword(&table_bytes, @offsetOf(TableEntry, "control"), 0x8000_0000);
        try testing.expectEqualSlices(u8, &entry1_before, table_bytes[16..32]);
        try testing.expectEqualSlices(u8, &entry2_before, table_bytes[32..48]);
    }

    test "setMasked preserves reserved bits and rolls back readback mismatch" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{ .table_size_minus_one = 1 });
        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;
        config_backend.resetLog();

        var table_bytes: [2 * @sizeOf(TableEntry)]u8 = @splat(0);
        seedEntry(&table_bytes, 1, .{
            .address = 0x1111_2222_3333_4444,
            .data = 0x5555_6666,
            .vector_control = 0xFFFF_FFFE,
        });
        var table_backend = BarBackend.from(&table_bytes);

        try Table.from(table_backend.accessor(), num_vectors).setMasked(1, true);

        try expectDword(&table_bytes, 16 + @offsetOf(TableEntry, "address_lo"), 0x3333_4444);
        try expectDword(&table_bytes, 16 + @offsetOf(TableEntry, "address_hi"), 0x1111_2222);
        try expectDword(&table_bytes, 16 + @offsetOf(TableEntry, "data"), 0x5555_6666);
        try expectDword(&table_bytes, 16 + @offsetOf(TableEntry, "control"), 0xFFFF_FFFF);
        try testing.expectEqual(@as(usize, 0), config_backend.op_count);

        seedEntry(&table_bytes, 1, .{
            .address = 0x1111_2222_3333_4444,
            .data = 0x5555_6666,
            .vector_control = 0xABCD_EF01,
        });
        const before = table_bytes;
        table_backend.resetLog();
        const mask_readback = 1;
        table_backend.corrupt_read_index = mask_readback;
        table_backend.corrupt_value = 0;

        try testing.expectError(error.ProgrammingReadbackMismatch, Table.from(table_backend.accessor(), num_vectors).setMasked(
            1,
            false,
        ));

        try testing.expectEqualSlices(u8, &before, &table_bytes);
    }

    test "integration: cross-BIR callers can use distinct BAR memories without cross-touching" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixCapability(&bytes, .{
            .table_size_minus_one = 0,
            .table_bir = 4,
            .table_offset = 0x1000,
            .pba_bir = 5,
            .pba_offset = 0x2000,
        });
        var config_backend = ConfigBackend.from(&bytes);
        const capability = try tryCapability(&config_backend);
        const word = try capability.control();
        const num_vectors = @as(u16, word.table_size_minus_one) + 1;

        var table_bytes: [@sizeOf(TableEntry)]u8 = @splat(0);
        seedEntry(&table_bytes, 0, .{ .address = 0, .data = 0, .vector_control = 0xAAAA_AAAA });
        var table_backend = BarBackend.from(&table_bytes);
        var pba_bytes: [4]u8 = @splat(0);
        store32(&pba_bytes, 0, 0x8000_0001);
        var pba_backend = BarBackend.from(&pba_bytes);

        try Table.from(table_backend.accessor(), num_vectors).program(0, .{
            .address = 0xFEE0_0000,
            .data = 0x45,
            .masked = false,
        });

        try testing.expect(table_backend.op_count > 0);
        try testing.expectEqual(@as(usize, 0), pba_backend.op_count);

        try testing.expectEqual(@as(u32, 0x8000_0001), try Pba.from(pba_backend.accessor(), num_vectors).read(0));
        try testing.expectEqual(@as(usize, 1), pba_backend.op_count);

        pba_backend.resetLog();
        try testing.expectError(error.BarMemoryOutOfBounds, Table.from(pba_backend.accessor(), num_vectors).program(
            0,
            .{ .address = 0, .data = 0, .masked = false },
        ));
        try testing.expectEqual(@as(usize, 0), pba_backend.op_count);
    }

    test "MSI-X capability extent stays in conventional config space" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedMsixPayload(&bytes, 0xF4, .{ .table_bir = 2, .table_offset = 0x1000, .pba_bir = 3, .pba_offset = 0x2000 });
        var backend = ConfigBackend.from(&bytes);
        const valid = try Capability.tryFrom(functionFor(&backend), .{ .id = .msix, .offset = 0xF4 });

        try expectLocation(try valid.tableLocation(), 2, 0x1000);
        try expectLocation(try valid.pbaLocation(), 3, 0x2000);

        backend.resetLog();
        try testing.expectError(error.MalformedCapability, Capability.tryFrom(functionFor(&backend), .{ .id = .msix, .offset = 0xF8 }));
        try testing.expectEqual(@as(usize, 0), backend.op_count);

        var invalid = valid;
        invalid.base = 0xFC;
        const before = bytes;

        try testing.expectError(error.ProgrammingWriteFailed, invalid.enable());
        try testing.expectEqual(@as(usize, 0), backend.op_count);
        try testing.expectEqualSlices(u8, &before, &bytes);
    }

    fn functionFor(backend: *ConfigBackend) Function {
        return Function.from(backend.config(), test_sbdf);
    }

    fn tryCapability(backend: *ConfigBackend) !Capability {
        return Capability.tryFrom(functionFor(backend), .{ .id = msix.id, .offset = cap_base });
    }

    fn seedMsixCapability(bytes: []u8, options: MsixSeed) void {
        seedHead(bytes, cap_base);
        seedCapability(bytes, cap_base, @intFromEnum(msix.id), 0);
        seedMsixPayload(bytes, cap_base, options);
    }

    fn seedMsixPayload(bytes: []u8, base: u8, options: MsixSeed) void {
        store16(bytes, @as(usize, base) + msix.offsets.control, messageControlRaw(options));
        store32(bytes, @as(usize, base) + msix.offsets.table, locationRaw(
            options.table_bir,
            options.table_offset,
        ));
        store32(bytes, @as(usize, base) + msix.offsets.pba, locationRaw(
            options.pba_bir,
            options.pba_offset,
        ));
    }

    fn seedHead(bytes: []u8, head: u8) void {
        store16(bytes, offset.status, status.cap_list);
        bytes[core.header.type0.offsets.cap_ptr] = head;
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

    fn messageControlRaw(options: MsixSeed) u16 {
        var control = Control.from(0);
        control.table_size_minus_one = options.table_size_minus_one;
        control._rsvd_11 = options.reserved;
        control.function_mask = options.function_mask;
        control.enable = options.enable;
        return Control.raw(control);
    }

    fn locationRaw(bir: u3, base_offset: u32) u32 {
        var location = msix.Location.from(0);
        location.bir = bir;
        location.offset_shifted = @intCast(base_offset >> 3);
        return msix.Location.raw(location);
    }

    fn expectLocation(actual: Location, bir: u3, base_offset: u32) !void {
        try testing.expectEqual(bir, actual.bir);
        try testing.expectEqual(base_offset, actual.offset);
    }

    fn expectVectorEntry(actual: Table.Entry, expected: Table.Entry) !void {
        try testing.expectEqual(expected.address, actual.address);
        try testing.expectEqual(expected.data, actual.data);
        try testing.expectEqual(expected.masked, actual.masked);
    }

    fn expectMessageControlRaw(bytes: []const u8, expected: MsixSeed) !void {
        try testing.expectEqual(
            messageControlRaw(expected),
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
