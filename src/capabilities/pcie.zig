//! PCI Express capability registers.

const std = @import("std");

const config = @import("config");
const core = @import("core");
const pcie = core.capabilities.pcie;

const standard = @import("standard.zig");

const Function = config.Function;
const Entry = standard.Entry;
const CapabilityError = standard.Error;
const Registers = standard.Registers;
const RelativeOffset = core.RelativeOffset;

const Capabilities = pcie.Capabilities.Word;
const DevicePortType = pcie.DevicePortType;

const DeviceCapabilities = pcie.device.Capabilities.Word;
const DeviceControl = pcie.device.Control.Word;
const DeviceControlArgs = pcie.device.Control.AssignArgs;
const DeviceStatus = pcie.device.Status.Word;
const DeviceCapabilities2 = pcie.device.Capabilities2.Word;
const DeviceControl2 = pcie.device.Control2.Word;
const DeviceControl2Args = pcie.device.Control2.AssignArgs;
const PayloadSize = pcie.device.PayloadSize;
const ReadRequestSize = pcie.device.ReadRequestSize;
const CompletionTimeout = pcie.device.CompletionTimeout;
const CompletionTimeoutRange = pcie.device.CompletionTimeoutRanges.Range;

const LinkCapabilities = pcie.link.Capabilities.Word;
const LinkControl = pcie.link.Control.Word;
const LinkControlArgs = pcie.link.Control.AssignArgs;
const LinkStatus = pcie.link.Status.Word;
const LinkCapabilities2 = pcie.link.Capabilities2.Word;
const LinkControl2 = pcie.link.Control2.Word;
const LinkControl2Args = pcie.link.Control2.AssignArgs;
const LinkStatus2 = pcie.link.Status2.Word;
const LinkSpeed = pcie.link.LinkSpeed;
const LinkGeneration = pcie.link.LinkSpeeds.Generation;

const SlotCapabilities = pcie.slot.Capabilities.Word;
const SlotControl = pcie.slot.Control.Word;
const SlotControlArgs = pcie.slot.Control.AssignArgs;
const SlotStatus = pcie.slot.Status.Word;
const SlotCapabilities2 = pcie.slot.Capabilities2.Word;

const RootControl = pcie.root.Control.Word;
const RootControlArgs = pcie.root.Control.AssignArgs;
const RootCapabilities = pcie.root.Capabilities.Word;
const RootStatus = pcie.root.Status.Word;

pub const Error = CapabilityError || error{
    UnsupportedRevision,
    UnsupportedRegister,
};

pub const ValidationError = Error || error{
    UnsupportedFeature,
    InvalidValue,
};

pub const ActionError = Error || error{
    UnsupportedFeature,
};

pub const Capability = struct {
    registers: Registers,
    version: u4,
    type: DevicePortType,
    has_slot: bool,

    pub fn tryFrom(function: Function, cap: Entry) Error!Capability {
        std.debug.assert(cap.id == pcie.id);

        const registers = try Registers.tryFrom(function, cap.offset);
        const caps = pcie.Capabilities.from(try registers.read(offsets.capabilities));

        if (caps.version == 0) {
            return error.UnsupportedRevision;
        }

        return .{
            .registers = registers,
            .version = caps.version,
            .type = caps.type,
            .has_slot = caps.has_slot,
        };
    }

    pub fn find(function: Function) Error!?Capability {
        const cap = (try standard.find(function, pcie.id)) orelse return null;
        return try Capability.tryFrom(function, cap);
    }

    pub fn capabilities(self: Capability) CapabilityError!Capabilities {
        return pcie.Capabilities.from(try self.registers.read(offsets.capabilities));
    }

    pub fn deviceCapabilities(self: Capability) CapabilityError!DeviceCapabilities {
        return pcie.device.Capabilities.from(try self.registers.read(offsets.device.capabilities));
    }

    pub fn deviceControl(self: Capability) CapabilityError!DeviceControl {
        return pcie.device.Control.from(try self.registers.read(offsets.device.control));
    }

    pub fn updateDeviceControl(self: Capability, args: DeviceControlArgs) CapabilityError!void {
        const observed = try self.deviceControl();
        var updated = pcie.device.Control.replace(observed, args);

        if (self.type != .pcie_to_pci_bridge) {
            updated.bcre_initiate_flr = false;
        }

        return self.registers.write(offsets.device.control, pcie.device.Control.raw(updated));
    }

    pub fn deviceStatus(self: Capability) CapabilityError!DeviceStatus {
        return pcie.device.Status.from(try self.registers.read(offsets.device.status));
    }

    pub fn ackDeviceStatus(self: Capability, observed: DeviceStatus, comptime fields: anytype) CapabilityError!void {
        return self.registers.write(offsets.device.status, pcie.device.Status.ack(observed, fields));
    }

    pub fn deviceCapabilities2(self: Capability) Error!DeviceCapabilities2 {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        return pcie.device.Capabilities2.from(try self.registers.read(offsets.device.capabilities_2));
    }

    pub fn deviceControl2(self: Capability) Error!DeviceControl2 {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        return pcie.device.Control2.from(try self.registers.read(offsets.device.control_2));
    }

    pub fn updateDeviceControl2(self: Capability, args: DeviceControl2Args) Error!void {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        const observed = try self.deviceControl2();
        const updated = pcie.device.Control2.replace(observed, args);

        return self.registers.write(offsets.device.control_2, pcie.device.Control2.raw(updated));
    }

    pub fn setMaxPayloadSize(self: Capability, size: PayloadSize) ValidationError!void {
        _ = size.bytes() catch return error.InvalidValue;

        const caps = try self.deviceCapabilities();
        if (@intFromEnum(size) > @intFromEnum(caps.max_payload_size)) {
            return error.UnsupportedFeature;
        }

        return self.updateDeviceControl(.{ .max_payload_size = size });
    }

    pub fn setMaxReadRequestSize(self: Capability, size: ReadRequestSize) ValidationError!void {
        _ = size.bytes() catch return error.InvalidValue;
        return self.updateDeviceControl(.{ .max_read_request_size = size });
    }

    pub fn setCompletionTimeout(self: Capability, timeout: CompletionTimeout) ValidationError!void {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        const range: ?CompletionTimeoutRange = switch (timeout) {
            .default => null,
            .range_a_50us_100us, .range_a_1ms_10ms => .a,
            .range_b_16ms_55ms, .range_b_65ms_210ms => .b,
            .range_c_260ms_900ms, .range_c_1s_3_5s => .c,
            .range_d_4s_13s, .range_d_17s_64s => .d,
            _ => return error.InvalidValue,
        };

        if (range) |requested| {
            const caps = try self.deviceCapabilities2();
            if (!caps.completion_timeout_ranges_supported.supports(requested)) {
                return error.UnsupportedFeature;
            }
        }

        return self.updateDeviceControl2(.{ .completion_timeout = timeout });
    }

    pub fn requestFlr(self: Capability) ActionError!void {
        const Control = pcie.device.Control;

        switch (self.type) {
            .endpoint, .legacy_endpoint, .root_complex_integrated_endpoint => {},
            else => return error.UnsupportedRegister,
        }

        const caps = try self.deviceCapabilities();
        const trigger = Control.triggerMask(self.type, caps);

        if (trigger == 0) {
            return error.UnsupportedFeature;
        }

        const observed = try self.deviceControl();
        const raw = (Control.raw(observed) & Control.rwMask(self.type)) | trigger;

        return self.registers.write(offsets.device.control, raw);
    }

    pub fn linkCapabilities(self: Capability) Error!LinkCapabilities {
        try self.requireLink();
        return pcie.link.Capabilities.from(try self.registers.read(offsets.link.capabilities));
    }

    pub fn linkControl(self: Capability) Error!LinkControl {
        try self.requireLink();
        return pcie.link.Control.from(try self.registers.read(offsets.link.control));
    }

    pub fn updateLinkControl(self: Capability, args: LinkControlArgs) Error!void {
        const Control = pcie.link.Control;

        try self.requireLink();

        const observed = try self.linkControl();
        const updated = Control.replace(observed, args);
        const raw = Control.raw(updated) & ~Control.masks.trigger;

        return self.registers.write(offsets.link.control, raw);
    }

    pub fn linkStatus(self: Capability) Error!LinkStatus {
        try self.requireLink();
        return pcie.link.Status.from(try self.registers.read(offsets.link.status));
    }

    pub fn ackLinkStatus(self: Capability, observed: LinkStatus, comptime fields: anytype) Error!void {
        try self.requireLink();
        return self.registers.write(offsets.link.status, pcie.link.Status.ack(observed, fields));
    }

    pub fn linkCapabilities2(self: Capability) Error!LinkCapabilities2 {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        try self.requireLink();

        return pcie.link.Capabilities2.from(try self.registers.read(offsets.link.capabilities_2));
    }

    pub fn linkControl2(self: Capability) Error!LinkControl2 {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        try self.requireLink();

        return pcie.link.Control2.from(try self.registers.read(offsets.link.control_2));
    }

    pub fn updateLinkControl2(self: Capability, args: LinkControl2Args) Error!void {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        try self.requireLink();

        const observed = try self.linkControl2();
        const updated = pcie.link.Control2.replace(observed, args);

        return self.registers.write(offsets.link.control_2, pcie.link.Control2.raw(updated));
    }

    pub fn linkStatus2(self: Capability) Error!LinkStatus2 {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        try self.requireLink();

        return pcie.link.Status2.from(try self.registers.read(offsets.link.status_2));
    }

    pub fn ackLinkStatus2(self: Capability, observed: LinkStatus2, comptime fields: anytype) Error!void {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        try self.requireLink();

        return self.registers.write(offsets.link.status_2, pcie.link.Status2.ack(observed, fields));
    }

    pub fn setTargetLinkSpeed(self: Capability, speed: LinkSpeed) ValidationError!void {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        try self.requireLink();

        const generation: LinkGeneration = switch (speed) {
            .gen1 => .gen1,
            .gen2 => .gen2,
            .gen3 => .gen3,
            .gen4 => .gen4,
            .gen5 => .gen5,
            .gen6 => .gen6,
            _ => return error.InvalidValue,
        };

        const caps = try self.linkCapabilities2();

        if (!caps.supported_speeds.supports(generation)) {
            return error.UnsupportedFeature;
        }

        return self.updateLinkControl2(.{ .target_speed = speed });
    }

    pub fn retrainLink(self: Capability) Error!void {
        const Control = pcie.link.Control;

        switch (self.type) {
            .root_port, .downstream, .pci_to_pcie_bridge => {},
            else => return error.UnsupportedRegister,
        }

        const observed = try self.linkControl();
        const raw = (Control.raw(observed) & ~Control.masks.trigger) | Control.trigger(.{.retrain});

        return self.registers.write(offsets.link.control, raw);
    }

    pub fn slotCapabilities(self: Capability) Error!SlotCapabilities {
        try self.requireSlot();
        return pcie.slot.Capabilities.from(try self.registers.read(offsets.slot.capabilities));
    }

    pub fn slotControl(self: Capability) Error!SlotControl {
        try self.requireSlot();
        return pcie.slot.Control.from(try self.registers.read(offsets.slot.control));
    }

    pub fn updateSlotControl(self: Capability, args: SlotControlArgs) Error!void {
        const Control = pcie.slot.Control;

        try self.requireSlot();

        const observed = try self.slotControl();
        const updated = Control.replace(observed, args);
        const raw = Control.raw(updated) & ~Control.masks.trigger;

        return self.registers.write(offsets.slot.control, raw);
    }

    pub fn slotStatus(self: Capability) Error!SlotStatus {
        try self.requireSlot();
        return pcie.slot.Status.from(try self.registers.read(offsets.slot.status));
    }

    pub fn ackSlotStatus(self: Capability, observed: SlotStatus, comptime fields: anytype) Error!void {
        try self.requireSlot();
        return self.registers.write(offsets.slot.status, pcie.slot.Status.ack(observed, fields));
    }

    pub fn slotCapabilities2(self: Capability) Error!SlotCapabilities2 {
        if (self.version < 2) {
            return error.UnsupportedRevision;
        }

        try self.requireSlot();

        return pcie.slot.Capabilities2.from(try self.registers.read(offsets.slot.capabilities_2));
    }

    pub fn toggleInterlock(self: Capability) ActionError!void {
        const Control = pcie.slot.Control;

        try self.requireSlot();

        const caps = try self.slotCapabilities();
        if (!caps.interlock_present) {
            return error.UnsupportedFeature;
        }

        const observed = try self.slotControl();
        const raw = (Control.raw(observed) & ~Control.masks.trigger) | Control.trigger(.{.interlock_control});

        return self.registers.write(offsets.slot.control, raw);
    }

    pub fn rootCapabilities(self: Capability) Error!RootCapabilities {
        try self.requireRoot();
        return pcie.root.Capabilities.from(try self.registers.read(offsets.root.capabilities));
    }

    pub fn rootControl(self: Capability) Error!RootControl {
        try self.requireRoot();
        return pcie.root.Control.from(try self.registers.read(offsets.root.control));
    }

    pub fn updateRootControl(self: Capability, args: RootControlArgs) Error!void {
        try self.requireRoot();

        const observed = try self.rootControl();
        const updated = pcie.root.Control.replace(observed, args);

        return self.registers.write(offsets.root.control, pcie.root.Control.raw(updated));
    }

    pub fn rootStatus(self: Capability) Error!RootStatus {
        try self.requireRoot();
        return pcie.root.Status.from(try self.registers.read(offsets.root.status));
    }

    pub fn ackRootStatus(self: Capability, observed: RootStatus, comptime fields: anytype) Error!void {
        try self.requireRoot();
        return self.registers.write(offsets.root.status, pcie.root.Status.ack(observed, fields));
    }

    fn requireLink(self: Capability) error{UnsupportedRegister}!void {
        switch (self.type) {
            .endpoint, .legacy_endpoint, .root_port, .upstream, .downstream, .pcie_to_pci_bridge, .pci_to_pcie_bridge => {},
            else => return error.UnsupportedRegister,
        }
    }

    fn requireSlot(self: Capability) error{UnsupportedRegister}!void {
        switch (self.type) {
            .root_port, .downstream, .pci_to_pcie_bridge => {},
            else => return error.UnsupportedRegister,
        }
    }

    fn requireRoot(self: Capability) error{UnsupportedRegister}!void {
        switch (self.type) {
            .root_port, .root_complex_event_collector => {},
            else => return error.UnsupportedRegister,
        }
    }
};

pub const offsets = struct {
    pub const capabilities = RelativeOffset(u16).from(pcie.offsets.capabilities);

    pub const device = struct {
        pub const capabilities = RelativeOffset(u32).from(pcie.device.offsets.capabilities);
        pub const control = RelativeOffset(u16).from(pcie.device.offsets.control);
        pub const status = RelativeOffset(u16).from(pcie.device.offsets.status);
        pub const capabilities_2 = RelativeOffset(u32).from(pcie.device.offsets.capabilities_2);
        pub const control_2 = RelativeOffset(u16).from(pcie.device.offsets.control_2);
        pub const status_2 = RelativeOffset(u16).from(pcie.device.offsets.status_2);
    };

    pub const link = struct {
        pub const capabilities = RelativeOffset(u32).from(pcie.link.offsets.capabilities);
        pub const control = RelativeOffset(u16).from(pcie.link.offsets.control);
        pub const status = RelativeOffset(u16).from(pcie.link.offsets.status);
        pub const capabilities_2 = RelativeOffset(u32).from(pcie.link.offsets.capabilities_2);
        pub const control_2 = RelativeOffset(u16).from(pcie.link.offsets.control_2);
        pub const status_2 = RelativeOffset(u16).from(pcie.link.offsets.status_2);
    };

    pub const slot = struct {
        pub const capabilities = RelativeOffset(u32).from(pcie.slot.offsets.capabilities);
        pub const control = RelativeOffset(u16).from(pcie.slot.offsets.control);
        pub const status = RelativeOffset(u16).from(pcie.slot.offsets.status);
        pub const capabilities_2 = RelativeOffset(u32).from(pcie.slot.offsets.capabilities_2);
        pub const control_2 = RelativeOffset(u16).from(pcie.slot.offsets.control_2);
        pub const status_2 = RelativeOffset(u16).from(pcie.slot.offsets.status_2);
    };

    pub const root = struct {
        pub const control = RelativeOffset(u16).from(pcie.root.offsets.control);
        pub const capabilities = RelativeOffset(u16).from(pcie.root.offsets.capabilities);
        pub const status = RelativeOffset(u32).from(pcie.root.offsets.status);
    };
};

pub const unit = struct {
    const testing = std.testing;

    const support = @import("testing");
    const header = core.header;
    const window = core.capabilities.standard.window;

    const head_offset = core.header.type0.offsets.cap_ptr;
    const pcie_window_size: usize = core.config.extended_size;
    const test_sbdf = Sbdf.from(.from(0), 0, 0, 0);

    const ConfigSpace = config.ConfigSpace;
    const ConfigError = ConfigSpace.Error;
    const Offset = core.Offset;
    const Sbdf = core.Sbdf;
    const Id = core.capabilities.standard.Id;
    const Pcie = Capability;

    const TestConfigSpace = support.config.TestConfigSpace;

    const ConfigBackend = struct {
        version: u4,
        port_type: DevicePortType = .root_port,
        has_slot: bool = true,
        access_count: usize = 0,
        bytes: ?*[pcie_window_size]u8 = null,
        write_count: usize = 0,
        fail_read: ?usize = null,
        fail_write: bool = false,
        last_write_value: u32 = 0,
        last_write_offset: usize = 0,

        fn config(self: *ConfigBackend) ConfigSpace {
            return ConfigSpace.from(@ptrCast(self), &vtable);
        }

        const vtable: ConfigSpace.VTable = .{
            .read8 = read8Unsupported,
            .read16 = read16,
            .read32 = read32,
            .write8 = write8Unsupported,
            .write16 = write16,
            .write32 = write32,
        };

        fn read8Unsupported(context: *anyopaque, _: Sbdf, _: usize) ConfigError!u8 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.access_count += 1;

            return error.UnsupportedAccessWidth;
        }

        fn read16(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u16 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.access_count += 1;

            if (self.fail_read == byte_offset) {
                return error.UnsupportedAccessWidth;
            }

            if (self.bytes) |bytes| {
                return std.mem.readInt(u16, bytes[byte_offset..][0..2], .little);
            }

            if (byte_offset == 0x80 + pcie.offsets.capabilities) {
                return pcie.Capabilities.encode(.{
                    .version = self.version,
                    .type = self.port_type,
                    .has_slot = self.has_slot,
                });
            }

            return error.UnsupportedAccessWidth;
        }

        fn read32(context: *anyopaque, _: Sbdf, byte_offset: usize) ConfigError!u32 {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.access_count += 1;

            if (self.fail_read == byte_offset) {
                return error.UnsupportedAccessWidth;
            }

            if (self.bytes) |bytes| {
                return std.mem.readInt(u32, bytes[byte_offset..][0..4], .little);
            }

            return error.UnsupportedAccessWidth;
        }

        fn write8Unsupported(context: *anyopaque, _: Sbdf, _: usize, _: u8) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.access_count += 1;

            return error.UnsupportedAccessWidth;
        }

        fn write16(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u16) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.access_count += 1;
            self.write_count += 1;
            self.last_write_value = value;
            self.last_write_offset = byte_offset;

            if (!self.fail_write) {
                if (self.bytes) |bytes| {
                    const clear_mask: u16 = switch (byte_offset) {
                        0x80 + pcie.device.offsets.status => pcie.device.Status.masks.w1c,
                        0x80 + pcie.link.offsets.status => pcie.link.Status.masks.w1c,
                        0x80 + pcie.link.offsets.status_2 => pcie.link.Status2.masks.w1c,
                        0x80 + pcie.slot.offsets.status => pcie.slot.Status.masks.w1c,
                        else => 0,
                    };
                    const trigger_mask: u16 = switch (byte_offset) {
                        0x80 + pcie.link.offsets.control => pcie.link.Control.masks.trigger,
                        0x80 + pcie.slot.offsets.control => pcie.slot.Control.masks.trigger,
                        else => 0,
                    };
                    const stored = if (clear_mask != 0)
                        std.mem.readInt(u16, bytes[byte_offset..][0..2], .little) & ~(value & clear_mask)
                    else
                        value & ~trigger_mask;

                    std.mem.writeInt(u16, bytes[byte_offset..][0..2], stored, .little);
                    return;
                }
            }

            return error.UnsupportedAccessWidth;
        }

        fn write32(context: *anyopaque, _: Sbdf, byte_offset: usize, value: u32) ConfigError!void {
            const self: *ConfigBackend = @ptrCast(@alignCast(context));
            self.access_count += 1;
            self.write_count += 1;
            self.last_write_value = value;
            self.last_write_offset = byte_offset;

            if (!self.fail_write) {
                if (self.bytes) |bytes| {
                    const stored = if (byte_offset == 0x80 + pcie.root.offsets.status)
                        std.mem.readInt(u32, bytes[byte_offset..][0..4], .little) & ~(value & pcie.root.Status.masks.w1c)
                    else
                        value;

                    std.mem.writeInt(u32, bytes[byte_offset..][0..4], stored, .little);
                    return;
                }
            }

            return error.UnsupportedAccessWidth;
        }
    };

    test "tryFrom accepts PCIe capabilities and rejects malformed offsets and revision zero" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 1, 0);

        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const function = makeFunction(&backend);

        const view = try Pcie.tryFrom(function, capabilityAt(0x80));

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

    test "common updates touch only control registers without feature or value validation" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.device.offsets.control, 0x800F);
        store16(&bytes, 0x80 + pcie.link.offsets.control, 0x8020);
        store16(&bytes, 0x80 + pcie.slot.offsets.control, 0x8C20);
        store16(&bytes, 0x80 + pcie.root.offsets.control, 0xFFE0);
        store16(&bytes, 0x80 + pcie.device.offsets.control_2, 0x0100);
        store16(&bytes, 0x80 + pcie.link.offsets.control_2, 0x0411);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try view.updateDeviceControl(.{
            .max_payload_size = @enumFromInt(6),
            .max_read_request_size = @enumFromInt(7),
            .ext_tag_enable = true,
        });
        try view.updateLinkControl(.{
            .aspm = .l1,
            .clock_pm_enable = true,
            .flit_mode_disable = true,
            .drs_signaling_control = true,
        });
        try view.updateSlotControl(.{ .power_control = .on, .presence_detect_changed_enable = true });
        try view.updateRootControl(.{ .crs_software_visibility_enable = true });
        try view.updateDeviceControl2(.{
            .completion_timeout = @enumFromInt(3),
            .ari_forwarding_enable = true,
            .obff_enable = .wake,
            .emergency_power_reduction_request = true,
        });
        try view.updateLinkControl2(.{ .target_speed = .gen6 });

        try testing.expectEqual(@as(u16, 0x71CF), std.mem.readInt(u16, bytes[0x88..0x8A], .little));
        try testing.expectEqual(@as(u16, 0xE102), std.mem.readInt(u16, bytes[0x90..0x92], .little));
        try testing.expectEqual(@as(u16, 0x8028), std.mem.readInt(u16, bytes[0x98..0x9A], .little));
        try testing.expectEqual(@as(u16, 0xFFF0), std.mem.readInt(u16, bytes[0x9C..0x9E], .little));
        try testing.expectEqual(@as(u16, 0x6923), std.mem.readInt(u16, bytes[0xA8..0xAA], .little));
        try testing.expectEqual(@as(u16, 0x0416), std.mem.readInt(u16, bytes[0xB0..0xB2], .little));
        try testing.expectEqual(@as(usize, 6), backend.write_count);
        try testing.expectEqual(@as(usize, 13), backend.access_count);
    }

    test "device updates preserve BCRE only on PCIe-to-PCI bridges and never replay FLR" {
        const ports = [_]DevicePortType{ .endpoint, .root_port, .pcie_to_pci_bridge };

        for (ports) |port_type| {
            var bytes: [pcie_window_size]u8 = @splat(0);
            seedPcieCapability(&bytes, 0x80, 2, 0);

            store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
                .version = 2,
                .type = port_type,
            }));
            store16(&bytes, 0x80 + pcie.device.offsets.control, 0xA91F);
            store16(&bytes, 0x80 + pcie.device.offsets.status, 0xFFFF);

            var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try view.updateDeviceControl(.{ .no_snoop_enable = false });

            const expected: u16 = if (port_type == .pcie_to_pci_bridge) 0xA11F else 0x211F;
            const raw = std.mem.readInt(u16, bytes[0x88..0x8A], .little);

            try testing.expectEqual(expected, raw);
            try testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, bytes[0x8A..0x8C], .little));
            try testing.expectEqual(@as(usize, 1), backend.write_count);
            try testing.expectEqual(@as(usize, 3), backend.access_count);
        }
    }

    test "payload and read-request setters validate values before changing control" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store32(&bytes, 0x80 + pcie.device.offsets.capabilities, 2);
        store16(&bytes, 0x80 + pcie.device.offsets.control, 0x000F);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.InvalidValue, view.setMaxPayloadSize(@enumFromInt(6)));
        try testing.expectError(error.InvalidValue, view.setMaxReadRequestSize(@enumFromInt(7)));
        try testing.expectError(error.UnsupportedFeature, view.setMaxPayloadSize(.bytes_1024));
        try testing.expectEqual(@as(usize, 0), backend.write_count);
        try testing.expectEqual(@as(u16, 0x000F), std.mem.readInt(u16, bytes[0x88..0x8A], .little));

        try view.setMaxPayloadSize(.bytes_512);
        try view.setMaxReadRequestSize(.bytes_1024);

        try testing.expectEqual(@as(u16, 0x304F), std.mem.readInt(u16, bytes[0x88..0x8A], .little));
        try testing.expectEqual(@as(usize, 2), backend.write_count);
    }

    test "link updates preserve reserved controls without replaying retrain" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.link.offsets.control, 0xB824);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try view.updateLinkControl(.{ .common_clock = true });

        try testing.expectEqual(@as(u16, 0xB844), std.mem.readInt(u16, bytes[0x90..0x92], .little));
        try testing.expectEqual(@as(usize, 1), backend.write_count);
    }

    test "slot updates preserve reserved bits and do not toggle the interlock" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.slot.offsets.control, 0xA800);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try view.updateSlotControl(.{ .attention_indicator = .on, .power_control = .off });

        try testing.expectEqual(@as(u16, 0xA440), std.mem.readInt(u16, bytes[0x98..0x9A], .little));
        try testing.expectEqual(@as(usize, 1), backend.write_count);
    }

    test "slot assignments distinguish omitted fields from zero-valued power-on" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.slot.offsets.control, 0x0420);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try view.updateSlotControl(.{
            .presence_detect_changed_enable = true,
            .hot_plug_intr_enable = false,
        });
        try testing.expectEqual(@as(u16, 0x0408), std.mem.readInt(u16, bytes[0x98..0x9A], .little));

        try view.updateSlotControl(.{ .power_control = .on });

        try testing.expectEqual(@as(u16, 0x0008), std.mem.readInt(u16, bytes[0x98..0x9A], .little));
        try testing.expectEqual(@as(usize, 2), backend.write_count);
    }

    test "root partial updates preserve reserved state" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.root.offsets.control, 0xFFE1);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try view.updateRootControl(.{ .crs_software_visibility_enable = true, .pme_interrupt_enable = true });
        try testing.expectEqual(@as(u16, 0xFFF9), std.mem.readInt(u16, bytes[0x9C..0x9E], .little));
    }

    test "device control two updates preserve a power request until explicitly cleared" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.device.offsets.control_2, 0x0800);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try view.updateDeviceControl2(.{ .ari_forwarding_enable = true, .obff_enable = .message_b });
        try testing.expectEqual(@as(u16, 0x4820), std.mem.readInt(u16, bytes[0xA8..0xAA], .little));

        try view.updateDeviceControl2(.{ .emergency_power_reduction_request = false });
        try testing.expectEqual(@as(u16, 0x4020), std.mem.readInt(u16, bytes[0xA8..0xAA], .little));
    }

    test "completion timeout setter validates ranges without changing other controls" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.device.offsets.control_2, 0x4800);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.InvalidValue, view.setCompletionTimeout(@enumFromInt(3)));
        try testing.expectError(error.UnsupportedFeature, view.setCompletionTimeout(.range_b_16ms_55ms));
        try testing.expectEqual(@as(usize, 0), backend.write_count);
        try testing.expectEqual(@as(u16, 0x4800), std.mem.readInt(u16, bytes[0xA8..0xAA], .little));

        store32(&bytes, 0x80 + pcie.device.offsets.capabilities_2, 2);
        try testing.expectError(error.UnsupportedFeature, view.setCompletionTimeout(.range_a_50us_100us));
        try view.setCompletionTimeout(.range_b_16ms_55ms);
        try testing.expectEqual(@as(u16, 0x4805), std.mem.readInt(u16, bytes[0xA8..0xAA], .little));

        store32(&bytes, 0x80 + pcie.device.offsets.capabilities_2, 0);
        try view.setCompletionTimeout(.default);

        try testing.expectEqual(@as(u16, 0x4800), std.mem.readInt(u16, bytes[0xA8..0xAA], .little));
        try testing.expectEqual(@as(usize, 2), backend.write_count);
    }

    test "target speed setter validates membership without retraining or changing compliance" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store32(&bytes, 0x80 + pcie.link.offsets.capabilities_2, 0x12);
        store16(&bytes, 0x80 + pcie.link.offsets.control, 0xA55A);
        store16(&bytes, 0x80 + pcie.link.offsets.control_2, 0xFC11);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.InvalidValue, view.setTargetLinkSpeed(@enumFromInt(0)));
        try testing.expectError(error.UnsupportedFeature, view.setTargetLinkSpeed(.gen2));
        try testing.expectEqual(@as(usize, 0), backend.write_count);

        try view.setTargetLinkSpeed(.gen4);
        try testing.expectEqual(@as(u16, 0xFC14), std.mem.readInt(u16, bytes[0xB0..0xB2], .little));

        try view.updateLinkControl2(.{ .enter_compliance = false, .enter_modified_compliance = false });
        try testing.expectEqual(@as(u16, 0xF804), std.mem.readInt(u16, bytes[0xB0..0xB2], .little));
        try testing.expectEqual(@as(u16, 0xA55A), std.mem.readInt(u16, bytes[0x90..0x92], .little));
    }

    test "control updates propagate a failed write without retries or rollback" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.root.offsets.control, 0xFFE1);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes, .fail_write = true };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedAccessWidth, view.updateRootControl(.{ .pme_interrupt_enable = true }));

        try testing.expectEqual(@as(usize, 1), backend.write_count);
        try testing.expectEqual(@as(u16, 0xFFE1), std.mem.readInt(u16, bytes[0x9C..0x9E], .little));
    }

    test "device acknowledgement writes only selected observed clearable bits" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.device.offsets.status, 0xFFFF);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));
        const observed = try view.deviceStatus();

        try view.ackDeviceStatus(observed, .{ .correctable_error_detected, .unsupported_request_detected });

        try testing.expectEqual(@as(u16, 0xFFF6), std.mem.readInt(u16, bytes[0x8A..0x8C], .little));
        try testing.expectEqual(@as(u32, 0x0009), backend.last_write_value);
        try testing.expectEqual(@as(usize, 0x8A), backend.last_write_offset);
        try testing.expectEqual(@as(usize, 1), backend.write_count);
        try testing.expectEqual(@as(usize, 3), backend.access_count);
    }

    test "link acknowledgements preserve unselected events and read-only status" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.link.offsets.status, 0xFFFF);
        store16(&bytes, 0x80 + pcie.link.offsets.status_2, 0xFFFF);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));
        const observed = try view.linkStatus();
        const observed2 = try view.linkStatus2();

        try view.ackLinkStatus(observed, .{.bw_management});

        try testing.expectEqual(@as(u16, 0xBFFF), std.mem.readInt(u16, bytes[0x92..0x94], .little));
        try testing.expectEqual(@as(u32, 0x4000), backend.last_write_value);

        try view.ackLinkStatus2(observed2, .{.eq_8gt_request});

        try testing.expectEqual(@as(u16, 0xFFDF), std.mem.readInt(u16, bytes[0xB2..0xB4], .little));
        try testing.expectEqual(@as(u32, 0x0020), backend.last_write_value);
        try testing.expectEqual(@as(usize, 2), backend.write_count);
        try testing.expectEqual(@as(usize, 5), backend.access_count);
    }

    test "slot acknowledgement does not clear a selected event absent from the observation" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.slot.offsets.status, 0x00F1);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));
        const observed = try view.slotStatus();

        store16(&bytes, 0x80 + pcie.slot.offsets.status, 0x00F9);
        try view.ackSlotStatus(observed, .{ .attention_button_pressed, .presence_detect_changed });

        try testing.expectEqual(@as(u16, 0x00F8), std.mem.readInt(u16, bytes[0x9A..0x9C], .little));
        try testing.expectEqual(@as(u32, 1), backend.last_write_value);
        try testing.expectEqual(@as(usize, 1), backend.write_count);
        try testing.expectEqual(@as(usize, 3), backend.access_count);
    }

    test "root acknowledgement respects the observation and preserves PME metadata" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store32(&bytes, 0x80 + pcie.root.offsets.status, 0x0002_1234);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));
        const observed = try view.rootStatus();

        store32(&bytes, 0x80 + pcie.root.offsets.status, 0x0003_1234);
        try view.ackRootStatus(observed, .{.pme_status});

        try testing.expectEqual(@as(u32, 0x0003_1234), std.mem.readInt(u32, bytes[0xA0..0xA4], .little));
        try testing.expectEqual(@as(u32, 0), backend.last_write_value);
        try testing.expectEqual(@as(usize, 3), backend.access_count);

        const pending = try view.rootStatus();
        try view.ackRootStatus(pending, .{.pme_status});

        try testing.expectEqual(@as(u32, 0x0002_1234), std.mem.readInt(u32, bytes[0xA0..0xA4], .little));
        try testing.expectEqual(@as(u32, 0x0001_0000), backend.last_write_value);
        try testing.expectEqual(@as(usize, 2), backend.write_count);
        try testing.expectEqual(@as(usize, 5), backend.access_count);
    }

    test "FLR requests preserve controls and do not poll pending transactions or access after the write" {
        const ports = [_]DevicePortType{ .endpoint, .legacy_endpoint, .root_complex_integrated_endpoint };

        for (ports) |port_type| {
            var bytes: [pcie_window_size]u8 = @splat(0);
            seedPcieCapability(&bytes, 0x80, 1, 0);
            store16(&bytes, core.header.offsets.command, 7);
            store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
                .version = 1,
                .type = port_type,
            }));
            store32(&bytes, 0x80 + pcie.device.offsets.capabilities, 1 << 28);
            store16(&bytes, 0x80 + pcie.device.offsets.control, 0x2BCD);
            store16(&bytes, 0x80 + pcie.device.offsets.status, 0xFFFF);

            var backend = ConfigBackend{
                .version = 1,
                .bytes = &bytes,
                .fail_read = 0x80 + pcie.device.offsets.status,
            };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try view.requestFlr();

            try testing.expectEqual(@as(u32, 0xABCD), backend.last_write_value);
            try testing.expectEqual(@as(usize, 0x88), backend.last_write_offset);
            try testing.expectEqual(@as(usize, 1), backend.write_count);
            try testing.expectEqual(@as(usize, 4), backend.access_count);
            try testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, bytes[4..6], .little));
            try testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, bytes[0x8A..0x8C], .little));
        }
    }

    test "FLR rejects bridge and unknown roles before backend access" {
        for (0..16) |encoding| {
            const port_type: DevicePortType = @enumFromInt(encoding);
            switch (port_type) {
                .endpoint, .legacy_endpoint, .root_complex_integrated_endpoint => continue,
                else => {},
            }

            var backend = ConfigBackend{ .version = 2, .port_type = port_type };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try testing.expectError(error.UnsupportedRegister, view.requestFlr());
            try testing.expectEqual(@as(usize, 1), backend.access_count);
            try testing.expectEqual(@as(usize, 0), backend.write_count);
        }
    }

    test "FLR support rejection precedes control reads on every eligible role" {
        const ports = [_]DevicePortType{ .endpoint, .legacy_endpoint, .root_complex_integrated_endpoint };

        for (ports) |port_type| {
            var bytes: [pcie_window_size]u8 = @splat(0);
            seedPcieCapability(&bytes, 0x80, 2, 0);
            store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
                .version = 2,
                .type = port_type,
            }));

            var backend = ConfigBackend{
                .version = 2,
                .bytes = &bytes,
                .fail_read = 0x80 + pcie.device.offsets.control,
            };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try testing.expectError(error.UnsupportedFeature, view.requestFlr());
            try testing.expectEqual(@as(usize, 2), backend.access_count);
            try testing.expectEqual(@as(usize, 0), backend.write_count);
        }
    }

    test "FLR read failures stop the sequence before any request write" {
        const fail_offsets = [_]usize{
            0x80 + pcie.device.offsets.capabilities,
            0x80 + pcie.device.offsets.control,
        };

        for (fail_offsets, 0..) |fail_offset, index| {
            var bytes: [pcie_window_size]u8 = @splat(0);
            seedPcieCapability(&bytes, 0x80, 2, 0);
            store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
                .version = 2,
                .type = .endpoint,
            }));
            store32(&bytes, 0x80 + pcie.device.offsets.capabilities, 1 << 28);

            var backend = ConfigBackend{ .version = 2, .bytes = &bytes, .fail_read = fail_offset };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try testing.expectError(error.UnsupportedAccessWidth, view.requestFlr());
            try testing.expectEqual(@as(usize, 2) + index, backend.access_count);
            try testing.expectEqual(@as(usize, 0), backend.write_count);
        }
    }

    test "FLR write failure propagates without retry readback or rollback" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
            .version = 2,
            .type = .endpoint,
        }));
        store32(&bytes, 0x80 + pcie.device.offsets.capabilities, 1 << 28);
        store16(&bytes, 0x80 + pcie.device.offsets.control, 0x2BCD);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes, .fail_write = true };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedAccessWidth, view.requestFlr());

        try testing.expectEqual(@as(u32, 0xABCD), backend.last_write_value);
        try testing.expectEqual(@as(usize, 1), backend.write_count);
        try testing.expectEqual(@as(usize, 4), backend.access_count);
        try testing.expectEqual(@as(u16, 0x2BCD), std.mem.readInt(u16, bytes[0x88..0x8A], .little));
    }

    test "retrain requests preserve controls without polling or observing completion" {
        const ports = [_]DevicePortType{ .root_port, .downstream, .pci_to_pcie_bridge };

        for (ports) |port_type| {
            var bytes: [pcie_window_size]u8 = @splat(0);
            seedPcieCapability(&bytes, 0x80, 1, 0);
            store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
                .version = 1,
                .type = port_type,
            }));
            store16(&bytes, 0x80 + pcie.link.offsets.control, 0xA14B);
            store16(&bytes, 0x80 + pcie.link.offsets.status, 0xA800);

            var backend = ConfigBackend{ .version = 1, .bytes = &bytes };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try view.retrainLink();

            try testing.expectEqual(@as(u32, 0xA16B), backend.last_write_value);
            try testing.expectEqual(@as(usize, 0x90), backend.last_write_offset);
            try testing.expectEqual(@as(u16, 0xA14B), std.mem.readInt(u16, bytes[0x90..0x92], .little));
            try testing.expectEqual(@as(u16, 0xA800), std.mem.readInt(u16, bytes[0x92..0x94], .little));
            try testing.expectEqual(@as(usize, 1), backend.write_count);
            try testing.expectEqual(@as(usize, 3), backend.access_count);
        }
    }

    test "retrain rejects roles where the action is reserved before backend I/O" {
        const ports = [_]DevicePortType{
            .endpoint,
            .legacy_endpoint,
            .upstream,
            .pcie_to_pci_bridge,
            .root_complex_integrated_endpoint,
            .root_complex_event_collector,
            @enumFromInt(0xF),
        };

        for (ports) |port_type| {
            var backend = ConfigBackend{ .version = 2, .port_type = port_type };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try testing.expectError(error.UnsupportedRegister, view.retrainLink());
            try testing.expectEqual(@as(usize, 1), backend.access_count);
        }
    }

    test "interlock action checks support and preserves controls without waiting" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 1, 0);
        store16(&bytes, 0x80 + pcie.slot.offsets.control, 0xA441);
        store16(&bytes, 0x80 + pcie.slot.offsets.status, 0x0080);

        var backend = ConfigBackend{ .version = 1, .bytes = &bytes };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedFeature, view.toggleInterlock());
        try testing.expectEqual(@as(usize, 2), backend.access_count);
        try testing.expectEqual(@as(usize, 0), backend.write_count);

        store32(&bytes, 0x80 + pcie.slot.offsets.capabilities, 1 << 17);
        try view.toggleInterlock();

        try testing.expectEqual(@as(u32, 0xAC41), backend.last_write_value);
        try testing.expectEqual(@as(usize, 0x98), backend.last_write_offset);
        try testing.expectEqual(@as(u16, 0xA441), std.mem.readInt(u16, bytes[0x98..0x9A], .little));
        try testing.expectEqual(@as(u16, 0x0080), std.mem.readInt(u16, bytes[0x9A..0x9C], .little));
        try testing.expectEqual(@as(usize, 1), backend.write_count);
        try testing.expectEqual(@as(usize, 5), backend.access_count);
    }

    test "acknowledgement and action write failures propagate without retry or rollback" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store32(&bytes, 0x80 + pcie.slot.offsets.capabilities, 1 << 17);
        store16(&bytes, 0x80 + pcie.device.offsets.status, 1);
        store16(&bytes, 0x80 + pcie.link.offsets.control, 0xA14B);
        store16(&bytes, 0x80 + pcie.slot.offsets.control, 0xA441);
        store32(&bytes, 0x80 + pcie.root.offsets.status, 0x0003_1234);

        var backend = ConfigBackend{ .version = 2, .bytes = &bytes, .fail_write = true };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedAccessWidth, view.ackDeviceStatus(.{ .correctable_error_detected = true }, .{.correctable_error_detected}));
        try testing.expectError(error.UnsupportedAccessWidth, view.ackRootStatus(.{ .pme_status = true }, .{.pme_status}));
        try testing.expectError(error.UnsupportedAccessWidth, view.retrainLink());
        try testing.expectError(error.UnsupportedAccessWidth, view.toggleInterlock());

        try testing.expectEqual(@as(usize, 4), backend.write_count);
        try testing.expectEqual(@as(usize, 8), backend.access_count);
        try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[0x8A..0x8C], .little));
        try testing.expectEqual(@as(u16, 0xA14B), std.mem.readInt(u16, bytes[0x90..0x92], .little));
        try testing.expectEqual(@as(u16, 0xA441), std.mem.readInt(u16, bytes[0x98..0x9A], .little));
        try testing.expectEqual(@as(u32, 0x0003_1234), std.mem.readInt(u32, bytes[0xA0..0xA4], .little));
    }

    test "v2 accessors gate UnsupportedRevision before config access" {
        var backend = ConfigBackend{ .version = 1, .port_type = .root_complex_integrated_endpoint };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedRevision, view.deviceCapabilities2());
        try testing.expectError(error.UnsupportedRevision, view.deviceControl2());
        try testing.expectError(error.UnsupportedRevision, view.updateDeviceControl2(.{}));
        try testing.expectError(error.UnsupportedRevision, view.linkCapabilities2());
        try testing.expectError(error.UnsupportedRevision, view.linkControl2());
        try testing.expectError(error.UnsupportedRevision, view.updateLinkControl2(.{}));
        try testing.expectError(error.UnsupportedRevision, view.setCompletionTimeout(@enumFromInt(3)));
        try testing.expectError(error.UnsupportedRevision, view.setTargetLinkSpeed(@enumFromInt(0)));
        try testing.expectError(error.UnsupportedRevision, view.linkStatus2());
        try testing.expectError(
            error.UnsupportedRevision,
            view.ackLinkStatus2(.{}, .{.drs_received}),
        );
        try testing.expectError(error.UnsupportedRevision, view.slotCapabilities2());

        try testing.expectEqual(@as(usize, 1), backend.access_count);
    }

    test "linkless roles reject link access before backend I/O" {
        const linkless = [_]DevicePortType{
            .root_complex_integrated_endpoint,
            .root_complex_event_collector,
            @enumFromInt(0xF),
        };

        for (linkless) |port_type| {
            var backend = ConfigBackend{ .version = 2, .port_type = port_type };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try testing.expectError(error.UnsupportedRegister, view.linkCapabilities());
            try testing.expectError(error.UnsupportedRegister, view.linkControl());
            try testing.expectError(error.UnsupportedRegister, view.updateLinkControl(.{}));
            try testing.expectError(error.UnsupportedRegister, view.linkStatus());
            try testing.expectError(error.UnsupportedRegister, view.ackLinkStatus(.{}, .{.bw_management}));
            try testing.expectError(error.UnsupportedRegister, view.linkCapabilities2());
            try testing.expectError(error.UnsupportedRegister, view.linkControl2());
            try testing.expectError(error.UnsupportedRegister, view.updateLinkControl2(.{}));
            try testing.expectError(error.UnsupportedRegister, view.setTargetLinkSpeed(@enumFromInt(0)));
            try testing.expectError(error.UnsupportedRegister, view.linkStatus2());
            try testing.expectError(error.UnsupportedRegister, view.ackLinkStatus2(.{}, .{.eq_8gt_request}));
            try testing.expectEqual(@as(usize, 1), backend.access_count);
        }
    }

    test "upstream-facing and linkless roles reject slot access before backend I/O" {
        const slotless = [_]DevicePortType{
            .endpoint,                         .legacy_endpoint,              .upstream,         .pcie_to_pci_bridge,
            .root_complex_integrated_endpoint, .root_complex_event_collector, @enumFromInt(0xF),
        };

        for (slotless) |port_type| {
            var backend = ConfigBackend{ .version = 2, .port_type = port_type };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try testing.expectError(error.UnsupportedRegister, view.slotCapabilities());
            try testing.expectError(error.UnsupportedRegister, view.slotControl());
            try testing.expectError(error.UnsupportedRegister, view.updateSlotControl(.{}));
            try testing.expectError(error.UnsupportedRegister, view.slotStatus());
            try testing.expectError(error.UnsupportedRegister, view.ackSlotStatus(.{}, .{.presence_detect_changed}));
            try testing.expectError(error.UnsupportedRegister, view.toggleInterlock());
            try testing.expectError(error.UnsupportedRegister, view.slotCapabilities2());
            try testing.expectEqual(@as(usize, 1), backend.access_count);
        }
    }

    test "non-root roles reject root access before backend I/O" {
        const non_root = [_]DevicePortType{
            .endpoint,           .legacy_endpoint,                  .upstream,         .downstream, .pcie_to_pci_bridge,
            .pci_to_pcie_bridge, .root_complex_integrated_endpoint, @enumFromInt(0xF),
        };

        for (non_root) |port_type| {
            var backend = ConfigBackend{ .version = 2, .port_type = port_type };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try testing.expectError(error.UnsupportedRegister, view.rootControl());
            try testing.expectError(error.UnsupportedRegister, view.updateRootControl(.{}));
            try testing.expectError(error.UnsupportedRegister, view.rootCapabilities());
            try testing.expectError(error.UnsupportedRegister, view.rootStatus());
            try testing.expectError(error.UnsupportedRegister, view.ackRootStatus(.{}, .{.pme_status}));
            try testing.expectEqual(@as(usize, 1), backend.access_count);
        }
    }

    test "link-bearing roles reach the backend and preserve its errors" {
        const ports = [_]DevicePortType{
            .endpoint,   .legacy_endpoint,    .root_port,          .upstream,
            .downstream, .pcie_to_pci_bridge, .pci_to_pcie_bridge,
        };

        for (ports) |port_type| {
            var backend = ConfigBackend{ .version = 2, .port_type = port_type };
            const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

            try testing.expectError(error.UnsupportedAccessWidth, view.linkStatus());
            try testing.expectError(error.UnsupportedAccessWidth, view.updateLinkControl(.{}));
            try testing.expectError(error.UnsupportedAccessWidth, view.linkStatus2());
            try testing.expectError(error.UnsupportedAccessWidth, view.updateLinkControl2(.{}));
            try testing.expectEqual(@as(usize, 5), backend.access_count);
        }
    }

    test "RCEC root status remains accessible without a link" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);
        store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
            .version = 2,
            .type = .root_complex_event_collector,
        }));
        store32(&bytes, 0x80 + pcie.root.offsets.status, 0x0001_1234);

        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0x80));

        const root_status = try view.rootStatus();

        try testing.expect(root_status.pme_status);
        try testing.expectEqual(@as(u16, 0x1234), root_status.pme_requester_id);
        try testing.expectError(error.UnsupportedRegister, view.linkStatus());
    }

    test "downstream slot registers remain inspectable without an implemented slot" {
        const ports = [_]DevicePortType{ .root_port, .downstream, .pci_to_pcie_bridge };

        for (ports) |port_type| {
            var bytes: [pcie_window_size]u8 = @splat(0);
            seedPcieCapability(&bytes, 0x80, 2, 0);
            store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
                .version = 2,
                .type = port_type,
            }));
            store32(&bytes, 0x80 + pcie.link.offsets.capabilities, 1 << 20);
            store16(&bytes, 0x80 + pcie.slot.offsets.status, 1 << 8);
            store32(&bytes, 0x80 + pcie.slot.offsets.capabilities_2, 1);

            var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
            const view = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0x80));

            try testing.expect(!view.has_slot);
            try testing.expect((try view.linkCapabilities()).dll_active_report_capable);
            try testing.expect((try view.slotStatus()).dll_state_changed);
            try testing.expect((try view.slotCapabilities2()).in_band_pd_disable_supported);
        }
    }

    test "structural metadata stays fixed while capabilities remain live" {
        var bytes: [pcie_window_size]u8 = @splat(0);
        seedPcieCapability(&bytes, 0x80, 2, 0);

        var backend = TestConfigSpace.fromSingle(test_sbdf, &bytes);
        const view = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0x80));

        store16(&bytes, 0x80 + pcie.offsets.capabilities, pcie.Capabilities.encode(.{
            .version = 1,
            .type = .root_complex_integrated_endpoint,
        }));
        store16(&bytes, 0x80 + pcie.root.offsets.control, 1 << 3);

        try testing.expectEqual(@as(u4, 2), view.version);
        try testing.expectEqual(DevicePortType.root_port, view.type);
        try testing.expect(view.has_slot);
        try testing.expect((try view.rootControl()).pme_interrupt_enable);
        try testing.expectEqual(DevicePortType.root_complex_integrated_endpoint, (try view.capabilities()).type);

        const refreshed = try Pcie.tryFrom(makeFunction(&backend), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedRegister, refreshed.rootControl());
        try testing.expectError(error.UnsupportedRevision, refreshed.linkCapabilities2());
    }

    test "backend errors propagate after capability validation succeeds" {
        var backend = ConfigBackend{ .version = 2 };
        const view = try Pcie.tryFrom(Function.from(backend.config(), test_sbdf), capabilityAt(0x80));

        try testing.expectError(error.UnsupportedAccessWidth, view.deviceCapabilities());
        try testing.expectError(error.UnsupportedAccessWidth, view.updateDeviceControl(.{}));
        try testing.expectError(error.UnsupportedAccessWidth, view.deviceCapabilities2());
        try testing.expectError(error.UnsupportedAccessWidth, view.updateLinkControl2(.{}));
        try testing.expectError(error.UnsupportedAccessWidth, view.setMaxPayloadSize(.bytes_512));
        try testing.expectError(error.UnsupportedAccessWidth, view.setMaxReadRequestSize(.bytes_512));
        try testing.expectError(error.UnsupportedAccessWidth, view.setCompletionTimeout(.default));
        try testing.expectError(error.UnsupportedAccessWidth, view.setTargetLinkSpeed(.gen1));
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
        try testing.expectError(error.MalformedCapability, view.updateDeviceControl2(.{}));
        try testing.expectEqualSlices(u8, &before, &bytes);

        var guard = ConfigBackend{ .version = 2 };
        const invalid: Pcie = .{
            .registers = .{ .function = Function.from(guard.config(), test_sbdf), .base = 0xFC },
            .version = 2,
            .type = .root_port,
            .has_slot = true,
        };

        try testing.expectError(error.MalformedCapability, invalid.deviceCapabilities());
        try testing.expectError(error.MalformedCapability, invalid.updateDeviceControl(.{}));
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
        store16(bytes, header.offsets.status, header.Status.mask(.cap_list));
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
};
