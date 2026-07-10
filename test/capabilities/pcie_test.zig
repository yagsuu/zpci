//! Tests for docs/specs/capabilities/pcie.md.

const std = @import("std");

const stdx = @import("stdx");
const zpci = @import("zpci");

const Capability = zpci.capabilities.list.Capability;
const ConfigSpace = zpci.config.ConfigSpace;
const Function = zpci.config.Function;
const Id = zpci.capabilities.list.Id;
const Sbdf = zpci.core.Sbdf;
const TestConfigSpace = zpci.testing.config.TestConfigSpace;

const pcie = zpci.capabilities.pcie;
const register = pcie.register;
const function_window_size: usize = 0x1000;
const test_sbdf = Sbdf.of(0, 0, 0, 0);
const standard = zpci.capabilities.list.standard;
const status = struct {
    const capabilities_list: u16 = 1 << 4;
};
const offset = struct {
    const status: usize = 0x06;
};

test "layout: public register constants match PCIe register map" {
    // Compare the public offsets against the PCIe capability map, grouped by register block.
    try std.testing.expectEqual(@as(u8, 0x02), register.capabilities);
    try std.testing.expectEqual(@as(u8, 0x04), register.device.capabilities);
    try std.testing.expectEqual(@as(u8, 0x08), register.device.control);
    try std.testing.expectEqual(@as(u8, 0x0A), register.device.status);
    try std.testing.expectEqual(@as(u8, 0x0C), register.link.capabilities);
    try std.testing.expectEqual(@as(u8, 0x10), register.link.control);
    try std.testing.expectEqual(@as(u8, 0x12), register.link.status);
    try std.testing.expectEqual(@as(u8, 0x14), register.slot.capabilities);
    try std.testing.expectEqual(@as(u8, 0x18), register.slot.control);
    try std.testing.expectEqual(@as(u8, 0x1A), register.slot.status);
    try std.testing.expectEqual(@as(u8, 0x1C), register.root.control);
    try std.testing.expectEqual(@as(u8, 0x1E), register.root.capabilities);
    try std.testing.expectEqual(@as(u8, 0x20), register.root.status);
    try std.testing.expectEqual(@as(u8, 0x24), register.device.capabilities_2);
    try std.testing.expectEqual(@as(u8, 0x28), register.device.control_2);
    try std.testing.expectEqual(@as(u8, 0x2A), register.device.status_2);
    try std.testing.expectEqual(@as(u8, 0x2C), register.link.capabilities_2);
    try std.testing.expectEqual(@as(u8, 0x30), register.link.control_2);
    try std.testing.expectEqual(@as(u8, 0x32), register.link.status_2);
    try std.testing.expectEqual(@as(u8, 0x34), register.slot.capabilities_2);
    try std.testing.expectEqual(@as(u8, 0x38), register.slot.control_2);
    try std.testing.expectEqual(@as(u8, 0x3A), register.slot.status_2);
    try std.testing.expectEqual(@as(u8, 0x3C), pcie.total_size);
}

test "layout: packed registers have spec bit widths and discriminating bit offsets" {
    // These checks pin the wire-order fields that would silently corrupt typed config I/O.
    try expectBitSize(pcie.Capabilities, 16);
    try expectBitSize(pcie.DeviceCapabilities, 32);
    try expectBitSize(pcie.DeviceControl, 16);
    try expectBitSize(pcie.DeviceStatus, 16);
    try expectBitSize(pcie.LinkCapabilities, 32);
    try expectBitSize(pcie.LinkControl, 16);
    try expectBitSize(pcie.LinkStatus, 16);
    try expectBitSize(pcie.SlotCapabilities, 32);
    try expectBitSize(pcie.SlotControl, 16);
    try expectBitSize(pcie.SlotStatus, 16);
    try expectBitSize(pcie.RootControl, 16);
    try expectBitSize(pcie.RootCapabilities, 16);
    try expectBitSize(pcie.RootStatus, 32);
    try expectBitSize(pcie.DeviceCapabilities2, 32);
    try expectBitSize(pcie.DeviceControl2, 16);
    try expectBitSize(pcie.DeviceStatus2, 16);
    try expectBitSize(pcie.LinkCapabilities2, 32);
    try expectBitSize(pcie.LinkControl2, 16);
    try expectBitSize(pcie.LinkStatus2, 16);
    try expectBitSize(pcie.SlotCapabilities2, 32);
    try expectBitSize(pcie.SlotControl2, 16);
    try expectBitSize(pcie.SlotStatus2, 16);

    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(pcie.Capabilities, "version"));
    try std.testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(pcie.Capabilities, "device_port_type"));
    try std.testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(pcie.Capabilities, "slot_implemented"));
    try std.testing.expectEqual(@as(comptime_int, 14), @bitOffsetOf(pcie.Capabilities, "_reserved_14"));
    try std.testing.expectEqual(@as(comptime_int, 5), @bitOffsetOf(pcie.DeviceControl, "max_payload_size"));
    try std.testing.expectEqual(@as(comptime_int, 12), @bitOffsetOf(pcie.DeviceControl, "max_read_request_size"));
    try std.testing.expectEqual(@as(comptime_int, 15), @bitOffsetOf(pcie.DeviceControl, "bcre_initiate_flr"));
    try std.testing.expectEqual(
        @as(comptime_int, 6),
        @bitOffsetOf(pcie.DeviceStatus, "emergency_power_reduction_detected"),
    );
    try std.testing.expectEqual(@as(comptime_int, 7), @bitOffsetOf(pcie.DeviceStatus, "_reserved_7"));
    try std.testing.expectEqual(@as(comptime_int, 4), @bitOffsetOf(pcie.LinkCapabilities, "max_link_width"));
    try std.testing.expectEqual(@as(comptime_int, 10), @bitOffsetOf(pcie.LinkCapabilities, "aspm_support"));
    try std.testing.expectEqual(@as(comptime_int, 24), @bitOffsetOf(pcie.LinkCapabilities, "port_number"));
    try std.testing.expectEqual(@as(comptime_int, 14), @bitOffsetOf(pcie.LinkControl, "drs_signaling_control"));
    try std.testing.expectEqual(
        @as(comptime_int, 14),
        @bitOffsetOf(pcie.LinkStatus, "link_bandwidth_management_status"),
    );
    try std.testing.expectEqual(
        @as(comptime_int, 15),
        @bitOffsetOf(pcie.LinkStatus, "link_autonomous_bandwidth_status"),
    );
    try std.testing.expectEqual(@as(comptime_int, 6), @bitOffsetOf(pcie.SlotControl, "attention_indicator_control"));
    try std.testing.expectEqual(
        @as(comptime_int, 12),
        @bitOffsetOf(pcie.SlotControl, "data_link_layer_state_changed_enable"),
    );
    try std.testing.expectEqual(@as(comptime_int, 8), @bitOffsetOf(pcie.SlotStatus, "data_link_layer_state_changed"));
    try std.testing.expectEqual(@as(comptime_int, 16), @bitOffsetOf(pcie.RootStatus, "pme_status"));
    try std.testing.expectEqual(@as(comptime_int, 17), @bitOffsetOf(pcie.RootStatus, "pme_pending"));
    try std.testing.expectEqual(
        @as(comptime_int, 4),
        @bitOffsetOf(pcie.DeviceControl2, "completion_timeout_disable"),
    );
    try std.testing.expectEqual(@as(comptime_int, 13), @bitOffsetOf(pcie.DeviceControl2, "obff_enable"));
    try std.testing.expectEqual(
        @as(comptime_int, 1),
        @bitOffsetOf(pcie.LinkCapabilities2, "supported_link_speeds_vector"),
    );
    try std.testing.expectEqual(@as(comptime_int, 25), @bitOffsetOf(pcie.LinkCapabilities2, "_reserved_25"));
    try std.testing.expectEqual(@as(comptime_int, 0), @bitOffsetOf(pcie.LinkControl2, "target_link_speed"));
    try std.testing.expectEqual(
        @as(comptime_int, 12),
        @bitOffsetOf(pcie.LinkControl2, "compliance_preset_or_deemphasis"),
    );
    try std.testing.expectEqual(
        @as(comptime_int, 5),
        @bitOffsetOf(pcie.LinkStatus2, "link_equalization_request_8gt"),
    );
    try std.testing.expectEqual(@as(comptime_int, 15), @bitOffsetOf(pcie.LinkStatus2, "drs_message_received"));
}

test "unit: enum helpers map named encodings and reject reserved encodings" {
    // Table cases cover every helper boundary: lowest valid, highest valid, and reserved holes.
    try expectPayloadBytes(.bytes_128, 128);
    try expectPayloadBytes(.bytes_256, 256);
    try expectPayloadBytes(.bytes_512, 512);
    try expectPayloadBytes(.bytes_1024, 1024);
    try expectPayloadBytes(.bytes_2048, 2048);
    try expectPayloadBytes(.bytes_4096, 4096);
    try std.testing.expectError(error.MalformedField, (@as(pcie.MaxPayloadSize, @enumFromInt(6))).bytes());
    try std.testing.expectError(error.MalformedField, (@as(pcie.MaxPayloadSize, @enumFromInt(7))).bytes());

    try expectReadRequestBytes(.bytes_128, 128);
    try expectReadRequestBytes(.bytes_4096, 4096);
    try std.testing.expectError(error.MalformedField, (@as(pcie.MaxReadRequestSize, @enumFromInt(6))).bytes());
    try std.testing.expectError(error.MalformedField, (@as(pcie.MaxReadRequestSize, @enumFromInt(7))).bytes());

    try expectLinkSpeed(.gen1, 2500);
    try expectLinkSpeed(.gen2, 5000);
    try expectLinkSpeed(.gen3, 8000);
    try expectLinkSpeed(.gen4, 16000);
    try expectLinkSpeed(.gen5, 32000);
    try expectLinkSpeed(.gen6, 64000);
    try std.testing.expectError(
        error.MalformedField,
        (@as(pcie.MaxLinkSpeed, @enumFromInt(0))).megaTransfersPerSecond(),
    );
    try std.testing.expectError(
        error.MalformedField,
        (@as(pcie.MaxLinkSpeed, @enumFromInt(7))).megaTransfersPerSecond(),
    );
    try std.testing.expectError(
        error.MalformedField,
        (@as(pcie.MaxLinkSpeed, @enumFromInt(15))).megaTransfersPerSecond(),
    );

    try expectLinkWidth(.x1, 1);
    try expectLinkWidth(.x2, 2);
    try expectLinkWidth(.x4, 4);
    try expectLinkWidth(.x8, 8);
    try expectLinkWidth(.x12, 12);
    try expectLinkWidth(.x16, 16);
    try expectLinkWidth(.x32, 32);
    try std.testing.expectError(error.MalformedField, (@as(pcie.MaxLinkWidth, @enumFromInt(0))).lanes());
    try std.testing.expectError(error.MalformedField, (@as(pcie.MaxLinkWidth, @enumFromInt(3))).lanes());
    try std.testing.expectError(error.MalformedField, (@as(pcie.MaxLinkWidth, @enumFromInt(63))).lanes());
}

test "unit: validate accepts PCIe capabilities and rejects malformed offsets and revision zero" {
    // Direct validation must cache version from the capability body and reject only offset/revision defects.
    var bytes: [function_window_size]u8 = @splat(0);
    seedPcieCapability(&bytes, 0x80, 1, 0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const function = uncheckedFunction(&backend);

    const view = try pcie.View.validate(function, capabilityAt(0x80));

    try std.testing.expectEqual(@as(u8, 0x80), view.base);
    try std.testing.expectEqual(@as(u4, 1), view.version);
    try std.testing.expectEqual(@as(u16, makeCapabilities(1)), @as(u16, @bitCast(try view.capabilities())));

    try std.testing.expectError(
        error.MalformedCapability,
        pcie.View.validate(function, capabilityAt(standard.window.start - 4)),
    );
    try std.testing.expectError(
        error.MalformedCapability,
        pcie.View.validate(function, capabilityAt(standard.window.start + 1)),
    );

    store16(&bytes, 0x80 + register.capabilities, makeCapabilities(0));
    try std.testing.expectError(error.UnsupportedRevision, pcie.View.validate(function, capabilityAt(0x80)));
}

test "unit: find returns PCIe view, null for absence, and propagates malformed traversal" {
    // The PCIe finder is responsible for preserving list walk errors instead of reporting absence.
    var found_bytes: [function_window_size]u8 = @splat(0);
    seedHead(&found_bytes, 0x40);
    seedCapabilityNode(&found_bytes, 0x40, @intFromEnum(Id.msi), 0x80);
    seedPcieCapability(&found_bytes, 0x80, 2, 0);
    var found_backend = TestConfigSpace.initSingle(test_sbdf, &found_bytes);
    const found_function = uncheckedFunction(&found_backend);

    const view = (try pcie.View.find(found_function)).?;
    try std.testing.expectEqual(@as(u8, 0x80), view.base);
    try std.testing.expectEqual(@as(u4, 2), view.version);

    var absent_bytes: [function_window_size]u8 = @splat(0);
    seedHead(&absent_bytes, 0x40);
    seedCapabilityNode(&absent_bytes, 0x40, @intFromEnum(Id.msi), 0);
    var absent_backend = TestConfigSpace.initSingle(test_sbdf, &absent_bytes);
    try std.testing.expectEqual(@as(?pcie.View, null), try pcie.View.find(uncheckedFunction(&absent_backend)));

    var cycle_bytes: [function_window_size]u8 = @splat(0);
    seedHead(&cycle_bytes, 0x40);
    seedCapabilityNode(&cycle_bytes, 0x40, @intFromEnum(Id.msi), 0x44);
    seedCapabilityNode(&cycle_bytes, 0x44, @intFromEnum(Id.msi_x), 0x40);
    var cycle_backend = TestConfigSpace.initSingle(test_sbdf, &cycle_bytes);
    try std.testing.expectError(error.MalformedCapability, pcie.View.find(uncheckedFunction(&cycle_backend)));

    var malformed_bytes: [function_window_size]u8 = @splat(0);
    seedHead(&malformed_bytes, 0x40);
    seedCapabilityNode(&malformed_bytes, 0x40, @intFromEnum(Id.msi), 0x42);
    var malformed_backend = TestConfigSpace.initSingle(test_sbdf, &malformed_bytes);
    try std.testing.expectError(error.MalformedCapability, pcie.View.find(uncheckedFunction(&malformed_backend)));
}

test "unit: v1 accessors read exact base-relative whole registers" {
    // Distinct raw values across device/link/slot/root registers expose wrong offsets and hidden RMW writes.
    var bytes: [function_window_size]u8 = @splat(0);
    seedPcieCapability(&bytes, 0x80, 1, 0);
    store32(&bytes, 0x80 + register.device.capabilities, 0xA39C_5A15);
    store16(&bytes, 0x80 + register.device.control, 0xFFFF);
    store16(&bytes, 0x80 + register.device.status, 0xFFFF);
    store32(&bytes, 0x80 + register.link.capabilities, 0x5A7E_3C21);
    store16(&bytes, 0x80 + register.link.control, 0xFFFF);
    store16(&bytes, 0x80 + register.link.status, 0xFFFF);
    store32(&bytes, 0x80 + register.slot.capabilities, 0x7BDF_93C1);
    store16(&bytes, 0x80 + register.slot.control, 0xFFFF);
    store16(&bytes, 0x80 + register.slot.status, 0xFFFF);
    store16(&bytes, 0x80 + register.root.control, 0xFFFF);
    store16(&bytes, 0x80 + register.root.capabilities, 0x0001);
    store32(&bytes, 0x80 + register.root.status, 0xBEEF_0000);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const view = try pcie.View.validate(uncheckedFunction(&backend), capabilityAt(0x80));

    try std.testing.expectEqual(@as(u32, 0xA39C_5A15), @as(u32, @bitCast(try view.deviceCapabilities())));
    try std.testing.expectEqual(@as(u32, 0x5A7E_3C21), @as(u32, @bitCast(try view.linkCapabilities())));
    try std.testing.expectEqual(@as(u32, 0x7BDF_93C1), @as(u32, @bitCast(try view.slotCapabilities())));
    try std.testing.expectEqual(@as(u16, 0x0001), @as(u16, @bitCast(try view.rootCapabilities())));
    try std.testing.expectEqual(@as(u32, 0xBEEF_0000), @as(u32, @bitCast(try view.rootStatus())));
}

test "unit: v1 accessors write exact base-relative whole registers" {
    // Distinct values across device/link/slot/root registers expose wrong offsets and hidden RMW writes.
    var bytes: [function_window_size]u8 = @splat(0);
    seedPcieCapability(&bytes, 0x80, 1, 0);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const view = try pcie.View.validate(uncheckedFunction(&backend), capabilityAt(0x80));

    const device_control = pcie.DeviceControl{
        .correctable_error_reporting_enable = true,
        .max_payload_size = .bytes_512,
        .max_read_request_size = .bytes_1024,
    };
    const link_control = pcie.LinkControl{
        .aspm_control = .l1,
        .retrain_link = true,
        .link_bandwidth_management_interrupt_enable = true,
    };
    const slot_control = pcie.SlotControl{
        .attention_button_pressed_enable = true,
        .attention_indicator_control = 0b10,
        .power_indicator_control = 0b01,
        .data_link_layer_state_changed_enable = true,
    };
    const root_control = pcie.RootControl{
        .system_error_on_fatal_error_enable = true,
        .pme_interrupt_enable = true,
    };

    try view.setDeviceControl(device_control);
    try view.setLinkControl(link_control);
    try view.setSlotControl(slot_control);
    try view.setRootControl(root_control);

    try std.testing.expectEqual(@as(u16, @bitCast(device_control)), load16(&bytes, 0x80 + register.device.control));
    try std.testing.expectEqual(@as(u16, @bitCast(link_control)), load16(&bytes, 0x80 + register.link.control));
    try std.testing.expectEqual(@as(u16, @bitCast(slot_control)), load16(&bytes, 0x80 + register.slot.control));
    try std.testing.expectEqual(@as(u16, @bitCast(root_control)), load16(&bytes, 0x80 + register.root.control));

    const device_status = pcie.DeviceStatus{
        .correctable_error_detected = true,
        .unsupported_request_detected = true,
        .emergency_power_reduction_detected = true,
    };
    const link_status = pcie.LinkStatus{
        .link_bandwidth_management_status = true,
    };
    const slot_status = pcie.SlotStatus{
        .attention_button_pressed = true,
        .command_completed = true,
        .data_link_layer_state_changed = true,
    };
    const root_status = pcie.RootStatus{
        .pme_status = true,
    };

    try view.clearDeviceStatusBits(device_status);
    try view.clearLinkStatusBits(link_status);
    try view.clearSlotStatusBits(slot_status);
    try view.clearRootStatusBits(root_status);

    try std.testing.expectEqual(@as(u16, @bitCast(device_status)), load16(&bytes, 0x80 + register.device.status));
    try std.testing.expectEqual(@as(u16, @bitCast(link_status)), load16(&bytes, 0x80 + register.link.status));
    try std.testing.expectEqual(@as(u16, @bitCast(slot_status)), load16(&bytes, 0x80 + register.slot.status));
    try std.testing.expectEqual(@as(u32, @bitCast(root_status)), load32(&bytes, 0x80 + register.root.status));
}

test "unit: v2 accessors gate UnsupportedRevision before config access" {
    // A backend that errors on every post-validation access proves v2 methods check version first.
    var backend = GateAfterValidateConfig{ .version = 1 };
    const view = try pcie.View.validate(Function.unchecked(backend.configSpace(), test_sbdf), capabilityAt(0x80));

    try std.testing.expectError(error.UnsupportedRevision, view.deviceCapabilities2());
    try std.testing.expectError(error.UnsupportedRevision, view.deviceControl2());
    try std.testing.expectError(error.UnsupportedRevision, view.setDeviceControl2(.{}));
    try std.testing.expectError(error.UnsupportedRevision, view.deviceStatus2());
    try std.testing.expectError(error.UnsupportedRevision, view.linkCapabilities2());
    try std.testing.expectError(error.UnsupportedRevision, view.linkControl2());
    try std.testing.expectError(error.UnsupportedRevision, view.setLinkControl2(.{}));
    try std.testing.expectError(error.UnsupportedRevision, view.linkStatus2());
    try std.testing.expectError(
        error.UnsupportedRevision,
        view.clearLinkStatus2Bits(.{ .drs_message_received = true }),
    );
    try std.testing.expectError(error.UnsupportedRevision, view.slotCapabilities2());
    try std.testing.expectError(error.UnsupportedRevision, view.slotControl2());
    try std.testing.expectError(error.UnsupportedRevision, view.setSlotControl2(.{ ._reserved_0 = 0xA5A5 }));
    try std.testing.expectError(error.UnsupportedRevision, view.slotStatus2());

    try std.testing.expectEqual(@as(usize, 1), backend.access_count);
}

test "unit: v2 accessors read and write exact whole registers on revision two or newer" {
    // Revision two enables the extended range while still requiring exact whole-register access.
    var bytes: [function_window_size]u8 = @splat(0);
    seedPcieCapability(&bytes, 0x80, 2, 0);
    store32(&bytes, 0x80 + register.device.capabilities_2, 0xC5A3_7E1F);
    store16(&bytes, 0x80 + register.device.control_2, 0x0A51);
    store16(&bytes, 0x80 + register.device.status_2, 0xA5A5);
    store32(&bytes, 0x80 + register.link.capabilities_2, 0x81FE_00AA);
    store16(&bytes, 0x80 + register.link.control_2, 0x1556);
    store16(&bytes, 0x80 + register.link.status_2, 0x8421);
    store32(&bytes, 0x80 + register.slot.capabilities_2, 0x0000_0002);
    store16(&bytes, 0x80 + register.slot.control_2, 0xBEEF);
    store16(&bytes, 0x80 + register.slot.status_2, 0xCAFE);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const view = try pcie.View.validate(uncheckedFunction(&backend), capabilityAt(0x80));

    try std.testing.expectEqual(@as(u32, 0xC5A3_7E1F), @as(u32, @bitCast(try view.deviceCapabilities2())));
    try std.testing.expectEqual(@as(u16, 0x0A51), @as(u16, @bitCast(try view.deviceControl2())));
    try std.testing.expectEqual(@as(u16, 0xA5A5), @as(u16, @bitCast(try view.deviceStatus2())));
    try std.testing.expectEqual(@as(u32, 0x81FE_00AA), @as(u32, @bitCast(try view.linkCapabilities2())));
    try std.testing.expectEqual(@as(u16, 0x1556), @as(u16, @bitCast(try view.linkControl2())));
    try std.testing.expectEqual(@as(u16, 0x8421), @as(u16, @bitCast(try view.linkStatus2())));
    try std.testing.expectEqual(@as(u32, 0x0000_0002), @as(u32, @bitCast(try view.slotCapabilities2())));
    try std.testing.expectEqual(@as(u16, 0xBEEF), @as(u16, @bitCast(try view.slotControl2())));
    try std.testing.expectEqual(@as(u16, 0xCAFE), @as(u16, @bitCast(try view.slotStatus2())));

    const device_control_2 = pcie.DeviceControl2{
        .completion_timeout_value = .range_c_1s_3_5s,
        .completion_timeout_disable = true,
        .ari_forwarding_enable = true,
        .obff_enable = 0b10,
    };
    const link_control_2 = pcie.LinkControl2{
        .target_link_speed = .gen5,
        .hardware_autonomous_speed_disable = true,
        .transmit_margin = 0b101,
        .compliance_preset_or_deemphasis = 0xC,
    };
    const link_status_2 = pcie.LinkStatus2{
        .link_equalization_request_8gt = true,
        .drs_message_received = true,
    };
    const slot_control_2 = pcie.SlotControl2{ ._reserved_0 = 0x5AA5 };

    try view.setDeviceControl2(device_control_2);
    try view.setLinkControl2(link_control_2);
    try view.clearLinkStatus2Bits(link_status_2);
    try view.setSlotControl2(slot_control_2);

    try std.testing.expectEqual(@as(u16, @bitCast(device_control_2)), load16(&bytes, 0x80 + register.device.control_2));
    try std.testing.expectEqual(@as(u16, @bitCast(link_control_2)), load16(&bytes, 0x80 + register.link.control_2));
    try std.testing.expectEqual(@as(u16, @bitCast(link_status_2)), load16(&bytes, 0x80 + register.link.status_2));
    try std.testing.expectEqual(@as(u16, @bitCast(slot_control_2)), load16(&bytes, 0x80 + register.slot.control_2));
}

test "unit: caller-side whole-register round trips preserve reserved bits" {
    // Read-mutate-write through public structs must retain reserved fields visible in the raw register image.
    var bytes: [function_window_size]u8 = @splat(0);
    seedPcieCapability(&bytes, 0x80, 2, 0);
    store16(&bytes, 0x80 + register.root.control, 0xFFE0);
    store16(&bytes, 0x80 + register.slot.control_2, 0x7E5A);
    var backend = TestConfigSpace.initSingle(test_sbdf, &bytes);
    const view = try pcie.View.validate(uncheckedFunction(&backend), capabilityAt(0x80));

    var root_control = try view.rootControl();
    root_control.pme_interrupt_enable = true;
    try view.setRootControl(root_control);

    try std.testing.expectEqual(@as(u16, 0xFFE8), load16(&bytes, 0x80 + register.root.control));

    const slot_control_2 = try view.slotControl2();
    try view.setSlotControl2(slot_control_2);

    try std.testing.expectEqual(@as(u16, 0x7E5A), load16(&bytes, 0x80 + register.slot.control_2));
}

test "unit: backend errors propagate after view validation succeeds" {
    // Version validation succeeds once; later legal v1 and v2 accesses must expose backend failures unchanged.
    var backend = GateAfterValidateConfig{ .version = 2 };
    const view = try pcie.View.validate(Function.unchecked(backend.configSpace(), test_sbdf), capabilityAt(0x80));

    try std.testing.expectError(error.UnsupportedAccessWidth, view.deviceCapabilities());
    try std.testing.expectError(error.UnsupportedAccessWidth, view.setDeviceControl(.{}));
    try std.testing.expectError(error.UnsupportedAccessWidth, view.deviceCapabilities2());
    try std.testing.expectError(error.UnsupportedAccessWidth, view.setLinkControl2(.{}));
}

const GateAfterValidateConfig = struct {
    version: u4,
    access_count: usize = 0,

    fn configSpace(self: *GateAfterValidateConfig) ConfigSpace {
        return ConfigSpace.init(@ptrCast(self), &vtable);
    }

    const vtable: ConfigSpace.VTable = .{
        .read8 = read8Unsupported,
        .read16 = read16,
        .read32 = read32Unsupported,
        .write8 = write8Unsupported,
        .write16 = write16Unsupported,
        .write32 = write32Unsupported,
    };

    fn read8Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u8 {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        return error.UnsupportedAccessWidth;
    }

    fn read16(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u16 {
        _ = sbdf;
        const self: *GateAfterValidateConfig = @ptrCast(@alignCast(context));
        self.access_count += 1;
        if (byte_offset == 0x80 + register.capabilities) return makeCapabilities(self.version);
        return error.UnsupportedAccessWidth;
    }

    fn read32Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize) ConfigSpace.Error!u32 {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        return error.UnsupportedAccessWidth;
    }

    fn write8Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u8) ConfigSpace.Error!void {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        _ = value;
        return error.UnsupportedAccessWidth;
    }

    fn write16Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u16) ConfigSpace.Error!void {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        _ = value;
        return error.UnsupportedAccessWidth;
    }

    fn write32Unsupported(context: *anyopaque, sbdf: Sbdf, byte_offset: usize, value: u32) ConfigSpace.Error!void {
        _ = context;
        _ = sbdf;
        _ = byte_offset;
        _ = value;
        return error.UnsupportedAccessWidth;
    }
};

fn expectBitSize(comptime T: type, expected: comptime_int) !void {
    try std.testing.expectEqual(@as(comptime_int, expected), @bitSizeOf(T));
}

fn expectPayloadBytes(value: pcie.MaxPayloadSize, expected: u32) !void {
    try std.testing.expectEqual(expected, try value.bytes());
}

fn expectReadRequestBytes(value: pcie.MaxReadRequestSize, expected: u32) !void {
    try std.testing.expectEqual(expected, try value.bytes());
}

fn expectLinkSpeed(value: pcie.MaxLinkSpeed, expected: u32) !void {
    try std.testing.expectEqual(expected, try value.megaTransfersPerSecond());
}

fn expectLinkWidth(value: pcie.MaxLinkWidth, expected: u6) !void {
    try std.testing.expectEqual(expected, try value.lanes());
}

fn uncheckedFunction(backend: *TestConfigSpace) Function {
    return Function.unchecked(backend.configSpace(), test_sbdf);
}

fn capabilityAt(base: u8) Capability {
    return .{ .id = @intFromEnum(Id.pci_express), .offset = base };
}

fn makeCapabilities(version: u4) u16 {
    return @as(u16, version) |
        (@as(u16, @intFromEnum(pcie.DevicePortType.root_port)) << 4) |
        (@as(u16, 1) << 8) |
        (@as(u16, 0x12) << 9);
}

fn enableCapabilities(bytes: *[function_window_size]u8) void {
    store16(bytes, offset.status, status.capabilities_list);
}

fn seedHead(bytes: *[function_window_size]u8, head: u8) void {
    enableCapabilities(bytes);
    bytes[standard.head_offset] = head;
}

fn seedCapabilityNode(bytes: *[function_window_size]u8, base: u8, id: u8, next: u8) void {
    bytes[base] = id;
    bytes[@as(usize, base) + 1] = next;
}

fn seedPcieCapability(bytes: *[function_window_size]u8, base: u8, version: u4, next: u8) void {
    seedCapabilityNode(bytes, base, @intFromEnum(Id.pci_express), next);
    store16(bytes, @as(usize, base) + register.capabilities, makeCapabilities(version));
}

fn store16(bytes: []u8, byte_offset: usize, value: u16) void {
    const encoded = stdx.layout.Le(u16).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u16), bytes, byte_offset, encoded) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
}

fn store32(bytes: []u8, byte_offset: usize, value: u32) void {
    const encoded = stdx.layout.Le(u32).fromNative(value);
    stdx.bytes.store(stdx.layout.Le(u32), bytes, byte_offset, encoded) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
}

fn load16(bytes: []const u8, byte_offset: usize) u16 {
    const wrapped = stdx.bytes.load(stdx.layout.Le(u16), bytes, byte_offset) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
    return wrapped.native();
}

fn load32(bytes: []const u8, byte_offset: usize) u32 {
    const wrapped = stdx.bytes.load(stdx.layout.Le(u32), bytes, byte_offset) catch |err| switch (err) {
        error.EndOfStream => unreachable,
    };
    return wrapped.native();
}
