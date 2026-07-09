//! Type-1 bridge header view. Spec: docs/specs/header/type1.md.

const std = @import("std");

const common = @import("common.zig");
const config = @import("../config.zig");

const CommonStatus = common.Status;
const ConfigSpace = config.ConfigSpace;
const Function = config.Function;

pub const bridge_bar_count: usize = 2;

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

pub const Type1Header = extern struct {
    bars: [bridge_bar_count]u32,
    primary_bus_number: u8,
    secondary_bus_number: u8,
    subordinate_bus_number: u8,
    secondary_latency_timer: u8,
    io_base: u8,
    io_limit: u8,
    secondary_status: u16,
    memory_base: u16,
    memory_limit: u16,
    prefetchable_memory_base: u16,
    prefetchable_memory_limit: u16,
    prefetchable_base_upper_32: u32,
    prefetchable_limit_upper_32: u32,
    io_base_upper_16: u16,
    io_limit_upper_16: u16,
    capabilities_pointer: u8,
    _reserved_0x35: [3]u8,
    expansion_rom_base_address: u32,
    interrupt_line: u8,
    interrupt_pin: u8,
    bridge_control: u16,

    comptime {
        std.debug.assert(@sizeOf(Type1Header) == 48);
        std.debug.assert(@offsetOf(Type1Header, "bars") == 0x00);
        std.debug.assert(@offsetOf(Type1Header, "primary_bus_number") == 0x08);
        std.debug.assert(@offsetOf(Type1Header, "secondary_bus_number") == 0x09);
        std.debug.assert(@offsetOf(Type1Header, "subordinate_bus_number") == 0x0A);
        std.debug.assert(@offsetOf(Type1Header, "secondary_latency_timer") == 0x0B);
        std.debug.assert(@offsetOf(Type1Header, "io_base") == 0x0C);
        std.debug.assert(@offsetOf(Type1Header, "io_limit") == 0x0D);
        std.debug.assert(@offsetOf(Type1Header, "secondary_status") == 0x0E);
        std.debug.assert(@offsetOf(Type1Header, "memory_base") == 0x10);
        std.debug.assert(@offsetOf(Type1Header, "memory_limit") == 0x12);
        std.debug.assert(@offsetOf(Type1Header, "prefetchable_memory_base") == 0x14);
        std.debug.assert(@offsetOf(Type1Header, "prefetchable_memory_limit") == 0x16);
        std.debug.assert(@offsetOf(Type1Header, "prefetchable_base_upper_32") == 0x18);
        std.debug.assert(@offsetOf(Type1Header, "prefetchable_limit_upper_32") == 0x1C);
        std.debug.assert(@offsetOf(Type1Header, "io_base_upper_16") == 0x20);
        std.debug.assert(@offsetOf(Type1Header, "io_limit_upper_16") == 0x22);
        std.debug.assert(@offsetOf(Type1Header, "capabilities_pointer") == 0x24);
        std.debug.assert(@offsetOf(Type1Header, "expansion_rom_base_address") == 0x28);
        std.debug.assert(@offsetOf(Type1Header, "interrupt_line") == 0x2C);
        std.debug.assert(@offsetOf(Type1Header, "interrupt_pin") == 0x2D);
        std.debug.assert(@offsetOf(Type1Header, "bridge_control") == 0x2E);
    }
};

pub const BridgeControl = packed struct(u16) {
    parity_response: bool = false,
    serr_enable: bool = false,
    isa_enable: bool = false,
    vga_enable: bool = false,
    vga_16bit_decode: bool = false,
    master_abort_mode: bool = false,
    secondary_bus_reset: bool = false,
    fast_back_to_back_enable: bool = false,
    primary_discard_timer: bool = false,
    secondary_discard_timer: bool = false,
    discard_timer_status: bool = false,
    discard_timer_serr_enable: bool = false,
    _reserved12: u4 = 0,
};

pub const View = struct {
    function: Function,

    pub fn init(function: Function) View {
        return .{ .function = function };
    }

    pub fn rawBar(self: View, index: usize) ConfigSpace.Error!u32 {
        std.debug.assert(index < bridge_bar_count);
        return self.function.read32(offset.bars + 4 * index);
    }

    pub fn primaryBus(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.primary_bus);
    }

    pub fn secondaryBus(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.secondary_bus);
    }

    pub fn subordinateBus(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.subordinate_bus);
    }

    pub fn secondaryLatencyTimer(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.secondary_latency);
    }

    pub fn ioBase(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.io_base);
    }

    pub fn ioLimit(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.io_limit);
    }

    pub fn ioBaseUpper(self: View) ConfigSpace.Error!u16 {
        return self.function.read16(offset.io_base_upper);
    }

    pub fn ioLimitUpper(self: View) ConfigSpace.Error!u16 {
        return self.function.read16(offset.io_limit_upper);
    }

    pub fn secondaryStatus(self: View) ConfigSpace.Error!CommonStatus {
        const raw = try self.function.read16(offset.secondary_status);
        return @bitCast(raw);
    }

    pub fn memoryBase(self: View) ConfigSpace.Error!u16 {
        return self.function.read16(offset.memory_base);
    }

    pub fn memoryLimit(self: View) ConfigSpace.Error!u16 {
        return self.function.read16(offset.memory_limit);
    }

    pub fn prefetchableMemoryBase(self: View) ConfigSpace.Error!u16 {
        return self.function.read16(offset.prefetchable_memory_base);
    }

    pub fn prefetchableMemoryLimit(self: View) ConfigSpace.Error!u16 {
        return self.function.read16(offset.prefetchable_memory_limit);
    }

    pub fn prefetchableBaseUpper(self: View) ConfigSpace.Error!u32 {
        return self.function.read32(offset.prefetchable_base_upper);
    }

    pub fn prefetchableLimitUpper(self: View) ConfigSpace.Error!u32 {
        return self.function.read32(offset.prefetchable_limit_upper);
    }

    pub fn capabilitiesPointer(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.cap_ptr);
    }

    pub fn expansionRomBase(self: View) ConfigSpace.Error!u32 {
        return self.function.read32(offset.expansion_rom_base);
    }

    pub fn interruptLine(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.interrupt_line);
    }

    pub fn interruptPin(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.interrupt_pin);
    }

    pub fn bridgeControl(self: View) ConfigSpace.Error!BridgeControl {
        const raw = try self.function.read16(offset.bridge_control);
        return @bitCast(raw);
    }

    pub fn setPrimaryBus(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.primary_bus, value);
    }

    pub fn setSecondaryBus(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.secondary_bus, value);
    }

    pub fn setSubordinateBus(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.subordinate_bus, value);
    }

    pub fn setSecondaryLatencyTimer(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.secondary_latency, value);
    }

    pub fn setIoBase(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.io_base, value);
    }

    pub fn setIoLimit(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.io_limit, value);
    }

    pub fn setIoBaseUpper(self: View, value: u16) ConfigSpace.Error!void {
        return self.function.write16(offset.io_base_upper, value);
    }

    pub fn setIoLimitUpper(self: View, value: u16) ConfigSpace.Error!void {
        return self.function.write16(offset.io_limit_upper, value);
    }

    pub fn setMemoryBase(self: View, value: u16) ConfigSpace.Error!void {
        return self.function.write16(offset.memory_base, value);
    }

    pub fn setMemoryLimit(self: View, value: u16) ConfigSpace.Error!void {
        return self.function.write16(offset.memory_limit, value);
    }

    pub fn setPrefetchableMemoryBase(self: View, value: u16) ConfigSpace.Error!void {
        return self.function.write16(offset.prefetchable_memory_base, value);
    }

    pub fn setPrefetchableMemoryLimit(self: View, value: u16) ConfigSpace.Error!void {
        return self.function.write16(offset.prefetchable_memory_limit, value);
    }

    pub fn setPrefetchableBaseUpper(self: View, value: u32) ConfigSpace.Error!void {
        return self.function.write32(offset.prefetchable_base_upper, value);
    }

    pub fn setPrefetchableLimitUpper(self: View, value: u32) ConfigSpace.Error!void {
        return self.function.write32(offset.prefetchable_limit_upper, value);
    }

    pub fn clearSecondaryStatus(self: View, bits: CommonStatus) ConfigSpace.Error!void {
        return self.function.write16(offset.secondary_status, @bitCast(bits));
    }

    pub fn setInterruptLine(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.interrupt_line, value);
    }

    pub fn setExpansionRomBase(self: View, value: u32) ConfigSpace.Error!void {
        return self.function.write32(offset.expansion_rom_base, value);
    }

    pub fn setBridgeControl(self: View, value: BridgeControl) ConfigSpace.Error!void {
        return self.function.write16(offset.bridge_control, @bitCast(value));
    }
};
