const std = @import("std");
const pci = @import("pci");

const Sbdf = pci.core.Sbdf;
const StandardId = pci.core.capabilities.standard.Id;

pub const pcie_window_size = pci.core.config.extended_size;

const offset = struct {
    const vendor_id: usize = 0x00;
    const device_id: usize = 0x02;
    const command: usize = 0x04;
    const status: usize = 0x06;
    const @"type": usize = 0x0E;
    const cap_ptr: usize = 0x34;
};

pub fn seedFunction(bytes: *[pcie_window_size]u8, fields: struct {
    vendor: u16 = 0x1234,
    device: u16 = 0x5678,
    command: u16 = 0,
    status: u16 = 0,
    header: u8 = 0,
    cap_head: u8 = 0,
}) void {
    bytes.* = @splat(0);
    store16(bytes, offset.vendor_id, fields.vendor);
    store16(bytes, offset.device_id, fields.device);
    store16(bytes, offset.command, fields.command);
    store16(bytes, offset.status, fields.status);
    bytes[offset.type] = fields.header;
    bytes[offset.cap_ptr] = fields.cap_head;
}

pub fn sbdf(fields: struct {
    bus: u8,
    device: u5 = 0,
    function: u3 = 0,
}) Sbdf {
    return Sbdf.from(.from(0), fields.bus, fields.device, fields.function);
}

pub fn seedCapability(bytes: []u8, fields: struct {
    base: u8,
    id: u8,
    next: u8,
}) void {
    store16(bytes, fields.base, pci.core.capabilities.standard.Header.encode(.{
        .id = @as(StandardId, @enumFromInt(fields.id)),
        .next = fields.next,
    }));
}

pub fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
}

pub fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], value, .little);
}
