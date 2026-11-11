//! PCI Express capability registers.

const std = @import("std");

const pci_config = @import("config");
const core = @import("core");
const canonical = core.capabilities.pcie;

const standard = @import("standard.zig");

const Function = pci_config.Function;
const Entry = standard.Entry;
const CapabilityError = standard.Error;
const Registers = standard.Registers;
const RelativeOffset = core.RelativeOffset;

const Capabilities = canonical.Capabilities.Word;

const DeviceCapabilities = canonical.device.Capabilities.Word;
const DeviceControl = canonical.device.Control.Word;
const DeviceStatus = canonical.device.Status.Word;
const DeviceCapabilities2 = canonical.device.Capabilities2.Word;
const DeviceControl2 = canonical.device.Control2.Word;
const DeviceStatus2 = canonical.device.Status2.Word;

const LinkCapabilities = canonical.link.Capabilities.Word;
const LinkControl = canonical.link.Control.Word;
const LinkStatus = canonical.link.Status.Word;
const LinkCapabilities2 = canonical.link.Capabilities2.Word;
const LinkControl2 = canonical.link.Control2.Word;
const LinkStatus2 = canonical.link.Status2.Word;

const SlotCapabilities = canonical.slot.Capabilities.Word;
const SlotControl = canonical.slot.Control.Word;
const SlotStatus = canonical.slot.Status.Word;
const SlotCapabilities2 = canonical.slot.Capabilities2.Word;
const SlotControl2 = canonical.slot.Control2.Word;
const SlotStatus2 = canonical.slot.Status2.Word;

const RootControl = canonical.root.Control.Word;
const RootCapabilities = canonical.root.Capabilities.Word;
const RootStatus = canonical.root.Status.Word;

pub const Error = CapabilityError || error{
    UnsupportedRevision,
};

pub const Capability = struct {
    function: Function,
    base: u8,
    /// Version accepted at construction; capabilities() reads the live register.
    version: u4,

    pub fn tryFrom(function: Function, cap: Entry) Error!Capability {
        std.debug.assert(cap.id == canonical.id);

        const registers = try Registers.tryFrom(function, cap.offset);
        const caps = canonical.Capabilities.from(try registers.read(offsets.capabilities));

        if (caps.version == 0) {
            return error.UnsupportedRevision;
        }

        return .{
            .function = function,
            .base = cap.offset,
            .version = caps.version,
        };
    }

    pub fn find(function: Function) Error!?Capability {
        const cap = (try standard.find(function, canonical.id)) orelse return null;
        return try Capability.tryFrom(function, cap);
    }

    pub fn capabilities(self: Capability) CapabilityError!Capabilities {
        return self.readPacked(Capabilities, offsets.capabilities);
    }

    pub fn deviceCapabilities(self: Capability) CapabilityError!DeviceCapabilities {
        return self.readPacked(DeviceCapabilities, offsets.device.capabilities);
    }

    pub fn deviceControl(self: Capability) CapabilityError!DeviceControl {
        return self.readPacked(DeviceControl, offsets.device.control);
    }

    pub fn setDeviceControl(self: Capability, value: DeviceControl) CapabilityError!void {
        return self.writePacked(DeviceControl, offsets.device.control, value);
    }

    pub fn deviceStatus(self: Capability) CapabilityError!DeviceStatus {
        return self.readPacked(DeviceStatus, offsets.device.status);
    }

    pub fn clearDeviceStatusBits(self: Capability, bits: u16) CapabilityError!void {
        const registers = try Registers.tryFrom(self.function, self.base);
        return registers.write(offsets.device.status, bits);
    }

    pub fn linkCapabilities(self: Capability) CapabilityError!LinkCapabilities {
        return self.readPacked(LinkCapabilities, offsets.link.capabilities);
    }

    pub fn linkControl(self: Capability) CapabilityError!LinkControl {
        return self.readPacked(LinkControl, offsets.link.control);
    }

    pub fn setLinkControl(self: Capability, value: LinkControl) CapabilityError!void {
        return self.writePacked(LinkControl, offsets.link.control, value);
    }

    pub fn linkStatus(self: Capability) CapabilityError!LinkStatus {
        return self.readPacked(LinkStatus, offsets.link.status);
    }

    pub fn clearLinkStatusBits(self: Capability, bits: u16) CapabilityError!void {
        const registers = try Registers.tryFrom(self.function, self.base);
        return registers.write(offsets.link.status, bits);
    }

    pub fn slotCapabilities(self: Capability) CapabilityError!SlotCapabilities {
        return self.readPacked(SlotCapabilities, offsets.slot.capabilities);
    }

    pub fn slotControl(self: Capability) CapabilityError!SlotControl {
        return self.readPacked(SlotControl, offsets.slot.control);
    }

    pub fn setSlotControl(self: Capability, value: SlotControl) CapabilityError!void {
        return self.writePacked(SlotControl, offsets.slot.control, value);
    }

    pub fn slotStatus(self: Capability) CapabilityError!SlotStatus {
        return self.readPacked(SlotStatus, offsets.slot.status);
    }

    pub fn clearSlotStatusBits(self: Capability, bits: u16) CapabilityError!void {
        const registers = try Registers.tryFrom(self.function, self.base);
        return registers.write(offsets.slot.status, bits);
    }

    pub fn rootControl(self: Capability) CapabilityError!RootControl {
        return self.readPacked(RootControl, offsets.root.control);
    }

    pub fn setRootControl(self: Capability, value: RootControl) CapabilityError!void {
        return self.writePacked(RootControl, offsets.root.control, value);
    }

    pub fn rootCapabilities(self: Capability) CapabilityError!RootCapabilities {
        return self.readPacked(RootCapabilities, offsets.root.capabilities);
    }

    pub fn rootStatus(self: Capability) CapabilityError!RootStatus {
        return self.readPacked(RootStatus, offsets.root.status);
    }

    pub fn clearRootStatusBits(self: Capability, bits: u32) CapabilityError!void {
        const registers = try Registers.tryFrom(self.function, self.base);
        return registers.write(offsets.root.status, bits);
    }

    pub fn deviceCapabilities2(self: Capability) Error!DeviceCapabilities2 {
        try self.requireV2();
        return self.readPacked(DeviceCapabilities2, offsets.device.capabilities_2);
    }

    pub fn deviceControl2(self: Capability) Error!DeviceControl2 {
        try self.requireV2();
        return self.readPacked(DeviceControl2, offsets.device.control_2);
    }

    pub fn setDeviceControl2(self: Capability, value: DeviceControl2) Error!void {
        try self.requireV2();
        return self.writePacked(DeviceControl2, offsets.device.control_2, value);
    }

    pub fn deviceStatus2(self: Capability) Error!DeviceStatus2 {
        try self.requireV2();
        return self.readPacked(DeviceStatus2, offsets.device.status_2);
    }

    pub fn linkCapabilities2(self: Capability) Error!LinkCapabilities2 {
        try self.requireV2();
        return self.readPacked(LinkCapabilities2, offsets.link.capabilities_2);
    }

    pub fn linkControl2(self: Capability) Error!LinkControl2 {
        try self.requireV2();
        return self.readPacked(LinkControl2, offsets.link.control_2);
    }

    pub fn setLinkControl2(self: Capability, value: LinkControl2) Error!void {
        try self.requireV2();
        return self.writePacked(LinkControl2, offsets.link.control_2, value);
    }

    pub fn linkStatus2(self: Capability) Error!LinkStatus2 {
        try self.requireV2();
        return self.readPacked(LinkStatus2, offsets.link.status_2);
    }

    pub fn clearLinkStatus2Bits(self: Capability, bits: u16) Error!void {
        try self.requireV2();
        const registers = try Registers.tryFrom(self.function, self.base);
        return registers.write(offsets.link.status_2, bits);
    }

    pub fn slotCapabilities2(self: Capability) Error!SlotCapabilities2 {
        try self.requireV2();
        return self.readPacked(SlotCapabilities2, offsets.slot.capabilities_2);
    }

    pub fn slotControl2(self: Capability) Error!SlotControl2 {
        try self.requireV2();
        return self.readPacked(SlotControl2, offsets.slot.control_2);
    }

    pub fn setSlotControl2(self: Capability, value: SlotControl2) Error!void {
        try self.requireV2();
        return self.writePacked(SlotControl2, offsets.slot.control_2, value);
    }

    pub fn slotStatus2(self: Capability) Error!SlotStatus2 {
        try self.requireV2();
        return self.readPacked(SlotStatus2, offsets.slot.status_2);
    }

    fn requireV2(self: Capability) error{UnsupportedRevision}!void {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }
    }

    fn readPacked(self: Capability, comptime T: type, offset: anytype) CapabilityError!T {
        comptime std.debug.assert(@bitSizeOf(T) == 16 or @bitSizeOf(T) == 32);

        const registers = try Registers.tryFrom(self.function, self.base);
        const raw = try registers.read(offset);
        return @bitCast(raw);
    }

    fn writePacked(self: Capability, comptime T: type, offset: anytype, value: T) CapabilityError!void {
        comptime std.debug.assert(@bitSizeOf(T) == 16 or @bitSizeOf(T) == 32);

        const Raw = @TypeOf(offset).Int;
        const raw: Raw = @bitCast(value);
        const registers = try Registers.tryFrom(self.function, self.base);
        return registers.write(offset, raw);
    }
};

pub const offsets = struct {
    pub const capabilities = RelativeOffset(u16).from(canonical.offsets.capabilities);

    pub const device = struct {
        pub const capabilities = RelativeOffset(u32).from(canonical.device.offsets.capabilities);
        pub const control = RelativeOffset(u16).from(canonical.device.offsets.control);
        pub const status = RelativeOffset(u16).from(canonical.device.offsets.status);
        pub const capabilities_2 = RelativeOffset(u32).from(canonical.device.offsets.capabilities_2);
        pub const control_2 = RelativeOffset(u16).from(canonical.device.offsets.control_2);
        pub const status_2 = RelativeOffset(u16).from(canonical.device.offsets.status_2);
    };

    pub const link = struct {
        pub const capabilities = RelativeOffset(u32).from(canonical.link.offsets.capabilities);
        pub const control = RelativeOffset(u16).from(canonical.link.offsets.control);
        pub const status = RelativeOffset(u16).from(canonical.link.offsets.status);
        pub const capabilities_2 = RelativeOffset(u32).from(canonical.link.offsets.capabilities_2);
        pub const control_2 = RelativeOffset(u16).from(canonical.link.offsets.control_2);
        pub const status_2 = RelativeOffset(u16).from(canonical.link.offsets.status_2);
    };

    pub const slot = struct {
        pub const capabilities = RelativeOffset(u32).from(canonical.slot.offsets.capabilities);
        pub const control = RelativeOffset(u16).from(canonical.slot.offsets.control);
        pub const status = RelativeOffset(u16).from(canonical.slot.offsets.status);
        pub const capabilities_2 = RelativeOffset(u32).from(canonical.slot.offsets.capabilities_2);
        pub const control_2 = RelativeOffset(u16).from(canonical.slot.offsets.control_2);
        pub const status_2 = RelativeOffset(u16).from(canonical.slot.offsets.status_2);
    };

    pub const root = struct {
        pub const control = RelativeOffset(u16).from(canonical.root.offsets.control);
        pub const capabilities = RelativeOffset(u16).from(canonical.root.offsets.capabilities);
        pub const status = RelativeOffset(u32).from(canonical.root.offsets.status);
    };
};

pub const unit = struct {
    const support = @import("testing");
    const pcie = core.capabilities.pcie;
    const device = pcie.device;
    const link = pcie.link;
    const slot = pcie.slot;
    const root = pcie.root;
    const window = core.capabilities.standard.window;
    const testing = std.testing;

    const head_offset = core.header.type0.offsets.cap_ptr;
    const pcie_window_size: usize = core.config.extended_size;
    const test_sbdf = Sbdf.from(.from(0), 0, 0, 0);

    const ConfigSpace = pci_config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Offset = core.Offset;
    const Sbdf = core.Sbdf;
    const Id = core.capabilities.standard.Id;
    const Pcie = Capability;
    const DevicePortType = pcie.DevicePortType;

    const TestConfigSpace = support.config.TestConfigSpace;

    const GateAfterTryFromConfig = struct {
        version: u4,
        access_count: usize = 0,

        fn config(self: *GateAfterTryFromConfig) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8Unsupported,
            .read16 = read16,
            .read32 = read32Unsupported,
            .write8 = write8Unsupported,
            .write16 = write16Unsupported,
            .write32 = write32Unsupported,
        };

        fn read8Unsupported(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
            return error.UnsupportedAccessWidth;
        }

        fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *GateAfterTryFromConfig = @ptrCast(@alignCast(context));
            self.access_count += 1;

            if (byte_offset == 0x80 + pcie.offsets.capabilities) {
                return makeCapabilities(self.version);
            }

            return error.UnsupportedAccessWidth;
        }

        fn read32Unsupported(_: *anyopaque, _: Sbdf, _: usize) ConfigError!u32 {
            return error.UnsupportedAccessWidth;
        }

        fn write8Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write16Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u16) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }

        fn write32Unsupported(_: *anyopaque, _: Sbdf, _: usize, _: u32) ConfigError!void {
            return error.UnsupportedAccessWidth;
        }
    };

    const status = struct {
        const cap_list: u16 = 1 << 4;
    };
    const offset = struct {
        const status: usize = 0x06;
    };

    test "tryFrom accepts PCIe capabilities and rejects malformed offsets and revision zero" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 1, 0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        const view = try Pcie.tryFrom(function, capabilityAt(0x80));

        try testing.expectEqual(@as(u8, 0x80), view.base);
        try testing.expectEqual(@as(u4, 1), view.version);
        try testing.expectEqual(@as(u16, makeCapabilities(1)), @as(u16, @bitCast(try view.capabilities())));

        try testing.expectError(
            error.MalformedCapability,
            Pcie.tryFrom(function, capabilityAt(window.range.start - 4)),
        );
        try testing.expectError(
            error.MalformedCapability,
            Pcie.tryFrom(function, capabilityAt(window.range.start + 1)),
        );

        store16(&bytes, 0x80 + pcie.offsets.capabilities, makeCapabilities(0));
        try testing.expectError(error.UnsupportedRevision, Pcie.tryFrom(function, capabilityAt(0x80)));
    }

    test "find returns PCIe capability, null for absence, and propagates malformed traversal" {
        var found_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&found_bytes, 0x40);
        seedCapabilityNode(&found_bytes, 0x40, @intFromEnum(Id.msi), 0x80);
        seedPcieCapability(&found_bytes, 0x80, 2, 0);
        var found_backend = TestConfigSpace.fromSingle(test_sbdf, &found_bytes);
        const found_function = makeFunction(&found_backend);

        const view = (try Pcie.find(found_function)).?;

        try testing.expectEqual(@as(u8, 0x80), view.base);
        try testing.expectEqual(@as(u4, 2), view.version);

        var absent_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&absent_bytes, 0x40);
        seedCapabilityNode(&absent_bytes, 0x40, @intFromEnum(Id.msi), 0);
        var absent_backend = TestConfigSpace.fromSingle(test_sbdf, &absent_bytes);

        try testing.expectEqual(@as(?Pcie, null), try Pcie.find(makeFunction(&absent_backend)));

        var cycle_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&cycle_bytes, 0x40);
        seedCapabilityNode(&cycle_bytes, 0x40, @intFromEnum(Id.msi), 0x44);
        seedCapabilityNode(&cycle_bytes, 0x44, @intFromEnum(Id.msix), 0x40);
        var cycle_backend = TestConfigSpace.fromSingle(test_sbdf, &cycle_bytes);

        try testing.expectError(error.MalformedCapability, Pcie.find(makeFunction(&cycle_backend)));

        var malformed_bytes: [pcie_window_size]u8 = @splat(0);
        seedHead(&malformed_bytes, 0x40);
        seedCapabilityNode(&malformed_bytes, 0x40, @intFromEnum(Id.msi), 0x42);
        var malformed_backend = TestConfigSpace.fromSingle(test_sbdf, &malformed_bytes);

        try testing.expectError(error.MalformedCapability, Pcie.find(makeFunction(&malformed_backend)));
    }

    test "v1 accessors read exact base-relative whole registers" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 1, 0);
        store32(&bytes, 0x80 + pcie.device.offsets.capabilities, 0xA39C_5A15);
        store16(&bytes, 0x80 + pcie.device.offsets.control, 0xFFFF);
        store16(&bytes, 0x80 + pcie.device.offsets.status, 0xFFFF);
        store32(&bytes, 0x80 + pcie.link.offsets.capabilities, 0x5A7E_3C21);
        store16(&bytes, 0x80 + pcie.link.offsets.control, 0xFFFF);
        store16(&bytes, 0x80 + pcie.link.offsets.status, 0xFFFF);
        store32(&bytes, 0x80 + pcie.slot.offsets.capabilities, 0x7BDF_93C1);
        store16(&bytes, 0x80 + pcie.slot.offsets.control, 0xFFFF);
        store16(&bytes, 0x80 + pcie.slot.offsets.status, 0xFFFF);
        store16(&bytes, 0x80 + pcie.root.offsets.control, 0xFFFF);
        store16(&bytes, 0x80 + pcie.root.offsets.capabilities, 0x0001);
        store32(&bytes, 0x80 + pcie.root.offsets.status, 0xBEEF_0000);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0x80));

        try testing.expectEqual(@as(u32, 0xA39C_5A15), @as(u32, @bitCast(try view.deviceCapabilities())));
        try testing.expectEqual(@as(u32, 0x5A7E_3C21), @as(u32, @bitCast(try view.linkCapabilities())));
        try testing.expectEqual(@as(u32, 0x7BDF_93C1), @as(u32, @bitCast(try view.slotCapabilities())));
        try testing.expectEqual(@as(u16, 0x0001), @as(u16, @bitCast(try view.rootCapabilities())));
        try testing.expectEqual(@as(u32, 0xBEEF_0000), @as(u32, @bitCast(try view.rootStatus())));
    }

    test "v1 accessors write exact base-relative whole registers" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 1, 0);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0x80));

        const device_control: DeviceControl = .{
            .correctable_error_reporting_enable = true,
            .max_payload_size = .bytes_512,
            .max_read_request_size = .bytes_1024,
        };
        const link_control: LinkControl = .{
            .aspm = .l1,
            .retrain = true,
            .link_bandwidth_management_interrupt_enable = true,
        };
        const slot_control: SlotControl = .{
            .attention_button_pressed_enable = true,
            .attention_indicator = 0b10,
            .power_indicator = 0b01,
            .data_link_layer_state_changed_enable = true,
        };
        const root_control: RootControl = .{
            .sys_error_on_fatal_enable = true,
            .pme_interrupt_enable = true,
        };

        try view.setDeviceControl(device_control);
        try view.setLinkControl(link_control);
        try view.setSlotControl(slot_control);
        try view.setRootControl(root_control);

        try testing.expectEqual(@as(u16, @bitCast(device_control)), load16(&bytes, 0x80 + pcie.device.offsets.control));
        try testing.expectEqual(@as(u16, @bitCast(link_control)), load16(&bytes, 0x80 + pcie.link.offsets.control));
        try testing.expectEqual(@as(u16, @bitCast(slot_control)), load16(&bytes, 0x80 + pcie.slot.offsets.control));
        try testing.expectEqual(@as(u16, @bitCast(root_control)), load16(&bytes, 0x80 + pcie.root.offsets.control));

        const device_status = device.Status.encode(.{
            .correctable_error_detected = true,
            .unsupported_request_detected = true,
            .emergency_power_reduction_detected = true,
        });
        const link_status = link.Status.mask(.link_bandwidth_management_status);
        const slot_status = slot.Status.mask(.{ .attention_button_pressed, .command_completed, .data_link_layer_state_changed });
        const root_status = root.Status.masks.w1c | 0xA500_002A;

        try view.clearDeviceStatusBits(device_status);
        try view.clearLinkStatusBits(link_status);
        try view.clearSlotStatusBits(slot_status);
        try view.clearRootStatusBits(root_status);

        try testing.expectEqual(@as(u16, 0x49), load16(&bytes, 0x80 + pcie.device.offsets.status));
        try testing.expectEqual(@as(u16, 0x4000), load16(&bytes, 0x80 + pcie.link.offsets.status));
        try testing.expectEqual(@as(u16, 0x111), load16(&bytes, 0x80 + pcie.slot.offsets.status));
        try testing.expectEqual(@as(u32, 0xA501_002A), load32(&bytes, 0x80 + pcie.root.offsets.status));
    }

    test "v2 accessors gate UnsupportedRevision before config access" {
        var backend = GateAfterTryFromConfig{ .version = 1 };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedRevision, view.deviceCapabilities2());
        try testing.expectError(error.UnsupportedRevision, view.deviceControl2());
        try testing.expectError(error.UnsupportedRevision, view.setDeviceControl2(.{}));
        try testing.expectError(error.UnsupportedRevision, view.deviceStatus2());
        try testing.expectError(error.UnsupportedRevision, view.linkCapabilities2());
        try testing.expectError(error.UnsupportedRevision, view.linkControl2());
        try testing.expectError(error.UnsupportedRevision, view.setLinkControl2(.{}));
        try testing.expectError(error.UnsupportedRevision, view.linkStatus2());
        try testing.expectError(
            error.UnsupportedRevision,
            view.clearLinkStatus2Bits(0x8000),
        );
        try testing.expectError(error.UnsupportedRevision, view.slotCapabilities2());
        try testing.expectError(error.UnsupportedRevision, view.slotControl2());
        try testing.expectError(error.UnsupportedRevision, view.setSlotControl2(slot.Control2.from(0xA5A5)));
        try testing.expectError(error.UnsupportedRevision, view.slotStatus2());

        try testing.expectEqual(@as(usize, 1), backend.access_count);
    }

    test "v2 accessors read and write exact whole registers on revision two or newer" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store32(&bytes, 0x80 + pcie.device.offsets.capabilities_2, 0xC5A3_7E1F);
        store16(&bytes, 0x80 + pcie.device.offsets.control_2, 0x0A51);
        store16(&bytes, 0x80 + pcie.device.offsets.status_2, 0xA5A5);
        store32(&bytes, 0x80 + pcie.link.offsets.capabilities_2, 0x81FE_00AA);
        store16(&bytes, 0x80 + pcie.link.offsets.control_2, 0x1556);
        store16(&bytes, 0x80 + pcie.link.offsets.status_2, 0x8421);
        store32(&bytes, 0x80 + pcie.slot.offsets.capabilities_2, 0x0000_0002);
        store16(&bytes, 0x80 + pcie.slot.offsets.control_2, 0xBEEF);
        store16(&bytes, 0x80 + pcie.slot.offsets.status_2, 0xCAFE);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0x80));

        try testing.expectEqual(@as(u32, 0xC5A3_7E1F), @as(u32, @bitCast(try view.deviceCapabilities2())));
        try testing.expectEqual(@as(u16, 0x0A51), @as(u16, @bitCast(try view.deviceControl2())));
        try testing.expectEqual(@as(u16, 0xA5A5), @as(u16, @bitCast(try view.deviceStatus2())));
        try testing.expectEqual(@as(u32, 0x81FE_00AA), @as(u32, @bitCast(try view.linkCapabilities2())));
        try testing.expectEqual(@as(u16, 0x1556), @as(u16, @bitCast(try view.linkControl2())));
        try testing.expectEqual(@as(u16, 0x8421), @as(u16, @bitCast(try view.linkStatus2())));
        try testing.expectEqual(@as(u32, 0x0000_0002), @as(u32, @bitCast(try view.slotCapabilities2())));
        try testing.expectEqual(@as(u16, 0xBEEF), @as(u16, @bitCast(try view.slotControl2())));
        try testing.expectEqual(@as(u16, 0xCAFE), @as(u16, @bitCast(try view.slotStatus2())));

        const device_control_2: DeviceControl2 = .{
            .completion_timeout = .range_c_1s_3_5s,
            .completion_timeout_disable = true,
            .ari_forwarding_enable = true,
            .obff_enable = 0b10,
        };
        const link_control_2: LinkControl2 = .{
            .target_speed = .gen5,
            .hardware_autonomous_speed_disable = true,
            .transmit_margin = 0b101,
            .compliance_preset_or_deemphasis = 0xC,
        };
        const link_status_2 = link.Status2.mask(.{ .link_equalization_request_8gt, .drs_message_received });

        const slot_control_2 = slot.Control2.from(0x5AA5);

        try view.setDeviceControl2(device_control_2);
        try view.setLinkControl2(link_control_2);
        try view.clearLinkStatus2Bits(link_status_2);
        try view.setSlotControl2(slot_control_2);

        try testing.expectEqual(@as(u16, @bitCast(device_control_2)), load16(&bytes, 0x80 + pcie.device.offsets.control_2));
        try testing.expectEqual(@as(u16, @bitCast(link_control_2)), load16(&bytes, 0x80 + pcie.link.offsets.control_2));
        try testing.expectEqual(@as(u16, 0x8020), load16(&bytes, 0x80 + pcie.link.offsets.status_2));
        try testing.expectEqual(@as(u16, @bitCast(slot_control_2)), load16(&bytes, 0x80 + pcie.slot.offsets.control_2));
    }

    test "caller-side whole-register round trips preserve reserved bits" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.root.offsets.control, 0xFFE0);
        store16(&bytes, 0x80 + pcie.slot.offsets.control_2, 0x7E5A);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0x80));

        var root_control = try view.rootControl();
        root_control.pme_interrupt_enable = true;
        try view.setRootControl(root_control);

        try testing.expectEqual(@as(u16, 0xFFE8), load16(&bytes, 0x80 + pcie.root.offsets.control));

        const slot_control_2 = try view.slotControl2();
        try view.setSlotControl2(slot_control_2);

        try testing.expectEqual(@as(u16, 0x7E5A), load16(&bytes, 0x80 + pcie.slot.offsets.control_2));
    }

    test "backend errors propagate after capability validation succeeds" {
        var backend = GateAfterTryFromConfig{ .version = 2 };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedAccessWidth, view.deviceCapabilities());
        try testing.expectError(error.UnsupportedAccessWidth, view.setDeviceControl(.{}));
        try testing.expectError(error.UnsupportedAccessWidth, view.deviceCapabilities2());
        try testing.expectError(error.UnsupportedAccessWidth, view.setLinkControl2(.{}));
    }

    test "PCIe register access cannot escape conventional config space" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0xDC, 2, 0);
        store32(&bytes, 0xFC, 0xAABB_CCDD);
        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0xDC));

        try testing.expectEqual(@as(u32, 0xAABB_CCDD), @as(u32, @bitCast(try view.rootStatus())));

        const before = bytes;

        try testing.expectError(error.MalformedCapability, view.deviceCapabilities2());
        try testing.expectError(error.MalformedCapability, view.setDeviceControl2(.{}));
        try testing.expectEqualSlices(u8, &before, &bytes);

        var guard = GateAfterTryFromConfig{ .version = 2 };
        const invalid: Pcie = .{ .function = Function.from(guard.config(), test_sbdf), .base = 0xFC, .version = 2 };

        try testing.expectError(error.MalformedCapability, invalid.deviceCapabilities());
        try testing.expectError(error.MalformedCapability, invalid.setDeviceControl(.{}));
        try testing.expectEqual(@as(usize, 0), guard.access_count);
    }

    fn makeFunction(backend: *TestConfigSpace) Function {
        return Function.from(backend.config(), test_sbdf);
    }

    fn capabilityAt(base: u8) Entry {
        return .{ .id = pcie.id, .offset = base };
    }

    fn makeCapabilities(version: u4) u16 {
        return @as(u16, version) |
            (@as(u16, @intFromEnum(DevicePortType.root_port)) << 4) |
            (@as(u16, 1) << 8) |
            (@as(u16, 0x12) << 9);
    }

    fn enableCapabilities(bytes: *[pcie_window_size]u8) void {
        store16(bytes, offset.status, status.cap_list);
    }

    fn seedHead(bytes: *[pcie_window_size]u8, head: u8) void {
        enableCapabilities(bytes);
        bytes[head_offset] = head;
    }

    fn seedCapabilityNode(bytes: *[pcie_window_size]u8, base: u8, id: u8, next: u8) void {
        bytes[base] = id;
        bytes[@as(usize, base) + 1] = next;
    }

    fn seedPcieCapability(bytes: *[pcie_window_size]u8, base: u8, version: u4, next: u8) void {
        seedCapabilityNode(bytes, base, @intFromEnum(pcie.id), next);
        store16(bytes, @as(usize, base) + pcie.offsets.capabilities, makeCapabilities(version));
    }

    fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
        std.mem.writeInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], value, .little);
    }

    fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
        std.mem.writeInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], value, .little);
    }

    fn load16(bytes: []const u8, byte_offset: usize) u16 {
        return std.mem.readInt(u16, bytes[byte_offset..][0..@sizeOf(u16)], .little);
    }

    fn load32(bytes: []const u8, byte_offset: usize) u32 {
        return std.mem.readInt(u32, bytes[byte_offset..][0..@sizeOf(u32)], .little);
    }
};
