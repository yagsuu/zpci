# PCI Express capability

Defines the typed view of the PCI Express capability structure identified by capability id `0x10` in the standard capability list. Owns the typed packed-struct decoding of every base PCIe capability register in the range `0x00..=0x3B` relative to the capability's base offset, and `capabilities.pcie.View` for typed reads and typed writes.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `capabilities.pcie.View` and its register types. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/common.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/capabilities/extended.md`

## Scope

Owned:

- Public constants naming each PCIe capability register's byte offset relative to the capability base.
- The full wire layout of the base PCI Express capability (`0x00..=0x3B`): register decodings as `packed struct(uN)` types with named-bool bit fields and consumer-facing named enums for a fixed subset of encodings.
- The named enums `DevicePortType`, `MaxPayloadSize`, `MaxReadRequestSize`, `MaxLinkSpeed`, `MaxLinkWidth`, `AspmSupport`, `AspmControl`, `CompletionTimeoutValue`.
- `capabilities.pcie.View`, a borrowed typed view over `config.Function` scoped to one PCIe capability instance.
- Typed reads for every owned register, typed writes for every writable register, and W1C-clear helpers for every register that PCIe defines with RW1C sticky bits.
- Version gating for v2-only registers (`0x24..=0x3B`) at the View boundary.
- Reserved-bit preservation policy for whole-register writes.
- Interpretation helpers on named enums that surface `MalformedField` for reserved encodings.

Deferred:

- Extended capability decode (`docs/specs/capabilities/extended.md`).
- Standard-capability-list traversal (`docs/specs/capabilities/list.md`).
- MSI and MSI-X capability programming (`docs/specs/interrupts/msi.md`, `docs/specs/interrupts/msix.md`).
- Any orchestration policy: hot-plug sequencing, link retrain sequencing, function-level reset sequencing, root-complex PME message routing, equalization phase management, ASPM enable ordering.
- Any hidden read-modify-write, backend retry, or diagnostic out-parameter.

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness.

Rules:

- Each register decoding is a `packed struct(uN)` bit-cast directly from a native-endian `uN` read at the register's byte offset.
- Reserved bits are represented as `_reserved{lo_bit}: uN` fields on the packed struct so that whole-register writes round-trip reserved encodings byte-for-byte back to hardware.
- No `zstdx.layout.Le(uN)` wrapper is required in the wire layout; multi-byte config reads return native integers from `ConfigSpace`.

## Register offsets `[std]`

```zig
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

pub const total_size: u8 = 0x3C; // 60 bytes: 0x00..=0x3B
```

The bytes at `0x00` (capability id) and `0x01` (next pointer) are owned by `docs/specs/capabilities/list.md` and are not reached through `View`. Bytes past `0x3B` are not owned by this spec.

Bytes at `0x2A` (`device_status_2`), `0x38` (`slot_control_2`), and `0x3A` (`slot_status_2`) are entirely reserved in the current PCI Express Base Specification. They are modeled here for wire-layout completeness so that whole-register reads and writes are byte-for-byte accurate; no named bit fields are defined on those registers.

## Version rules `[std]`

The 4-bit `version` field of `Capabilities` (`0x02[3:0]`) selects the accessible register subset:

- `version == 0` — invalid. `View.validate` returns `UnsupportedRevision`.
- `version == 1` — the v1 register range (`0x02..=0x23`) is accessible. Any v2 accessor returns `UnsupportedRevision`.
- `version >= 2` — the full v2 register range (`0x02..=0x3B`) is accessible. Values greater than the current PCI Express Base Specification's highest defined version are accepted and treated as `2` for gating purposes; newer registers introduced by later PCIe versions are not owned by this spec.

The version is read once at `View.validate` and cached on the view. PCIe fixes the version for the lifetime of a function instance, so caching is safe.

## Named enums `[zpci]`

Each enum is a Zig `enum(uN)` matching the field width in the owning register. Enums that reserve encodings in the PCIe base specification are open (`_` wildcard). Enums that PCIe defines exhaustively are closed.

`DevicePortType` — `Capabilities.device_port_type` (u4). Open; PCIe reserves `0x2`, `0x3`, and `0xB..=0xF`.

```zig
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
```

`MaxPayloadSize` — `DeviceCapabilities.max_payload_size_supported` and `DeviceControl.max_payload_size` (u3). Open; encodings `0..=5` are named, `6..=7` reserved.

```zig
pub const MaxPayloadSize = enum(u3) {
    bytes_128 = 0,
    bytes_256 = 1,
    bytes_512 = 2,
    bytes_1024 = 3,
    bytes_2048 = 4,
    bytes_4096 = 5,
    _,

    pub fn bytes(self: MaxPayloadSize) error{MalformedField}!u32;
};
```

`bytes` returns `128 << @intFromEnum(self)` for the six named encodings and `MalformedField` for `6` and `7`.

`MaxReadRequestSize` — `DeviceControl.max_read_request_size` (u3). Same encoding domain as `MaxPayloadSize`.

```zig
pub const MaxReadRequestSize = enum(u3) {
    bytes_128 = 0,
    bytes_256 = 1,
    bytes_512 = 2,
    bytes_1024 = 3,
    bytes_2048 = 4,
    bytes_4096 = 5,
    _,

    pub fn bytes(self: MaxReadRequestSize) error{MalformedField}!u32;
};
```

`MaxLinkSpeed` — `LinkCapabilities.max_link_speed`, `LinkStatus.current_link_speed`, `LinkControl2.target_link_speed` (u4). Open; `0x0` reserved, `0x1..=0x6` named, `0x7..=0xF` reserved for future PCIe generations.

```zig
pub const MaxLinkSpeed = enum(u4) {
    gen1 = 0x1,
    gen2 = 0x2,
    gen3 = 0x3,
    gen4 = 0x4,
    gen5 = 0x5,
    gen6 = 0x6,
    _,

    pub fn megaTransfersPerSecond(self: MaxLinkSpeed) error{MalformedField}!u32;
};
```

`megaTransfersPerSecond` returns `2500`, `5000`, `8000`, `16000`, `32000`, `64000` for the six named encodings and `MalformedField` for `0x0` and any wildcard encoding.

`MaxLinkWidth` — `LinkCapabilities.max_link_width`, `LinkStatus.negotiated_link_width` (u6). Open; PCIe names `x1`, `x2`, `x4`, `x8`, `x12`, `x16`, `x32`.

```zig
pub const MaxLinkWidth = enum(u6) {
    x1 = 1,
    x2 = 2,
    x4 = 4,
    x8 = 8,
    x12 = 12,
    x16 = 16,
    x32 = 32,
    _,

    pub fn lanes(self: MaxLinkWidth) error{MalformedField}!u6;
};
```

`lanes` returns `1`, `2`, `4`, `8`, `12`, `16`, or `32` for the named encodings and `MalformedField` for `0` and any wildcard encoding.

`AspmSupport` — `LinkCapabilities.aspm_support` (u2). Closed.

```zig
pub const AspmSupport = enum(u2) {
    disabled = 0,
    l0s = 1,
    l1 = 2,
    l0s_l1 = 3,
};
```

`AspmControl` — `LinkControl.aspm_control` (u2). Closed.

```zig
pub const AspmControl = enum(u2) {
    disabled = 0,
    l0s = 1,
    l1 = 2,
    l0s_l1 = 3,
};
```

`CompletionTimeoutValue` — `DeviceControl2.completion_timeout_value` (u4). Open; PCIe names range A/B/C/D subranges plus `default`.

```zig
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
```

## Register decodings `[std]`

Each register is a `packed struct(uN)` bit-cast to and from a native `uN` value read at the register's byte offset. Field order is LSB-first, matching Zig's `packed struct` layout and PCIe's bit numbering.

Every field carries a Zig default value: `bool` fields default to `false`; integer fields (`uN`, including `_reserved_*`) default to `0`; enum fields default to the enum's zero encoding (or `._` wildcard when zero is reserved). Callers of `clear*Bits` helpers on RW1C registers set only the sticky bits they want cleared; every other field takes its default and the resulting bit pattern has those defaults on the wire. Callers of `set*` on writable registers still read live state via the corresponding read accessor, mutate, and write back — defaults do not participate in RMW paths.

### PCI Express Capabilities Register (`0x02`, u16)

```zig
pub const Capabilities = packed struct(u16) {
    version: u4,
    device_port_type: DevicePortType,
    slot_implemented: bool,
    interrupt_message_number: u5,
    _reserved_14: u2,
};
```

`interrupt_message_number` is the MSI vector index this function uses for PCIe-defined interrupts (link bandwidth, PME, hot-plug). Interpretation is caller-owned.

### Device Capabilities Register (`0x04`, u32) `[RO]`

```zig
pub const DeviceCapabilities = packed struct(u32) {
    max_payload_size_supported: MaxPayloadSize,
    phantom_functions_supported: u2,
    extended_tag_field_supported: bool,
    endpoint_l0s_acceptable_latency: u3,
    endpoint_l1_acceptable_latency: u3,
    _reserved_12: u3,
    role_based_error_reporting: bool,
    _reserved_16: u2,
    captured_slot_power_limit_value: u8,
    captured_slot_power_limit_scale: u2,
    function_level_reset_capability: bool,
    _reserved_29: u3,
};
```

### Device Control Register (`0x08`, u16) `[RW]`

```zig
pub const DeviceControl = packed struct(u16) {
    correctable_error_reporting_enable: bool,
    non_fatal_error_reporting_enable: bool,
    fatal_error_reporting_enable: bool,
    unsupported_request_reporting_enable: bool,
    enable_relaxed_ordering: bool,
    max_payload_size: MaxPayloadSize,
    extended_tag_field_enable: bool,
    phantom_functions_enable: bool,
    aux_power_pm_enable: bool,
    enable_no_snoop: bool,
    max_read_request_size: MaxReadRequestSize,
    bcre_initiate_flr: bool,
};
```

Bit 15 is dual-purpose per PCIe: on type-1 (bridge) functions it is `Bridge Configuration Retry Enable` (RW); on non-bridge functions it initiates Function-Level Reset when written `1` (self-clearing). The view exposes it as one `bool` field named `bcre_initiate_flr`; caller policy interprets the bit against the function's header kind and `DeviceCapabilities.function_level_reset_capability`.

### Device Status Register (`0x0A`, u16) `[RW1C + RO]`

```zig
pub const DeviceStatus = packed struct(u16) {
    correctable_error_detected: bool,           // RW1C
    non_fatal_error_detected: bool,             // RW1C
    fatal_error_detected: bool,                 // RW1C
    unsupported_request_detected: bool,         // RW1C
    aux_power_detected: bool,                   // RO
    transactions_pending: bool,                 // RO
    emergency_power_reduction_detected: bool,   // RW1C
    _reserved_7: u9,
};
```

`clearDeviceStatusBits(bits)` writes a `DeviceStatus` value with each RW1C bit set to `true` for the bits to clear. RO bits (`aux_power_detected`, `transactions_pending`) are ignored by hardware regardless of the written value.

### Link Capabilities Register (`0x0C`, u32) `[RO]`

```zig
pub const LinkCapabilities = packed struct(u32) {
    max_link_speed: MaxLinkSpeed,
    max_link_width: MaxLinkWidth,
    aspm_support: AspmSupport,
    l0s_exit_latency: u3,
    l1_exit_latency: u3,
    clock_power_management: bool,
    surprise_down_error_reporting_capable: bool,
    data_link_layer_link_active_reporting_capable: bool,
    link_bandwidth_notification_capability: bool,
    aspm_optionality_compliance: bool,
    _reserved_23: u1,
    port_number: u8,
};
```

### Link Control Register (`0x10`, u16) `[RW]`

```zig
pub const LinkControl = packed struct(u16) {
    aspm_control: AspmControl,
    _reserved_2: u1,
    read_completion_boundary: bool,
    link_disable: bool,
    retrain_link: bool,
    common_clock_configuration: bool,
    extended_synch: bool,
    enable_clock_power_management: bool,
    hardware_autonomous_width_disable: bool,
    link_bandwidth_management_interrupt_enable: bool,
    link_autonomous_bandwidth_interrupt_enable: bool,
    _reserved_12: u2,
    drs_signaling_control: bool,
    _reserved_15: u1,
};
```

`retrain_link` is a write-1-triggers-action bit that reads back as `0`. `setLinkControl` writes the caller-supplied value verbatim; retrain orchestration is not owned by this spec.

### Link Status Register (`0x12`, u16) `[RW1C + RO]`

```zig
pub const LinkStatus = packed struct(u16) {
    current_link_speed: MaxLinkSpeed,           // RO
    negotiated_link_width: MaxLinkWidth,        // RO
    _undefined_10: u1,
    link_training: bool,                        // RO
    slot_clock_configuration: bool,             // RO
    data_link_layer_link_active: bool,          // RO
    link_bandwidth_management_status: bool,     // RW1C
    link_autonomous_bandwidth_status: bool,     // RW1C
};
```

`clearLinkStatusBits(bits)` writes the two RW1C bits set to `true` to clear them; RO bits are ignored by hardware.

### Slot Capabilities Register (`0x14`, u32) `[RO]`

Meaningful only when `Capabilities.slot_implemented` is `true` on a downstream port. `View` does not gate on that precondition.

```zig
pub const SlotCapabilities = packed struct(u32) {
    attention_button_present: bool,
    power_controller_present: bool,
    mrl_sensor_present: bool,
    attention_indicator_present: bool,
    power_indicator_present: bool,
    hot_plug_surprise: bool,
    hot_plug_capable: bool,
    slot_power_limit_value: u8,
    slot_power_limit_scale: u2,
    electromechanical_interlock_present: bool,
    no_command_completed_support: bool,
    physical_slot_number: u13,
};
```

### Slot Control Register (`0x18`, u16) `[RW]`

```zig
pub const SlotControl = packed struct(u16) {
    attention_button_pressed_enable: bool,
    power_fault_detected_enable: bool,
    mrl_sensor_changed_enable: bool,
    presence_detect_changed_enable: bool,
    command_completed_interrupt_enable: bool,
    hot_plug_interrupt_enable: bool,
    attention_indicator_control: u2,
    power_indicator_control: u2,
    power_controller_control: bool,
    electromechanical_interlock_control: bool,
    data_link_layer_state_changed_enable: bool,
    auto_slot_power_limit_disable: bool,
    in_band_pd_disable: bool,
    _reserved_15: u1,
};
```

### Slot Status Register (`0x1A`, u16) `[RW1C + RO]`

```zig
pub const SlotStatus = packed struct(u16) {
    attention_button_pressed: bool,             // RW1C
    power_fault_detected: bool,                 // RW1C
    mrl_sensor_changed: bool,                   // RW1C
    presence_detect_changed: bool,              // RW1C
    command_completed: bool,                    // RW1C
    mrl_sensor_state: bool,                     // RO
    presence_detect_state: bool,                // RO
    electromechanical_interlock_status: bool,   // RO
    data_link_layer_state_changed: bool,        // RW1C
    _reserved_9: u7,
};
```

`clearSlotStatusBits(bits)` writes the five RW1C bits set to `true` to clear them; RO bits are ignored by hardware.

### Root Control Register (`0x1C`, u16) `[RW]`

Meaningful only on root-port functions. `View` does not gate on `DevicePortType == .root_port`.

```zig
pub const RootControl = packed struct(u16) {
    system_error_on_correctable_error_enable: bool,
    system_error_on_non_fatal_error_enable: bool,
    system_error_on_fatal_error_enable: bool,
    pme_interrupt_enable: bool,
    crs_software_visibility_enable: bool,
    _reserved_5: u11,
};
```

### Root Capabilities Register (`0x1E`, u16) `[RO]`

```zig
pub const RootCapabilities = packed struct(u16) {
    crs_software_visibility: bool,
    _reserved_1: u15,
};
```

### Root Status Register (`0x20`, u32) `[RW1C + RO]`

```zig
pub const RootStatus = packed struct(u32) {
    pme_requester_id: u16,      // RO
    pme_status: bool,           // RW1C
    pme_pending: bool,          // RO
    _reserved_18: u14,
};
```

`clearRootStatusBits(bits)` writes the RW1C `pme_status` bit set to `true` to clear it; `pme_pending` and `pme_requester_id` are ignored by hardware.

### Device Capabilities 2 Register (`0x24`, u32) `[RO, v2]`

```zig
pub const DeviceCapabilities2 = packed struct(u32) {
    completion_timeout_ranges_supported: u4,
    completion_timeout_disable_supported: bool,
    ari_forwarding_supported: bool,
    atomic_op_routing_supported: bool,
    atomic_op_completer_32_supported: bool,
    atomic_op_completer_64_supported: bool,
    cas_completer_128_supported: bool,
    no_ro_enabled_pr_pr_passing: bool,
    ltr_mechanism_supported: bool,
    tph_completer_supported: u2,
    ln_system_cls: u2,
    tag_completer_10bit_supported: bool,
    tag_requester_10bit_supported: bool,
    obff_supported: u2,
    extended_fmt_field_supported: bool,
    end_end_tlp_prefix_supported: bool,
    max_end_end_tlp_prefixes: u2,
    emergency_power_reduction_supported: u2,
    emergency_power_reduction_init_required: bool,
    _reserved_27: u3,
    frs_supported: bool,
    _reserved_31: u1,
};
```

`completion_timeout_ranges_supported` is a 4-bit bitmask (bit 0 → range A, bit 1 → range B, bit 2 → range C, bit 3 → range D), not a `CompletionTimeoutValue`.

### Device Control 2 Register (`0x28`, u16) `[RW, v2]`

```zig
pub const DeviceControl2 = packed struct(u16) {
    completion_timeout_value: CompletionTimeoutValue,
    completion_timeout_disable: bool,
    ari_forwarding_enable: bool,
    atomic_op_requester_enable: bool,
    atomic_op_egress_blocking: bool,
    ido_request_enable: bool,
    ido_completion_enable: bool,
    ltr_mechanism_enable: bool,
    emergency_power_reduction_request: bool,
    tag_requester_10bit_enable: bool,
    obff_enable: u2,
    end_end_tlp_prefix_blocking: bool,
};
```

### Device Status 2 Register (`0x2A`, u16) `[Reserved, v2]`

```zig
pub const DeviceStatus2 = packed struct(u16) {
    _reserved_0: u16,
};
```

### Link Capabilities 2 Register (`0x2C`, u32) `[RO, v2]`

```zig
pub const LinkCapabilities2 = packed struct(u32) {
    _reserved_0: u1,
    supported_link_speeds_vector: u7,
    crosslink_supported: bool,
    lower_skp_os_generation_supported: u7,
    lower_skp_os_reception_supported: u7,
    retimer_presence_detect_supported: bool,
    two_retimers_presence_detect_supported: bool,
    _reserved_25: u6,
    drs_supported: bool,
};
```

`supported_link_speeds_vector` is a bitmask (bit 0 → 2.5 GT/s, bit 1 → 5 GT/s, bit 2 → 8 GT/s, bit 3 → 16 GT/s, bit 4 → 32 GT/s, bit 5 → 64 GT/s, bit 6 reserved), not a `MaxLinkSpeed`.

### Link Control 2 Register (`0x30`, u16) `[RW, v2]`

```zig
pub const LinkControl2 = packed struct(u16) {
    target_link_speed: MaxLinkSpeed,
    enter_compliance: bool,
    hardware_autonomous_speed_disable: bool,
    selectable_deemphasis: bool,
    transmit_margin: u3,
    enter_modified_compliance: bool,
    compliance_sos: bool,
    compliance_preset_or_deemphasis: u4,
};
```

### Link Status 2 Register (`0x32`, u16) `[RW1C + RO, v2]`

```zig
pub const LinkStatus2 = packed struct(u16) {
    current_deemphasis_level: bool,             // RO
    equalization_8gt_complete: bool,            // RO
    equalization_8gt_phase1_successful: bool,   // RO
    equalization_8gt_phase2_successful: bool,   // RO
    equalization_8gt_phase3_successful: bool,   // RO
    link_equalization_request_8gt: bool,        // RW1C
    retimer_presence_detected: bool,            // RO
    two_retimers_presence_detected: bool,       // RO
    crosslink_resolution: u2,                   // RO
    _reserved_10: u2,
    downstream_component_presence: u3,          // RO
    drs_message_received: bool,                 // RW1C
};
```

`clearLinkStatus2Bits(bits)` writes the two RW1C bits (`link_equalization_request_8gt`, `drs_message_received`) set to `true` to clear them; RO bits are ignored by hardware.

### Slot Capabilities 2 Register (`0x34`, u32) `[RO, v2]`

```zig
pub const SlotCapabilities2 = packed struct(u32) {
    _reserved_0: u1,
    in_band_pd_disable_supported: bool,
    _reserved_2: u30,
};
```

### Slot Control 2 Register (`0x38`, u16) `[Reserved, v2]`

```zig
pub const SlotControl2 = packed struct(u16) {
    _reserved_0: u16,
};
```

### Slot Status 2 Register (`0x3A`, u16) `[Reserved, v2]`

```zig
pub const SlotStatus2 = packed struct(u16) {
    _reserved_0: u16,
};
```

## Compile-time layout assertions `[zpci]`

`src/capabilities/pcie.zig` colocates the following assertions with the register decodings:

```zig
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
```

## `View` `[zpci]`

```zig
pub const Error = ConfigSpace.Error || error{
    MalformedCapability,
    MalformedField,
    UnsupportedRevision,
};

pub const View = struct {
    function: config.Function,
    base: u8,
    version: u4,

    pub fn validate(function: config.Function, cap: capabilities.list.Capability) Error!View;

    /// Walks the capability list for `id == .pci_express` and delegates
    /// to `validate`. Returns `null` when no PCIe capability is present.
    pub fn find(function: config.Function) Error!?View;

    pub fn capabilities(self: View) ConfigSpace.Error!Capabilities;

    // v1: Device
    pub fn deviceCapabilities(self: View) ConfigSpace.Error!DeviceCapabilities;
    pub fn deviceControl(self: View) ConfigSpace.Error!DeviceControl;
    pub fn setDeviceControl(self: View, value: DeviceControl) ConfigSpace.Error!void;
    pub fn deviceStatus(self: View) ConfigSpace.Error!DeviceStatus;
    pub fn clearDeviceStatusBits(self: View, bits: DeviceStatus) ConfigSpace.Error!void;

    // v1: Link
    pub fn linkCapabilities(self: View) ConfigSpace.Error!LinkCapabilities;
    pub fn linkControl(self: View) ConfigSpace.Error!LinkControl;
    pub fn setLinkControl(self: View, value: LinkControl) ConfigSpace.Error!void;
    pub fn linkStatus(self: View) ConfigSpace.Error!LinkStatus;
    pub fn clearLinkStatusBits(self: View, bits: LinkStatus) ConfigSpace.Error!void;

    // v1: Slot
    pub fn slotCapabilities(self: View) ConfigSpace.Error!SlotCapabilities;
    pub fn slotControl(self: View) ConfigSpace.Error!SlotControl;
    pub fn setSlotControl(self: View, value: SlotControl) ConfigSpace.Error!void;
    pub fn slotStatus(self: View) ConfigSpace.Error!SlotStatus;
    pub fn clearSlotStatusBits(self: View, bits: SlotStatus) ConfigSpace.Error!void;

    // v1: Root
    pub fn rootControl(self: View) ConfigSpace.Error!RootControl;
    pub fn setRootControl(self: View, value: RootControl) ConfigSpace.Error!void;
    pub fn rootCapabilities(self: View) ConfigSpace.Error!RootCapabilities;
    pub fn rootStatus(self: View) ConfigSpace.Error!RootStatus;
    pub fn clearRootStatusBits(self: View, bits: RootStatus) ConfigSpace.Error!void;

    // v2: Device
    pub fn deviceCapabilities2(self: View) Error!DeviceCapabilities2;
    pub fn deviceControl2(self: View) Error!DeviceControl2;
    pub fn setDeviceControl2(self: View, value: DeviceControl2) Error!void;
    pub fn deviceStatus2(self: View) Error!DeviceStatus2;

    // v2: Link
    pub fn linkCapabilities2(self: View) Error!LinkCapabilities2;
    pub fn linkControl2(self: View) Error!LinkControl2;
    pub fn setLinkControl2(self: View, value: LinkControl2) Error!void;
    pub fn linkStatus2(self: View) Error!LinkStatus2;
    pub fn clearLinkStatus2Bits(self: View, bits: LinkStatus2) Error!void;

    // v2: Slot
    pub fn slotCapabilities2(self: View) Error!SlotCapabilities2;
    pub fn slotControl2(self: View) Error!SlotControl2;
    pub fn setSlotControl2(self: View, value: SlotControl2) Error!void;
    pub fn slotStatus2(self: View) Error!SlotStatus2;
};
```

`validate(function, cap)` behavior:

1. Assert `cap.idTag() == .pci_express`. Programmer-error precondition, not a runtime error.
2. Validate `capabilities.list.standard.window.range.contains(cap.offset)` and `cap.offset % capabilities.list.standard.window.step == 0`. Otherwise, return `error.MalformedCapability`.
3. Read `Capabilities` via `function.read16(cap.offset + register.capabilities)` and bit-cast to `Capabilities`. `ConfigSpace.Error` propagates directly.
4. If `capabilities.version == 0`, return `error.UnsupportedRevision`.
5. Return `View{ .function = function, .base = cap.offset, .version = capabilities.version }`.

Register accessor behavior:

- v1 accessors (`deviceCapabilities`..=`rootStatus`, and their `set*`/`clear*Bits` partners) return `ConfigSpace.Error` only. They read/write `self.base + register.<name>` and bit-cast to/from the corresponding typed struct.
- v2 accessors (`deviceCapabilities2`..=`slotStatus2`, and their `set*`/`clear*Bits` partners) check `self.version >= 2` at entry. When `self.version < 2`, they return `error.UnsupportedRevision` without performing any config access. Otherwise they behave like the v1 accessors, reading/writing at `self.base + register.<name>` and bit-casting to/from the typed struct.
- Every write is one config write of the exact bit-cast of the caller-supplied value. `View` performs no hidden read-modify-write. Reserved bits and RW1C sticky bits round-trip through the caller's typed value, so callers who read, mutate, and write back preserve the pattern PCIe requires.
- `clear*Bits` helpers write the caller-supplied value verbatim. Setting an RW1C bit `true` clears it; setting an RO or RW0 bit `true` has no effect per PCIe semantics.

`View` does not validate:

- Function presence or vendor id (`config.Function.validate` owns that).
- Header kind against register applicability (Slot registers on non-slot functions, Root registers on non-root ports, etc.). Callers filter by `capabilities()`, `deviceCapabilities()`, or `slotCapabilities()` before reading policy-dependent registers.
- Which bits of a writable register are legal to change given the current link/slot state.

## Errors

`View.Error` is:

```zig
ConfigSpace.Error || error{
    MalformedCapability,
    MalformedField,
    UnsupportedRevision,
}
```

Variant ownership:

- `OutOfBounds`, `UnsupportedAccessWidth`, `UnalignedAccess` come from `ConfigSpace`.
- `MalformedCapability` is produced by `View.validate` when `cap.offset` falls outside the conventional capability window or is not dword-aligned. This spec re-owns the variant against the byte offset it hands to `function.readN`, matching the `capabilities.list.Cursor` pattern.
- `MalformedField` is produced only by named-enum interpretation helpers (`MaxPayloadSize.bytes`, `MaxReadRequestSize.bytes`, `MaxLinkSpeed.megaTransfersPerSecond`, `MaxLinkWidth.lanes`) for reserved encodings. Register reads never produce it; the raw enum value round-trips through the wildcard `_` case.
- `UnsupportedRevision` is produced by `View.validate` for `Capabilities.version == 0` and by every v2 accessor when `self.version < 2`.

## Validation behavior

`View` performs the following validation and no more:

- `View.validate` validates `cap.offset` against the standard capability window and reads `Capabilities.version`, rejecting `0`.
- v2 accessors validate `self.version >= 2` before any config access.
- Register reads and writes delegate containment, natural alignment, and backend width to `ConfigSpace`.
- Enum interpretation helpers validate the read encoding at the caller's request.

Reserved-bit preservation:

- Every reserved bit is a named `_reserved_<lo>: uN` field on the packed struct. `command`-style RMW patterns are the caller's responsibility: `var value = try view.deviceControl(); value.<field> = ...; try view.setDeviceControl(value);` round-trips reserved bits.
- `clear*Bits` helpers write the value verbatim, so a caller that constructs the `bits` argument by zero-initializing the struct and setting only the sticky bits to `true` writes `0` to reserved bits, matching PCIe RW1C semantics (`0` has no effect on RW1C, RO, or reserved bits).

## View / borrowing behavior

- `View` is a borrowed value: it stores a `config.Function`, a `u8` base offset, and a `u4` version.
- `View` is copyable; copies share the same backend through `config.Function`.
- `View` does not allocate, retry, cache config-space bytes, or synchronize.
- `version` is the only cached value on the view.
- Lifetime follows the underlying `ConfigSpace` backend.

## zstdx usage

Direct usage: none.

This spec does not need `zstdx.bytes`, `zstdx.layout.Le`, `zstdx.bits.BitSet`, or `zstdx.ranges.*` directly. Containment, byte access, and multi-byte endian handling are owned upstream by `ConfigSpace`, `Function`, and Zig's native `packed struct` bit-cast.

## Facade re-export `[zpci]`

`src/capabilities.zig`:

```zig
pub const pcie = @import("capabilities/pcie.zig");
```

Callers reach the public surface as `pci.capabilities.pcie.View`, `pci.capabilities.pcie.Capabilities`, `pci.capabilities.pcie.DeviceControl`, `pci.capabilities.pcie.MaxPayloadSize`, etc.

## Usage

Walk the standard capability list and construct a PCIe view when the id matches:

```zig
const function = try pci.config.Function.validate(config, sbdf);
var it = try pci.capabilities.list.Iterator.validate(function);

while (try it.next()) |cap| {
    if (cap.idTag() != .pci_express) continue;
    const view = try pci.capabilities.pcie.View.validate(function, cap);
    _ = view;
}
```

Read the device port type and slot-implemented bit:

```zig
const caps = try view.capabilities();
switch (caps.device_port_type) {
    .root_port, .downstream_port => {
        if (caps.slot_implemented) {
            const slot = try view.slotCapabilities();
            _ = slot;
        }
    },
    else => {},
}
```

Program Max Payload Size and Extended Tag Field Enable through a whole-register write:

```zig
var ctrl = try view.deviceControl();
ctrl.max_payload_size = .bytes_256;
ctrl.extended_tag_field_enable = true;
try view.setDeviceControl(ctrl);
```

Interpret an enum encoding, surfacing reserved values:

```zig
const dcap = try view.deviceCapabilities();
const mps_bytes = dcap.max_payload_size_supported.bytes() catch |err| switch (err) {
    error.MalformedField => 128, // caller policy for reserved encoding
};
_ = mps_bytes;
```

Clear the sticky RW1C bits on Device Status:

```zig
const sticky = pci.capabilities.pcie.DeviceStatus{
    .correctable_error_detected = true,
    .non_fatal_error_detected = true,
    .fatal_error_detected = true,
    .unsupported_request_detected = true,
    .aux_power_detected = false,       // RO, ignored
    .transactions_pending = false,     // RO, ignored
    .emergency_power_reduction_detected = true,
    ._reserved_7 = 0,
};
try view.clearDeviceStatusBits(sticky);
```

Gate on version for v2-only registers:

```zig
const dcap2 = view.deviceCapabilities2() catch |err| switch (err) {
    error.UnsupportedRevision => return, // v1 endpoint; no v2 data
    else => return err,
};
_ = dcap2;
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `View.validate` | never | one config read | `cap.offset` window and `version != 0` | none | backend-defined | one 16-bit read |
| v1 register read | never | one config read | delegated to `ConfigSpace` | none | backend-defined | one access |
| v1 register write / `clear*Bits` | never | one config write | delegated to `ConfigSpace` | written config state on success | backend-defined | one access |
| v2 register read | never | one config read after version check | delegated to `ConfigSpace` | none | backend-defined | one access |
| v2 register write / `clear*Bits` | never | one config write after version check | delegated to `ConfigSpace` | written config state on success | backend-defined | one access |
| enum interpretation helper | never | never | O(1) | none | pure | none |

## Non-goals

- Extended capability decode (`docs/specs/capabilities/extended.md`).
- Standard capability-list traversal (`docs/specs/capabilities/list.md`).
- MSI or MSI-X programming (`docs/specs/interrupts/msi.md`, `docs/specs/interrupts/msix.md`).
- Hot-plug slot orchestration, indicator sequencing, or power-controller sequencing.
- Link retrain, link disable, or ASPM state-machine sequencing.
- Function-Level Reset sequencing (the FLR bit is exposed on `DeviceControl`; sequencing is caller-owned).
- Root-complex PME message routing or error-message routing beyond exposing `RootControl`, `RootCapabilities`, and `RootStatus` for whole-register access.
- Equalization phase management or `LinkStatus2` interpretation beyond the register decoding.
- Slot power-limit programming policy.
- Header-kind gating: this spec does not check `header_type` before exposing the Bridge Configuration Retry Enable / FLR-initiate bit or the Root registers.
- Dispatch tables over `DevicePortType`.
- Diagnostic out-parameters or `Diagnostic` structs.
- Hidden read-modify-write inside any accessor.

## Open questions

None owned by this spec.
