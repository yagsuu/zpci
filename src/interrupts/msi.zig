//! MSI capability access and programming.

const std = @import("std");

const pci_config = @import("config");
const core = @import("core");
const capabilities = @import("capabilities");
const programming = @import("programming.zig");

const standard = capabilities.standard;
const msi = core.capabilities.msi;

const ConfigSpace = pci_config.ConfigSpace;
const ConfigError = ConfigSpace.Error;
const Function = pci_config.Function;

const RelativeOffset = core.RelativeOffset;
const Control = msi.Control;
const ControlWord = Control.Word;
const VectorCount = msi.VectorCount;

const Entry = standard.Entry;
const Registers = standard.Registers;
const CapabilityIterator = standard.Iterator;
const CapabilityError = standard.Error;

const ProgrammingError = programming.Error;

pub const Capability = struct {
    function: Function,
    base: u8,

    pub const ReadError = error{
        MalformedCapability,
        MalformedField,
    } || ConfigError;

    pub const ProgramError = error{
        MalformedField,
        InvalidRouting,
        ProgrammingReadbackMismatch,
        ProgrammingWriteFailed,
        ProgrammingPartial,
    };

    pub const Routing = struct {
        address: u64,
        data: u16,
        num_vectors: VectorCount,
        initial_mask: ?u32 = null,
        ext_data: ?u16 = null,
    };

    pub fn find(function: Function) ReadError!?Capability {
        var iterator = try CapabilityIterator.tryFrom(function);
        while (try iterator.next()) |capability| {
            if (capability.id == msi.id) {
                return try Capability.tryFrom(function, capability);
            }
        }

        return null;
    }

    pub fn tryFrom(function: Function, entry: Entry) ReadError!Capability {
        std.debug.assert(entry.id == msi.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        const word = Control.from(try registers.read(offsets.addr32.control));
        _ = try VectorCount.from(word.multiple_msg_capable).count();

        const capability: Capability = .{
            .function = function,
            .base = entry.offset,
        };

        try validateExtent(registers, word);

        return capability;
    }

    pub fn control(self: Capability) ReadError!ControlWord {
        const registers = try Registers.tryFrom(self.function, self.base);
        return Control.from(try registers.read(offsets.addr32.control));
    }

    pub fn address(self: Capability) ReadError!u64 {
        const registers = try Registers.tryFrom(self.function, self.base);
        const word = Control.from(try registers.read(offsets.addr32.control));
        return readAddress(registers, word);
    }

    pub fn data(self: Capability) ReadError!u16 {
        const registers = try Registers.tryFrom(self.function, self.base);
        const word = Control.from(try registers.read(offsets.addr32.control));
        return registers.read(dataOffset(word));
    }

    pub fn extData(self: Capability) ReadError!u16 {
        const registers = try Registers.tryFrom(self.function, self.base);
        const word = Control.from(try registers.read(offsets.addr32.control));
        std.debug.assert(word.ext_data_capable);
        return registers.read(extDataOffset(word));
    }

    pub fn mask(self: Capability) ReadError!u32 {
        const registers = try Registers.tryFrom(self.function, self.base);
        const word = Control.from(try registers.read(offsets.addr32.control));
        std.debug.assert(word.pvm_capable);
        return registers.read(maskOffset(word));
    }

    pub fn pending(self: Capability) ReadError!u32 {
        const registers = try Registers.tryFrom(self.function, self.base);
        const word = Control.from(try registers.read(offsets.addr32.control));
        std.debug.assert(word.pvm_capable);
        return registers.read(pendingOffset(word));
    }

    pub fn readRouting(self: Capability) ReadError!Routing {
        const registers = try Registers.tryFrom(self.function, self.base);
        const word = Control.from(try registers.read(offsets.addr32.control));
        const num_vectors = VectorCount.from(word.multiple_msg_enable);
        _ = try num_vectors.count();

        return .{
            .address = try readAddress(registers, word),
            .data = try registers.read(dataOffset(word)),
            .num_vectors = num_vectors,
            .initial_mask = if (word.pvm_capable) try registers.read(maskOffset(word)) else null,
            .ext_data = if (word.ext_data_capable) try registers.read(extDataOffset(word)) else null,
        };
    }

    pub fn setVectorMasked(self: Capability, index: u5, masked: bool) ProgramError!void {
        const registers = Registers.tryFrom(self.function, self.base) catch return error.ProgrammingWriteFailed;
        const word = Control.from(registers.read(offsets.addr32.control) catch return error.ProgrammingWriteFailed);
        std.debug.assert(word.pvm_capable);
        const num_vectors = try VectorCount.from(word.multiple_msg_capable).count();
        std.debug.assert(index < num_vectors);
        validateExtent(registers, word) catch return error.ProgrammingWriteFailed;

        var tx = Transaction.from(ConfigTarget.from(registers, word));
        const offset = tx.target.mask.?;
        const saved = tx.read(u32, offset) catch return error.ProgrammingWriteFailed;
        var value = saved;
        const bit = @as(u32, 1) << index;
        if (masked) {
            value |= bit;
        } else {
            value &= ~bit;
        }

        try tx.writeReadback(u32, offset, value, saved);
    }

    pub fn setMask(self: Capability, value: u32) ProgramError!void {
        const registers = Registers.tryFrom(self.function, self.base) catch return error.ProgrammingWriteFailed;
        const word = Control.from(registers.read(offsets.addr32.control) catch return error.ProgrammingWriteFailed);
        validateExtent(registers, word) catch return error.ProgrammingWriteFailed;
        std.debug.assert(word.pvm_capable);

        var tx = Transaction.from(ConfigTarget.from(registers, word));
        const offset = tx.target.mask.?;
        const saved = tx.read(u32, offset) catch return error.ProgrammingWriteFailed;

        try tx.writeReadback(u32, offset, value, saved);
    }

    pub fn program(self: Capability, routing: Routing) ProgramError!void {
        const registers = Registers.tryFrom(self.function, self.base) catch return error.ProgrammingWriteFailed;
        const word = Control.from(registers.read(offsets.addr32.control) catch return error.ProgrammingWriteFailed);
        try validateRouting(word, routing);
        validateExtent(registers, word) catch return error.ProgrammingWriteFailed;

        var tx = Transaction.from(ConfigTarget.from(registers, word));
        const saved = Snapshot.read(word, &tx) catch return error.ProgrammingWriteFailed;

        var disabled_control = saved.control;
        disabled_control.enable = false;
        try tx.writeReadback(u16, tx.target.control, Control.raw(disabled_control), Control.raw(saved.control));

        if (routing.initial_mask) |value| {
            try tx.writeReadback(u32, tx.target.mask.?, value, saved.mask);
        }

        try tx.writeReadback(u32, tx.target.address_lo, @truncate(routing.address), saved.address_lo);
        if (word.addr64_capable) {
            try tx.writeReadback(u32, tx.target.address_hi.?, @truncate(routing.address >> 32), saved.address_hi);
        }

        try tx.writeReadback(u16, tx.target.data, routing.data, saved.data);

        if (routing.ext_data) |value| {
            try tx.writeReadback(u16, tx.target.ext_data.?, value, saved.ext_data);
        }

        var enabled_control = saved.control;
        enabled_control.enable = true;
        enabled_control.multiple_msg_enable = @intFromEnum(routing.num_vectors);
        enabled_control.ext_data_enable = routing.ext_data != null;
        try tx.writeReadback(u16, tx.target.control, Control.raw(enabled_control), Control.raw(saved.control));
    }

    pub fn disable(self: Capability) ProgramError!void {
        const registers = Registers.tryFrom(self.function, self.base) catch return error.ProgrammingWriteFailed;
        var word = Control.from(registers.read(offsets.addr32.control) catch return error.ProgrammingWriteFailed);
        validateExtent(registers, word) catch return error.ProgrammingWriteFailed;

        var tx = Transaction.from(ConfigTarget.from(registers, word));
        const saved_raw = Control.raw(word);

        word.enable = false;

        try tx.writeReadback(u16, tx.target.control, Control.raw(word), saved_raw);
    }

    fn validateRouting(word: ControlWord, routing: Routing) ProgramError!void {
        const requested = try routing.num_vectors.count();
        const capable = try VectorCount.from(word.multiple_msg_capable).count();
        if (requested > capable) {
            return error.InvalidRouting;
        }

        if (!word.addr64_capable and routing.address > std.math.maxInt(u32)) {
            return error.InvalidRouting;
        }

        const data_mask = @as(u16, @intCast(requested - 1));
        if (routing.data & data_mask != 0) {
            return error.InvalidRouting;
        }

        if (routing.initial_mask != null and !word.pvm_capable) {
            return error.InvalidRouting;
        }

        if ((routing.ext_data != null) != word.ext_data_capable) {
            return error.InvalidRouting;
        }
    }

    fn readAddress(registers: Registers, word: ControlWord) ReadError!u64 {
        const lo = try registers.read(offsets.addr32.address_lo);
        if (!word.addr64_capable) {
            return lo;
        }

        const hi = try registers.read(offsets.addr64.address_hi);
        return (@as(u64, hi) << 32) | @as(u64, lo);
    }

    fn dataOffset(word: ControlWord) RelativeOffset(u16) {
        return if (word.addr64_capable) offsets.addr64.data else offsets.addr32.data;
    }

    fn extDataOffset(word: ControlWord) RelativeOffset(u16) {
        return if (word.addr64_capable) offsets.addr64.ext_data else offsets.addr32.ext_data;
    }

    fn maskOffset(word: ControlWord) RelativeOffset(u32) {
        return if (word.addr64_capable) offsets.addr64.mask else offsets.addr32.mask;
    }

    fn pendingOffset(word: ControlWord) RelativeOffset(u32) {
        return if (word.addr64_capable) offsets.addr64.pending else offsets.addr32.pending;
    }

    fn validateExtent(registers: Registers, word: ControlWord) error{MalformedCapability}!void {
        const contained = if (word.pvm_capable)
            registers.contains(pendingOffset(word))
        else if (word.ext_data_capable)
            registers.contains(extDataOffset(word))
        else
            registers.contains(dataOffset(word));

        if (!contained) {
            return error.MalformedCapability;
        }
    }
};

pub const offsets = struct {
    pub const addr32 = struct {
        pub const control = RelativeOffset(u16).from(msi.offsets.control);
        pub const address_lo = RelativeOffset(u32).from(msi.offsets.address_lo);
        pub const data = RelativeOffset(u16).from(msi.addr32.offsets.data);
        pub const ext_data = RelativeOffset(u16).from(msi.addr32.offsets.ext_data);
        pub const mask = RelativeOffset(u32).from(msi.addr32.offsets.mask);
        pub const pending = RelativeOffset(u32).from(msi.addr32.offsets.pending);
    };

    pub const addr64 = struct {
        pub const control = RelativeOffset(u16).from(msi.offsets.control);
        pub const address_lo = RelativeOffset(u32).from(msi.offsets.address_lo);
        pub const address_hi = RelativeOffset(u32).from(msi.addr64.offsets.address_hi);
        pub const data = RelativeOffset(u16).from(msi.addr64.offsets.data);
        pub const ext_data = RelativeOffset(u16).from(msi.addr64.offsets.ext_data);
        pub const mask = RelativeOffset(u32).from(msi.addr64.offsets.mask);
        pub const pending = RelativeOffset(u32).from(msi.addr64.offsets.pending);
    };
};

const ConfigTarget = struct {
    registers: Registers,
    control: Offset16,
    address_lo: Offset32,
    address_hi: ?Offset32,
    data: Offset16,
    ext_data: ?Offset16,
    mask: ?Offset32,

    pub const Offset16 = RelativeOffset(u16);
    pub const Offset32 = RelativeOffset(u32);

    pub fn from(registers: Registers, word: ControlWord) ConfigTarget {
        return .{
            .registers = registers,
            .control = offsets.addr32.control,
            .address_lo = offsets.addr32.address_lo,
            .address_hi = if (word.addr64_capable) offsets.addr64.address_hi else null,
            .data = Capability.dataOffset(word),
            .ext_data = if (word.ext_data_capable) Capability.extDataOffset(word) else null,
            .mask = if (word.pvm_capable) Capability.maskOffset(word) else null,
        };
    }

    pub fn read16(self: ConfigTarget, offset: Offset16) CapabilityError!u16 {
        return self.registers.read(offset);
    }

    pub fn read32(self: ConfigTarget, offset: Offset32) CapabilityError!u32 {
        return self.registers.read(offset);
    }

    pub fn write16(self: ConfigTarget, offset: Offset16, value: u16) CapabilityError!void {
        return self.registers.write(offset, value);
    }

    pub fn write32(self: ConfigTarget, offset: Offset32, value: u32) CapabilityError!void {
        return self.registers.write(offset, value);
    }
};

const Transaction = programming.Transaction(ConfigTarget, .{
    .capacity = 7,
    .word16 = true,
    .word32 = true,
});

const Snapshot = struct {
    control: ControlWord,
    address_lo: u32,
    address_hi: u32 = 0,
    data: u16,
    ext_data: u16 = 0,
    mask: u32 = 0,

    fn read(word: ControlWord, tx: *Transaction) ProgrammingError!Snapshot {
        const address_lo = try tx.read(u32, tx.target.address_lo);
        const address_hi = if (word.addr64_capable)
            try tx.read(u32, tx.target.address_hi.?)
        else
            0;
        const data = try tx.read(u16, tx.target.data);
        const ext_data = if (word.ext_data_capable)
            try tx.read(u16, tx.target.ext_data.?)
        else
            0;
        const mask = if (word.pvm_capable)
            try tx.read(u32, tx.target.mask.?)
        else
            0;

        return .{
            .control = word,
            .address_lo = address_lo,
            .address_hi = address_hi,
            .data = data,
            .ext_data = ext_data,
            .mask = mask,
        };
    }
};

pub const unit = struct {
    const testing = std.testing;

    const addr32_offsets = msi.addr32.offsets;
    const addr64_offsets = msi.addr64.offsets;

    const pcie_window_size = core.config.extended_size;
    const test_base: u8 = 0x80;
    const test_sbdf = Sbdf.from(.from(0), 0, 0, 0);

    const Offset = core.Offset;
    const Sbdf = core.Sbdf;
    const Id = core.capabilities.standard.Id;

    const Routing = Capability.Routing;

    const ControlFields = struct {
        enable: bool = false,
        multiple_msg_capable: u3 = 0,
        multiple_msg_enable: u3 = 0,
        addr64_capable: bool = false,
        pvm_capable: bool = false,
        ext_data_capable: bool = false,
        ext_data_enable: bool = false,
        reserved11: u5 = 0,
    };

    const ExpectedWrite = struct {
        width: u8,
        offset: usize,
        value: u32,
    };

    const MsiConfig = struct {
        sbdf: Sbdf = test_sbdf,
        bytes: [pcie_window_size]u8 = @splat(0),
        read_count: usize = 0,
        write_count: usize = 0,
        writes: [32]ExpectedWrite = undefined,
        write_len: usize = 0,
        mismatch_once: ?Mismatch = null,
        last_write: ?ExpectedWrite = null,
        control_after_read: ?u16 = null,
        fail_control: bool = false,

        const Mismatch = struct {
            width: u8,
            offset: usize,
        };

        fn from() MsiConfig {
            return .{};
        }

        fn config(self: *MsiConfig) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn resetIoCounts(self: *MsiConfig) void {
            self.read_count = 0;
            self.write_count = 0;
            self.write_len = 0;
            self.last_write = null;
        }

        fn recordWrite(self: *MsiConfig, write: ExpectedWrite) void {
            std.debug.assert(self.write_len < self.writes.len);
            self.writes[self.write_len] = write;
            self.write_len += 1;
            self.write_count += 1;
            self.last_write = write;
        }

        fn consumeMismatch(self: *MsiConfig, width: u8, byte_offset: usize) bool {
            const mismatch = self.mismatch_once orelse return false;
            const last = self.last_write orelse return false;

            if (mismatch.width != width or mismatch.offset != byte_offset) {
                return false;
            }

            if (last.width != width or last.offset != byte_offset) {
                return false;
            }

            self.mismatch_once = null;
            return true;
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
            const self: *MsiConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;
            return self.bytes[byte_offset];
        }

        fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *MsiConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;

            const value = load16(&self.bytes, byte_offset);
            if (byte_offset == @as(usize, test_base) + addr32_offsets.control) {
                if (self.fail_control) {
                    return error.OutOfBounds;
                }
                if (self.control_after_read) |next| {
                    store16(&self.bytes, byte_offset, next);
                    self.control_after_read = null;
                }
            }

            if (self.consumeMismatch(2, byte_offset)) {
                return value ^ 0x0001;
            }

            return value;
        }

        fn read32(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u32 {
            const self: *MsiConfig = @ptrCast(@alignCast(context));
            self.read_count += 1;

            const value = load32(&self.bytes, byte_offset);

            if (self.consumeMismatch(4, byte_offset)) {
                return value ^ 0x0000_0001;
            }

            return value;
        }

        fn write8(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u8) ConfigError!void {
            const self: *MsiConfig = @ptrCast(@alignCast(context));
            self.recordWrite(.{ .width = 1, .offset = byte_offset, .value = value });
            self.bytes[byte_offset] = value;
        }

        fn write16(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *MsiConfig = @ptrCast(@alignCast(context));
            self.recordWrite(.{ .width = 2, .offset = byte_offset, .value = value });
            store16(&self.bytes, byte_offset, value);
        }

        fn write32(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u32) ConfigError!void {
            const self: *MsiConfig = @ptrCast(@alignCast(context));
            self.recordWrite(.{ .width = 4, .offset = byte_offset, .value = value });
            store32(&self.bytes, byte_offset, value);
        }
    };

    const offset = struct {
        const status: usize = 0x06;
    };

    const status = struct {
        const cap_list: u16 = 1 << 4;
    };

    test "VectorCount helpers map valid encodings and reject reserved or invalid counts" {
        try expectVectorCount(.one, 1);
        try expectVectorCount(.two, 2);
        try expectVectorCount(.four, 4);
        try expectVectorCount(.eight, 8);
        try expectVectorCount(.sixteen, 16);
        try expectVectorCount(.thirty_two, 32);

        inline for ([_]u3{ 6, 7 }) |raw| {
            const runtime = VectorCount.from(raw);
            try testing.expectEqual(raw, @intFromEnum(runtime));
            try testing.expectError(error.MalformedField, runtime.count());
        }

        try testing.expectError(error.InvalidRouting, VectorCount.fromCount(0));
        try testing.expectError(error.InvalidRouting, VectorCount.fromCount(3));
        try testing.expectError(error.InvalidRouting, VectorCount.fromCount(33));
        try testing.expectError(error.InvalidRouting, VectorCount.fromCount(63));
    }

    test "find returns present MSI capability, null for absence, and errors on malformed traversal" {
        var present = MsiConfig.from();
        seedHead(&present.bytes, 0x40);
        seedCapabilityNode(&present.bytes, 0x40, @intFromEnum(Id.pcie), test_base);
        seedCapabilityNode(&present.bytes, test_base, @intFromEnum(msi.id), 0);
        store16(&present.bytes, @as(usize, test_base) + addr32_offsets.control, controlRaw(.{
            .multiple_msg_capable = @intFromEnum(VectorCount.four),
            .addr64_capable = true,
            .pvm_capable = true,
        }));

        const found = (try Capability.find(function(&present))).?;

        try testing.expectEqual(test_base, found.base);
        const word = try found.control();
        try testing.expect(word.addr64_capable);
        try testing.expect(word.pvm_capable);
        try testing.expectEqual(VectorCount.four, VectorCount.from(word.multiple_msg_capable));

        var no_list = MsiConfig.from();
        try testing.expect((try Capability.find(function(&no_list))) == null);

        var no_msi = MsiConfig.from();
        seedHead(&no_msi.bytes, 0x40);
        seedCapabilityNode(&no_msi.bytes, 0x40, @intFromEnum(Id.pcie), 0);

        try testing.expect((try Capability.find(function(&no_msi))) == null);

        var cycle = MsiConfig.from();
        seedHead(&cycle.bytes, 0x40);
        seedCapabilityNode(&cycle.bytes, 0x40, @intFromEnum(Id.pcie), 0x44);
        seedCapabilityNode(&cycle.bytes, 0x44, @intFromEnum(Id.msix), 0x40);

        try testing.expectError(error.MalformedCapability, Capability.find(function(&cycle)));
    }

    test "tryFrom rejects reserved multiple_msg_capable encodings" {
        for ([_]u3{ 6, 7 }) |reserved| {
            var backend = MsiConfig.from();
            store16(&backend.bytes, @as(usize, test_base) + addr32_offsets.control, controlRaw(.{
                .multiple_msg_capable = reserved,
            }));

            try testing.expectError(error.MalformedField, Capability.tryFrom(function(&backend), capabilityAt(test_base)));
        }
    }

    test "live reads dispatch through 32-bit and 64-bit MSI layouts" {
        var msi32 = MsiConfig.from();
        seedMsiCapability(&msi32, test_base, controlRaw(.{
            .multiple_msg_enable = @intFromEnum(VectorCount.two),
            .pvm_capable = true,
        }));
        store32(&msi32.bytes, @as(usize, test_base) + addr32_offsets.address_lo, 0x89AB_CDEF);
        store16(&msi32.bytes, @as(usize, test_base) + addr32_offsets.data, 0x3456);
        store32(&msi32.bytes, @as(usize, test_base) + addr32_offsets.mask, 0xCAFE_BABE);
        store32(&msi32.bytes, @as(usize, test_base) + addr32_offsets.pending, 0x1234_5678);

        const capability32 = try Capability.tryFrom(function(&msi32), capabilityAt(test_base));

        try testing.expectEqual(@as(u64, 0x89AB_CDEF), try capability32.address());
        try testing.expectEqual(@as(u16, 0x3456), try capability32.data());
        try testing.expectEqual(VectorCount.two, VectorCount.from((try capability32.control()).multiple_msg_enable));
        try testing.expectEqual(@as(u32, 0xCAFE_BABE), try capability32.mask());
        try testing.expectEqual(@as(u32, 0x1234_5678), try capability32.pending());

        var msi64 = MsiConfig.from();
        seedMsiCapability(&msi64, test_base, controlRaw(.{
            .multiple_msg_enable = @intFromEnum(VectorCount.four),
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .ext_data_enable = true,
        }));
        store32(&msi64.bytes, @as(usize, test_base) + addr32_offsets.address_lo, 0x5566_7788);
        store32(&msi64.bytes, @as(usize, test_base) + addr64_offsets.address_hi, 0x1122_3344);
        store16(&msi64.bytes, @as(usize, test_base) + addr64_offsets.data, 0x7788);
        store16(&msi64.bytes, @as(usize, test_base) + addr64_offsets.ext_data, 0x99AA);
        store32(&msi64.bytes, @as(usize, test_base) + addr64_offsets.mask, 0x0F0F_F0F0);
        store32(&msi64.bytes, @as(usize, test_base) + addr64_offsets.pending, 0xA5A5_5A5A);

        const capability64 = try Capability.tryFrom(function(&msi64), capabilityAt(test_base));

        try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), try capability64.address());
        try testing.expectEqual(@as(u16, 0x7788), try capability64.data());
        const word64 = try capability64.control();
        try testing.expectEqual(VectorCount.four, VectorCount.from(word64.multiple_msg_enable));
        try testing.expect(word64.ext_data_enable);
        try testing.expectEqual(@as(u16, 0x99AA), try capability64.extData());
        try testing.expectEqual(@as(u32, 0x0F0F_F0F0), try capability64.mask());
        try testing.expectEqual(@as(u32, 0xA5A5_5A5A), try capability64.pending());
    }

    test "live vector encodings fail before payload reads or writes" {
        var backend = MsiConfig.from();
        seedMsiCapability(&backend, test_base, controlRaw(.{ .pvm_capable = true }));
        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        for ([_]u3{ 6, 7 }) |reserved| {
            store16(&backend.bytes, @as(usize, test_base) + addr32_offsets.control, controlRaw(.{
                .multiple_msg_capable = reserved,
                .multiple_msg_enable = reserved,
                .pvm_capable = true,
            }));
            backend.resetIoCounts();

            try testing.expectError(error.MalformedField, capability.readRouting());
            try testing.expectError(error.MalformedField, capability.program(.{
                .address = 0xFEE0_0000,
                .data = 0x40,
                .num_vectors = .one,
            }));
            try testing.expectError(error.MalformedField, capability.setVectorMasked(0, true));
            try testing.expectEqual(@as(usize, 3), backend.read_count);
            try testing.expectEqual(@as(usize, 0), backend.write_count);
        }
    }

    test "routing uses live layout and one control snapshot" {
        var backend = MsiConfig.from();
        seedMsiCapability(&backend, test_base, controlRaw(.{}));
        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        store16(&backend.bytes, @as(usize, test_base) + addr32_offsets.control, controlRaw(.{
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .multiple_msg_enable = @intFromEnum(VectorCount.two),
        }));
        store32(&backend.bytes, @as(usize, test_base) + addr32_offsets.address_lo, 0x5566_7788);
        store32(&backend.bytes, @as(usize, test_base) + addr64_offsets.address_hi, 0x1122_3344);
        store16(&backend.bytes, @as(usize, test_base) + addr64_offsets.data, 0x40);
        store32(&backend.bytes, @as(usize, test_base) + addr64_offsets.mask, 0x1234);
        store16(&backend.bytes, @as(usize, test_base) + addr64_offsets.ext_data, 0x5678);
        backend.resetIoCounts();
        backend.control_after_read = 0;

        const routing = try capability.readRouting();

        try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), routing.address);
        try testing.expectEqual(@as(u16, 0x40), routing.data);
        try testing.expectEqual(VectorCount.two, routing.num_vectors);
        try testing.expectEqual(@as(?u32, 0x1234), routing.initial_mask);
        try testing.expectEqual(@as(?u16, 0x5678), routing.ext_data);
        try testing.expectEqual(@as(usize, 6), backend.read_count);
        try testing.expectEqual(@as(u16, 0x3344), try capability.data());
    }

    test "control read failures stop programming before writes" {
        var backend = MsiConfig.from();
        seedMsiCapability(&backend, test_base, controlRaw(.{ .pvm_capable = true }));
        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();
        backend.fail_control = true;

        try testing.expectError(error.OutOfBounds, capability.control());
        try testing.expectError(error.OutOfBounds, capability.readRouting());
        try testing.expectError(error.ProgrammingWriteFailed, capability.program(.{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .one,
        }));
        try testing.expectError(error.ProgrammingWriteFailed, capability.disable());
        try testing.expectError(error.ProgrammingWriteFailed, capability.setMask(0));
        try testing.expectError(error.ProgrammingWriteFailed, capability.setVectorMasked(0, true));
        try testing.expectEqual(@as(usize, 6), backend.read_count);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    test "setVectorMasked uses one saved mask for update and rollback" {
        var backend = MsiConfig.from();
        seedMsiCapability(&backend, test_base, controlRaw(.{ .pvm_capable = true }));
        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        store32(&backend.bytes, @as(usize, test_base) + addr32_offsets.mask, 0xAAAA_0000);
        backend.resetIoCounts();
        backend.mismatch_once = .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask };

        try testing.expectError(error.ProgrammingReadbackMismatch, capability.setVectorMasked(0, true));

        try testing.expectEqual(@as(usize, 4), backend.read_count);
        try expectWrites(&backend, &.{
            .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask, .value = 0xAAAA_0001 },
            .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask, .value = 0xAAAA_0000 },
        });
    }

    test "invalid routing is rejected after control read and before writes" {
        try expectInvalidRoutingNoWrites(controlRaw(.{}), .{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .two,
        });
        try expectInvalidRoutingNoWrites(controlRaw(.{ .multiple_msg_capable = @intFromEnum(VectorCount.two) }), .{
            .address = 0xFEE0_0000,
            .data = 0x41,
            .num_vectors = .two,
        });
        try expectInvalidRoutingNoWrites(controlRaw(.{}), .{
            .address = 0x1_0000_0000,
            .data = 0x40,
            .num_vectors = .one,
        });
        try expectInvalidRoutingNoWrites(controlRaw(.{}), .{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .one,
            .initial_mask = 0xFFFF_FFFF,
        });
        try expectInvalidRoutingNoWrites(controlRaw(.{}), .{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .one,
            .ext_data = 0x1234,
        });
    }

    test "disable clears enable while preserving reserved and writable Control bits" {
        var backend = MsiConfig.from();
        seedMsiCapability(&backend, test_base, controlRaw(.{
            .enable = true,
            .multiple_msg_capable = @intFromEnum(VectorCount.four),
            .multiple_msg_enable = @intFromEnum(VectorCount.four),
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .ext_data_enable = true,
            .reserved11 = 0b10101,
        }));
        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();

        try capability.disable();

        const raw = load16(&backend.bytes, @as(usize, test_base) + addr32_offsets.control);
        const control = Control.from(raw);
        try testing.expect(!control.enable);
        try testing.expectEqual(@as(u3, @intFromEnum(VectorCount.four)), control.multiple_msg_capable);
        try testing.expectEqual(@as(u3, @intFromEnum(VectorCount.four)), control.multiple_msg_enable);
        try testing.expect(control.addr64_capable);
        try testing.expect(control.pvm_capable);
        try testing.expect(control.ext_data_capable);
        try testing.expect(control.ext_data_enable);
        try testing.expectEqual(@as(u5, 0b10101), control._rsvd_11);
        try expectWrites(&backend, &.{.{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.control, .value = raw }});
    }

    test "setMask writes with readback and restores saved mask on mismatch" {
        var success = MsiConfig.from();
        seedMsiCapability(&success, test_base, controlRaw(.{ .pvm_capable = true }));
        store32(&success.bytes, @as(usize, test_base) + addr32_offsets.mask, 0xAAAA_0000);
        const success_capability = try Capability.tryFrom(function(&success), capabilityAt(test_base));
        success.resetIoCounts();

        try success_capability.setMask(0x5555_F0F0);

        try testing.expectEqual(@as(u32, 0x5555_F0F0), load32(&success.bytes, @as(usize, test_base) + addr32_offsets.mask));
        try expectWrites(&success, &.{.{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask, .value = 0x5555_F0F0 }});

        var rollback = MsiConfig.from();
        seedMsiCapability(&rollback, test_base, controlRaw(.{
            .addr64_capable = true,
            .pvm_capable = true,
        }));
        store32(&rollback.bytes, @as(usize, test_base) + addr64_offsets.mask, 0x1357_9BDF);
        const rollback_capability = try Capability.tryFrom(function(&rollback), capabilityAt(test_base));
        rollback.resetIoCounts();
        rollback.mismatch_once = .{ .width = 4, .offset = @as(usize, test_base) + addr64_offsets.mask };

        try testing.expectError(error.ProgrammingReadbackMismatch, rollback_capability.setMask(0x2468_ACE0));

        try testing.expectEqual(@as(u32, 0x1357_9BDF), load32(&rollback.bytes, @as(usize, test_base) + addr64_offsets.mask));
        try expectWrites(&rollback, &.{
            .{ .width = 4, .offset = @as(usize, test_base) + addr64_offsets.mask, .value = 0x2468_ACE0 },
            .{ .width = 4, .offset = @as(usize, test_base) + addr64_offsets.mask, .value = 0x1357_9BDF },
        });
    }

    test "program commits full routing and preserves reserved control bits" {
        var backend = MsiConfig.from();
        seedMsiCapability(&backend, test_base, controlRaw(.{
            .enable = true,
            .multiple_msg_capable = @intFromEnum(VectorCount.four),
            .multiple_msg_enable = @intFromEnum(VectorCount.two),
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .reserved11 = 0b10010,
        }));
        store32(&backend.bytes, @as(usize, test_base) + addr32_offsets.address_lo, 0x1111_2222);
        store32(&backend.bytes, @as(usize, test_base) + addr64_offsets.address_hi, 0x3333_4444);
        store16(&backend.bytes, @as(usize, test_base) + addr64_offsets.data, 0x0050);
        store16(&backend.bytes, @as(usize, test_base) + addr64_offsets.ext_data, 0x6666);
        store32(&backend.bytes, @as(usize, test_base) + addr64_offsets.mask, 0x7777_8888);
        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();
        backend.control_after_read = 0;

        try capability.program(.{
            .address = 0x1234_5678_9ABC_DEF0,
            .data = 0x0040,
            .num_vectors = .four,
            .initial_mask = 0xFFFF_0000,
            .ext_data = 0xABCD,
        });
        try testing.expectEqual(@as(usize, 13), backend.read_count);

        const disabled = controlRaw(.{
            .multiple_msg_capable = @intFromEnum(VectorCount.four),
            .multiple_msg_enable = @intFromEnum(VectorCount.two),
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .reserved11 = 0b10010,
        });
        const enabled = controlRaw(.{
            .enable = true,
            .multiple_msg_capable = @intFromEnum(VectorCount.four),
            .multiple_msg_enable = @intFromEnum(VectorCount.four),
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .ext_data_enable = true,
            .reserved11 = 0b10010,
        });

        try testing.expectEqual(@as(u32, 0x9ABC_DEF0), load32(&backend.bytes, @as(usize, test_base) + addr32_offsets.address_lo));
        try testing.expectEqual(@as(u32, 0x1234_5678), load32(&backend.bytes, @as(usize, test_base) + addr64_offsets.address_hi));
        try testing.expectEqual(@as(u16, 0x0040), load16(&backend.bytes, @as(usize, test_base) + addr64_offsets.data));
        try testing.expectEqual(@as(u16, 0xABCD), load16(&backend.bytes, @as(usize, test_base) + addr64_offsets.ext_data));
        try testing.expectEqual(@as(u32, 0xFFFF_0000), load32(&backend.bytes, @as(usize, test_base) + addr64_offsets.mask));
        try testing.expectEqual(enabled, load16(&backend.bytes, @as(usize, test_base) + addr32_offsets.control));
        try expectWrites(&backend, &.{
            .{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.control, .value = disabled },
            .{ .width = 4, .offset = @as(usize, test_base) + addr64_offsets.mask, .value = 0xFFFF_0000 },
            .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.address_lo, .value = 0x9ABC_DEF0 },
            .{ .width = 4, .offset = @as(usize, test_base) + addr64_offsets.address_hi, .value = 0x1234_5678 },
            .{ .width = 2, .offset = @as(usize, test_base) + addr64_offsets.data, .value = 0x0040 },
            .{ .width = 2, .offset = @as(usize, test_base) + addr64_offsets.ext_data, .value = 0xABCD },
            .{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.control, .value = enabled },
        });
    }

    test "program rolls back prior writes after a representative data readback failure" {
        var backend = MsiConfig.from();
        seedMsiCapability(&backend, test_base, controlRaw(.{
            .enable = true,
            .multiple_msg_capable = @intFromEnum(VectorCount.two),
            .multiple_msg_enable = @intFromEnum(VectorCount.two),
            .pvm_capable = true,
            .reserved11 = 0b01101,
        }));
        store32(&backend.bytes, @as(usize, test_base) + addr32_offsets.address_lo, 0xAAAA_BBBB);
        store16(&backend.bytes, @as(usize, test_base) + addr32_offsets.data, 0x0060);
        store32(&backend.bytes, @as(usize, test_base) + addr32_offsets.mask, 0x0000_FFFF);
        const before = backend.bytes;
        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();
        backend.mismatch_once = .{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.data };

        try testing.expectError(error.ProgrammingReadbackMismatch, capability.program(.{
            .address = 0xFEE0_0000,
            .data = 0x0040,
            .num_vectors = .two,
            .initial_mask = 0xFFFF_FFFF,
        }));

        try testing.expectEqualSlices(u8, &before, &backend.bytes);
        try expectWrites(&backend, &.{
            .{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.control, .value = controlRaw(.{
                .multiple_msg_capable = @intFromEnum(VectorCount.two),
                .multiple_msg_enable = @intFromEnum(VectorCount.two),
                .pvm_capable = true,
                .reserved11 = 0b01101,
            }) },
            .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask, .value = 0xFFFF_FFFF },
            .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.address_lo, .value = 0xFEE0_0000 },
            .{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.data, .value = 0x0040 },
            .{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.data, .value = 0x0060 },
            .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.address_lo, .value = 0xAAAA_BBBB },
            .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask, .value = 0x0000_FFFF },
            .{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.control, .value = controlRaw(.{
                .enable = true,
                .multiple_msg_capable = @intFromEnum(VectorCount.two),
                .multiple_msg_enable = @intFromEnum(VectorCount.two),
                .pvm_capable = true,
                .reserved11 = 0b01101,
            }) },
        });
    }

    test "MSI rejects truncated shapes before payload access or programming" {
        const shapes = [_]struct { control: ControlFields, length: u16 }{
            .{ .control = .{}, .length = 10 },
            .{ .control = .{ .addr64_capable = true }, .length = 14 },
            .{ .control = .{ .ext_data_capable = true }, .length = 12 },
            .{ .control = .{ .addr64_capable = true, .ext_data_capable = true }, .length = 16 },
            .{ .control = .{ .pvm_capable = true }, .length = 20 },
            .{ .control = .{ .addr64_capable = true, .pvm_capable = true }, .length = 24 },
        };

        for (shapes) |shape| {
            var backend = MsiConfig.from();
            const base: u8 = @intCast((0x100 - shape.length) & ~@as(u16, 3));
            seedMsiCapability(&backend, base, controlRaw(shape.control));
            store32(&backend.bytes, @as(usize, base) + 4, 0xFEE0_1000);
            const valid = try Capability.tryFrom(function(&backend), capabilityAt(base));

            try testing.expectEqual(@as(u64, 0xFEE0_1000), try valid.address());

            const invalid_base = base + 4;
            seedMsiCapability(&backend, invalid_base, controlRaw(shape.control));
            try testing.expectError(error.MalformedCapability, Capability.tryFrom(function(&backend), capabilityAt(invalid_base)));

            var invalid = valid;
            invalid.base = invalid_base;
            backend.resetIoCounts();
            if (shape.control.pvm_capable) {
                try testing.expectError(error.MalformedCapability, invalid.pending());
            } else if (shape.control.ext_data_capable) {
                try testing.expectError(error.MalformedCapability, invalid.extData());
            } else {
                try testing.expectError(error.MalformedCapability, invalid.data());
            }

            const before = backend.bytes;

            try testing.expectError(error.ProgrammingWriteFailed, invalid.disable());
            try testing.expectError(error.ProgrammingWriteFailed, invalid.program(.{
                .address = 0xFEE0_1000,
                .data = 0x40,
                .num_vectors = .one,
                .initial_mask = if (shape.control.pvm_capable) 0 else null,
                .ext_data = if (shape.control.ext_data_capable) 0 else null,
            }));
            try testing.expectEqual(@as(usize, 3), backend.read_count);
            try testing.expectEqual(@as(usize, 0), backend.write_count);
            try testing.expectEqualSlices(u8, &before, &backend.bytes);
        }

        var backend = MsiConfig.from();
        seedMsiCapability(&backend, 0xFC, 0);
        store32(&backend.bytes, 0x100, 0xDEAD_BEEF);

        try testing.expectError(error.MalformedCapability, Capability.tryFrom(function(&backend), capabilityAt(0xFC)));

        const invalid: Capability = .{ .function = function(&backend), .base = 0xFC };
        backend.resetIoCounts();

        try testing.expectError(error.MalformedCapability, invalid.address());
        try testing.expectEqual(@as(usize, 1), backend.read_count);
    }

    fn controlRaw(fields: ControlFields) u16 {
        return Control.raw(.{
            .enable = fields.enable,
            .multiple_msg_capable = fields.multiple_msg_capable,
            .multiple_msg_enable = fields.multiple_msg_enable,
            .addr64_capable = fields.addr64_capable,
            .pvm_capable = fields.pvm_capable,
            .ext_data_capable = fields.ext_data_capable,
            .ext_data_enable = fields.ext_data_enable,
            ._rsvd_11 = fields.reserved11,
        });
    }

    fn expectVectorCount(comptime count: VectorCount, expected: u6) !void {
        const raw = @intFromEnum(count);
        try testing.expectEqual(expected, try VectorCount.from(raw).count());
        try testing.expectEqual(count, try VectorCount.fromCount(expected));
    }

    fn expectInvalidRoutingNoWrites(control: u16, routing: Routing) !void {
        var backend = MsiConfig.from();
        seedMsiCapability(&backend, test_base, control);
        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();

        try testing.expectError(error.InvalidRouting, capability.program(routing));
        try testing.expectEqual(@as(usize, 1), backend.read_count);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    fn expectWrites(backend: *const MsiConfig, expected: []const ExpectedWrite) !void {
        try testing.expectEqual(expected.len, backend.write_len);
        for (expected, 0..) |write, index| {
            try testing.expectEqual(write.width, backend.writes[index].width);
            try testing.expectEqual(write.offset, backend.writes[index].offset);
            try testing.expectEqual(write.value, backend.writes[index].value);
        }
    }

    fn function(backend: *MsiConfig) Function {
        return Function.from(backend.config(), backend.sbdf);
    }

    fn capabilityAt(base: u8) Entry {
        return .{ .id = msi.id, .offset = base };
    }

    fn seedMsiCapability(backend: *MsiConfig, base: u8, control: u16) void {
        seedHead(&backend.bytes, base);
        seedCapabilityNode(&backend.bytes, base, @intFromEnum(msi.id), 0);
        store16(&backend.bytes, @as(usize, base) + addr32_offsets.control, control);
    }

    fn seedHead(bytes: *[pcie_window_size]u8, head: u8) void {
        store16(bytes, offset.status, status.cap_list);
        bytes[core.header.type0.offsets.cap_ptr] = head;
    }

    fn seedCapabilityNode(bytes: *[pcie_window_size]u8, base: u8, id: u8, next: u8) void {
        bytes[base] = id;
        bytes[@as(usize, base) + 1] = next;
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
        const low = @as(u32, load16(bytes, byte_offset));
        const high = @as(u32, load16(bytes, byte_offset + 2)) << 16;
        return high | low;
    }

    fn store32(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u32) void {
        store16(bytes, byte_offset, @truncate(value));
        store16(bytes, byte_offset + 2, @truncate(value >> 16));
    }
};
