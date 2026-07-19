//! Tests for docs/specs/header/common.md.

const std = @import("std");

const pci = @import("pci");

const Bist = pci.header.Bist;
const Command = pci.header.Command;
const CommonHeader = pci.header.CommonHeader;
const Function = pci.config.Function;
const Pin = pci.interrupts.Pin;
const Sbdf = pci.core.Sbdf;
const Status = pci.header.Status;
const TestConfigSpace = pci.testing.config.TestConfigSpace;
const View = pci.header.common.View;

const pcie_window_size: usize = 0x1000;
const offset = struct {
    const vendor_id: usize = 0x00;
    const device_id: usize = 0x02;
    const command: usize = 0x04;
    const status: usize = 0x06;
    const revision_id: usize = 0x08;
    const prog_if: usize = 0x09;
    const subclass: usize = 0x0A;
    const base_class: usize = 0x0B;
    const cache_line_size: usize = 0x0C;
    const latency_timer: usize = 0x0D;
    const header_type: usize = 0x0E;
    const bist: usize = 0x0F;
    const cap_ptr: usize = 0x34;
    const interrupt_line: usize = 0x3C;
    const interrupt_pin: usize = 0x3D;
};

test "layout: CommonHeader covers the first 16 common PCI config bytes" {
    // Pins the common extern ABI by comparing public struct size and offsets with the PCI layout.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CommonHeader));
    try std.testing.expectEqual(@as(usize, 0x00), @offsetOf(CommonHeader, "vendor_id"));
    try std.testing.expectEqual(@as(usize, 0x02), @offsetOf(CommonHeader, "device_id"));
    try std.testing.expectEqual(@as(usize, 0x04), @offsetOf(CommonHeader, "command"));
    try std.testing.expectEqual(@as(usize, 0x06), @offsetOf(CommonHeader, "status"));
    try std.testing.expectEqual(@as(usize, 0x08), @offsetOf(CommonHeader, "revision_id"));
    try std.testing.expectEqual(@as(usize, 0x09), @offsetOf(CommonHeader, "prog_if"));
    try std.testing.expectEqual(@as(usize, 0x0A), @offsetOf(CommonHeader, "subclass"));
    try std.testing.expectEqual(@as(usize, 0x0B), @offsetOf(CommonHeader, "base_class"));
    try std.testing.expectEqual(@as(usize, 0x0C), @offsetOf(CommonHeader, "cache_line_size"));
    try std.testing.expectEqual(@as(usize, 0x0D), @offsetOf(CommonHeader, "latency_timer"));
    try std.testing.expectEqual(@as(usize, 0x0E), @offsetOf(CommonHeader, "header_type"));
    try std.testing.expectEqual(@as(usize, 0x0F), @offsetOf(CommonHeader, "bist"));
}

test "layout: common register constants expose absolute PCI offsets" {
    const register = pci.header.common.register;

    try std.testing.expectEqual(@as(usize, 0x00), register.vendor_id);
    try std.testing.expectEqual(@as(usize, 0x02), register.device_id);
    try std.testing.expectEqual(@as(usize, 0x04), register.command);
    try std.testing.expectEqual(@as(usize, 0x06), register.status);
    try std.testing.expectEqual(@as(usize, 0x08), register.revision_id);
    try std.testing.expectEqual(@as(usize, 0x09), register.prog_if);
    try std.testing.expectEqual(@as(usize, 0x0A), register.subclass);
    try std.testing.expectEqual(@as(usize, 0x0B), register.base_class);
    try std.testing.expectEqual(@as(usize, 0x0C), register.cache_line_size);
    try std.testing.expectEqual(@as(usize, 0x0D), register.latency_timer);
    try std.testing.expectEqual(@as(usize, 0x0E), register.header_type);
    try std.testing.expectEqual(@as(usize, 0x0F), register.bist);
    try std.testing.expectEqual(@as(usize, 0x34), register.capabilities_pointer);
    try std.testing.expectEqual(@as(usize, 0x3C), register.interrupt_line);
    try std.testing.expectEqual(@as(usize, 0x3D), register.interrupt_pin);
}

test "layout: HeaderType maps layout and multifunction bits" {
    const HeaderType = pci.header.common.HeaderType;

    try std.testing.expectEqual(@as(comptime_int, 8), @bitSizeOf(HeaderType));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(HeaderType, "layout"));
    try std.testing.expectEqual(@as(comptime_int, 7), @bitOffsetOf(HeaderType, "multifunction"));

    const decoded: HeaderType = @bitCast(@as(u8, 0x81));
    try std.testing.expectEqual(@as(u7, 0x01), decoded.layout);
    try std.testing.expect(decoded.multifunction);
    try std.testing.expectEqual(@as(u8, 0x02), (HeaderType{ .layout = 0x02 }).raw());
}

test "layout: Command maps the PCI command register bits" {
    // Pins command-register bit semantics by checking bit offsets and decoding a mixed raw word.
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(Command));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Command, "io_space"));
    try std.testing.expectEqual(@as(comptime_int, 1), @bitOffsetOf(Command, "memory_space"));
    try std.testing.expectEqual(@as(comptime_int, 2), @bitOffsetOf(Command, "bus_master"));
    try std.testing.expectEqual(@as(comptime_int, 3), @bitOffsetOf(Command, "special_cycles"));
    try std.testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(Command, "mwi_enable"));
    try std.testing.expectEqual(@as(comptime_int, 5), @bitOffsetOf(Command, "vga_palette_snoop"));
    try std.testing.expectEqual(@as(comptime_int, 6), @bitOffsetOf(Command, "parity_response"));
    try std.testing.expectEqual(@as(comptime_int, 7), @bitOffsetOf(Command, "_reserved7"));
    try std.testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(Command, "serr_enable"));
    try std.testing.expectEqual(@as(comptime_int, 9), @bitOffsetOf(Command, "fast_back_to_back"));
    try std.testing.expectEqual(@as(comptime_int, 10), @bitOffsetOf(Command, "interrupt_disable"));
    try std.testing.expectEqual(@as(comptime_int, 11), @bitOffsetOf(Command, "_reserved11"));

    const decoded: Command = @bitCast(@as(u16, 0x0557));
    try std.testing.expect(decoded.io_space);
    try std.testing.expect(decoded.memory_space);
    try std.testing.expect(decoded.bus_master);
    try std.testing.expect(!decoded.special_cycles);
    try std.testing.expect(decoded.mwi_enable);
    try std.testing.expect(!decoded.vga_palette_snoop);
    try std.testing.expect(decoded.parity_response);
    try std.testing.expectEqual(@as(u1, 0), decoded._reserved7);
    try std.testing.expect(decoded.serr_enable);
    try std.testing.expect(!decoded.fast_back_to_back);
    try std.testing.expect(decoded.interrupt_disable);
    try std.testing.expectEqual(@as(u5, 0), decoded._reserved11);
}

test "layout: Status maps PCI status bits and sticky-error mask" {
    // Pins status-register bit semantics and the sticky-error mask with a mixed raw word.
    try std.testing.expectEqual(@as(comptime_int, 16), @bitSizeOf(Status));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Status, "_reserved0"));
    try std.testing.expectEqual(@as(comptime_int, 3), @bitOffsetOf(Status, "interrupt_status"));
    try std.testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(Status, "capabilities_list"));
    try std.testing.expectEqual(@as(comptime_int, 5), @bitOffsetOf(Status, "capable_66mhz"));
    try std.testing.expectEqual(@as(comptime_int, 6), @bitOffsetOf(Status, "_reserved6"));
    try std.testing.expectEqual(@as(comptime_int, 7), @bitOffsetOf(Status, "fast_back_to_back_capable"));
    try std.testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(Status, "master_data_parity_error"));
    try std.testing.expectEqual(@as(comptime_int, 9), @bitOffsetOf(Status, "devsel_timing"));
    try std.testing.expectEqual(@as(comptime_int, 11), @bitOffsetOf(Status, "signaled_target_abort"));
    try std.testing.expectEqual(@as(comptime_int, 12), @bitOffsetOf(Status, "received_target_abort"));
    try std.testing.expectEqual(@as(comptime_int, 13), @bitOffsetOf(Status, "received_master_abort"));
    try std.testing.expectEqual(@as(comptime_int, 14), @bitOffsetOf(Status, "signaled_system_error"));
    try std.testing.expectEqual(@as(comptime_int, 15), @bitOffsetOf(Status, "detected_parity_error"));

    const decoded: Status = @bitCast(@as(u16, 0xFDB8));
    try std.testing.expect(decoded.interrupt_status);
    try std.testing.expect(decoded.capabilities_list);
    try std.testing.expect(decoded.capable_66mhz);
    try std.testing.expect(decoded.fast_back_to_back_capable);
    try std.testing.expect(decoded.master_data_parity_error);
    try std.testing.expectEqual(@as(u2, 2), decoded.devsel_timing);
    try std.testing.expect(decoded.signaled_target_abort);
    try std.testing.expect(decoded.received_target_abort);
    try std.testing.expect(decoded.received_master_abort);
    try std.testing.expect(decoded.signaled_system_error);
    try std.testing.expect(decoded.detected_parity_error);

    try std.testing.expectEqual(@as(u16, 0xF900), @as(u16, @bitCast(Status.all_sticky_errors)));
}

test "layout: Bist maps completion, start, and capable bits" {
    // Pins BIST bit semantics by decoding completion, start, and capability bits from one raw byte.
    try std.testing.expectEqual(@as(comptime_int, 8), @bitSizeOf(Bist));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(Bist, "completion_code"));
    try std.testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(Bist, "_reserved4"));
    try std.testing.expectEqual(@as(comptime_int, 6), @bitOffsetOf(Bist, "start"));
    try std.testing.expectEqual(@as(comptime_int, 7), @bitOffsetOf(Bist, "capable"));

    const decoded: Bist = @bitCast(@as(u8, 0xD7));
    try std.testing.expectEqual(@as(u4, 0x7), decoded.completion_code);
    try std.testing.expectEqual(@as(u2, 0x1), decoded._reserved4);
    try std.testing.expect(decoded.start);
    try std.testing.expect(decoded.capable);
}

test "unit: View reads every common-header field from seeded config bytes" {
    // Seeds config bytes at every common-header offset, then verifies the public view decodes them.
    var bytes: [pcie_window_size]u8 = @splat(0);
    seedCommonHeader(&bytes, .{
        .vendor = 0x1234,
        .device = 0xABCD,
        .command = 0x0557,
        .status = 0xFDB8,
        .revision = 0x42,
        .base = 0x0C,
        .sub = 0x03,
        .pif = 0x30,
        .cache_line = 0x10,
        .latency = 0x40,
        .header = 0x81,
        .bist = 0xD7,
        .capabilities = 0xA0,
        .interrupt_line = 0xFE,
        .interrupt_pin = 0x02,
    });
    const sbdf = Sbdf.of(0, 0, 1, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const view = View.init(try Function.validate(backend.configSpace(), sbdf));

    try std.testing.expectEqual(@as(u16, 0x1234), (try view.vendorId()).value);
    try std.testing.expectEqual(@as(u16, 0xABCD), (try view.deviceId()).value);
    try std.testing.expectEqual(@as(u8, 0x42), (try view.revisionId()).value);
    try std.testing.expect((try view.classCode()).eql(pci.core.ClassCode.from(0x0C, 0x03, 0x30)));
    try std.testing.expectEqual(@as(u16, 0x0557), @as(u16, @bitCast(try view.command())));
    try std.testing.expectEqual(@as(u16, 0xFDB8), @as(u16, @bitCast(try view.status())));
    try std.testing.expectEqual(@as(u8, 0x10), try view.cacheLineSize());
    try std.testing.expectEqual(@as(u8, 0x40), try view.latencyTimer());
    try std.testing.expectEqual(@as(u8, 0x81), try view.headerTypeByte());
    try std.testing.expect(try view.isMultifunction());
    try std.testing.expectEqual(@as(u8, 0xD7), @as(u8, @bitCast(try view.bist())));
    try std.testing.expectEqual(@as(u8, 0xA0), try view.capabilitiesPointer());
    try std.testing.expectEqual(@as(u8, 0xFE), try view.interruptLine());
    try std.testing.expectEqual(Pin.intb, try view.interruptPin());
}

test "unit: View writes exact common-header bytes" {
    // Writes through the public view, then checks the exact PCI config bytes and little-endian order.
    var bytes: [pcie_window_size]u8 = @splat(0xA5);
    const sbdf = Sbdf.of(0, 0, 2, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const view = View.init(Function.unchecked(backend.configSpace(), sbdf));

    try view.setCommand(@bitCast(@as(u16, 0x0557)));
    try std.testing.expectEqual(@as(u8, 0x57), bytes[offset.command]);
    try std.testing.expectEqual(@as(u8, 0x05), bytes[offset.command + 1]);

    try view.clearStatusBits(Status.all_sticky_errors);
    try std.testing.expectEqual(@as(u8, 0x00), bytes[offset.status]);
    try std.testing.expectEqual(@as(u8, 0xF9), bytes[offset.status + 1]);

    try view.setCacheLineSize(0x20);
    try std.testing.expectEqual(@as(u8, 0x20), bytes[offset.cache_line_size]);

    try view.setLatencyTimer(0x80);
    try std.testing.expectEqual(@as(u8, 0x80), bytes[offset.latency_timer]);

    try view.setBist(@bitCast(@as(u8, 0xC3)));
    try std.testing.expectEqual(@as(u8, 0xC3), bytes[offset.bist]);

    try view.setInterruptLine(0x11);
    try std.testing.expectEqual(@as(u8, 0x11), bytes[offset.interrupt_line]);
}

test "malformed: missing function is rejected by validate and not translated by View" {
    // Probes an absent SBDF to verify validation rejects it while unchecked reads expose absent bytes.
    var bytes: [pcie_window_size]u8 = @splat(0);
    seedCommonHeader(&bytes, .{ .vendor = 0x1234, .header = 0x00 });
    const present = Sbdf.of(0, 0, 3, 0);
    const missing = Sbdf.of(0, 0, 4, 0);
    var backend = TestConfigSpace.initSingle(present, &bytes);

    try std.testing.expectError(error.AbsentFunction, Function.validate(backend.configSpace(), missing));

    const view = View.init(Function.unchecked(backend.configSpace(), missing));
    try std.testing.expect((try view.vendorId()).isAbsent());
    try std.testing.expectEqual(@as(u16, 0xFFFF), (try view.deviceId()).value);
    try std.testing.expectEqual(@as(u8, 0xFF), try view.headerTypeByte());
}

test "malformed: View rejects reserved interrupt-pin bytes" {
    // Seeds the first reserved INTx pin byte and verifies typed decode reports a malformed field.
    var bytes: [pcie_window_size]u8 = @splat(0);
    seedCommonHeader(&bytes, .{ .interrupt_pin = 5 });
    const sbdf = Sbdf.of(0, 0, 5, 0);
    var backend = TestConfigSpace.initSingle(sbdf, &bytes);
    const view = View.init(Function.unchecked(backend.configSpace(), sbdf));

    try std.testing.expectError(error.MalformedField, view.interruptPin());
}

fn seedCommonHeader(bytes: *[pcie_window_size]u8, fields: struct {
    vendor: u16 = 0x1234,
    device: u16 = 0x5678,
    command: u16 = 0,
    status: u16 = 0,
    revision: u8 = 0,
    base: u8 = 0,
    sub: u8 = 0,
    pif: u8 = 0,
    cache_line: u8 = 0,
    latency: u8 = 0,
    header: u8 = 0,
    bist: u8 = 0,
    capabilities: u8 = 0,
    interrupt_line: u8 = 0,
    interrupt_pin: u8 = 0,
}) void {
    bytes.* = @splat(0);
    store16(bytes, offset.vendor_id, fields.vendor);
    store16(bytes, offset.device_id, fields.device);
    store16(bytes, offset.command, fields.command);
    store16(bytes, offset.status, fields.status);
    bytes[offset.revision_id] = fields.revision;
    bytes[offset.prog_if] = fields.pif;
    bytes[offset.subclass] = fields.sub;
    bytes[offset.base_class] = fields.base;
    bytes[offset.cache_line_size] = fields.cache_line;
    bytes[offset.latency_timer] = fields.latency;
    bytes[offset.header_type] = fields.header;
    bytes[offset.bist] = fields.bist;
    bytes[offset.cap_ptr] = fields.capabilities;
    bytes[offset.interrupt_line] = fields.interrupt_line;
    bytes[offset.interrupt_pin] = fields.interrupt_pin;
}

fn store16(bytes: *[pcie_window_size]u8, byte_offset: usize, value: u16) void {
    bytes[byte_offset] = @truncate(value);
    bytes[byte_offset + 1] = @truncate(value >> 8);
}
