//! Common PCI header view. Spec: docs/specs/header/common.md.

const std = @import("std");

const config = @import("../config.zig");
const core = @import("../core.zig");
const pin = @import("../interrupts/pin.zig");

const ConfigSpace = config.ConfigSpace;
const Pin = pin.Pin;

const offset = struct {
    const vendor_id: usize = 0x00;
    const device_id: usize = 0x02;
    const command: usize = 0x04;
    const status: usize = 0x06;
    const revision_id: usize = 0x08;
    const cache_line_size: usize = 0x0C;
    const latency_timer: usize = 0x0D;
    const header_type: usize = 0x0E;
    const bist: usize = 0x0F;
    const cap_ptr: usize = 0x34;
    const interrupt_line: usize = 0x3C;
    const interrupt_pin: usize = 0x3D;
};

pub const CommonHeader = extern struct {
    vendor_id: u16,
    device_id: u16,
    command: u16,
    status: u16,
    revision_id: u8,
    prog_if: u8,
    subclass: u8,
    base_class: u8,
    cache_line_size: u8,
    latency_timer: u8,
    header_type: u8,
    bist: u8,

    comptime {
        std.debug.assert(@sizeOf(CommonHeader) == 16);
        std.debug.assert(@offsetOf(CommonHeader, "vendor_id") == 0x00);
        std.debug.assert(@offsetOf(CommonHeader, "device_id") == 0x02);
        std.debug.assert(@offsetOf(CommonHeader, "command") == 0x04);
        std.debug.assert(@offsetOf(CommonHeader, "status") == 0x06);
        std.debug.assert(@offsetOf(CommonHeader, "revision_id") == 0x08);
        std.debug.assert(@offsetOf(CommonHeader, "prog_if") == 0x09);
        std.debug.assert(@offsetOf(CommonHeader, "subclass") == 0x0A);
        std.debug.assert(@offsetOf(CommonHeader, "base_class") == 0x0B);
        std.debug.assert(@offsetOf(CommonHeader, "cache_line_size") == 0x0C);
        std.debug.assert(@offsetOf(CommonHeader, "latency_timer") == 0x0D);
        std.debug.assert(@offsetOf(CommonHeader, "header_type") == 0x0E);
        std.debug.assert(@offsetOf(CommonHeader, "bist") == 0x0F);
    }
};

pub const Command = packed struct(u16) {
    io_space: bool,
    memory_space: bool,
    bus_master: bool,
    special_cycles: bool,
    mwi_enable: bool,
    vga_palette_snoop: bool,
    parity_response: bool,
    _reserved7: u1,
    serr_enable: bool,
    fast_back_to_back: bool,
    interrupt_disable: bool,
    _reserved11: u5,
};

pub const Status = packed struct(u16) {
    _reserved0: u3 = 0,
    interrupt_status: bool = false,
    capabilities_list: bool = false,
    capable_66mhz: bool = false,
    _reserved6: u1 = 0,
    fast_back_to_back_capable: bool = false,
    master_data_parity_error: bool = false,
    devsel_timing: u2 = 0,
    signaled_target_abort: bool = false,
    received_target_abort: bool = false,
    received_master_abort: bool = false,
    signaled_system_error: bool = false,
    detected_parity_error: bool = false,

    pub const all_sticky_errors: Status = .{
        .master_data_parity_error = true,
        .signaled_target_abort = true,
        .received_target_abort = true,
        .received_master_abort = true,
        .signaled_system_error = true,
        .detected_parity_error = true,
    };
};

pub const Bist = packed struct(u8) {
    completion_code: u4,
    _reserved4: u2 = 0,
    start: bool = false,
    capable: bool = false,
};

pub const View = struct {
    function: config.Function,

    pub fn init(function: config.Function) View {
        return .{ .function = function };
    }

    pub fn vendorId(self: View) ConfigSpace.Error!core.VendorId {
        return self.function.vendorId();
    }

    pub fn deviceId(self: View) ConfigSpace.Error!core.DeviceId {
        return self.function.deviceId();
    }

    pub fn revisionId(self: View) ConfigSpace.Error!core.RevisionId {
        return self.function.revisionId();
    }

    pub fn classCode(self: View) ConfigSpace.Error!core.ClassCode {
        return self.function.classCode();
    }

    pub fn command(self: View) ConfigSpace.Error!Command {
        const raw = try self.function.read16(offset.command);
        return @bitCast(raw);
    }

    pub fn setCommand(self: View, value: Command) ConfigSpace.Error!void {
        return self.function.write16(offset.command, @bitCast(value));
    }

    pub fn status(self: View) ConfigSpace.Error!Status {
        const raw = try self.function.read16(offset.status);
        return @bitCast(raw);
    }

    pub fn clearStatusBits(self: View, bits: Status) ConfigSpace.Error!void {
        return self.function.write16(offset.status, @bitCast(bits));
    }

    pub fn cacheLineSize(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.cache_line_size);
    }

    pub fn setCacheLineSize(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.cache_line_size, value);
    }

    pub fn latencyTimer(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.latency_timer);
    }

    pub fn setLatencyTimer(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.latency_timer, value);
    }

    pub fn headerTypeByte(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.header_type);
    }

    pub fn isMultifunction(self: View) ConfigSpace.Error!bool {
        return self.function.isMultifunction();
    }

    pub fn bist(self: View) ConfigSpace.Error!Bist {
        const raw = try self.function.read8(offset.bist);
        return @bitCast(raw);
    }

    pub fn setBist(self: View, value: Bist) ConfigSpace.Error!void {
        return self.function.write8(offset.bist, @bitCast(value));
    }

    pub fn capabilitiesPointer(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.cap_ptr);
    }

    pub fn interruptLine(self: View) ConfigSpace.Error!u8 {
        return self.function.read8(offset.interrupt_line);
    }

    pub fn setInterruptLine(self: View, value: u8) ConfigSpace.Error!void {
        return self.function.write8(offset.interrupt_line, value);
    }

    pub fn interruptPin(self: View) (ConfigSpace.Error || Pin.Error)!Pin {
        return Pin.from(try self.function.read8(offset.interrupt_pin));
    }
};
