//! Type-0 endpoint header view.

const std = @import("std");

const config = @import("config");
const core = @import("core");

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
const Status = core.header.Status.Word;
const ExpansionRom = core.header.ExpansionRom;
const ExpansionRomWord = ExpansionRom.Word;
const Subsystem = core.header.Subsystem;
const IntrPin = core.header.IntrPin;

const type0 = core.header.type0;

pub const Type0 = struct {
    function: Function,

    pub const num_bar_slots = type0.num_bar_slots;

    pub fn from(function: Function) Type0 {
        return .{ .function = function };
    }

    pub fn vendorId(self: Type0) ConfigError!VendorId {
        return self.function.vendorId();
    }

    pub fn deviceId(self: Type0) ConfigError!DeviceId {
        return self.function.deviceId();
    }

    pub fn revisionId(self: Type0) ConfigError!RevisionId {
        return self.function.revisionId();
    }

    pub fn classCode(self: Type0) ConfigError!ClassCode {
        return self.function.classCode();
    }

    pub fn command(self: Type0) ConfigError!Command {
        return self.function.command();
    }

    pub fn setCommand(self: Type0, value: Command) ConfigError!void {
        return self.function.setCommand(value);
    }

    pub fn status(self: Type0) ConfigError!Status {
        return self.function.status();
    }

    pub fn clearStatusBits(self: Type0, bits: u16) ConfigError!void {
        return self.function.clearStatusBits(bits);
    }

    pub fn cacheLineSize(self: Type0) ConfigError!u8 {
        return self.function.cacheLineSize();
    }

    pub fn setCacheLineSize(self: Type0, value: u8) ConfigError!void {
        return self.function.setCacheLineSize(value);
    }

    pub fn latencyTimer(self: Type0) ConfigError!u8 {
        return self.function.latencyTimer();
    }

    pub fn setLatencyTimer(self: Type0, value: u8) ConfigError!void {
        return self.function.setLatencyTimer(value);
    }

    pub fn typeByte(self: Type0) ConfigError!u8 {
        return self.function.typeByte();
    }

    pub fn multifunction(self: Type0) ConfigError!bool {
        return self.function.multifunction();
    }

    pub fn bist(self: Type0) ConfigError!Bist {
        return self.function.bist();
    }

    pub fn setBist(self: Type0, value: Bist) ConfigError!void {
        return self.function.setBist(value);
    }

    pub fn rawBar(self: Type0, index: usize) ConfigError!u32 {
        std.debug.assert(index < num_bar_slots);
        return self.function.read(offsets.bar(index));
    }

    pub fn cardbusCisPtr(self: Type0) ConfigError!u32 {
        return self.function.read(offsets.cardbus_cis_ptr);
    }

    pub fn subsystemVendorId(self: Type0) ConfigError!VendorId {
        return .from(try self.function.read(offsets.subsystem_vendor_id));
    }

    pub fn subsystemId(self: Type0) ConfigError!u16 {
        return self.function.read(offsets.subsystem_id);
    }

    pub fn subsystem(self: Type0) ConfigError!Subsystem {
        const raw = try self.function.read(offsets.subsystem);

        return .{
            .vendor_id = .from(@truncate(raw)),
            .id = @truncate(raw >> 16),
        };
    }

    pub fn rom(self: Type0) ConfigError!ExpansionRomWord {
        const raw = try self.function.read(offsets.rom_base);
        return ExpansionRom.from(raw);
    }

    pub fn setRom(self: Type0, value: ExpansionRomWord) ConfigError!void {
        return self.function.write(offsets.rom_base, ExpansionRom.raw(value));
    }

    pub fn capPtr(self: Type0) ConfigError!u8 {
        return self.function.capPtr();
    }

    pub fn intrLine(self: Type0) ConfigError!u8 {
        return self.function.intrLine();
    }

    pub fn setIntrLine(self: Type0, value: u8) ConfigError!void {
        return self.function.setIntrLine(value);
    }

    pub fn intrPin(self: Type0) (ConfigError || IntrPin.Error)!IntrPin {
        return IntrPin.tryFrom(try self.function.read(Function.offsets.intr_pin));
    }

    pub fn minGrant(self: Type0) ConfigError!u8 {
        return self.function.read(offsets.min_grant);
    }

    pub fn maxLatency(self: Type0) ConfigError!u8 {
        return self.function.read(offsets.max_latency);
    }
};

pub const offsets = struct {
    pub const cardbus_cis_ptr = Offset(u32).from(type0.offsets.cardbus_cis_ptr);
    pub const subsystem_vendor_id = Offset(u16).from(type0.offsets.subsystem_vendor_id);
    pub const subsystem_id = Offset(u16).from(type0.offsets.subsystem_id);
    pub const subsystem = Offset(u32).from(type0.offsets.subsystem);
    pub const rom_base = Offset(u32).from(type0.offsets.rom_base);
    pub const min_grant = Offset(u8).from(type0.offsets.min_grant);
    pub const max_latency = Offset(u8).from(type0.offsets.max_latency);

    pub fn bar(index: usize) Offset(u32) {
        return .from(type0.offsets.bar(index));
    }
};

pub const unit = struct {
    const support = @import("testing");
    const testing = std.testing;

    const num_bar_slots = Type0.num_bar_slots;
    const pcie_window_size = core.config.extended_size;

    const Sbdf = core.Sbdf;

    const TestConfigSpace = support.config.TestConfigSpace;

    const offset = struct {
        const vendor_id: usize = 0x00;
        const bars: usize = 0x10;
        const cardbus_cis_ptr: usize = 0x28;
        const subsystem: usize = 0x2C;
        const subsystem_vendor_id: usize = 0x2C;
        const subsystem_id: usize = 0x2E;
        const rom_base: usize = 0x30;
        const cap_ptr: usize = 0x34;
        const intr_line: usize = 0x3C;
        const intr_pin: usize = 0x3D;
        const min_grant: usize = 0x3E;
        const max_latency: usize = 0x3F;
    };

    test "Type0 reads every type-0 endpoint field from seeded config bytes" {
        const bars = [_]u32{
            0x1000_0004,
            0x2000_0000,
            0x3000_0008,
            0x4000_000C,
            0x5000_0010,
            0x6000_0014,
        };
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedType0Header(&bytes, .{
            .bars = bars,
            .cardbus_cis = 0xCAFE_BABE,
            .subsystem_vendor = 0x1AF4,
            .subsystem = 0x1042,
            .rom_base = 0xD5E6_5AAB,
            .cap_ptr = 0x90,
            .intr_line = 0xFE,
            .intr_pin = 0x03,
            .min_grant = 0x11,
            .max_latency = 0x22,
        });
        const sbdf = Sbdf.from(.from(0), 0, 1, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const view = Type0.from(Function.from(backend.config(), sbdf));

        inline for (bars, 0..) |expected, index| {
            try testing.expectEqual(expected, try view.rawBar(index));
        }

        try testing.expectEqual(@as(u32, 0xCAFE_BABE), try view.cardbusCisPtr());
        try testing.expectEqual(@as(u16, 0x1AF4), @intFromEnum(try view.subsystemVendorId()));
        try testing.expectEqual(@as(u16, 0x1042), try view.subsystemId());
        try testing.expectEqual(Subsystem{ .vendor_id = .from(0x1AF4), .id = 0x1042 }, try view.subsystem());
        try testing.expectEqual(@as(u32, 0xD5E6_5AAB), ExpansionRom.raw(try view.rom()));
        try testing.expectEqual(@as(u8, 0x90), try view.capPtr());
        try testing.expectEqual(@as(u8, 0xFE), try view.intrLine());
        try testing.expectEqual(IntrPin.intc, try view.intrPin());
        try testing.expectEqual(@as(u8, 0x11), try view.minGrant());
        try testing.expectEqual(@as(u8, 0x22), try view.maxLatency());
    }

    test "Type0 writes exact type-0 endpoint bytes" {
        var bytes: [pcie_window_size]u8 = @splat(0xA5);
        const sbdf = Sbdf.from(.from(0), 0, 2, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const view = Type0.from(Function.from(backend.config(), sbdf));

        try view.setIntrLine(0x44);

        try testing.expectEqual(@as(u8, 0x44), bytes[offset.intr_line]);

        try view.setRom(ExpansionRom.from(0xFEDC_BA98));

        try testing.expectEqual(@as(u8, 0x98), bytes[offset.rom_base]);
        try testing.expectEqual(@as(u8, 0xBA), bytes[offset.rom_base + 1]);
        try testing.expectEqual(@as(u8, 0xDC), bytes[offset.rom_base + 2]);
        try testing.expectEqual(@as(u8, 0xFE), bytes[offset.rom_base + 3]);
    }

    test "Type0 rejects reserved interrupt-pin bytes" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        bytes[0x3D] = 5;
        const sbdf = Sbdf.from(.from(0), 0, 5, 0);
        var backend = TestConfigSpace.fromSingle(sbdf, &bytes);
        const view = Type0.from(Function.from(backend.config(), sbdf));

        try testing.expectError(error.MalformedField, view.intrPin());
    }

    fn seedType0Header(bytes: *[pcie_window_size]u8, fields: struct {
        bars: [num_bar_slots]u32,
        cardbus_cis: u32,
        subsystem_vendor: u16,
        subsystem: u16,
        rom_base: u32,
        cap_ptr: u8,
        intr_line: u8,
        intr_pin: u8,
        min_grant: u8,
        max_latency: u8,
    }) void {
        bytes.* = @splat(0);

        inline for (fields.bars, 0..) |raw, index| {
            store32(bytes, offset.bars + 4 * index, raw);
        }

        store32(bytes, offset.cardbus_cis_ptr, fields.cardbus_cis);
        store16(bytes, offset.subsystem_vendor_id, fields.subsystem_vendor);
        store16(bytes, offset.subsystem_id, fields.subsystem);
        store32(bytes, offset.rom_base, fields.rom_base);
        bytes[offset.cap_ptr] = fields.cap_ptr;
        bytes[offset.intr_line] = fields.intr_line;
        bytes[offset.intr_pin] = fields.intr_pin;
        bytes[offset.min_grant] = fields.min_grant;
        bytes[offset.max_latency] = fields.max_latency;
    }

    fn store16(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u16) void {
        bytes[byte_offset] = @truncate(value);
        bytes[byte_offset + 1] = @truncate(value >> 8);
    }

    fn store32(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u32) void {
        bytes[byte_offset] = @truncate(value);
        bytes[byte_offset + 1] = @truncate(value >> 8);
        bytes[byte_offset + 2] = @truncate(value >> 16);
        bytes[byte_offset + 3] = @truncate(value >> 24);
    }
};
