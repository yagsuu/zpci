# Type-1 header

Defines the typed view of PCI **header type 1 (PCI-PCI bridge)** configuration space at offsets `0x10..=0x3F`. Owns the `Type1Header` wire layout and `header.type1.View` for the typed reads and the writes the bridge enumerator and resource programmer need.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `Type1Header` and `header.type1.View`. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/common.md`
- `docs/specs/header/type0.md`
- `docs/specs/bar.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/resources/programming.md`
- `docs/specs/resources/bridge.md`
- `docs/specs/topology/enumerate.md`
- `docs/specs/topology/bridge.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- `Type1Header` `extern struct` covering the 48 bytes (`0x10..=0x3F`) following the common header for header type 1.
- Compile-time layout assertions for `Type1Header`.
- `bridge_bar_count` constant.
- `header.type1.View` borrowed typed view over `config.Function`.
- Typed reads for every type-1 field listed below.
- Typed writes that the bridge enumerator and resource programmer must issue exactly once per field, without hidden read-modify-write.
- The RW1C semantics of secondary status surfaced as `clearSecondaryStatus(bits: common.Status)`.

Deferred:

- BAR decode/sizing on the 2 bridge BARs — `docs/specs/bar.md`.
- Bus-number assignment policy and recursive enumeration — `docs/specs/topology/enumerate.md`.
- Bridge resource-window alignment, encodability, and disabled encodings — `docs/specs/resources/bridge.md`.
- Base-register programming order and decode-disable orchestration — `docs/specs/resources/programming.md`. Bus-number programming — `docs/specs/resources/bus.md`.
- Bridge-control bit semantics (secondary bus reset, ISA enable, VGA enable, master-abort mode, discard timers, parity/SERR, fast back-to-back) — caller policy.
- Capability-list traversal — `docs/specs/capabilities/list.md`.
- Expansion-ROM enable-bit orchestration — caller policy. Base-register programming — `docs/specs/resources/programming.md`.
- Interrupt-pin decoding — `docs/specs/interrupts/*.md`.

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness. `Type1Header` uses native integer fields and no `zstdx.layout.Le(uN)` wrappers.

## Wire layout `[std]`

`Type1Header` covers config-space offsets `0x10..=0x3F`. Field offsets in the struct are relative to the start of `Type1Header`; adding `0x10` gives the absolute config-space offset.

```zig
pub const bridge_bar_count: usize = 2;

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
};

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
```

Absolute config-space offsets for the same fields:

| Config offset | Field | Width |
|---:|---|---:|
| `0x10..=0x17` | `bars[0..2]` | 2 × 32 bits |
| `0x18` | `primary_bus_number` | 8 bits |
| `0x19` | `secondary_bus_number` | 8 bits |
| `0x1A` | `subordinate_bus_number` | 8 bits |
| `0x1B` | `secondary_latency_timer` | 8 bits |
| `0x1C` | `io_base` | 8 bits |
| `0x1D` | `io_limit` | 8 bits |
| `0x1E` | `secondary_status` | 16 bits |
| `0x20` | `memory_base` | 16 bits |
| `0x22` | `memory_limit` | 16 bits |
| `0x24` | `prefetchable_memory_base` | 16 bits |
| `0x26` | `prefetchable_memory_limit` | 16 bits |
| `0x28` | `prefetchable_base_upper_32` | 32 bits |
| `0x2C` | `prefetchable_limit_upper_32` | 32 bits |
| `0x30` | `io_base_upper_16` | 16 bits |
| `0x32` | `io_limit_upper_16` | 16 bits |
| `0x34` | `capabilities_pointer` | 8 bits |
| `0x35..=0x37` | reserved | 3 bytes |
| `0x38` | `expansion_rom_base_address` | 32 bits |
| `0x3C` | `interrupt_line` | 8 bits |
| `0x3D` | `interrupt_pin` | 8 bits |
| `0x3E` | `bridge_control` | 16 bits |

## Bridge Control register `[std]`

```zig
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
```

Rules:

- `BridgeControl` is bit-cast from the `u16` read at offset `0x3E`.
- `discard_timer_status` (bit `[10]`) is RW1C; other bits are RW.
- Reserved bits (`_reserved12`) round-trip unchanged on writes performed through `setBridgeControl`.
- Secondary-bus-reset orchestration (setting `secondary_bus_reset` to `true`, waiting the spec-required reset period, then clearing it) is caller policy.

## `View` `[zpci]`

```zig
pub const View = struct {
    function: config.Function,

    pub fn init(function: config.Function) View;

    // Raw BARs
    pub fn rawBar(self: View, index: usize) ConfigSpace.Error!u32;

    // Bus numbers
    pub fn primaryBus(self: View) ConfigSpace.Error!u8;
    pub fn secondaryBus(self: View) ConfigSpace.Error!u8;
    pub fn subordinateBus(self: View) ConfigSpace.Error!u8;
    pub fn secondaryLatencyTimer(self: View) ConfigSpace.Error!u8;

    // IO window
    pub fn ioBase(self: View) ConfigSpace.Error!u8;
    pub fn ioLimit(self: View) ConfigSpace.Error!u8;
    pub fn ioBaseUpper(self: View) ConfigSpace.Error!u16;
    pub fn ioLimitUpper(self: View) ConfigSpace.Error!u16;

    // Secondary status
    pub fn secondaryStatus(self: View) ConfigSpace.Error!common.Status;

    // Memory windows
    pub fn memoryBase(self: View) ConfigSpace.Error!u16;
    pub fn memoryLimit(self: View) ConfigSpace.Error!u16;
    pub fn prefetchableMemoryBase(self: View) ConfigSpace.Error!u16;
    pub fn prefetchableMemoryLimit(self: View) ConfigSpace.Error!u16;
    pub fn prefetchableBaseUpper(self: View) ConfigSpace.Error!u32;
    pub fn prefetchableLimitUpper(self: View) ConfigSpace.Error!u32;

    // Misc
    pub fn capabilitiesPointer(self: View) ConfigSpace.Error!u8;
    pub fn expansionRomBase(self: View) ConfigSpace.Error!u32;
    pub fn interruptLine(self: View) ConfigSpace.Error!u8;
    pub fn interruptPin(self: View) ConfigSpace.Error!u8;
    pub fn bridgeControl(self: View) ConfigSpace.Error!BridgeControl;

    // Writes
    pub fn setPrimaryBus(self: View, value: u8) ConfigSpace.Error!void;
    pub fn setSecondaryBus(self: View, value: u8) ConfigSpace.Error!void;
    pub fn setSubordinateBus(self: View, value: u8) ConfigSpace.Error!void;
    pub fn setSecondaryLatencyTimer(self: View, value: u8) ConfigSpace.Error!void;

    pub fn setIoBase(self: View, value: u8) ConfigSpace.Error!void;
    pub fn setIoLimit(self: View, value: u8) ConfigSpace.Error!void;
    pub fn setIoBaseUpper(self: View, value: u16) ConfigSpace.Error!void;
    pub fn setIoLimitUpper(self: View, value: u16) ConfigSpace.Error!void;

    pub fn setMemoryBase(self: View, value: u16) ConfigSpace.Error!void;
    pub fn setMemoryLimit(self: View, value: u16) ConfigSpace.Error!void;
    pub fn setPrefetchableMemoryBase(self: View, value: u16) ConfigSpace.Error!void;
    pub fn setPrefetchableMemoryLimit(self: View, value: u16) ConfigSpace.Error!void;
    pub fn setPrefetchableBaseUpper(self: View, value: u32) ConfigSpace.Error!void;
    pub fn setPrefetchableLimitUpper(self: View, value: u32) ConfigSpace.Error!void;

    pub fn clearSecondaryStatus(self: View, bits: common.Status) ConfigSpace.Error!void;

    pub fn setInterruptLine(self: View, value: u8) ConfigSpace.Error!void;
    pub fn setExpansionRomBase(self: View, value: u32) ConfigSpace.Error!void;
    pub fn setBridgeControl(self: View, value: BridgeControl) ConfigSpace.Error!void;
};
```

Behavior rules:

- `rawBar(index)` asserts `index < bridge_bar_count` (programmer error) and reads `0x10 + 4 * index` through `config.Function.read32`. Decode of memory vs IO, prefetchability, 32/64-bit width, BAR pairing, and the sizing probe are owned by `docs/specs/bar.md`.
- `primaryBus` / `secondaryBus` / `subordinateBus` / `secondaryLatencyTimer` read `0x18`/`0x19`/`0x1A`/`0x1B`.
- `setPrimaryBus` / `setSecondaryBus` / `setSubordinateBus` / `setSecondaryLatencyTimer` write the same offsets with `write8`.
- IO window accessors read `0x1C` / `0x1D` for the 8-bit base/limit nibbles and `0x30` / `0x32` for the upper-16 extensions; writes mirror.
- Memory window accessors read `0x20` / `0x22`; writes mirror.
- Prefetchable memory window accessors read `0x24` / `0x26` for the lower halves and `0x28` / `0x2C` for the upper 32-bit halves; writes mirror.
- `secondaryStatus()` reads `0x1E` and bit-casts the value to `common.Status` (spec: `docs/specs/header/common.md` §Status). The secondary-status register shares the primary-status wire layout; the RO-0 bits on the secondary side (capabilities list, 66 MHz capable) are returned as `false` and are ignored by hardware on writes.
- `clearSecondaryStatus(bits)` bit-casts `bits` to `u16` and writes `0x1E` in a single 16-bit config write. Consumers set the RW1C bits they want to clear to `true`; RO bits are ignored by hardware.
- `capabilitiesPointer` reads `0x34`. Walking the list is owned by `docs/specs/capabilities/list.md`.
- `expansionRomBase` reads `0x38`. Decoding the enable bit (bit 0) versus the base address belongs to `docs/specs/resources/programming.md`.
- `setExpansionRomBase(value)` writes the full 32-bit register at `0x38`. The caller is responsible for the base|enable composition and the programming order.
- `interruptLine` / `setInterruptLine` read/write `0x3C`.
- `interruptPin` reads `0x3D`. Decoding to `INTA`/`INTB`/`INTC`/`INTD`/none is owned by an interrupt-routing spec.
- `bridgeControl` / `setBridgeControl` read/write `0x3E` and bit-cast to `BridgeControl`.

`View` does not expose typed BAR writes, capability-pointer writes, or interrupt-pin writes; those fields are either RO, BAR-managed, or programmed exclusively through `bar.md` / `resources/programming.md`.

## Validation behavior

- All reads and writes flow through `config.Function`, which delegates containment, natural-alignment, and width checks to `ConfigSpace`.
- `rawBar` asserts `index < bridge_bar_count` after public-shape validation. A misindexed BAR access is a programmer error, not a typed error.
- The view does not validate header kind. Dispatch at `config/space.md` ensures that the function actually advertises header type 1.
- Disabled-window encodings (`base > limit`) are valid wire states and are returned as-is.

## View / borrowing behavior

- `View` is a borrowed value: `config.Function` plus nothing else.
- `View` is copyable; copies share the same backend through `config.Function`.
- `View` does not allocate, cache, retry, or synchronize.
- Lifetime follows the underlying `ConfigSpace` backend.

## Error behavior

All public read/write methods return `ConfigSpace.Error`. No new error variants.

## zstdx usage

Direct usage: none. Containment, byte access, and identifier wrapping are owned upstream by `ConfigSpace`, `Function`, and `core/ids`. No `zstdx.layout.Le` wrappers are needed under the LE-host assumption.

## Facade re-export `[zpci]`

`src/header.zig` re-exports the type-1 module, its wire struct, and its typed registers:

```zig
pub const type1 = @import("header/type1.zig");
pub const Type1Header = type1.Type1Header;
pub const BridgeControl = type1.BridgeControl;
```

Callers reach the view as `pci.header.type1.View` and the structs as `pci.header.Type1Header`, `pci.header.BridgeControl`.

## Usage

Bridge dispatch and bus-number programming:

```zig
const function = try pci.config.Function.validate(config, sbdf);
switch (try function.headerKind()) {
    .type0 => {},
    .type1 => {
        const view = pci.header.type1.View.init(function);

        try view.setPrimaryBus(0x00);
        try view.setSecondaryBus(0x01);
        try view.setSubordinateBus(0x01);

        // Disable all windows until resource programming runs.
        try view.setMemoryBase(0xFFF0);
        try view.setMemoryLimit(0x0000);
        try view.setPrefetchableMemoryBase(0xFFF0);
        try view.setPrefetchableMemoryLimit(0x0000);
        try view.setPrefetchableBaseUpper(0xFFFF_FFFF);
        try view.setPrefetchableLimitUpper(0x0000_0000);
        try view.setIoBase(0xF0);
        try view.setIoLimit(0x00);
        try view.setIoBaseUpper(0xFFFF);
        try view.setIoLimitUpper(0x0000);
    },
}
```

Acknowledge secondary-status bits:

```zig
const ss = try view.secondaryStatus();
try view.clearSecondaryStatus(ss); // RW1C: set bits clear, cleared bits are no-op
```

Selectively acknowledge one bit:

```zig
try view.clearSecondaryStatus(.{
    .received_target_abort = true,
});
```

Atomic expansion-ROM base-and-enable write:

```zig
const rom_base_and_enable: u32 = (computed_base & 0xFFFF_F800) | 0x0000_0001;
try view.setExpansionRomBase(rom_base_and_enable);
```

Secondary-bus reset composition (caller-owned):

```zig
var control = try view.bridgeControl();
control.secondary_bus_reset = true;
try view.setBridgeControl(control);
// caller waits the spec-required reset period
control.secondary_bus_reset = false;
try view.setBridgeControl(control);
// caller waits Trhfa
```

## Non-goals

- BAR decode, sizing, or programming policy.
- Bus-number assignment and recursive enumeration.
- Bridge-window alignment, prefetchable promotion, or resource-fit policy.
- Secondary-bus reset timing and orchestration.
- Capability-list traversal.
- Interrupt routing or MSI/MSI-X programming.
- Expansion-ROM orchestration order.
- Hidden retries, read-modify-write, or locking.

## Open questions

None owned by this spec.
