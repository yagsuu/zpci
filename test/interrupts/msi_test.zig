//! Tests for docs/specs/interrupts/msi.md.

const std = @import("std");
const pci = @import("pci");

const Capability = pci.capabilities.list.Capability;
const ConfigSpace = pci.config.ConfigSpace;
const Function = pci.config.Function;
const MessageControl = pci.interrupts.msi.MessageControl;
const Sbdf = pci.core.Sbdf;
const VectorCount = pci.interrupts.msi.VectorCount;
const View = pci.interrupts.msi.View;

const msi = pci.interrupts.msi;
const register = msi.register;
const standard = pci.capabilities.list.standard;
const pcie_window_size: usize = 0x1000;
const test_base: u8 = 0x80;
const test_sbdf = Sbdf.of(0, 0, 0, 0);
const offset = struct {
    const status: usize = 0x06;
};
const status = struct {
    const capabilities_list: u16 = 1 << 4;
};

test "layout: MSI register constants and MessageControl bit fields match spec" {
    // Pin the public MSI offsets and packed bit placement used by typed config reads and writes.
    try std.testing.expectEqual(@as(u8, 0x05), msi.cap_id);
    try std.testing.expectEqual(@as(u8, 0x02), register.message_control);
    try std.testing.expectEqual(@as(u8, 0x04), register.message_address_lo);
    try std.testing.expectEqual(@as(u8, 0x08), register.message_address_hi_64);
    try std.testing.expectEqual(@as(u8, 0x08), register.message_data_32);
    try std.testing.expectEqual(@as(u8, 0x0C), register.message_data_64);
    try std.testing.expectEqual(@as(u8, 0x0A), register.ext_message_data_32);
    try std.testing.expectEqual(@as(u8, 0x0E), register.ext_message_data_64);
    try std.testing.expectEqual(@as(u8, 0x0C), register.mask_bits_32);
    try std.testing.expectEqual(@as(u8, 0x10), register.mask_bits_64);
    try std.testing.expectEqual(@as(u8, 0x10), register.pending_bits_32);
    try std.testing.expectEqual(@as(u8, 0x14), register.pending_bits_64);

    try std.testing.expectEqual(@as(comptime_int, 2), @sizeOf(MessageControl));
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(MessageControl));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(MessageControl, "msi_enable"));
    try std.testing.expectEqual(@as(comptime_int, 1), @bitOffsetOf(MessageControl, "multiple_message_capable"));
    try std.testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(MessageControl, "multiple_message_enable"));
    try std.testing.expectEqual(@as(comptime_int, 7), @bitOffsetOf(MessageControl, "addr_64_capable"));
    try std.testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(MessageControl, "pvm_capable"));
    try std.testing.expectEqual(@as(comptime_int, 9), @bitOffsetOf(MessageControl, "ext_msg_data_capable"));
    try std.testing.expectEqual(@as(comptime_int, 10), @bitOffsetOf(MessageControl, "ext_msg_data_enable"));
    try std.testing.expectEqual(@as(comptime_int, 11), @bitOffsetOf(MessageControl, "_reserved11"));
    try std.testing.expectEqual(@as(u16, 0), (MessageControl{}).raw());
}

test "unit: VectorCount helpers map valid encodings and reject reserved or invalid counts" {
    // Table cases cover the PCI power-of-two domain plus reserved enum holes and non-power-of-two requests.
    try expectVectorCount(.one, 1);
    try expectVectorCount(.two, 2);
    try expectVectorCount(.four, 4);
    try expectVectorCount(.eight, 8);
    try expectVectorCount(.sixteen, 16);
    try expectVectorCount(.thirty_two, 32);

    try std.testing.expectError(error.MalformedField, (@as(VectorCount, @enumFromInt(6))).numVectors());
    try std.testing.expectError(error.MalformedField, (@as(VectorCount, @enumFromInt(7))).numVectors());
    try std.testing.expectError(error.InvalidRouting, VectorCount.fromCount(0));
    try std.testing.expectError(error.InvalidRouting, VectorCount.fromCount(3));
    try std.testing.expectError(error.InvalidRouting, VectorCount.fromCount(33));
    try std.testing.expectError(error.InvalidRouting, VectorCount.fromCount(63));
}

test "unit: find returns present MSI view, null for absence, and errors on malformed traversal" {
    // Walk real capability-list bytes through present, steady-state absent, and corrupt-list cases.
    var present = MsiConfig.init();
    seedHead(&present.bytes, 0x40);
    seedCapabilityNode(&present.bytes, 0x40, @intFromEnum(pci.capabilities.list.Id.pci_express), test_base);
    seedCapabilityNode(&present.bytes, test_base, msi.cap_id, 0);
    store16(&present.bytes, @as(usize, test_base) + register.message_control, controlRaw(.{
        .multiple_message_capable = @intFromEnum(VectorCount.four),
        .addr_64_capable = true,
        .pvm_capable = true,
    }));
    const found = (try View.find(function(&present))).?;

    try std.testing.expectEqual(test_base, found.base);
    try std.testing.expect(found.addr64Capable());
    try std.testing.expect(found.pvmCapable());
    try std.testing.expectEqual(VectorCount.four, try found.multipleMessageCapable());

    var no_list = MsiConfig.init();
    try std.testing.expect((try View.find(function(&no_list))) == null);

    var no_msi = MsiConfig.init();
    seedHead(&no_msi.bytes, 0x40);
    seedCapabilityNode(&no_msi.bytes, 0x40, @intFromEnum(pci.capabilities.list.Id.pci_express), 0);
    try std.testing.expect((try View.find(function(&no_msi))) == null);

    var cycle = MsiConfig.init();
    seedHead(&cycle.bytes, 0x40);
    seedCapabilityNode(&cycle.bytes, 0x40, @intFromEnum(pci.capabilities.list.Id.pci_express), 0x44);
    seedCapabilityNode(&cycle.bytes, 0x44, @intFromEnum(pci.capabilities.list.Id.msi_x), 0x40);
    try std.testing.expectError(error.MalformedCapability, View.find(function(&cycle)));
}

test "malformed: validate rejects reserved multiple_message_capable encodings" {
    // Direct validation must reject PCI-reserved vector-count encodings before handing out a usable view.
    for ([_]u3{ 6, 7 }) |reserved| {
        var backend = MsiConfig.init();
        store16(&backend.bytes, @as(usize, test_base) + register.message_control, controlRaw(.{
            .multiple_message_capable = reserved,
        }));

        try std.testing.expectError(error.MalformedField, View.validate(function(&backend), capabilityAt(test_base)));
    }
}

test "unit: live reads dispatch through 32-bit and 64-bit MSI layouts" {
    // Distinct sentinels at every shape-selected offset catch wrong 32/64/PVM/extended dispatch.
    var msi32 = MsiConfig.init();
    seedMsiCapability(&msi32, test_base, controlRaw(.{
        .multiple_message_enable = @intFromEnum(VectorCount.two),
        .pvm_capable = true,
    }));
    store32(&msi32.bytes, @as(usize, test_base) + register.message_address_lo, 0x89AB_CDEF);
    store16(&msi32.bytes, @as(usize, test_base) + register.message_data_32, 0x3456);
    store32(&msi32.bytes, @as(usize, test_base) + register.mask_bits_32, 0xCAFE_BABE);
    store32(&msi32.bytes, @as(usize, test_base) + register.pending_bits_32, 0x1234_5678);
    const view32 = try View.validate(function(&msi32), capabilityAt(test_base));

    try std.testing.expectEqual(@as(u64, 0x89AB_CDEF), try view32.messageAddress());
    try std.testing.expectEqual(@as(u16, 0x3456), try view32.messageData());
    try std.testing.expectEqual(VectorCount.two, try view32.multipleMessageEnable());
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try view32.mask());
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try view32.pending());

    var msi64 = MsiConfig.init();
    seedMsiCapability(&msi64, test_base, controlRaw(.{
        .multiple_message_enable = @intFromEnum(VectorCount.four),
        .addr_64_capable = true,
        .pvm_capable = true,
        .ext_msg_data_capable = true,
        .ext_msg_data_enable = true,
    }));
    store32(&msi64.bytes, @as(usize, test_base) + register.message_address_lo, 0x5566_7788);
    store32(&msi64.bytes, @as(usize, test_base) + register.message_address_hi_64, 0x1122_3344);
    store16(&msi64.bytes, @as(usize, test_base) + register.message_data_64, 0x7788);
    store16(&msi64.bytes, @as(usize, test_base) + register.ext_message_data_64, 0x99AA);
    store32(&msi64.bytes, @as(usize, test_base) + register.mask_bits_64, 0x0F0F_F0F0);
    store32(&msi64.bytes, @as(usize, test_base) + register.pending_bits_64, 0xA5A5_5A5A);
    const view64 = try View.validate(function(&msi64), capabilityAt(test_base));

    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), try view64.messageAddress());
    try std.testing.expectEqual(@as(u16, 0x7788), try view64.messageData());
    try std.testing.expectEqual(VectorCount.four, try view64.multipleMessageEnable());
    try std.testing.expect(try view64.extendedMessageDataEnabled());
    try std.testing.expectEqual(@as(u16, 0x99AA), try view64.extendedMessageData());
    try std.testing.expectEqual(@as(u32, 0x0F0F_F0F0), try view64.mask());
    try std.testing.expectEqual(@as(u32, 0xA5A5_5A5A), try view64.pending());
}

test "unit: invalid routing is rejected before program performs config I/O" {
    // Each invalid route is checked against the snapshot before the save phase can read or write config space.
    try expectInvalidRoutingNoIo(controlRaw(.{}), .{
        .address = 0xFEE0_0000,
        .data = 0x40,
        .vector_count = .two,
    });
    try expectInvalidRoutingNoIo(controlRaw(.{ .multiple_message_capable = @intFromEnum(VectorCount.two) }), .{
        .address = 0xFEE0_0000,
        .data = 0x41,
        .vector_count = .two,
    });
    try expectInvalidRoutingNoIo(controlRaw(.{}), .{
        .address = 0x1_0000_0000,
        .data = 0x40,
        .vector_count = .one,
    });
    try expectInvalidRoutingNoIo(controlRaw(.{}), .{
        .address = 0xFEE0_0000,
        .data = 0x40,
        .vector_count = .one,
        .pvm = .{ .initial_mask = 0xFFFF_FFFF },
    });
    try expectInvalidRoutingNoIo(controlRaw(.{}), .{
        .address = 0xFEE0_0000,
        .data = 0x40,
        .vector_count = .one,
        .ext_data = .{ .value = 0x1234 },
    });
}

test "unit: disable clears enable while preserving reserved and writable MessageControl bits" {
    // Disable performs a Message Control RMW and must leave every non-enable bit byte-for-byte intact.
    var backend = MsiConfig.init();
    seedMsiCapability(&backend, test_base, controlRaw(.{
        .msi_enable = true,
        .multiple_message_capable = @intFromEnum(VectorCount.four),
        .multiple_message_enable = @intFromEnum(VectorCount.four),
        .addr_64_capable = true,
        .pvm_capable = true,
        .ext_msg_data_capable = true,
        .ext_msg_data_enable = true,
        .reserved11 = 0b10101,
    }));
    const view = try View.validate(function(&backend), capabilityAt(test_base));
    backend.resetIoCounts();

    try view.disable();

    const raw = load16(&backend.bytes, @as(usize, test_base) + register.message_control);
    const control: MessageControl = @bitCast(raw);
    try std.testing.expect(!control.msi_enable);
    try std.testing.expectEqual(@as(u3, @intFromEnum(VectorCount.four)), control.multiple_message_capable);
    try std.testing.expectEqual(@as(u3, @intFromEnum(VectorCount.four)), control.multiple_message_enable);
    try std.testing.expect(control.addr_64_capable);
    try std.testing.expect(control.pvm_capable);
    try std.testing.expect(control.ext_msg_data_capable);
    try std.testing.expect(control.ext_msg_data_enable);
    try std.testing.expectEqual(@as(u5, 0b10101), control._reserved11);
    try expectWrites(&backend, &.{.{ .width = 2, .offset = @as(usize, test_base) + register.message_control, .value = raw }});
}

test "unit: setMask writes with readback and restores saved mask on mismatch" {
    // A successful write proves readback commit, and a forced readback mismatch must rollback to the saved mask.
    var success = MsiConfig.init();
    seedMsiCapability(&success, test_base, controlRaw(.{ .pvm_capable = true }));
    store32(&success.bytes, @as(usize, test_base) + register.mask_bits_32, 0xAAAA_0000);
    const success_view = try View.validate(function(&success), capabilityAt(test_base));
    success.resetIoCounts();

    try success_view.setMask(0x5555_F0F0);

    try std.testing.expectEqual(@as(u32, 0x5555_F0F0), load32(&success.bytes, @as(usize, test_base) + register.mask_bits_32));
    try expectWrites(&success, &.{.{ .width = 4, .offset = @as(usize, test_base) + register.mask_bits_32, .value = 0x5555_F0F0 }});

    var rollback = MsiConfig.init();
    seedMsiCapability(&rollback, test_base, controlRaw(.{
        .addr_64_capable = true,
        .pvm_capable = true,
    }));
    store32(&rollback.bytes, @as(usize, test_base) + register.mask_bits_64, 0x1357_9BDF);
    const rollback_view = try View.validate(function(&rollback), capabilityAt(test_base));
    rollback.resetIoCounts();
    rollback.mismatch_once = .{ .width = 4, .offset = @as(usize, test_base) + register.mask_bits_64 };

    try std.testing.expectError(error.ProgrammingReadbackMismatch, rollback_view.setMask(0x2468_ACE0));

    try std.testing.expectEqual(@as(u32, 0x1357_9BDF), load32(&rollback.bytes, @as(usize, test_base) + register.mask_bits_64));
    try expectWrites(&rollback, &.{
        .{ .width = 4, .offset = @as(usize, test_base) + register.mask_bits_64, .value = 0x2468_ACE0 },
        .{ .width = 4, .offset = @as(usize, test_base) + register.mask_bits_64, .value = 0x1357_9BDF },
    });
}

test "unit: program commits full routing and preserves reserved control bits" {
    // A maximal MSI shape exercises deterministic disable-mask-address-data-ext-enable ordering.
    var backend = MsiConfig.init();
    seedMsiCapability(&backend, test_base, controlRaw(.{
        .msi_enable = true,
        .multiple_message_capable = @intFromEnum(VectorCount.four),
        .multiple_message_enable = @intFromEnum(VectorCount.two),
        .addr_64_capable = true,
        .pvm_capable = true,
        .ext_msg_data_capable = true,
        .reserved11 = 0b10010,
    }));
    store32(&backend.bytes, @as(usize, test_base) + register.message_address_lo, 0x1111_2222);
    store32(&backend.bytes, @as(usize, test_base) + register.message_address_hi_64, 0x3333_4444);
    store16(&backend.bytes, @as(usize, test_base) + register.message_data_64, 0x0050);
    store16(&backend.bytes, @as(usize, test_base) + register.ext_message_data_64, 0x6666);
    store32(&backend.bytes, @as(usize, test_base) + register.mask_bits_64, 0x7777_8888);
    const view = try View.validate(function(&backend), capabilityAt(test_base));
    backend.resetIoCounts();

    try view.program(.{
        .address = 0x1234_5678_9ABC_DEF0,
        .data = 0x0040,
        .vector_count = .four,
        .pvm = .{ .initial_mask = 0xFFFF_0000 },
        .ext_data = .{ .value = 0xABCD },
    });

    const disabled = controlRaw(.{
        .multiple_message_capable = @intFromEnum(VectorCount.four),
        .multiple_message_enable = @intFromEnum(VectorCount.two),
        .addr_64_capable = true,
        .pvm_capable = true,
        .ext_msg_data_capable = true,
        .reserved11 = 0b10010,
    });
    const enabled = controlRaw(.{
        .msi_enable = true,
        .multiple_message_capable = @intFromEnum(VectorCount.four),
        .multiple_message_enable = @intFromEnum(VectorCount.four),
        .addr_64_capable = true,
        .pvm_capable = true,
        .ext_msg_data_capable = true,
        .ext_msg_data_enable = true,
        .reserved11 = 0b10010,
    });

    try std.testing.expectEqual(@as(u32, 0x9ABC_DEF0), load32(&backend.bytes, @as(usize, test_base) + register.message_address_lo));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), load32(&backend.bytes, @as(usize, test_base) + register.message_address_hi_64));
    try std.testing.expectEqual(@as(u16, 0x0040), load16(&backend.bytes, @as(usize, test_base) + register.message_data_64));
    try std.testing.expectEqual(@as(u16, 0xABCD), load16(&backend.bytes, @as(usize, test_base) + register.ext_message_data_64));
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), load32(&backend.bytes, @as(usize, test_base) + register.mask_bits_64));
    try std.testing.expectEqual(enabled, load16(&backend.bytes, @as(usize, test_base) + register.message_control));
    try expectWrites(&backend, &.{
        .{ .width = 2, .offset = @as(usize, test_base) + register.message_control, .value = disabled },
        .{ .width = 4, .offset = @as(usize, test_base) + register.mask_bits_64, .value = 0xFFFF_0000 },
        .{ .width = 4, .offset = @as(usize, test_base) + register.message_address_lo, .value = 0x9ABC_DEF0 },
        .{ .width = 4, .offset = @as(usize, test_base) + register.message_address_hi_64, .value = 0x1234_5678 },
        .{ .width = 2, .offset = @as(usize, test_base) + register.message_data_64, .value = 0x0040 },
        .{ .width = 2, .offset = @as(usize, test_base) + register.ext_message_data_64, .value = 0xABCD },
        .{ .width = 2, .offset = @as(usize, test_base) + register.message_control, .value = enabled },
    });
}

test "unit: program rolls back prior writes after a representative data readback failure" {
    // A data-register readback mismatch must restore data, address, mask, and Message Control in reverse order.
    var backend = MsiConfig.init();
    seedMsiCapability(&backend, test_base, controlRaw(.{
        .msi_enable = true,
        .multiple_message_capable = @intFromEnum(VectorCount.two),
        .multiple_message_enable = @intFromEnum(VectorCount.two),
        .pvm_capable = true,
        .reserved11 = 0b01101,
    }));
    store32(&backend.bytes, @as(usize, test_base) + register.message_address_lo, 0xAAAA_BBBB);
    store16(&backend.bytes, @as(usize, test_base) + register.message_data_32, 0x0060);
    store32(&backend.bytes, @as(usize, test_base) + register.mask_bits_32, 0x0000_FFFF);
    const before = backend.bytes;
    const view = try View.validate(function(&backend), capabilityAt(test_base));
    backend.resetIoCounts();
    backend.mismatch_once = .{ .width = 2, .offset = @as(usize, test_base) + register.message_data_32 };

    try std.testing.expectError(error.ProgrammingReadbackMismatch, view.program(.{
        .address = 0xFEE0_0000,
        .data = 0x0040,
        .vector_count = .two,
        .pvm = .{ .initial_mask = 0xFFFF_FFFF },
    }));

    try std.testing.expectEqualSlices(u8, &before, &backend.bytes);
    try expectWrites(&backend, &.{
        .{ .width = 2, .offset = @as(usize, test_base) + register.message_control, .value = controlRaw(.{
            .multiple_message_capable = @intFromEnum(VectorCount.two),
            .multiple_message_enable = @intFromEnum(VectorCount.two),
            .pvm_capable = true,
            .reserved11 = 0b01101,
        }) },
        .{ .width = 4, .offset = @as(usize, test_base) + register.mask_bits_32, .value = 0xFFFF_FFFF },
        .{ .width = 4, .offset = @as(usize, test_base) + register.message_address_lo, .value = 0xFEE0_0000 },
        .{ .width = 2, .offset = @as(usize, test_base) + register.message_data_32, .value = 0x0040 },
        .{ .width = 2, .offset = @as(usize, test_base) + register.message_data_32, .value = 0x0060 },
        .{ .width = 4, .offset = @as(usize, test_base) + register.message_address_lo, .value = 0xAAAA_BBBB },
        .{ .width = 4, .offset = @as(usize, test_base) + register.mask_bits_32, .value = 0x0000_FFFF },
        .{ .width = 2, .offset = @as(usize, test_base) + register.message_control, .value = controlRaw(.{
            .msi_enable = true,
            .multiple_message_capable = @intFromEnum(VectorCount.two),
            .multiple_message_enable = @intFromEnum(VectorCount.two),
            .pvm_capable = true,
            .reserved11 = 0b01101,
        }) },
    });
}

const ControlFields = struct {
    msi_enable: bool = false,
    multiple_message_capable: u3 = 0,
    multiple_message_enable: u3 = 0,
    addr_64_capable: bool = false,
    pvm_capable: bool = false,
    ext_msg_data_capable: bool = false,
    ext_msg_data_enable: bool = false,
    reserved11: u5 = 0,
};

fn controlRaw(fields: ControlFields) u16 {
    const control = MessageControl{
        .msi_enable = fields.msi_enable,
        .multiple_message_capable = fields.multiple_message_capable,
        .multiple_message_enable = fields.multiple_message_enable,
        .addr_64_capable = fields.addr_64_capable,
        .pvm_capable = fields.pvm_capable,
        .ext_msg_data_capable = fields.ext_msg_data_capable,
        .ext_msg_data_enable = fields.ext_msg_data_enable,
        ._reserved11 = fields.reserved11,
    };
    return @bitCast(control);
}

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

    const Mismatch = struct {
        width: u8,
        offset: usize,
    };

    fn init() MsiConfig {
        return .{};
    }

    fn configSpace(self: *MsiConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
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
        if (mismatch.width != width or mismatch.offset != byte_offset) return false;
        if (last.width != width or last.offset != byte_offset) return false;

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

    fn read8(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        const self: *MsiConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        return self.bytes[byte_offset];
    }

    fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigSpace.Error!u16 {
        const self: *MsiConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        const value = load16(&self.bytes, byte_offset);
        if (self.consumeMismatch(2, byte_offset)) return value ^ 0x0001;
        return value;
    }

    fn read32(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigSpace.Error!u32 {
        const self: *MsiConfig = @ptrCast(@alignCast(context));
        self.read_count += 1;
        const value = load32(&self.bytes, byte_offset);
        if (self.consumeMismatch(4, byte_offset)) return value ^ 0x0000_0001;
        return value;
    }

    fn write8(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        const self: *MsiConfig = @ptrCast(@alignCast(context));
        self.recordWrite(.{ .width = 1, .offset = byte_offset, .value = value });
        self.bytes[byte_offset] = value;
    }

    fn write16(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        const self: *MsiConfig = @ptrCast(@alignCast(context));
        self.recordWrite(.{ .width = 2, .offset = byte_offset, .value = value });
        store16(&self.bytes, byte_offset, value);
    }

    fn write32(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        const self: *MsiConfig = @ptrCast(@alignCast(context));
        self.recordWrite(.{ .width = 4, .offset = byte_offset, .value = value });
        store32(&self.bytes, byte_offset, value);
    }
};

fn expectVectorCount(count: VectorCount, expected: u6) !void {
    try std.testing.expectEqual(expected, try count.numVectors());
    try std.testing.expectEqual(count, try VectorCount.fromCount(expected));
}

fn expectInvalidRoutingNoIo(control: u16, routing: View.Routing) !void {
    var backend = MsiConfig.init();
    seedMsiCapability(&backend, test_base, control);
    const view = try View.validate(function(&backend), capabilityAt(test_base));
    backend.resetIoCounts();

    try std.testing.expectError(error.InvalidRouting, view.program(routing));
    try std.testing.expectEqual(@as(usize, 0), backend.read_count);
    try std.testing.expectEqual(@as(usize, 0), backend.write_count);
}

fn expectWrites(backend: *const MsiConfig, expected: []const ExpectedWrite) !void {
    try std.testing.expectEqual(expected.len, backend.write_len);
    for (expected, 0..) |write, index| {
        try std.testing.expectEqual(write.width, backend.writes[index].width);
        try std.testing.expectEqual(write.offset, backend.writes[index].offset);
        try std.testing.expectEqual(write.value, backend.writes[index].value);
    }
}

fn function(backend: *MsiConfig) Function {
    return Function.unchecked(backend.configSpace(), backend.sbdf);
}

fn capabilityAt(base: u8) Capability {
    return .{ .id = msi.cap_id, .offset = base };
}

fn seedMsiCapability(backend: *MsiConfig, base: u8, control: u16) void {
    seedHead(&backend.bytes, base);
    seedCapabilityNode(&backend.bytes, base, msi.cap_id, 0);
    store16(&backend.bytes, @as(usize, base) + register.message_control, control);
}

fn seedHead(bytes: *[pcie_window_size]u8, head: u8) void {
    store16(bytes, offset.status, status.capabilities_list);
    bytes[standard.head_offset] = head;
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
