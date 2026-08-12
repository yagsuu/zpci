//! PCI Express capability view. Spec: docs/specs/capabilities/pcie.md.

const std = @import("std");

const config = @import("../config.zig");
const list = @import("list.zig");

const ConfigSpace = config.ConfigSpace;
const Function = config.Function;

pub const register = struct {
    pub const capabilities: u8 = 0x02;

    pub const device = struct {
        pub const capabilities: u8 = 0x04;
        pub const control: u8 = 0x08;
        pub const status: u8 = 0x0A;
        pub const capabilities_2: u8 = 0x24;
        pub const control_2: u8 = 0x28;
        pub const status_2: u8 = 0x2A;
    };

    pub const link = struct {
        pub const capabilities: u8 = 0x0C;
        pub const control: u8 = 0x10;
        pub const status: u8 = 0x12;
        pub const capabilities_2: u8 = 0x2C;
        pub const control_2: u8 = 0x30;
        pub const status_2: u8 = 0x32;
    };

    pub const slot = struct {
        pub const capabilities: u8 = 0x14;
        pub const control: u8 = 0x18;
        pub const status: u8 = 0x1A;
        pub const capabilities_2: u8 = 0x34;
        pub const control_2: u8 = 0x38;
        pub const status_2: u8 = 0x3A;
    };

    pub const root = struct {
        pub const control: u8 = 0x1C;
        pub const capabilities: u8 = 0x1E;
        pub const status: u8 = 0x20;
    };
};

pub const total_size: u8 = 0x3C;

pub const Error = ConfigSpace.Error || error{
    MalformedCapability,
    MalformedField,
    UnsupportedRevision,
};

pub const DevicePortType = enum(u4) {
    endpoint = 0x0,
    legacy_endpoint = 0x1,
    root_port = 0x4,
    upstream_port = 0x5,
    downstream_port = 0x6,
    pcie_to_pci_bridge = 0x7,
    pci_to_pcie_bridge = 0x8,
    root_complex_integrated_endpoint = 0x9,
    root_complex_event_collector = 0xA,
    _,
};

pub const MaxPayloadSize = enum(u3) {
    bytes_128 = 0,
    bytes_256 = 1,
    bytes_512 = 2,
    bytes_1024 = 3,
    bytes_2048 = 4,
    bytes_4096 = 5,
    _,

    pub fn bytes(self: MaxPayloadSize) error{MalformedField}!u32 {
        return switch (@intFromEnum(self)) {
            0...5 => @as(u32, 128) << @as(u5, @intCast(@intFromEnum(self))),
            else => error.MalformedField,
        };
    }
};

pub const MaxReadRequestSize = enum(u3) {
    bytes_128 = 0,
    bytes_256 = 1,
    bytes_512 = 2,
    bytes_1024 = 3,
    bytes_2048 = 4,
    bytes_4096 = 5,
    _,

    pub fn bytes(self: MaxReadRequestSize) error{MalformedField}!u32 {
        return switch (@intFromEnum(self)) {
            0...5 => @as(u32, 128) << @as(u5, @intCast(@intFromEnum(self))),
            else => error.MalformedField,
        };
    }
};

pub const MaxLinkSpeed = enum(u4) {
    gen1 = 0x1,
    gen2 = 0x2,
    gen3 = 0x3,
    gen4 = 0x4,
    gen5 = 0x5,
    gen6 = 0x6,
    _,

    pub fn megaTransfersPerSecond(self: MaxLinkSpeed) error{MalformedField}!u32 {
        return switch (self) {
            .gen1 => 2500,
            .gen2 => 5000,
            .gen3 => 8000,
            .gen4 => 16000,
            .gen5 => 32000,
            .gen6 => 64000,
            _ => error.MalformedField,
        };
    }
};

pub const MaxLinkWidth = enum(u6) {
    x1 = 1,
    x2 = 2,
    x4 = 4,
    x8 = 8,
    x12 = 12,
    x16 = 16,
    x32 = 32,
    _,

    pub fn lanes(self: MaxLinkWidth) error{MalformedField}!u6 {
        return switch (self) {
            .x1 => 1,
            .x2 => 2,
            .x4 => 4,
            .x8 => 8,
            .x12 => 12,
            .x16 => 16,
            .x32 => 32,
            _ => error.MalformedField,
        };
    }
};

pub const AspmSupport = enum(u2) {
    disabled = 0,
    l0s = 1,
    l1 = 2,
    l0s_l1 = 3,
};

pub const AspmControl = enum(u2) {
    disabled = 0,
    l0s = 1,
    l1 = 2,
    l0s_l1 = 3,
};

pub const CompletionTimeoutValue = enum(u4) {
    default = 0x0,
    range_a_50us_100us = 0x1,
    range_a_1ms_10ms = 0x2,
    range_b_16ms_55ms = 0x5,
    range_b_65ms_210ms = 0x6,
    range_c_260ms_900ms = 0x9,
    range_c_1s_3_5s = 0xA,
    range_d_4s_13s = 0xD,
    range_d_17s_64s = 0xE,
    _,
};

pub const Capabilities = packed struct(u16) {
    version: u4 = 0,
    device_port_type: DevicePortType = .endpoint,
    slot_implemented: bool = false,
    interrupt_message_number: u5 = 0,
    _reserved_14: u2 = 0,
};

pub const DeviceCapabilities = packed struct(u32) {
    max_payload_size_supported: MaxPayloadSize = .bytes_128,
    phantom_functions_supported: u2 = 0,
    extended_tag_field_supported: bool = false,
    endpoint_l0s_acceptable_latency: u3 = 0,
    endpoint_l1_acceptable_latency: u3 = 0,
    _reserved_12: u3 = 0,
    role_based_error_reporting: bool = false,
    _reserved_16: u2 = 0,
    captured_slot_power_limit_value: u8 = 0,
    captured_slot_power_limit_scale: u2 = 0,
    function_level_reset_capability: bool = false,
    _reserved_29: u3 = 0,
};

pub const DeviceControl = packed struct(u16) {
    correctable_error_reporting_enable: bool = false,
    non_fatal_error_reporting_enable: bool = false,
    fatal_error_reporting_enable: bool = false,
    unsupported_request_reporting_enable: bool = false,
    enable_relaxed_ordering: bool = false,
    max_payload_size: MaxPayloadSize = .bytes_128,
    extended_tag_field_enable: bool = false,
    phantom_functions_enable: bool = false,
    aux_power_pm_enable: bool = false,
    enable_no_snoop: bool = false,
    max_read_request_size: MaxReadRequestSize = .bytes_128,
    bcre_initiate_flr: bool = false,
};

pub const DeviceStatus = packed struct(u16) {
    correctable_error_detected: bool = false,
    non_fatal_error_detected: bool = false,
    fatal_error_detected: bool = false,
    unsupported_request_detected: bool = false,
    aux_power_detected: bool = false,
    transactions_pending: bool = false,
    emergency_power_reduction_detected: bool = false,
    _reserved_7: u9 = 0,
};

pub const LinkCapabilities = packed struct(u32) {
    max_link_speed: MaxLinkSpeed = @enumFromInt(0),
    max_link_width: MaxLinkWidth = @enumFromInt(0),
    aspm_support: AspmSupport = .disabled,
    l0s_exit_latency: u3 = 0,
    l1_exit_latency: u3 = 0,
    clock_power_management: bool = false,
    surprise_down_error_reporting_capable: bool = false,
    data_link_layer_link_active_reporting_capable: bool = false,
    link_bandwidth_notification_capability: bool = false,
    aspm_optionality_compliance: bool = false,
    _reserved_23: u1 = 0,
    port_number: u8 = 0,
};

pub const LinkControl = packed struct(u16) {
    aspm_control: AspmControl = .disabled,
    _reserved_2: u1 = 0,
    read_completion_boundary: bool = false,
    link_disable: bool = false,
    retrain_link: bool = false,
    common_clock_configuration: bool = false,
    extended_synch: bool = false,
    enable_clock_power_management: bool = false,
    hardware_autonomous_width_disable: bool = false,
    link_bandwidth_management_interrupt_enable: bool = false,
    link_autonomous_bandwidth_interrupt_enable: bool = false,
    _reserved_12: u2 = 0,
    drs_signaling_control: bool = false,
    _reserved_15: u1 = 0,
};

pub const LinkStatus = packed struct(u16) {
    current_link_speed: MaxLinkSpeed = @enumFromInt(0),
    negotiated_link_width: MaxLinkWidth = @enumFromInt(0),
    _undefined_10: u1 = 0,
    link_training: bool = false,
    slot_clock_configuration: bool = false,
    data_link_layer_link_active: bool = false,
    link_bandwidth_management_status: bool = false,
    link_autonomous_bandwidth_status: bool = false,
};

pub const SlotCapabilities = packed struct(u32) {
    attention_button_present: bool = false,
    power_controller_present: bool = false,
    mrl_sensor_present: bool = false,
    attention_indicator_present: bool = false,
    power_indicator_present: bool = false,
    hot_plug_surprise: bool = false,
    hot_plug_capable: bool = false,
    slot_power_limit_value: u8 = 0,
    slot_power_limit_scale: u2 = 0,
    electromechanical_interlock_present: bool = false,
    no_command_completed_support: bool = false,
    physical_slot_number: u13 = 0,
};

pub const SlotControl = packed struct(u16) {
    attention_button_pressed_enable: bool = false,
    power_fault_detected_enable: bool = false,
    mrl_sensor_changed_enable: bool = false,
    presence_detect_changed_enable: bool = false,
    command_completed_interrupt_enable: bool = false,
    hot_plug_interrupt_enable: bool = false,
    attention_indicator_control: u2 = 0,
    power_indicator_control: u2 = 0,
    power_controller_control: bool = false,
    electromechanical_interlock_control: bool = false,
    data_link_layer_state_changed_enable: bool = false,
    auto_slot_power_limit_disable: bool = false,
    in_band_pd_disable: bool = false,
    _reserved_15: u1 = 0,
};

pub const SlotStatus = packed struct(u16) {
    attention_button_pressed: bool = false,
    power_fault_detected: bool = false,
    mrl_sensor_changed: bool = false,
    presence_detect_changed: bool = false,
    command_completed: bool = false,
    mrl_sensor_state: bool = false,
    presence_detect_state: bool = false,
    electromechanical_interlock_status: bool = false,
    data_link_layer_state_changed: bool = false,
    _reserved_9: u7 = 0,
};

pub const RootControl = packed struct(u16) {
    system_error_on_correctable_error_enable: bool = false,
    system_error_on_non_fatal_error_enable: bool = false,
    system_error_on_fatal_error_enable: bool = false,
    pme_interrupt_enable: bool = false,
    crs_software_visibility_enable: bool = false,
    _reserved_5: u11 = 0,
};

pub const RootCapabilities = packed struct(u16) {
    crs_software_visibility: bool = false,
    _reserved_1: u15 = 0,
};

pub const RootStatus = packed struct(u32) {
    pme_requester_id: u16 = 0,
    pme_status: bool = false,
    pme_pending: bool = false,
    _reserved_18: u14 = 0,
};

pub const DeviceCapabilities2 = packed struct(u32) {
    completion_timeout_ranges_supported: u4 = 0,
    completion_timeout_disable_supported: bool = false,
    ari_forwarding_supported: bool = false,
    atomic_op_routing_supported: bool = false,
    atomic_op_completer_32_supported: bool = false,
    atomic_op_completer_64_supported: bool = false,
    cas_completer_128_supported: bool = false,
    no_ro_enabled_pr_pr_passing: bool = false,
    ltr_mechanism_supported: bool = false,
    tph_completer_supported: u2 = 0,
    ln_system_cls: u2 = 0,
    tag_completer_10bit_supported: bool = false,
    tag_requester_10bit_supported: bool = false,
    obff_supported: u2 = 0,
    extended_fmt_field_supported: bool = false,
    end_end_tlp_prefix_supported: bool = false,
    max_end_end_tlp_prefixes: u2 = 0,
    emergency_power_reduction_supported: u2 = 0,
    emergency_power_reduction_init_required: bool = false,
    _reserved_27: u3 = 0,
    frs_supported: bool = false,
    _reserved_31: u1 = 0,
};

pub const DeviceControl2 = packed struct(u16) {
    completion_timeout_value: CompletionTimeoutValue = .default,
    completion_timeout_disable: bool = false,
    ari_forwarding_enable: bool = false,
    atomic_op_requester_enable: bool = false,
    atomic_op_egress_blocking: bool = false,
    ido_request_enable: bool = false,
    ido_completion_enable: bool = false,
    ltr_mechanism_enable: bool = false,
    emergency_power_reduction_request: bool = false,
    tag_requester_10bit_enable: bool = false,
    obff_enable: u2 = 0,
    end_end_tlp_prefix_blocking: bool = false,
};

pub const DeviceStatus2 = packed struct(u16) {
    _reserved_0: u16 = 0,
};

pub const LinkCapabilities2 = packed struct(u32) {
    _reserved_0: u1 = 0,
    supported_link_speeds_vector: u7 = 0,
    crosslink_supported: bool = false,
    lower_skp_os_generation_supported: u7 = 0,
    lower_skp_os_reception_supported: u7 = 0,
    retimer_presence_detect_supported: bool = false,
    two_retimers_presence_detect_supported: bool = false,
    _reserved_25: u6 = 0,
    drs_supported: bool = false,
};

pub const LinkControl2 = packed struct(u16) {
    target_link_speed: MaxLinkSpeed = @enumFromInt(0),
    enter_compliance: bool = false,
    hardware_autonomous_speed_disable: bool = false,
    selectable_deemphasis: bool = false,
    transmit_margin: u3 = 0,
    enter_modified_compliance: bool = false,
    compliance_sos: bool = false,
    compliance_preset_or_deemphasis: u4 = 0,
};

pub const LinkStatus2 = packed struct(u16) {
    current_deemphasis_level: bool = false,
    equalization_8gt_complete: bool = false,
    equalization_8gt_phase1_successful: bool = false,
    equalization_8gt_phase2_successful: bool = false,
    equalization_8gt_phase3_successful: bool = false,
    link_equalization_request_8gt: bool = false,
    retimer_presence_detected: bool = false,
    two_retimers_presence_detected: bool = false,
    crosslink_resolution: u2 = 0,
    _reserved_10: u2 = 0,
    downstream_component_presence: u3 = 0,
    drs_message_received: bool = false,
};

pub const SlotCapabilities2 = packed struct(u32) {
    _reserved_0: u1 = 0,
    in_band_pd_disable_supported: bool = false,
    _reserved_2: u30 = 0,
};

pub const SlotControl2 = packed struct(u16) {
    _reserved_0: u16 = 0,
};

pub const SlotStatus2 = packed struct(u16) {
    _reserved_0: u16 = 0,
};

comptime {
    std.debug.assert(@bitSizeOf(Capabilities) == 16);
    std.debug.assert(@bitSizeOf(DeviceCapabilities) == 32);
    std.debug.assert(@bitSizeOf(DeviceControl) == 16);
    std.debug.assert(@bitSizeOf(DeviceStatus) == 16);
    std.debug.assert(@bitSizeOf(LinkCapabilities) == 32);
    std.debug.assert(@bitSizeOf(LinkControl) == 16);
    std.debug.assert(@bitSizeOf(LinkStatus) == 16);
    std.debug.assert(@bitSizeOf(SlotCapabilities) == 32);
    std.debug.assert(@bitSizeOf(SlotControl) == 16);
    std.debug.assert(@bitSizeOf(SlotStatus) == 16);
    std.debug.assert(@bitSizeOf(RootControl) == 16);
    std.debug.assert(@bitSizeOf(RootCapabilities) == 16);
    std.debug.assert(@bitSizeOf(RootStatus) == 32);
    std.debug.assert(@bitSizeOf(DeviceCapabilities2) == 32);
    std.debug.assert(@bitSizeOf(DeviceControl2) == 16);
    std.debug.assert(@bitSizeOf(DeviceStatus2) == 16);
    std.debug.assert(@bitSizeOf(LinkCapabilities2) == 32);
    std.debug.assert(@bitSizeOf(LinkControl2) == 16);
    std.debug.assert(@bitSizeOf(LinkStatus2) == 16);
    std.debug.assert(@bitSizeOf(SlotCapabilities2) == 32);
    std.debug.assert(@bitSizeOf(SlotControl2) == 16);
    std.debug.assert(@bitSizeOf(SlotStatus2) == 16);
}

pub const View = struct {
    function: Function,
    base: u8,
    version: u4,

    /// Validates a standard PCIe capability node and caches its major revision.
    /// Effects: one 16-bit config read at the capability's `Capabilities` register.
    /// Errors: `MalformedCapability` for bad node placement; `UnsupportedRevision` for version zero.
    pub fn validate(function: Function, cap: list.Capability) Error!View {
        std.debug.assert(cap.idTag() == .pci_express);
        try validateCapabilityOffset(cap.offset);

        const raw = try function.read16(@as(usize, cap.offset) + register.capabilities);
        const caps: Capabilities = @bitCast(raw);
        if (caps.version == 0) return error.UnsupportedRevision;

        return .{
            .function = function,
            .base = cap.offset,
            .version = caps.version,
        };
    }

    /// Finds the first PCIe capability in the standard list and validates it.
    /// Returns: `null` when the standard list terminates without a PCIe capability.
    /// Errors: propagates malformed standard-list traversal and `validate` failures.
    pub fn find(function: Function) Error!?View {
        const cap = (try list.find(function, .pci_express)) orelse return null;
        return try View.validate(function, cap);
    }

    pub fn capabilities(self: View) ConfigSpace.Error!Capabilities {
        return self.readPacked(Capabilities, register.capabilities);
    }

    pub fn deviceCapabilities(self: View) ConfigSpace.Error!DeviceCapabilities {
        return self.readPacked(DeviceCapabilities, register.device.capabilities);
    }

    pub fn deviceControl(self: View) ConfigSpace.Error!DeviceControl {
        return self.readPacked(DeviceControl, register.device.control);
    }

    pub fn setDeviceControl(self: View, value: DeviceControl) ConfigSpace.Error!void {
        return self.writePacked(DeviceControl, register.device.control, value);
    }

    pub fn deviceStatus(self: View) ConfigSpace.Error!DeviceStatus {
        return self.readPacked(DeviceStatus, register.device.status);
    }

    pub fn clearDeviceStatusBits(self: View, bits: DeviceStatus) ConfigSpace.Error!void {
        return self.writePacked(DeviceStatus, register.device.status, bits);
    }

    pub fn linkCapabilities(self: View) ConfigSpace.Error!LinkCapabilities {
        return self.readPacked(LinkCapabilities, register.link.capabilities);
    }

    pub fn linkControl(self: View) ConfigSpace.Error!LinkControl {
        return self.readPacked(LinkControl, register.link.control);
    }

    pub fn setLinkControl(self: View, value: LinkControl) ConfigSpace.Error!void {
        return self.writePacked(LinkControl, register.link.control, value);
    }

    pub fn linkStatus(self: View) ConfigSpace.Error!LinkStatus {
        return self.readPacked(LinkStatus, register.link.status);
    }

    pub fn clearLinkStatusBits(self: View, bits: LinkStatus) ConfigSpace.Error!void {
        return self.writePacked(LinkStatus, register.link.status, bits);
    }

    pub fn slotCapabilities(self: View) ConfigSpace.Error!SlotCapabilities {
        return self.readPacked(SlotCapabilities, register.slot.capabilities);
    }

    pub fn slotControl(self: View) ConfigSpace.Error!SlotControl {
        return self.readPacked(SlotControl, register.slot.control);
    }

    pub fn setSlotControl(self: View, value: SlotControl) ConfigSpace.Error!void {
        return self.writePacked(SlotControl, register.slot.control, value);
    }

    pub fn slotStatus(self: View) ConfigSpace.Error!SlotStatus {
        return self.readPacked(SlotStatus, register.slot.status);
    }

    pub fn clearSlotStatusBits(self: View, bits: SlotStatus) ConfigSpace.Error!void {
        return self.writePacked(SlotStatus, register.slot.status, bits);
    }

    pub fn rootControl(self: View) ConfigSpace.Error!RootControl {
        return self.readPacked(RootControl, register.root.control);
    }

    pub fn setRootControl(self: View, value: RootControl) ConfigSpace.Error!void {
        return self.writePacked(RootControl, register.root.control, value);
    }

    pub fn rootCapabilities(self: View) ConfigSpace.Error!RootCapabilities {
        return self.readPacked(RootCapabilities, register.root.capabilities);
    }

    pub fn rootStatus(self: View) ConfigSpace.Error!RootStatus {
        return self.readPacked(RootStatus, register.root.status);
    }

    pub fn clearRootStatusBits(self: View, bits: RootStatus) ConfigSpace.Error!void {
        return self.writePacked(RootStatus, register.root.status, bits);
    }

    pub fn deviceCapabilities2(self: View) Error!DeviceCapabilities2 {
        try self.requireV2();
        return self.readPacked(DeviceCapabilities2, register.device.capabilities_2);
    }

    pub fn deviceControl2(self: View) Error!DeviceControl2 {
        try self.requireV2();
        return self.readPacked(DeviceControl2, register.device.control_2);
    }

    pub fn setDeviceControl2(self: View, value: DeviceControl2) Error!void {
        try self.requireV2();
        return self.writePacked(DeviceControl2, register.device.control_2, value);
    }

    pub fn deviceStatus2(self: View) Error!DeviceStatus2 {
        try self.requireV2();
        return self.readPacked(DeviceStatus2, register.device.status_2);
    }

    pub fn linkCapabilities2(self: View) Error!LinkCapabilities2 {
        try self.requireV2();
        return self.readPacked(LinkCapabilities2, register.link.capabilities_2);
    }

    pub fn linkControl2(self: View) Error!LinkControl2 {
        try self.requireV2();
        return self.readPacked(LinkControl2, register.link.control_2);
    }

    pub fn setLinkControl2(self: View, value: LinkControl2) Error!void {
        try self.requireV2();
        return self.writePacked(LinkControl2, register.link.control_2, value);
    }

    pub fn linkStatus2(self: View) Error!LinkStatus2 {
        try self.requireV2();
        return self.readPacked(LinkStatus2, register.link.status_2);
    }

    pub fn clearLinkStatus2Bits(self: View, bits: LinkStatus2) Error!void {
        try self.requireV2();
        return self.writePacked(LinkStatus2, register.link.status_2, bits);
    }

    pub fn slotCapabilities2(self: View) Error!SlotCapabilities2 {
        try self.requireV2();
        return self.readPacked(SlotCapabilities2, register.slot.capabilities_2);
    }

    pub fn slotControl2(self: View) Error!SlotControl2 {
        try self.requireV2();
        return self.readPacked(SlotControl2, register.slot.control_2);
    }

    pub fn setSlotControl2(self: View, value: SlotControl2) Error!void {
        try self.requireV2();
        return self.writePacked(SlotControl2, register.slot.control_2, value);
    }

    pub fn slotStatus2(self: View) Error!SlotStatus2 {
        try self.requireV2();
        return self.readPacked(SlotStatus2, register.slot.status_2);
    }

    fn requireV2(self: View) error{UnsupportedRevision}!void {
        if (self.version < 2) return error.UnsupportedRevision;
    }

    fn readPacked(self: View, comptime T: type, offset: u8) ConfigSpace.Error!T {
        comptime std.debug.assert(@bitSizeOf(T) == 16 or @bitSizeOf(T) == 32);

        if (@bitSizeOf(T) == 16) {
            const raw = try self.function.read16(self.byteOffset(offset));
            return @bitCast(raw);
        }

        const raw = try self.function.read32(self.byteOffset(offset));
        return @bitCast(raw);
    }

    fn writePacked(self: View, comptime T: type, offset: u8, value: T) ConfigSpace.Error!void {
        comptime std.debug.assert(@bitSizeOf(T) == 16 or @bitSizeOf(T) == 32);

        if (@bitSizeOf(T) == 16) {
            const raw: u16 = @bitCast(value);
            return self.function.write16(self.byteOffset(offset), raw);
        }

        const raw: u32 = @bitCast(value);
        return self.function.write32(self.byteOffset(offset), raw);
    }

    fn byteOffset(self: View, offset: u8) usize {
        return @as(usize, self.base) + @as(usize, offset);
    }
};

fn validateCapabilityOffset(offset: u8) Error!void {
    if (!list.standard.window.range.contains(offset)) return error.MalformedCapability;
    if (offset % list.standard.window.step != 0) return error.MalformedCapability;
}
