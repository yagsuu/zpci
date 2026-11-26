const std = @import("std");

const config = @import("config");
const core = @import("core");

const standard = @import("standard.zig");

const msi = core.capabilities.msi;

const Rel16 = core.RelativeOffset(u16);
const Rel32 = core.RelativeOffset(u32);

const Function = config.Function;
const Entry = standard.Entry;
const Registers = standard.Registers;

const Control = msi.Control.Word;
const ControlArgs = msi.Control.AssignArgs;
const VectorCount = msi.VectorCount;

pub const Error = standard.Error || error{MalformedField};
pub const ProgramError = Error || error{ InvalidRouting, InvalidState };

pub const Capability = struct {
    registers: Registers,

    pub const Routing = struct {
        address: u64,
        data: u16,
        num_vectors: VectorCount,
        mask: ?u32 = null,
        ext_data: ?u16 = null,
    };

    pub fn tryFrom(function: Function, entry: Entry) Error!Capability {
        std.debug.assert(entry.id == msi.id);

        const registers = try Registers.tryFrom(function, entry.offset);
        const observed = msi.Control.from(try registers.read(offsets.control));

        try Layout.from(observed).validateExtent(registers);

        return .{ .registers = registers };
    }

    pub fn find(function: Function) Error!?Capability {
        const entry = try standard.find(function, msi.id) orelse return null;
        return try tryFrom(function, entry);
    }

    pub fn control(self: Capability) Error!Control {
        return msi.Control.from(try self.registers.read(offsets.control));
    }

    pub fn updateControl(self: Capability, args: ControlArgs) Error!void {
        const observed = try self.control();
        const updated = msi.Control.replace(observed, args);

        try self.registers.write(offsets.control, msi.Control.raw(updated));
    }

    pub fn address(self: Capability) Error!u64 {
        const observed = try self.control();
        return readAddress(self.registers, observed);
    }

    pub fn data(self: Capability) Error!u16 {
        const observed = try self.control();
        const offset = if (observed.addr64_capable) offsets.addr64.data else offsets.addr32.data;

        return self.registers.read(offset);
    }

    pub fn extData(self: Capability) Error!u16 {
        const observed = try self.control();
        std.debug.assert(observed.ext_data_capable);

        const offset = if (observed.addr64_capable) offsets.addr64.ext_data else offsets.addr32.ext_data;
        return self.registers.read(offset);
    }

    pub fn mask(self: Capability) Error!u32 {
        const observed = try self.control();
        std.debug.assert(observed.pvm_capable);

        const offset = if (observed.addr64_capable) offsets.addr64.mask else offsets.addr32.mask;
        return self.registers.read(offset);
    }

    pub fn pending(self: Capability) Error!u32 {
        const observed = try self.control();
        std.debug.assert(observed.pvm_capable);

        const offset = if (observed.addr64_capable) offsets.addr64.pending else offsets.addr32.pending;
        return self.registers.read(offset);
    }

    pub fn routing(self: Capability) Error!Routing {
        const observed = try self.control();
        const num_vectors = observed.multi_msg_enable;
        _ = try num_vectors.count();

        const registers = self.registers;
        const layout = Layout.from(observed);
        const address_value = try readAddress(registers, observed);
        const data_value = try registers.read(layout.data);

        const mask_value = if (layout.mask) |offset| try registers.read(offset) else null;
        const ext_data = if (layout.ext_data) |offset| try registers.read(offset) else null;

        return .{
            .address = address_value,
            .data = data_value,
            .num_vectors = num_vectors,
            .mask = mask_value,
            .ext_data = ext_data,
        };
    }

    pub fn setMasked(self: Capability, index: u5, masked: bool) Error!void {
        const observed = try self.control();
        std.debug.assert(observed.pvm_capable);

        const num_vectors = try observed.multi_msg_capable.count();
        std.debug.assert(index < num_vectors);

        const offset = if (observed.addr64_capable) offsets.addr64.mask else offsets.addr32.mask;
        const mask_value = try self.registers.read(offset);
        const bit = @as(u32, 1) << index;
        const updated = if (masked) mask_value | bit else mask_value & ~bit;

        try self.registers.write(offset, updated);
    }

    pub fn setMask(self: Capability, value: u32) Error!void {
        const observed = try self.control();
        std.debug.assert(observed.pvm_capable);

        const offset = if (observed.addr64_capable) offsets.addr64.mask else offsets.addr32.mask;
        try self.registers.write(offset, value);
    }

    pub fn program(self: Capability, args: Routing) ProgramError!void {
        const observed = try self.control();
        const registers = self.registers;
        const layout = Layout.from(observed);

        try validateRouting(observed, args);
        try layout.validateExtent(registers);

        if (observed.enable) {
            return error.InvalidState;
        }

        if (args.mask) |value| {
            try registers.write(layout.mask.?, value);
        }

        try registers.write(offsets.address_lo, @truncate(args.address));

        if (layout.address_hi) |offset| {
            try registers.write(offset, @truncate(args.address >> 32));
        }

        try registers.write(layout.data, args.data);

        if (args.ext_data) |value| {
            try registers.write(layout.ext_data.?, value);
        }

        const updated = msi.Control.replace(observed, .{
            .multi_msg_enable = args.num_vectors,
            .ext_data_enable = args.ext_data != null,
        });

        try registers.write(offsets.control, msi.Control.raw(updated));
    }

    fn readAddress(registers: Registers, observed: Control) Error!u64 {
        const lo = try registers.read(offsets.address_lo);
        if (!observed.addr64_capable) {
            return lo;
        }

        const hi = try registers.read(offsets.addr64.address_hi);

        return (@as(u64, hi) << 32) | @as(u64, lo);
    }

    fn validateRouting(observed: Control, args: Routing) ProgramError!void {
        const requested = try args.num_vectors.count();
        const capable = try observed.multi_msg_capable.count();

        if (requested > capable) {
            return error.InvalidRouting;
        }

        if (!observed.addr64_capable and args.address > std.math.maxInt(u32)) {
            return error.InvalidRouting;
        }

        const data_mask = @as(u16, @intCast(requested - 1));
        if (args.data & data_mask != 0) {
            return error.InvalidRouting;
        }

        if (args.mask != null and !observed.pvm_capable) {
            return error.InvalidRouting;
        }

        if (args.ext_data != null and !observed.ext_data_capable) {
            return error.InvalidRouting;
        }
    }
};

pub const offsets = struct {
    pub const control = Rel16.from(msi.offsets.control);
    pub const address_lo = Rel32.from(msi.offsets.address_lo);

    pub const addr32 = struct {
        pub const data = Rel16.from(msi.addr32.offsets.data);
        pub const ext_data = Rel16.from(msi.addr32.offsets.ext_data);
        pub const mask = Rel32.from(msi.addr32.offsets.mask);
        pub const pending = Rel32.from(msi.addr32.offsets.pending);
    };

    pub const addr64 = struct {
        pub const address_hi = Rel32.from(msi.addr64.offsets.address_hi);
        pub const data = Rel16.from(msi.addr64.offsets.data);
        pub const ext_data = Rel16.from(msi.addr64.offsets.ext_data);
        pub const mask = Rel32.from(msi.addr64.offsets.mask);
        pub const pending = Rel32.from(msi.addr64.offsets.pending);
    };
};

const Layout = struct {
    address_hi: ?Rel32,
    data: Rel16,
    ext_data: ?Rel16,
    mask: ?Rel32,
    pending: ?Rel32,

    fn from(control: Control) Layout {
        var layout: Layout = if (control.addr64_capable) .{
            .address_hi = offsets.addr64.address_hi,
            .data = offsets.addr64.data,
            .ext_data = offsets.addr64.ext_data,
            .mask = offsets.addr64.mask,
            .pending = offsets.addr64.pending,
        } else .{
            .address_hi = null,
            .data = offsets.addr32.data,
            .ext_data = offsets.addr32.ext_data,
            .mask = offsets.addr32.mask,
            .pending = offsets.addr32.pending,
        };

        if (!control.ext_data_capable) {
            layout.ext_data = null;
        }

        if (!control.pvm_capable) {
            layout.mask = null;
            layout.pending = null;
        }

        return layout;
    }

    fn validateExtent(self: Layout, registers: Registers) error{MalformedCapability}!void {
        const contained = if (self.pending) |offset|
            registers.contains(offset)
        else if (self.ext_data) |offset|
            registers.contains(offset)
        else
            registers.contains(self.data);

        if (!contained) {
            return error.MalformedCapability;
        }
    }
};

pub const unit = struct {
    const testing = std.testing;

    const addr32_offsets = msi.addr32.offsets;
    const addr64_offsets = msi.addr64.offsets;

    const pcie_window_size = core.config.extended_size;
    const test_base: u8 = 0x80;
    const test_sbdf = Sbdf.from(.from(0), 0, 0, 0);

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Sbdf = core.Sbdf;
    const Id = core.capabilities.standard.Id;
    const Routing = Capability.Routing;

    const ExpectedWrite = struct {
        width: u8,
        offset: usize,
        value: u32,
    };

    const ConfigBackend = struct {
        sbdf: Sbdf = test_sbdf,
        bytes: [pcie_window_size]u8 = @splat(0),
        read_count: usize = 0,
        reads: [64]usize = undefined,
        write_count: usize = 0,
        writes: [32]ExpectedWrite = undefined,
        fail_write: ?usize = null,
        mutate_before_failure: bool = false,
        fail_control: bool = false,

        fn from() ConfigBackend {
            return .{};
        }

        fn config(self: *ConfigBackend) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        fn resetIoCounts(self: *ConfigBackend) void {
            self.read_count = 0;
            self.write_count = 0;
        }

        fn recordWrite(self: *ConfigBackend, write: ExpectedWrite) void {
            std.debug.assert(self.write_count < self.writes.len);
            self.writes[self.write_count] = write;
            self.write_count += 1;
        }

        fn recordRead(self: *ConfigBackend, byte_offset: usize) void {
            std.debug.assert(self.read_count < self.reads.len);
            self.reads[self.read_count] = byte_offset;
            self.read_count += 1;
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

            self.recordRead(byte_offset);

            return self.bytes[byte_offset];
        }

        fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.recordRead(byte_offset);

            const value = load16(&self.bytes, byte_offset);

            if (byte_offset == @as(usize, test_base) + msi.offsets.control) {
                if (self.fail_control) {
                    return error.OutOfBounds;
                }
            }

            return value;
        }

        fn read32(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u32 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.recordRead(byte_offset);

            return load32(&self.bytes, byte_offset);
        }

        fn write8(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u8) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.recordWrite(.{ .width = 1, .offset = byte_offset, .value = value });
            self.bytes[byte_offset] = value;
        }

        fn write16(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.recordWrite(.{ .width = 2, .offset = byte_offset, .value = value });

            if (self.fail_write == byte_offset and !self.mutate_before_failure) {
                return error.OutOfBounds;
            }

            store16(&self.bytes, byte_offset, value);

            if (self.fail_write == byte_offset) {
                return error.OutOfBounds;
            }
        }

        fn write32(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u32) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));

            self.recordWrite(.{ .width = 4, .offset = byte_offset, .value = value });

            if (self.fail_write == byte_offset and !self.mutate_before_failure) {
                return error.OutOfBounds;
            }

            store32(&self.bytes, byte_offset, value);

            if (self.fail_write == byte_offset) {
                return error.OutOfBounds;
            }
        }
    };

    test "find returns the MSI capability" {
        var present = ConfigBackend.from();
        seedHead(&present.bytes, 0x40);
        seedCapabilityNode(&present.bytes, 0x40, @backingInt(Id.pcie), test_base);
        seedCapabilityNode(&present.bytes, test_base, @backingInt(msi.id), 0);
        store16(&present.bytes, @as(usize, test_base) + msi.offsets.control, msi.Control.raw(.{
            .multi_msg_capable = .four,
            .addr64_capable = true,
            .pvm_capable = true,
        }));

        const found = (try Capability.find(function(&present))).?;

        try testing.expectEqual(test_base, found.registers.base);

        const control = try found.control();
        try testing.expect(control.addr64_capable);
        try testing.expect(control.pvm_capable);
        try testing.expectEqual(VectorCount.four, control.multi_msg_capable);
    }

    test "find returns null when MSI is absent" {
        var no_list = ConfigBackend.from();

        try testing.expect((try Capability.find(function(&no_list))) == null);

        var no_msi = ConfigBackend.from();
        seedHead(&no_msi.bytes, 0x40);
        seedCapabilityNode(&no_msi.bytes, 0x40, @backingInt(Id.pcie), 0);

        try testing.expect((try Capability.find(function(&no_msi))) == null);
    }

    test "find propagates malformed traversal errors" {
        var cycle = ConfigBackend.from();
        seedHead(&cycle.bytes, 0x40);
        seedCapabilityNode(&cycle.bytes, 0x40, @backingInt(Id.pcie), 0x44);
        seedCapabilityNode(&cycle.bytes, 0x44, @backingInt(Id.msix), 0x40);

        try testing.expectError(error.MalformedCapability, Capability.find(function(&cycle)));
    }

    test "reserved advertised counts do not block unrelated register access" {
        for ([_]u3{ 6, 7 }) |reserved| {
            var backend = ConfigBackend.from();
            store16(&backend.bytes, @as(usize, test_base) + msi.offsets.control, msi.Control.raw(.{
                .multi_msg_capable = .from(reserved),
                .pvm_capable = true,
            }));
            store32(&backend.bytes, @as(usize, test_base) + msi.offsets.address_lo, 0xFEE0_1000);
            store16(&backend.bytes, @as(usize, test_base) + addr32_offsets.data, 0x40);

            const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));

            try testing.expectEqual(reserved, @backingInt((try capability.control()).multi_msg_capable));
            try testing.expectEqual(@as(u64, 0xFEE0_1000), try capability.address());
            try testing.expectEqual(@as(u16, 0x40), try capability.data());

            try capability.updateControl(.{ .enable = false });
            try capability.setMask(3);
            try testing.expectEqual(@as(u32, 3), try capability.mask());

            backend.resetIoCounts();

            try testing.expectError(error.MalformedField, capability.setMasked(0, false));
            try testing.expectError(error.MalformedField, capability.program(.{
                .address = 0xFEE0_1000,
                .data = 0x40,
                .num_vectors = .one,
            }));
            try testing.expectEqual(@as(usize, 0), backend.write_count);
        }
    }

    test "live reads use the 32-bit MSI layout" {
        var msi32 = ConfigBackend.from();
        seedMsiCapability(&msi32, test_base, msi.Control.raw(.{
            .multi_msg_enable = .two,
            .pvm_capable = true,
        }));
        store32(&msi32.bytes, @as(usize, test_base) + msi.offsets.address_lo, 0x89AB_CDEF);
        store16(&msi32.bytes, @as(usize, test_base) + addr32_offsets.data, 0x3456);
        store32(&msi32.bytes, @as(usize, test_base) + addr32_offsets.mask, 0xCAFE_BABE);
        store32(&msi32.bytes, @as(usize, test_base) + addr32_offsets.pending, 0x1234_5678);

        const capability32 = try Capability.tryFrom(function(&msi32), capabilityAt(test_base));

        try testing.expectEqual(@as(u64, 0x89AB_CDEF), try capability32.address());
        try testing.expectEqual(@as(u16, 0x3456), try capability32.data());
        try testing.expectEqual(VectorCount.two, (try capability32.control()).multi_msg_enable);
        try testing.expectEqual(@as(u32, 0xCAFE_BABE), try capability32.mask());
        try testing.expectEqual(@as(u32, 0x1234_5678), try capability32.pending());
    }

    test "live reads use the 64-bit MSI layout" {
        var msi64 = ConfigBackend.from();
        seedMsiCapability(&msi64, test_base, msi.Control.raw(.{
            .multi_msg_enable = .four,
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .ext_data_enable = true,
        }));
        store32(&msi64.bytes, @as(usize, test_base) + msi.offsets.address_lo, 0x5566_7788);
        store32(&msi64.bytes, @as(usize, test_base) + addr64_offsets.address_hi, 0x1122_3344);
        store16(&msi64.bytes, @as(usize, test_base) + addr64_offsets.data, 0x7788);
        store16(&msi64.bytes, @as(usize, test_base) + addr64_offsets.ext_data, 0x99AA);
        store32(&msi64.bytes, @as(usize, test_base) + addr64_offsets.mask, 0x0F0F_F0F0);
        store32(&msi64.bytes, @as(usize, test_base) + addr64_offsets.pending, 0xA5A5_5A5A);

        const capability64 = try Capability.tryFrom(function(&msi64), capabilityAt(test_base));

        try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), try capability64.address());
        try testing.expectEqual(@as(u16, 0x7788), try capability64.data());

        const word64 = try capability64.control();
        try testing.expectEqual(VectorCount.four, word64.multi_msg_enable);
        try testing.expect(word64.ext_data_enable);
        try testing.expectEqual(@as(u16, 0x99AA), try capability64.extData());
        try testing.expectEqual(@as(u32, 0x0F0F_F0F0), try capability64.mask());
        try testing.expectEqual(@as(u32, 0xA5A5_5A5A), try capability64.pending());
    }

    test "live vector encodings fail before payload reads or writes" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{ .pvm_capable = true }));

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));

        for ([_]u3{ 6, 7 }) |reserved| {
            store16(&backend.bytes, @as(usize, test_base) + msi.offsets.control, msi.Control.raw(.{
                .multi_msg_capable = .from(reserved),
                .multi_msg_enable = .from(reserved),
                .pvm_capable = true,
            }));
            backend.resetIoCounts();

            try testing.expectError(error.MalformedField, capability.routing());
            try testing.expectError(error.MalformedField, capability.program(.{
                .address = 0xFEE0_0000,
                .data = 0x40,
                .num_vectors = .one,
            }));
            try testing.expectError(error.MalformedField, capability.setMasked(0, true));
            try testing.expectEqualSlices(usize, &.{ 0x82, 0x82, 0x82 }, backend.reads[0..backend.read_count]);
            try testing.expectEqual(@as(usize, 0), backend.write_count);
        }
    }

    test "routing uses live layout" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{}));

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));

        store16(&backend.bytes, @as(usize, test_base) + msi.offsets.control, msi.Control.raw(.{
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .multi_msg_enable = .two,
        }));
        store32(&backend.bytes, @as(usize, test_base) + msi.offsets.address_lo, 0x5566_7788);
        store32(&backend.bytes, @as(usize, test_base) + addr64_offsets.address_hi, 0x1122_3344);
        store16(&backend.bytes, @as(usize, test_base) + addr64_offsets.data, 0x40);
        store32(&backend.bytes, @as(usize, test_base) + addr64_offsets.mask, 0x1234);
        store16(&backend.bytes, @as(usize, test_base) + addr64_offsets.ext_data, 0x5678);

        const routing = try capability.routing();

        try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), routing.address);
        try testing.expectEqual(@as(u16, 0x40), routing.data);
        try testing.expectEqual(VectorCount.two, routing.num_vectors);
        try testing.expectEqual(@as(?u32, 0x1234), routing.mask);
        try testing.expectEqual(@as(?u16, 0x5678), routing.ext_data);
    }

    test "control read failures stop programming before writes" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{ .pvm_capable = true }));

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));

        backend.resetIoCounts();
        backend.fail_control = true;

        try testing.expectError(error.OutOfBounds, capability.control());
        try testing.expectError(error.OutOfBounds, capability.routing());
        try testing.expectError(error.OutOfBounds, capability.program(.{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .one,
        }));
        try testing.expectError(error.OutOfBounds, capability.updateControl(.{ .enable = false }));
        try testing.expectError(error.OutOfBounds, capability.setMask(0));
        try testing.expectError(error.OutOfBounds, capability.setMasked(0, true));
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    test "setMasked preserves other bits" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{ .pvm_capable = true }));
        store32(&backend.bytes, @as(usize, test_base) + addr32_offsets.mask, 0xAAAA_0000);

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();

        try capability.setMasked(0, true);
        try expectWrites(&backend, &.{
            .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask, .value = 0xAAAA_0001 },
        });

        try capability.setMasked(0, false);
        try testing.expectEqual(@as(u32, 0xAAAA_0000), load32(&backend.bytes, @as(usize, test_base) + addr32_offsets.mask));
    }

    test "invalid routing is rejected after control read and before writes" {
        try expectInvalidRoutingNoWrites(msi.Control.raw(.{}), .{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .two,
        });

        try expectInvalidRoutingNoWrites(msi.Control.raw(.{ .multi_msg_capable = .two }), .{
            .address = 0xFEE0_0000,
            .data = 0x41,
            .num_vectors = .two,
        });

        try expectInvalidRoutingNoWrites(msi.Control.raw(.{}), .{
            .address = 0x1_0000_0000,
            .data = 0x40,
            .num_vectors = .one,
        });

        try expectInvalidRoutingNoWrites(msi.Control.raw(.{}), .{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .one,
            .mask = 0xFFFF_FFFF,
        });

        try expectInvalidRoutingNoWrites(msi.Control.raw(.{}), .{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .one,
            .ext_data = 0x1234,
        });
    }

    test "updateControl clears enable while preserving unrelated Control bits" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{
            .enable = true,
            .multi_msg_capable = .four,
            .multi_msg_enable = .four,
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .ext_data_enable = true,
        }) | (@as(u16, 0b10101) << 11));

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();

        try capability.updateControl(.{ .enable = false });

        const raw = load16(&backend.bytes, @as(usize, test_base) + msi.offsets.control);
        const control = msi.Control.from(raw);

        try testing.expect(!control.enable);
        try testing.expectEqual(VectorCount.four, control.multi_msg_capable);
        try testing.expectEqual(VectorCount.four, control.multi_msg_enable);
        try testing.expect(control.addr64_capable);
        try testing.expect(control.pvm_capable);
        try testing.expect(control.ext_data_capable);
        try testing.expect(control.ext_data_enable);
        try testing.expectEqual(@as(u16, 0b10101 << 11), raw & msi.Control.masks.reserved);
        try expectWrites(&backend, &.{.{ .width = 2, .offset = @as(usize, test_base) + msi.offsets.control, .value = raw }});
    }

    test "setMask writes directly without reading the old mask" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{ .pvm_capable = true }));

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();

        try capability.setMask(0x5555_F0F0);

        try testing.expectEqualSlices(usize, &.{0x82}, backend.reads[0..backend.read_count]);
        try expectWrites(&backend, &.{.{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask, .value = 0x5555_F0F0 }});
    }

    test "program orders full routing writes and preserves reserved control bits" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{
            .multi_msg_capable = .four,
            .multi_msg_enable = .two,
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
        }) | (@as(u16, 0b10010) << 11));
        store32(&backend.bytes, @as(usize, test_base) + msi.offsets.address_lo, 0x1111_2222);
        store32(&backend.bytes, @as(usize, test_base) + addr64_offsets.address_hi, 0x3333_4444);
        store16(&backend.bytes, @as(usize, test_base) + addr64_offsets.data, 0x0050);
        store16(&backend.bytes, @as(usize, test_base) + addr64_offsets.ext_data, 0x6666);
        store32(&backend.bytes, @as(usize, test_base) + addr64_offsets.mask, 0x7777_8888);

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();

        try capability.program(.{
            .address = 0x1234_5678_9ABC_DEF0,
            .data = 0x0040,
            .num_vectors = .four,
            .mask = 0xFFFF_0000,
            .ext_data = 0xABCD,
        });

        try testing.expectEqualSlices(usize, &.{0x82}, backend.reads[0..backend.read_count]);

        const updated = msi.Control.raw(.{
            .multi_msg_capable = .four,
            .multi_msg_enable = .four,
            .addr64_capable = true,
            .pvm_capable = true,
            .ext_data_capable = true,
            .ext_data_enable = true,
        }) | (@as(u16, 0b10010) << 11);

        try expectWrites(&backend, &.{
            .{ .width = 4, .offset = @as(usize, test_base) + addr64_offsets.mask, .value = 0xFFFF_0000 },
            .{ .width = 4, .offset = @as(usize, test_base) + msi.offsets.address_lo, .value = 0x9ABC_DEF0 },
            .{ .width = 4, .offset = @as(usize, test_base) + addr64_offsets.address_hi, .value = 0x1234_5678 },
            .{ .width = 2, .offset = @as(usize, test_base) + addr64_offsets.data, .value = 0x0040 },
            .{ .width = 2, .offset = @as(usize, test_base) + addr64_offsets.ext_data, .value = 0xABCD },
            .{ .width = 2, .offset = @as(usize, test_base) + msi.offsets.control, .value = updated },
        });
    }

    test "mask accesses check their register while programming checks the full live layout" {
        const base: u8 = 0xF0;
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, base, msi.Control.raw(.{}));

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(base));

        store16(&backend.bytes, @as(usize, base) + msi.offsets.control, msi.Control.raw(.{
            .pvm_capable = true,
        }));

        try capability.setMask(0xAAAA);
        try capability.setMasked(0, true);
        try testing.expectEqual(@as(u32, 0xAAAB), try capability.mask());
        try testing.expectError(error.MalformedCapability, capability.pending());

        backend.resetIoCounts();

        try testing.expectError(error.MalformedCapability, capability.program(.{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .one,
            .mask = 0,
        }));

        try testing.expectEqual(@as(usize, 0), backend.write_count);
        try testing.expectEqual(@as(u32, 0xAAAB), try capability.mask());
    }

    test "program requires disabled MSI before any writes" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{ .enable = true }));

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();

        try testing.expectError(error.InvalidState, capability.program(.{
            .address = 0xFEE0_0000,
            .data = 0x40,
            .num_vectors = .one,
        }));

        try testing.expectEqualSlices(usize, &.{0x82}, backend.reads[0..backend.read_count]);
        try testing.expectEqual(@as(usize, 0), backend.write_count);
        try testing.expect((try capability.control()).enable);
    }

    test "program writes payload at 32-bit and 64-bit wire offsets" {
        var backend32 = ConfigBackend.from();
        seedMsiCapability(&backend32, test_base, 0);

        const capability32 = try Capability.tryFrom(function(&backend32), capabilityAt(test_base));
        backend32.resetIoCounts();

        try capability32.program(.{ .address = 0xFEE0_1000, .data = 0x40, .num_vectors = .one });
        try expectWrites(&backend32, &.{
            .{ .width = 4, .offset = 0x84, .value = 0xFEE0_1000 },
            .{ .width = 2, .offset = 0x88, .value = 0x40 },
            .{ .width = 2, .offset = 0x82, .value = 0 },
        });

        var backend64 = ConfigBackend.from();
        seedMsiCapability(&backend64, test_base, 0x80);

        const capability64 = try Capability.tryFrom(function(&backend64), capabilityAt(test_base));
        backend64.resetIoCounts();

        try capability64.program(.{ .address = 0x1234_5678_FEE0_1000, .data = 0x40, .num_vectors = .one });
        try expectWrites(&backend64, &.{
            .{ .width = 4, .offset = 0x84, .value = 0xFEE0_1000 },
            .{ .width = 4, .offset = 0x88, .value = 0x1234_5678 },
            .{ .width = 2, .offset = 0x8C, .value = 0x40 },
            .{ .width = 2, .offset = 0x82, .value = 0x80 },
        });
    }

    test "program writes supplied masks and preserves omitted masks" {
        for ([_]bool{ false, true }) |addr64| {
            const mask_offset: usize = if (addr64) 0x90 else 0x8C;
            const control: u16 = if (addr64) 0x180 else 0x100;
            var backend = ConfigBackend.from();
            seedMsiCapability(&backend, test_base, control);
            store32(&backend.bytes, mask_offset, 0xCAFE_BABE);

            const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
            backend.resetIoCounts();

            try capability.program(.{ .address = 0xFEE0_0000, .data = 0x40, .num_vectors = .one });
            try testing.expectEqual(@as(u32, 0xCAFE_BABE), load32(&backend.bytes, mask_offset));

            for (backend.writes[0..backend.write_count]) |write| {
                try testing.expect(write.offset != mask_offset);
            }

            backend.resetIoCounts();

            try capability.program(.{ .address = 0xFEE0_0000, .data = 0x40, .num_vectors = .one, .mask = 0xA5A5 });
            try testing.expectEqual(@as(u32, 0xA5A5), load32(&backend.bytes, mask_offset));
            try testing.expectEqual(mask_offset, backend.writes[0].offset);
        }
    }

    test "program enables supplied extended data in both layouts" {
        for ([_]bool{ false, true }) |addr64| {
            const ext_offset: usize = if (addr64) 0x8E else 0x8A;
            const control: u16 = if (addr64) 0x280 else 0x200;
            var backend = ConfigBackend.from();
            seedMsiCapability(&backend, test_base, control);
            store16(&backend.bytes, ext_offset, 0x1234);

            const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));

            try capability.program(.{ .address = 0xFEE0_0000, .data = 0x40, .num_vectors = .one, .ext_data = 0xABCD });
            try testing.expectEqual(@as(u16, 0xABCD), load16(&backend.bytes, ext_offset));
            try testing.expectEqual(control | 0x400, load16(&backend.bytes, 0x82));
        }
    }

    test "program disables omitted extended data without writing its register" {
        for ([_]bool{ false, true }) |addr64| {
            const ext_offset: usize = if (addr64) 0x8E else 0x8A;
            const control: u16 = if (addr64) 0x680 else 0x600;
            var backend = ConfigBackend.from();
            seedMsiCapability(&backend, test_base, control);
            store16(&backend.bytes, ext_offset, 0x1234);

            const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
            backend.resetIoCounts();

            try capability.program(.{ .address = 0xFEE0_0000, .data = 0x40, .num_vectors = .one });
            try testing.expectEqual(@as(u16, 0x1234), load16(&backend.bytes, ext_offset));
            try testing.expectEqual(control & ~@as(u16, 0x400), load16(&backend.bytes, 0x82));

            for (backend.writes[0..backend.write_count]) |write| {
                try testing.expect(write.offset != ext_offset);
            }
        }
    }

    test "mask and control writes return backend errors without recovery" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, msi.Control.raw(.{ .pvm_capable = true }));

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();
        backend.mutate_before_failure = true;
        backend.fail_write = @as(usize, test_base) + addr32_offsets.mask;

        try testing.expectError(error.OutOfBounds, capability.setMask(0xAAAA));
        try testing.expectError(error.OutOfBounds, capability.setMasked(0, true));
        try testing.expectEqual(@as(u32, 0xAAAB), load32(&backend.bytes, backend.fail_write.?));
        try testing.expectEqualSlices(usize, &.{ 0x82, 0x82, 0x8C }, backend.reads[0..backend.read_count]);
        try expectWrites(&backend, &.{
            .{ .width = 4, .offset = 0x8C, .value = 0xAAAA },
            .{ .width = 4, .offset = 0x8C, .value = 0xAAAB },
        });

        backend.resetIoCounts();
        backend.fail_write = @as(usize, test_base) + msi.offsets.control;

        try testing.expectError(error.OutOfBounds, capability.updateControl(.{ .enable = true }));
        try testing.expectEqualSlices(usize, &.{0x82}, backend.reads[0..backend.read_count]);
        try expectWrites(&backend, &.{.{ .width = 2, .offset = 0x82, .value = 0x101 }});
        try testing.expect(msi.Control.from(load16(&backend.bytes, backend.fail_write.?)).enable);
    }

    test "program stops on the original backend error without recovery" {
        for ([_]bool{ false, true }) |mutate| {
            var backend = ConfigBackend.from();
            seedMsiCapability(&backend, test_base, msi.Control.raw(.{
                .multi_msg_capable = .two,
                .pvm_capable = true,
            }));
            store16(&backend.bytes, @as(usize, test_base) + addr32_offsets.data, 0x60);

            const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
            backend.resetIoCounts();
            backend.fail_write = @as(usize, test_base) + addr32_offsets.data;
            backend.mutate_before_failure = mutate;

            try testing.expectError(error.OutOfBounds, capability.program(.{
                .address = 0xFEE0_0000,
                .data = 0x40,
                .num_vectors = .two,
                .mask = 0xFFFF_FFFF,
            }));

            try testing.expectEqualSlices(usize, &.{0x82}, backend.reads[0..backend.read_count]);
            try testing.expectEqual(@as(u16, if (mutate) 0x40 else 0x60), load16(&backend.bytes, @as(usize, test_base) + addr32_offsets.data));
            try expectWrites(&backend, &.{
                .{ .width = 4, .offset = @as(usize, test_base) + addr32_offsets.mask, .value = 0xFFFF_FFFF },
                .{ .width = 4, .offset = @as(usize, test_base) + msi.offsets.address_lo, .value = 0xFEE0_0000 },
                .{ .width = 2, .offset = @as(usize, test_base) + addr32_offsets.data, .value = 0x40 },
            });
        }
    }

    test "MSI rejects truncated shapes before payload access or programming" {
        const shapes = [_]struct { control: Control, length: u16 }{
            .{ .control = .{}, .length = 10 },
            .{ .control = .{ .addr64_capable = true }, .length = 14 },
            .{ .control = .{ .ext_data_capable = true }, .length = 12 },
            .{ .control = .{ .addr64_capable = true, .ext_data_capable = true }, .length = 16 },
            .{ .control = .{ .pvm_capable = true }, .length = 20 },
            .{ .control = .{ .addr64_capable = true, .pvm_capable = true }, .length = 24 },
        };

        for (shapes) |shape| {
            const base: u8 = @intCast((0x100 - shape.length) & ~@as(u16, 3));
            var backend = ConfigBackend.from();
            seedMsiCapability(&backend, base, msi.Control.raw(shape.control));
            store32(&backend.bytes, @as(usize, base) + 4, 0xFEE0_1000);

            const valid = try Capability.tryFrom(function(&backend), capabilityAt(base));

            try testing.expectEqual(@as(u64, 0xFEE0_1000), try valid.address());

            const invalid_base = base + 4;
            seedMsiCapability(&backend, invalid_base, msi.Control.raw(shape.control));

            try testing.expectError(error.MalformedCapability, Capability.tryFrom(function(&backend), capabilityAt(invalid_base)));

            var invalid = valid;
            invalid.registers = try Registers.tryFrom(function(&backend), invalid_base);

            backend.resetIoCounts();

            if (shape.control.pvm_capable) {
                try testing.expectError(error.MalformedCapability, invalid.pending());
            } else if (shape.control.ext_data_capable) {
                try testing.expectError(error.MalformedCapability, invalid.extData());
            } else {
                try testing.expectError(error.MalformedCapability, invalid.data());
            }

            const before = backend.bytes;

            try testing.expectError(error.MalformedCapability, invalid.program(.{
                .address = 0xFEE0_1000,
                .data = 0x40,
                .num_vectors = .one,
                .mask = if (shape.control.pvm_capable) 0 else null,
                .ext_data = if (shape.control.ext_data_capable) 0 else null,
            }));

            try testing.expectEqual(@as(usize, 0), backend.write_count);
            try testing.expectEqualSlices(u8, &before, &backend.bytes);
        }
    }

    test "tryFrom rejects a capability without room for its payload" {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, 0xFC, 0);
        store32(&backend.bytes, 0x100, 0xDEAD_BEEF);

        try testing.expectError(error.MalformedCapability, Capability.tryFrom(function(&backend), capabilityAt(0xFC)));
    }

    fn expectInvalidRoutingNoWrites(control: u16, routing: Routing) !void {
        var backend = ConfigBackend.from();
        seedMsiCapability(&backend, test_base, control);

        const capability = try Capability.tryFrom(function(&backend), capabilityAt(test_base));
        backend.resetIoCounts();

        try testing.expectError(error.InvalidRouting, capability.program(routing));
        try testing.expectEqual(@as(usize, 0), backend.write_count);
    }

    fn expectWrites(backend: *const ConfigBackend, expected: []const ExpectedWrite) !void {
        try testing.expectEqual(expected.len, backend.write_count);

        for (expected, 0..) |write, index| {
            try testing.expectEqual(write.width, backend.writes[index].width);
            try testing.expectEqual(write.offset, backend.writes[index].offset);
            try testing.expectEqual(write.value, backend.writes[index].value);
        }
    }

    fn function(backend: *ConfigBackend) Function {
        return Function.from(backend.config(), backend.sbdf);
    }

    fn capabilityAt(base: u8) Entry {
        return .{ .id = msi.id, .offset = base };
    }

    fn seedMsiCapability(backend: *ConfigBackend, base: u8, control: u16) void {
        seedHead(&backend.bytes, base);
        seedCapabilityNode(&backend.bytes, base, @backingInt(msi.id), 0);
        store16(&backend.bytes, @as(usize, base) + msi.offsets.control, control);
    }

    fn seedHead(bytes: *[pcie_window_size]u8, head: u8) void {
        store16(bytes, core.header.offsets.status, core.header.Status.raw(.{ .cap_list = true }));
        bytes[core.header.type0.offsets.cap_ptr] = head;
    }

    fn seedCapabilityNode(bytes: *[pcie_window_size]u8, base: u8, id: u8, next: u8) void {
        bytes[base] = id;
        bytes[@as(usize, base) + 1] = next;
    }

    fn load16(bytes: *const [pcie_window_size]u8, byte_offset: usize) u16 {
        return std.mem.readInt(u16, bytes[byte_offset..][0..2], .little);
    }

    fn store16(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[byte_offset..][0..2], value, .little);
    }

    fn load32(bytes: *const [pcie_window_size]u8, byte_offset: usize) u32 {
        return std.mem.readInt(u32, bytes[byte_offset..][0..4], .little);
    }

    fn store32(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[byte_offset..][0..4], value, .little);
    }
};
