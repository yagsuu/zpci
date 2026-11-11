const std = @import("std");

const stdx = @import("stdx");

const pci_bar = @import("../bar.zig");
const header = @import("../header.zig");
const ids = @import("../ids.zig");

const Bist = header.Bist.Word;
const BridgeControl = header.BridgeControl.Word;
const ClassCode = ids.ClassCode;
const Command = header.Command.Word;
const DeviceId = ids.DeviceId;
const ExpansionRom = header.ExpansionRom.Word;
const HeaderWord = header.Type.Word;
const RevisionId = ids.RevisionId;
const Status = header.Status.Word;
const Struct = stdx.layout.Struct;
const VendorId = ids.VendorId;

pub const num_bar_slots: usize = 2;

pub const Header = blk: {
    @setEvalBranchQuota(10_000);

    break :blk Struct(.{ .size = 64, .alignment = 4 }, .{
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
        .primary_bus = .{ .type = u8, .offset = offsets.primary_bus },
        .secondary_bus = .{ .type = u8, .offset = offsets.secondary_bus },
        .subordinate_bus = .{ .type = u8, .offset = offsets.subordinate_bus },
        .secondary_latency_timer = .{ .type = u8, .offset = offsets.secondary_latency_timer },
        .io_base_lo = .{ .type = u8, .offset = offsets.io_base_lo },
        .io_limit_lo = .{ .type = u8, .offset = offsets.io_limit_lo },
        .secondary_status = .{ .type = Status, .offset = offsets.secondary_status },
        .mem_base = .{ .type = u16, .offset = offsets.mem_base },
        .mem_limit = .{ .type = u16, .offset = offsets.mem_limit },
        .prefetch_base_lo = .{ .type = u16, .offset = offsets.prefetch_base_lo },
        .prefetch_limit_lo = .{ .type = u16, .offset = offsets.prefetch_limit_lo },
        .prefetch_base_hi = .{ .type = u32, .offset = offsets.prefetch_base_hi },
        .prefetch_limit_hi = .{ .type = u32, .offset = offsets.prefetch_limit_hi },
        .io_base_hi = .{ .type = u16, .offset = offsets.io_base_hi },
        .io_limit_hi = .{ .type = u16, .offset = offsets.io_limit_hi },
        .cap_ptr = .{ .type = u8, .offset = offsets.cap_ptr },
        .rom_base = .{ .type = ExpansionRom, .offset = offsets.rom_base },
        .intr_line = .{ .type = u8, .offset = offsets.intr_line },
        .intr_pin = .{ .type = u8, .offset = offsets.intr_pin },
        .bridge_control = .{ .type = BridgeControl, .offset = offsets.bridge_control },
    });
};

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
    pub const primary_bus: u8 = 0x18;
    pub const secondary_bus: u8 = 0x19;
    pub const subordinate_bus: u8 = 0x1A;
    pub const secondary_latency_timer: u8 = 0x1B;
    pub const io_base_lo: u8 = 0x1C;
    pub const io_limit_lo: u8 = 0x1D;
    pub const secondary_status: u8 = 0x1E;
    pub const mem_base: u8 = 0x20;
    pub const mem_limit: u8 = 0x22;
    pub const prefetch_base_lo: u8 = 0x24;
    pub const prefetch_limit_lo: u8 = 0x26;
    pub const prefetch_base_hi: u8 = 0x28;
    pub const prefetch_limit_hi: u8 = 0x2C;
    pub const io_base_hi: u8 = 0x30;
    pub const io_limit_hi: u8 = 0x32;
    pub const cap_ptr: u8 = header.offsets.cap_ptr;
    pub const rom_base: u8 = 0x38;
    pub const intr_line: u8 = header.offsets.intr_line;
    pub const intr_pin: u8 = header.offsets.intr_pin;
    pub const bridge_control: u8 = 0x3E;

    pub fn bar(index: usize) usize {
        std.debug.assert(index < num_bar_slots);
        return bar_base + pci_bar.stride * index;
    }
};

pub const unit = struct {
    const testing = std.testing;

    test "complete bridge header separates bus, window, and ROM registers" {
        var bytes = [_]u8{0} ** 64;
        bytes[0x18] = 1;
        bytes[0x19] = 2;
        bytes[0x1A] = 7;
        bytes[0x35] = 0xA5;
        bytes[0x36] = 0x5A;
        bytes[0x37] = 0xC3;
        std.mem.writeInt(u16, bytes[0x1E..0x20], 0x8000, .little);
        std.mem.writeInt(u32, bytes[0x28..0x2C], 0x0123_4567, .little);
        std.mem.writeInt(u32, bytes[0x38..0x3C], 0xD000_0001, .little);
        std.mem.writeInt(u16, bytes[0x3E..0x40], 0x0040, .little);

        var decoded: Header = @bitCast(bytes);

        try testing.expectEqual(@as(u8, 1), decoded.primary_bus);
        try testing.expectEqual(@as(u8, 2), decoded.secondary_bus);
        try testing.expectEqual(@as(u8, 7), decoded.subordinate_bus);
        try testing.expect(decoded.secondary_status.detected_parity_error);
        try testing.expectEqual(@as(u32, 0x0123_4567), decoded.prefetch_base_hi);
        try testing.expect(decoded.rom_base.enable);
        try testing.expect(decoded.bridge_control.secondary_bus_reset);

        decoded.subordinate_bus = 9;
        bytes[0x1A] = 9;

        try testing.expectEqualSlices(u8, &bytes, std.mem.asBytes(&decoded));
    }
};
