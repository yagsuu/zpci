//! Tests for docs/specs/header/type1.md.

const std = @import("std");

const pci = @import("pci");

const BridgeControl = pci.header.BridgeControl;
const Function = pci.config.Function;
const Pin = pci.interrupts.Pin;
const Sbdf = pci.core.Sbdf;
const Status = pci.header.Status;
const TestConfigSpace = pci.testing.config.TestConfigSpace;
const Type1Header = pci.header.Type1Header;
const View = pci.header.type1.View;

const bridge_bar_count = pci.header.type1.bridge_bar_count;
const pcie_window_size: usize = 0x1000;
const offset = struct {
    const bars: usize = 0x10;
    const primary_bus: usize = 0x18;
    const secondary_bus: usize = 0x19;
    const subordinate_bus: usize = 0x1A;
    const secondary_latency: usize = 0x1B;
    const io_base: usize = 0x1C;
    const io_limit: usize = 0x1D;
    const secondary_status: usize = 0x1E;
    const memory_base: usize = 0x20;
    const memory_limit: usize = 0x22;
    const prefetchable_memory_base: usize = 0x24;
    const prefetchable_memory_limit: usize = 0x26;
    const prefetchable_base_upper: usize = 0x28;
    const prefetchable_limit_upper: usize = 0x2C;
    const io_base_upper: usize = 0x30;
    const io_limit_upper: usize = 0x32;
    const cap_ptr: usize = 0x34;
    const expansion_rom_base: usize = 0x38;
    const interrupt_line: usize = 0x3C;
    const interrupt_pin: usize = 0x3D;
    const bridge_control: usize = 0x3E;
};

test "layout: Type1Header covers bridge-specific PCI config bytes" {
    // Pins the type-1 extern ABI by comparing public struct size and offsets with the bridge layout.
    try std.testing.expectEqual(@as(usize, 2), bridge_bar_count);
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Type1Header));
    try std.testing.expectEqual(@as(usize, 0x00), @offsetOf(Type1Header, "bars"));
    try std.testing.expectEqual(@as(usize, 0x08), @offsetOf(Type1Header, "primary_bus_number"));
    try std.testing.expectEqual(@as(usize, 0x09), @offsetOf(Type1Header, "secondary_bus_number"));
    try std.testing.expectEqual(@as(usize, 0x0A), @offsetOf(Type1Header, "subordinate_bus_number"));
    try std.testing.expectEqual(@as(usize, 0x0B), @offsetOf(Type1Header, "secondary_latency_timer"));
    try std.testing.expectEqual(@as(usize, 0x0C), @offsetOf(Type1Header, "io_base"));
    try std.testing.expectEqual(@as(usize, 0x0D), @offsetOf(Type1Header, "io_limit"));
    try std.testing.expectEqual(@as(usize, 0x0E), @offsetOf(Type1Header, "secondary_status"));
    try std.testing.expectEqual(@as(usize, 0x10), @offsetOf(Type1Header, "memory_base"));
    try std.testing.expectEqual(@as(usize, 0x12), @offsetOf(Type1Header, "memory_limit"));
    try std.testing.expectEqual(@as(usize, 0x14), @offsetOf(Type1Header, "prefetchable_memory_base"));
    try std.testing.expectEqual(@as(usize, 0x16), @offsetOf(Type1Header, "prefetchable_memory_limit"));
    try std.testing.expectEqual(@as(usize, 0x18), @offsetOf(Type1Header, "prefetchable_base_upper_32"));
    try std.testing.expectEqual(@as(usize, 0x1C), @offsetOf(Type1Header, "prefetchable_limit_upper_32"));
    try std.testing.expectEqual(@as(usize, 0x20), @offsetOf(Type1Header, "io_base_upper_16"));
    try std.testing.expectEqual(@as(usize, 0x22), @offsetOf(Type1Header, "io_limit_upper_16"));
    try std.testing.expectEqual(@as(usize, 0x24), @offsetOf(Type1Header, "capabilities_pointer"));
    try std.testing.expectEqual(@as(usize, 0x28), @offsetOf(Type1Header, "expansion_rom_base_address"));
    try std.testing.expectEqual(@as(usize, 0x2C), @offsetOf(Type1Header, "interrupt_line"));
    try std.testing.expectEqual(@as(usize, 0x2D), @offsetOf(Type1Header, "interrupt_pin"));
    try std.testing.expectEqual(@as(usize, 0x2E), @offsetOf(Type1Header, "bridge_control"));
}

test "layout: type-1 register constants expose absolute PCI offsets" {
    const register = pci.header.type1.register;

    try std.testing.expectEqual(@as(usize, 0x10), register.bar_base);
    try std.testing.expectEqual(@as(usize, 4), register.bar_stride);
    try std.testing.expectEqual(@as(usize, 0x10), register.bar(0));
    try std.testing.expectEqual(@as(usize, 0x14), register.bar(1));
    try std.testing.expectEqual(@as(usize, 0x18), register.primary_bus);
    try std.testing.expectEqual(@as(usize, 0x19), register.secondary_bus);
    try std.testing.expectEqual(@as(usize, 0x1A), register.subordinate_bus);
    try std.testing.expectEqual(@as(usize, 0x1B), register.secondary_latency);
    try std.testing.expectEqual(@as(usize, 0x1C), register.io_base);
    try std.testing.expectEqual(@as(usize, 0x1D), register.io_limit);
    try std.testing.expectEqual(@as(usize, 0x1E), register.secondary_status);
    try std.testing.expectEqual(@as(usize, 0x20), register.memory_base);
    try std.testing.expectEqual(@as(usize, 0x22), register.memory_limit);
    try std.testing.expectEqual(@as(usize, 0x24), register.prefetchable_memory_base);
    try std.testing.expectEqual(@as(usize, 0x26), register.prefetchable_memory_limit);
    try std.testing.expectEqual(@as(usize, 0x28), register.prefetchable_base_upper);
    try std.testing.expectEqual(@as(usize, 0x2C), register.prefetchable_limit_upper);
    try std.testing.expectEqual(@as(usize, 0x30), register.io_base_upper);
    try std.testing.expectEqual(@as(usize, 0x32), register.io_limit_upper);
    try std.testing.expectEqual(@as(usize, 0x34), register.capabilities_pointer);
    try std.testing.expectEqual(@as(usize, 0x38), register.expansion_rom_base);
    try std.testing.expectEqual(@as(usize, 0x3C), register.interrupt_line);
    try std.testing.expectEqual(@as(usize, 0x3D), register.interrupt_pin);
    try std.testing.expectEqual(@as(usize, 0x3E), register.bridge_control);
}

test "layout: BridgeControl maps parity response and timer bits" {
    // Pins bridge-control bit semantics by decoding a mixed raw word and round-tripping it.
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(BridgeControl));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(BridgeControl, "parity_response"));
    try std.testing.expectEqual(@as(comptime_int, 1), @bitOffsetOf(BridgeControl, "serr_enable"));
    try std.testing.expectEqual(@as(comptime_int, 2), @bitOffsetOf(BridgeControl, "isa_enable"));
    try std.testing.expectEqual(@as(comptime_int, 3), @bitOffsetOf(BridgeControl, "vga_enable"));
    try std.testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(BridgeControl, "vga_16bit_decode"));
    try std.testing.expectEqual(@as(comptime_int, 5), @bitOffsetOf(BridgeControl, "master_abort_mode"));
    try std.testing.expectEqual(@as(comptime_int, 6), @bitOffsetOf(BridgeControl, "secondary_bus_reset"));
    try std.testing.expectEqual(@as(comptime_int, 7), @bitOffsetOf(BridgeControl, "fast_back_to_back_enable"));
    try std.testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(BridgeControl, "primary_discard_timer"));
    try std.testing.expectEqual(@as(comptime_int, 9), @bitOffsetOf(BridgeControl, "secondary_discard_timer"));
    try std.testing.expectEqual(@as(comptime_int, 10), @bitOffsetOf(BridgeControl, "discard_timer_status"));
    try std.testing.expectEqual(@as(comptime_int, 11), @bitOffsetOf(BridgeControl, "discard_timer_serr_enable"));
    try std.testing.expectEqual(@as(comptime_int, 12), @bitOffsetOf(BridgeControl, "_reserved12"));

    const raw: u16 = 0xAD53;
    const decoded: BridgeControl = @bitCast(raw);
    try std.testing.expect(decoded.parity_response);
    try std.testing.expect(decoded.serr_enable);
    try std.testing.expect(!decoded.isa_enable);
    try std.testing.expect(!decoded.vga_enable);
    try std.testing.expect(decoded.vga_16bit_decode);
    try std.testing.expect(!decoded.master_abort_mode);
    try std.testing.expect(decoded.secondary_bus_reset);
    try std.testing.expect(!decoded.fast_back_to_back_enable);
    try std.testing.expect(decoded.primary_discard_timer);
    try std.testing.expect(!decoded.secondary_discard_timer);
    try std.testing.expect(decoded.discard_timer_status);
    try std.testing.expect(decoded.discard_timer_serr_enable);
    try std.testing.expectEqual(@as(u4, 0xA), decoded._reserved12);
    try std.testing.expectEqual(raw, @as(u16, @bitCast(decoded)));
}

test "unit: View reads every type-1 bridge field from seeded config bytes" {
    // Seeds config bytes at every bridge offset, then verifies the public view decodes them.
    const bars = [_]u32{ 0x1000_0004, 0x2000_0008 };
    var bytes: [pcie_window_size]u8 = @splat(0);
    seedType1Header(&bytes, .{
        .bars = bars,
        .primary_bus = 0x01,
        .secondary_bus = 0x02,
        .subordinate_bus = 0x20,
        .secondary_latency = 0x40,
        .io_base = 0x51,
        .io_limit = 0xF1,
        .secondary_status = 0xFDB8,
        .memory_base = 0x8000,
        .memory_limit = 0x8FFF,
        .prefetchable_memory_base = 0x9001,
        .prefetchable_memory_limit = 0x9FF1,
        .prefetchable_base_upper = 0x0000_000A,
        .prefetchable_limit_upper = 0x0000_000B,
        .io_base_upper = 0x1234,
        .io_limit_upper = 0x5678,
        .capabilities = 0xA0,
        .expansion_rom = 0xC000_0801,
        .interrupt_line = 0xFE,
        .interrupt_pin = 0x01,
        .bridge_control = 0xAD53,
    });
    const sbdf = Sbdf.of(0, 0, 1, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const view = View.init(Function.unchecked(backend.configSpace(), sbdf));

    inline for (bars, 0..) |expected, index| {
        try std.testing.expectEqual(expected, try view.rawBar(index));
    }

    try std.testing.expectEqual(@as(u8, 0x01), try view.primaryBus());
    try std.testing.expectEqual(@as(u8, 0x02), try view.secondaryBus());
    try std.testing.expectEqual(@as(u8, 0x20), try view.subordinateBus());
    try std.testing.expectEqual(@as(u8, 0x40), try view.secondaryLatencyTimer());
    try std.testing.expectEqual(@as(u8, 0x51), try view.ioBase());
    try std.testing.expectEqual(@as(u8, 0xF1), try view.ioLimit());
    try std.testing.expectEqual(@as(u16, 0xFDB8), @as(u16, @bitCast(try view.secondaryStatus())));
    try std.testing.expectEqual(@as(u16, 0x8000), try view.memoryBase());
    try std.testing.expectEqual(@as(u16, 0x8FFF), try view.memoryLimit());
    try std.testing.expectEqual(@as(u16, 0x9001), try view.prefetchableMemoryBase());
    try std.testing.expectEqual(@as(u16, 0x9FF1), try view.prefetchableMemoryLimit());
    try std.testing.expectEqual(@as(u32, 0x0000_000A), try view.prefetchableBaseUpper());
    try std.testing.expectEqual(@as(u32, 0x0000_000B), try view.prefetchableLimitUpper());
    try std.testing.expectEqual(@as(u16, 0x1234), try view.ioBaseUpper());
    try std.testing.expectEqual(@as(u16, 0x5678), try view.ioLimitUpper());
    try std.testing.expectEqual(@as(u8, 0xA0), try view.capabilitiesPointer());
    try std.testing.expectEqual(@as(u32, 0xC000_0801), try view.expansionRomBase());
    try std.testing.expectEqual(@as(u8, 0xFE), try view.interruptLine());
    try std.testing.expectEqual(Pin.inta, try view.interruptPin());
    try std.testing.expectEqual(@as(u16, 0xAD53), @as(u16, @bitCast(try view.bridgeControl())));
}

test "unit: View writes exact type-1 bridge bytes" {
    // Writes through the public view, then checks the exact bridge bytes and little-endian order.
    var bytes: [pcie_window_size]u8 = @splat(0xA5);
    const sbdf = Sbdf.of(0, 0, 2, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const view = View.init(Function.unchecked(backend.configSpace(), sbdf));

    try view.setPrimaryBus(0x11);
    try std.testing.expectEqual(@as(u8, 0x11), bytes[offset.primary_bus]);

    try view.setSecondaryBus(0x22);
    try std.testing.expectEqual(@as(u8, 0x22), bytes[offset.secondary_bus]);

    try view.setSubordinateBus(0x33);
    try std.testing.expectEqual(@as(u8, 0x33), bytes[offset.subordinate_bus]);

    try view.setSecondaryLatencyTimer(0x44);
    try std.testing.expectEqual(@as(u8, 0x44), bytes[offset.secondary_latency]);

    try view.setIoBase(0x55);
    try std.testing.expectEqual(@as(u8, 0x55), bytes[offset.io_base]);

    try view.setIoLimit(0x66);
    try std.testing.expectEqual(@as(u8, 0x66), bytes[offset.io_limit]);

    try view.setIoBaseUpper(0x7788);
    try std.testing.expectEqual(@as(u8, 0x88), bytes[offset.io_base_upper]);
    try std.testing.expectEqual(@as(u8, 0x77), bytes[offset.io_base_upper + 1]);

    try view.setIoLimitUpper(0x99AA);
    try std.testing.expectEqual(@as(u8, 0xAA), bytes[offset.io_limit_upper]);
    try std.testing.expectEqual(@as(u8, 0x99), bytes[offset.io_limit_upper + 1]);

    try view.setMemoryBase(0xBBCD);
    try std.testing.expectEqual(@as(u8, 0xCD), bytes[offset.memory_base]);
    try std.testing.expectEqual(@as(u8, 0xBB), bytes[offset.memory_base + 1]);

    try view.setMemoryLimit(0xDDEF);
    try std.testing.expectEqual(@as(u8, 0xEF), bytes[offset.memory_limit]);
    try std.testing.expectEqual(@as(u8, 0xDD), bytes[offset.memory_limit + 1]);

    try view.setPrefetchableMemoryBase(0x1357);
    try std.testing.expectEqual(@as(u8, 0x57), bytes[offset.prefetchable_memory_base]);
    try std.testing.expectEqual(@as(u8, 0x13), bytes[offset.prefetchable_memory_base + 1]);

    try view.setPrefetchableMemoryLimit(0x2468);
    try std.testing.expectEqual(@as(u8, 0x68), bytes[offset.prefetchable_memory_limit]);
    try std.testing.expectEqual(@as(u8, 0x24), bytes[offset.prefetchable_memory_limit + 1]);

    try view.setPrefetchableBaseUpper(0x89AB_CDEF);
    try std.testing.expectEqual(@as(u8, 0xEF), bytes[offset.prefetchable_base_upper]);
    try std.testing.expectEqual(@as(u8, 0xCD), bytes[offset.prefetchable_base_upper + 1]);
    try std.testing.expectEqual(@as(u8, 0xAB), bytes[offset.prefetchable_base_upper + 2]);
    try std.testing.expectEqual(@as(u8, 0x89), bytes[offset.prefetchable_base_upper + 3]);

    try view.setPrefetchableLimitUpper(0x0123_4567);
    try std.testing.expectEqual(@as(u8, 0x67), bytes[offset.prefetchable_limit_upper]);
    try std.testing.expectEqual(@as(u8, 0x45), bytes[offset.prefetchable_limit_upper + 1]);
    try std.testing.expectEqual(@as(u8, 0x23), bytes[offset.prefetchable_limit_upper + 2]);
    try std.testing.expectEqual(@as(u8, 0x01), bytes[offset.prefetchable_limit_upper + 3]);

    try view.clearSecondaryStatus(Status.all_sticky_errors);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[offset.secondary_status]);
    try std.testing.expectEqual(@as(u8, 0xF9), bytes[offset.secondary_status + 1]);

    try view.setInterruptLine(0xEE);
    try std.testing.expectEqual(@as(u8, 0xEE), bytes[offset.interrupt_line]);

    try view.setExpansionRomBase(0x7654_3210);
    try std.testing.expectEqual(@as(u8, 0x10), bytes[offset.expansion_rom_base]);
    try std.testing.expectEqual(@as(u8, 0x32), bytes[offset.expansion_rom_base + 1]);
    try std.testing.expectEqual(@as(u8, 0x54), bytes[offset.expansion_rom_base + 2]);
    try std.testing.expectEqual(@as(u8, 0x76), bytes[offset.expansion_rom_base + 3]);

    try view.setBridgeControl(@bitCast(@as(u16, 0xAD53)));
    try std.testing.expectEqual(@as(u8, 0x53), bytes[offset.bridge_control]);
    try std.testing.expectEqual(@as(u8, 0xAD), bytes[offset.bridge_control + 1]);
}

fn seedType1Header(bytes: *[pcie_window_size]u8, fields: struct {
    bars: [bridge_bar_count]u32,
    primary_bus: u8,
    secondary_bus: u8,
    subordinate_bus: u8,
    secondary_latency: u8,
    io_base: u8,
    io_limit: u8,
    secondary_status: u16,
    memory_base: u16,
    memory_limit: u16,
    prefetchable_memory_base: u16,
    prefetchable_memory_limit: u16,
    prefetchable_base_upper: u32,
    prefetchable_limit_upper: u32,
    io_base_upper: u16,
    io_limit_upper: u16,
    capabilities: u8,
    expansion_rom: u32,
    interrupt_line: u8,
    interrupt_pin: u8,
    bridge_control: u16,
}) void {
    bytes.* = @splat(0);

    inline for (fields.bars, 0..) |raw, index| {
        store32(bytes, offset.bars + 4 * index, raw);
    }

    bytes[offset.primary_bus] = fields.primary_bus;
    bytes[offset.secondary_bus] = fields.secondary_bus;
    bytes[offset.subordinate_bus] = fields.subordinate_bus;
    bytes[offset.secondary_latency] = fields.secondary_latency;
    bytes[offset.io_base] = fields.io_base;
    bytes[offset.io_limit] = fields.io_limit;
    store16(bytes, offset.secondary_status, fields.secondary_status);
    store16(bytes, offset.memory_base, fields.memory_base);
    store16(bytes, offset.memory_limit, fields.memory_limit);
    store16(bytes, offset.prefetchable_memory_base, fields.prefetchable_memory_base);
    store16(bytes, offset.prefetchable_memory_limit, fields.prefetchable_memory_limit);
    store32(bytes, offset.prefetchable_base_upper, fields.prefetchable_base_upper);
    store32(bytes, offset.prefetchable_limit_upper, fields.prefetchable_limit_upper);
    store16(bytes, offset.io_base_upper, fields.io_base_upper);
    store16(bytes, offset.io_limit_upper, fields.io_limit_upper);
    bytes[offset.cap_ptr] = fields.capabilities;
    store32(bytes, offset.expansion_rom_base, fields.expansion_rom);
    bytes[offset.interrupt_line] = fields.interrupt_line;
    bytes[offset.interrupt_pin] = fields.interrupt_pin;
    store16(bytes, offset.bridge_control, fields.bridge_control);
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
