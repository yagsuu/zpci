//! Tests for docs/specs/header/type0.md.

const std = @import("std");

const pci = @import("pci");

const ExpansionRom = pci.header.ExpansionRom;
const Function = pci.config.Function;
const Sbdf = pci.core.Sbdf;
const Subsystem = pci.header.Subsystem;
const TestConfigSpace = pci.testing.config.TestConfigSpace;
const Type0Header = pci.header.Type0Header;
const View = pci.header.type0.View;

const bar_count = pci.header.type0.bar_count;
const function_window_size: usize = 0x1000;
const offset = struct {
    const vendor_id: usize = 0x00;
    const bars: usize = 0x10;
    const cardbus_cis_ptr: usize = 0x28;
    const subsystem: usize = 0x2C;
    const subsystem_vendor_id: usize = 0x2C;
    const subsystem_id: usize = 0x2E;
    const expansion_rom_base: usize = 0x30;
    const cap_ptr: usize = 0x34;
    const interrupt_line: usize = 0x3C;
    const interrupt_pin: usize = 0x3D;
    const min_grant: usize = 0x3E;
    const max_latency: usize = 0x3F;
};

test "layout: Type0Header covers endpoint-specific PCI config bytes" {
    // Pins the type-0 extern ABI by comparing public struct size and offsets with the endpoint layout.
    try std.testing.expectEqual(@as(usize, 6), bar_count);
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Type0Header));
    try std.testing.expectEqual(@as(usize, 0x00), @offsetOf(Type0Header, "bars"));
    try std.testing.expectEqual(@as(usize, 0x18), @offsetOf(Type0Header, "cardbus_cis_pointer"));
    try std.testing.expectEqual(@as(usize, 0x1C), @offsetOf(Type0Header, "subsystem_vendor_id"));
    try std.testing.expectEqual(@as(usize, 0x1E), @offsetOf(Type0Header, "subsystem_id"));
    try std.testing.expectEqual(@as(usize, 0x20), @offsetOf(Type0Header, "expansion_rom_base_address"));
    try std.testing.expectEqual(@as(usize, 0x24), @offsetOf(Type0Header, "capabilities_pointer"));
    try std.testing.expectEqual(@as(usize, 0x2C), @offsetOf(Type0Header, "interrupt_line"));
    try std.testing.expectEqual(@as(usize, 0x2D), @offsetOf(Type0Header, "interrupt_pin"));
    try std.testing.expectEqual(@as(usize, 0x2E), @offsetOf(Type0Header, "min_grant"));
    try std.testing.expectEqual(@as(usize, 0x2F), @offsetOf(Type0Header, "max_latency"));
}

test "layout: ExpansionRom maps enable and base address bits" {
    // Pins expansion-ROM bit semantics by decoding enable, reserved, and shifted-base fields.
    try std.testing.expectEqual(@as(comptime_int, 32), @bitSizeOf(ExpansionRom));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(ExpansionRom, "enable"));
    try std.testing.expectEqual(@as(comptime_int, 1), @bitOffsetOf(ExpansionRom, "_reserved1"));
    try std.testing.expectEqual(@as(comptime_int, 11), @bitOffsetOf(ExpansionRom, "base_shifted"));

    const raw: u32 = 0xD5E6_5AAB;
    const decoded: ExpansionRom = @bitCast(raw);
    try std.testing.expect(decoded.enable);
    try std.testing.expectEqual(@as(u10, 0x155), decoded._reserved1);
    try std.testing.expectEqual(@as(u21, 0x1ABC_CB), decoded.base_shifted);
    try std.testing.expectEqual(raw, @as(u32, @bitCast(decoded)));
}

test "unit: View reads every type-0 endpoint field from seeded config bytes" {
    // Seeds config bytes at every endpoint offset, then verifies the public view decodes them.
    const bars = [_]u32{
        0x1000_0004,
        0x2000_0000,
        0x3000_0008,
        0x4000_000C,
        0x5000_0010,
        0x6000_0014,
    };
    var bytes: [function_window_size]u8 = @splat(0);
    seedType0Header(&bytes, .{
        .bars = bars,
        .cardbus_cis = 0xCAFE_BABE,
        .subsystem_vendor = 0x1AF4,
        .subsystem = 0x1042,
        .expansion_rom = 0xD5E6_5AAB,
        .capabilities = 0x90,
        .interrupt_line = 0xFE,
        .interrupt_pin = 0x03,
        .min_grant = 0x11,
        .max_latency = 0x22,
    });
    const sbdf = Sbdf.of(0, 0, 1, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const view = View.init(Function.unchecked(backend.configSpace(), sbdf));

    inline for (bars, 0..) |expected, index| {
        try std.testing.expectEqual(expected, try view.rawBar(index));
    }

    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try view.cardbusCisPointer());
    try std.testing.expectEqual(@as(u16, 0x1AF4), try view.subsystemVendorId());
    try std.testing.expectEqual(@as(u16, 0x1042), try view.subsystemId());
    try std.testing.expectEqual(Subsystem{ .vendor_id = 0x1AF4, .id = 0x1042 }, try view.subsystem());
    try std.testing.expectEqual(@as(u32, 0xD5E6_5AAB), @as(u32, @bitCast(try view.expansionRomBase())));
    try std.testing.expectEqual(@as(u8, 0x90), try view.capabilitiesPointer());
    try std.testing.expectEqual(@as(u8, 0xFE), try view.interruptLine());
    try std.testing.expectEqual(@as(u8, 0x03), try view.interruptPin());
    try std.testing.expectEqual(@as(u8, 0x11), try view.minGrant());
    try std.testing.expectEqual(@as(u8, 0x22), try view.maxLatency());
}

test "unit: View writes exact type-0 endpoint bytes" {
    // Writes through the public view, then checks the exact endpoint bytes and little-endian order.
    var bytes: [function_window_size]u8 = @splat(0xA5);
    const sbdf = Sbdf.of(0, 0, 2, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const view = View.init(Function.unchecked(backend.configSpace(), sbdf));

    try view.setInterruptLine(0x44);
    try std.testing.expectEqual(@as(u8, 0x44), bytes[offset.interrupt_line]);

    try view.setExpansionRomBase(0xFEDC_BA98);
    try std.testing.expectEqual(@as(u8, 0x98), bytes[offset.expansion_rom_base]);
    try std.testing.expectEqual(@as(u8, 0xBA), bytes[offset.expansion_rom_base + 1]);
    try std.testing.expectEqual(@as(u8, 0xDC), bytes[offset.expansion_rom_base + 2]);
    try std.testing.expectEqual(@as(u8, 0xFE), bytes[offset.expansion_rom_base + 3]);
}

test "unit: common returns a common-header view over the same function" {
    // Reads a common-header field through the type-0 view to verify it preserves the same function.
    var bytes: [function_window_size]u8 = @splat(0);
    store16(&bytes, offset.vendor_id, 0x1234);
    const sbdf = Sbdf.of(0, 0, 3, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const view = View.init(Function.unchecked(backend.configSpace(), sbdf));

    try std.testing.expectEqual(@as(u16, 0x1234), (try view.common().vendorId()).value);
}

fn seedType0Header(bytes: *[function_window_size]u8, fields: struct {
    bars: [bar_count]u32,
    cardbus_cis: u32,
    subsystem_vendor: u16,
    subsystem: u16,
    expansion_rom: u32,
    capabilities: u8,
    interrupt_line: u8,
    interrupt_pin: u8,
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
    store32(bytes, offset.expansion_rom_base, fields.expansion_rom);
    bytes[offset.cap_ptr] = fields.capabilities;
    bytes[offset.interrupt_line] = fields.interrupt_line;
    bytes[offset.interrupt_pin] = fields.interrupt_pin;
    bytes[offset.min_grant] = fields.min_grant;
    bytes[offset.max_latency] = fields.max_latency;
}

fn store16(bytes: *[function_window_size]u8, byte_offset: usize, value: u16) void {
    bytes[byte_offset] = @truncate(value);
    bytes[byte_offset + 1] = @truncate(value >> 8);
}

fn store32(bytes: *[function_window_size]u8, byte_offset: usize, value: u32) void {
    bytes[byte_offset] = @truncate(value);
    bytes[byte_offset + 1] = @truncate(value >> 8);
    bytes[byte_offset + 2] = @truncate(value >> 16);
    bytes[byte_offset + 3] = @truncate(value >> 24);
}
