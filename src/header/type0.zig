//! Type-0 endpoint header view. Spec: docs/specs/header/type0.md.

const std = @import("std");

const common = @import("common.zig");
const config = @import("../config.zig");

const CommonView = common.View;
const ConfigSpace = config.ConfigSpace;
const Function = config.Function;

pub const bar_count: usize = 6;

const offset = struct {
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

pub const Type0Header = extern struct {
    bars: [bar_count]u32,
    cardbus_cis_pointer: u32,
    subsystem_vendor_id: u16,
    subsystem_id: u16,
    expansion_rom_base_address: u32,
    capabilities_pointer: u8,
    _reserved_0x35: [3]u8,
    _reserved_0x38: u32,
    interrupt_line: u8,
    interrupt_pin: u8,
    min_grant: u8,
    max_latency: u8,

    comptime {
        std.debug.assert(@sizeOf(Type0Header) == 48);
        std.debug.assert(@offsetOf(Type0Header, "bars") == 0x00);
        std.debug.assert(@offsetOf(Type0Header, "cardbus_cis_pointer") == 0x18);
        std.debug.assert(@offsetOf(Type0Header, "subsystem_vendor_id") == 0x1C);
        std.debug.assert(@offsetOf(Type0Header, "subsystem_id") == 0x1E);
        std.debug.assert(@offsetOf(Type0Header, "expansion_rom_base_address") == 0x20);
        std.debug.assert(@offsetOf(Type0Header, "capabilities_pointer") == 0x24);
        std.debug.assert(@offsetOf(Type0Header, "interrupt_line") == 0x2C);
        std.debug.assert(@offsetOf(Type0Header, "interrupt_pin") == 0x2D);
        std.debug.assert(@offsetOf(Type0Header, "min_grant") == 0x2E);
        std.debug.assert(@offsetOf(Type0Header, "max_latency") == 0x2F);
    }
};

pub const ExpansionRom = packed struct(u32) {
    enable: bool = false,
    _reserved1: u10 = 0,
    base_shifted: u21 = 0,
};

pub const Subsystem = struct {
    vendor_id: u16,
    id: u16,
};

pub const View = struct {
    function: Function,

    pub fn init(function: Function) View {
        return .{ .function = function };
    }

    pub fn rawBar(self: View, index: usize) ConfigSpace.Error!u32 {
        std.debug.assert(index < bar_count);
        return self.function.read32(offset.bars + 4 * index);
    }

    pub fn cardbusCisPointer(self: View) ConfigSpace.Error!u32 {
        return self.function.read32(offset.cardbus_cis_ptr);
    }

    pub fn subsystemVendorId(self: View) ConfigSpace.Error!u16 {
        return self.function.read16(offset.subsystem_vendor_id);
    }

    pub fn subsystemId(self: View) ConfigSpace.Error!u16 {
        return self.function.read16(offset.subsystem_id);
    }

    pub fn expansionRomBase(self: View) ConfigSpace.Error!ExpansionRom {
        const raw = try self.function.read32(offset.expansion_rom_base);
        return @bitCast(raw);
    }

    pub fn capabilitiesPointer(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.cap_ptr);
    }

    pub fn subsystem(self: View) ConfigSpace.Error!Subsystem {
        const raw = try self.function.read32(offset.subsystem);
        return .{
            .vendor_id = @truncate(raw),
            .id = @truncate(raw >> 16),
        };
    }

    pub fn interruptLine(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.interrupt_line);
    }

    pub fn interruptPin(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.interrupt_pin);
    }

    pub fn minGrant(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.min_grant);
    }

    pub fn maxLatency(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.max_latency);
    }

    pub fn setInterruptLine(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.interrupt_line, value);
    }

    pub fn setExpansionRomBase(self: View, value: u32) ConfigSpace.Error!void {
        return self.function.write32(offset.expansion_rom_base, value);
    }

    pub fn common(self: View) CommonView {
        return CommonView.init(self.function);
    }
};
