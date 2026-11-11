const std = @import("std");

const stdx = @import("stdx");

const pci_bar = @import("../bar.zig");
const header = @import("../header.zig");
const ids = @import("../ids.zig");

const Bist = header.Bist.Word;
const ClassCode = ids.ClassCode;
const Command = header.Command.Word;
const DeviceId = ids.DeviceId;
const ExpansionRom = header.ExpansionRom.Word;
const HeaderWord = header.Type.Word;
const RevisionId = ids.RevisionId;
const Status = header.Status.Word;
const Struct = stdx.layout.Struct;
const VendorId = ids.VendorId;

pub const num_bar_slots: usize = 6;

pub const Header = Struct(.{ .size = 64, .alignment = 4 }, .{
    .vendor_id = .{ .type = VendorId, .offset = offsets.vendor_id },
    .device_id = .{ .type = DeviceId, .offset = offsets.device_id },
    .command = .{ .type = Command, .offset = offsets.command },
    .status = .{ .type = Status, .offset = offsets.status },
    .revision_id = .{ .type = RevisionId, .offset = offsets.revision_id },
    .class_code = .{ .type = ClassCode, .offset = offsets.class_code },
    .cache_line_size = .{ .type = u8, .offset = offsets.cache_line_size },
    .latency_timer = .{ .type = u8, .offset = offsets.latency_timer },
    .type = .{ .type = HeaderWord, .offset = offsets.type },
    .bist = .{ .type = Bist, .offset = offsets.bist },
    .bars = .{ .type = [num_bar_slots]u32, .offset = offsets.bar_base },
    .cardbus_cis_ptr = .{ .type = u32, .offset = offsets.cardbus_cis_ptr },
    .subsystem_vendor_id = .{ .type = VendorId, .offset = offsets.subsystem_vendor_id },
    .subsystem_id = .{ .type = u16, .offset = offsets.subsystem_id },
    .rom_base = .{ .type = ExpansionRom, .offset = offsets.rom_base },
    .cap_ptr = .{ .type = u8, .offset = offsets.cap_ptr },
    .intr_line = .{ .type = u8, .offset = offsets.intr_line },
    .intr_pin = .{ .type = u8, .offset = offsets.intr_pin },
    .min_grant = .{ .type = u8, .offset = offsets.min_grant },
    .max_latency = .{ .type = u8, .offset = offsets.max_latency },
});

pub const offsets = struct {
    pub const vendor_id: u8 = header.offsets.vendor_id;
    pub const device_id: u8 = header.offsets.device_id;
    pub const command: u8 = header.offsets.command;
    pub const status: u8 = header.offsets.status;
    pub const revision_id: u8 = header.offsets.revision_id;
    pub const class_code: u8 = header.offsets.class_code;
    pub const prog_if: u8 = header.offsets.prog_if;
    pub const subclass: u8 = header.offsets.subclass;
    pub const base_class: u8 = header.offsets.base_class;
    pub const cache_line_size: u8 = header.offsets.cache_line_size;
    pub const latency_timer: u8 = header.offsets.latency_timer;
    pub const @"type": u8 = header.offsets.type;
    pub const bist: u8 = header.offsets.bist;
    pub const bar_base: u8 = header.offsets.bar_base;
    pub const cardbus_cis_ptr: u8 = 0x28;
    pub const subsystem_vendor_id: u8 = 0x2C;
    pub const subsystem_id: u8 = 0x2E;
    pub const rom_base: u8 = 0x30;
    pub const cap_ptr: u8 = header.offsets.cap_ptr;
    pub const intr_line: u8 = header.offsets.intr_line;
    pub const intr_pin: u8 = header.offsets.intr_pin;
    pub const min_grant: u8 = 0x3E;
    pub const max_latency: u8 = 0x3F;
    pub const subsystem: u8 = subsystem_vendor_id;

    pub fn bar(index: usize) usize {
        std.debug.assert(index < num_bar_slots);
        return bar_base + pci_bar.stride * index;
    }
};

pub const unit = struct {
    const testing = std.testing;

    test "complete endpoint header preserves typed fields and reserved bytes" {
        var bytes = [_]u8{0xA5} ** 64;
        std.mem.writeInt(u16, bytes[0..2], 0x1234, .little);
        std.mem.writeInt(u16, bytes[2..4], 0x5678, .little);
        std.mem.writeInt(u16, bytes[4..6], 0x0007, .little);
        bytes[9] = 0x02;
        bytes[10] = 0x08;
        bytes[11] = 0x01;
        bytes[14] = 0x80;
        std.mem.writeInt(u32, bytes[0x10..0x14], 0x8000_0004, .little);
        std.mem.writeInt(u16, bytes[0x2C..0x2E], 0x1AF4, .little);
        std.mem.writeInt(u32, bytes[0x30..0x34], 0xC000_0001, .little);

        var decoded: Header = @bitCast(bytes);

        try testing.expectEqual(VendorId.from(0x1234), decoded.vendor_id);
        try testing.expectEqual(DeviceId.from(0x5678), decoded.device_id);
        try testing.expect(decoded.command.bus_master);
        try testing.expect(decoded.class_code.eql(.nvme));
        try testing.expect(decoded.type.multifunction);
        try testing.expectEqual(@as(u32, 0x8000_0004), decoded.bars[0]);
        try testing.expectEqual(VendorId.from(0x1AF4), decoded.subsystem_vendor_id);
        try testing.expect(decoded.rom_base.enable);

        decoded.command.bus_master = false;
        bytes[4] = 0x03;

        try testing.expectEqualSlices(u8, &bytes, std.mem.asBytes(&decoded));
    }
};
