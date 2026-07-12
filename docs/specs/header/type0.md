# Type-0 header

Defines the typed view of PCI **header type 0 (endpoint)** configuration space at offsets `0x10..=0x3F`. Owns the `Type0Header` wire layout and `header.type0.View` for typed reads and the narrow set of typed writes resource programming requires.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `Type0Header` and `header.type0.View`. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/common.md`
- `docs/specs/header/type1.md`
- `docs/specs/bar.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/resources/programming.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- `Type0Header` `extern struct` covering the 48 bytes (`0x10..=0x3F`) following the common header for header type 0.
- Compile-time layout assertions for `Type0Header`.
- `bar_count` constant.
- `header.type0.View` borrowed typed view over `config.Function`.
- Typed reads for every field at type-0 layout positions:
  - 6 BARs as raw `u32` (`0x10`, `0x14`, `0x18`, `0x1C`, `0x20`, `0x24`).
  - Cardbus CIS pointer (`0x28`).
  - Subsystem vendor id (`0x2C`).
  - Subsystem id (`0x2E`).
  - Expansion ROM base address (`0x30`).
  - Capabilities pointer (`0x34`).
  - Interrupt line (`0x3C`).
  - Interrupt pin (`0x3D`).
  - Min Gnt (`0x3E`).
  - Max Lat (`0x3F`).
- Typed `setInterruptLine` write at `0x3C`.
- Typed `setExpansionRomBase` write at `0x30` (used by resource programming for the atomic base+enable update).

Deferred:

- BAR decode (memory vs IO, prefetchable, width, 64-bit pairing) — `docs/specs/bar.md`.
- BAR sizing probe — `docs/specs/bar.md`.
- BAR programming writes — `docs/specs/bar.md` and `docs/specs/resources/programming.md`.
- Expansion-ROM enable-bit orchestration — caller policy. Base-register programming — `docs/specs/resources/programming.md`.
- Capability-list traversal and cycle handling — `docs/specs/capabilities/list.md`.
- Subsystem id semantic interpretation — caller policy, not pci.
- Interrupt-pin decoding (INTA/INTB/INTC/INTD/none) — `docs/specs/interrupts/*.md`.
- Type-1 (PCI-PCI bridge) fields — `docs/specs/header/type1.md`.
- Multifunction enumeration policy — `docs/specs/topology/enumerate.md`.

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness. `Type0Header` uses native integer fields and no `zstdx.layout.Le(uN)` wrappers.

## Wire layout `[std]`

`Type0Header` covers config-space offsets `0x10..=0x3F`. Field offsets in the struct are relative to the start of `Type0Header`; adding `0x10` gives the absolute config-space offset.

```zig
pub const bar_count: usize = 6;

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
};

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
```

Absolute config-space offsets for the same fields:

| Config offset | Field | Width |
|---:|---|---:|
| `0x10..=0x27` | `bars[0..6]` | 6 × 32 bits |
| `0x28` | `cardbus_cis_pointer` | 32 bits |
| `0x2C` | `subsystem_vendor_id` | 16 bits |
| `0x2E` | `subsystem_id` | 16 bits |
| `0x30` | `expansion_rom_base_address` | 32 bits |
| `0x34` | `capabilities_pointer` | 8 bits |
| `0x35..=0x37` | reserved | 3 bytes |
| `0x38..=0x3B` | reserved | 32 bits |
| `0x3C` | `interrupt_line` | 8 bits |
| `0x3D` | `interrupt_pin` | 8 bits |
| `0x3E` | `min_grant` | 8 bits |
| `0x3F` | `max_latency` | 8 bits |

## Expansion ROM register `[std]`

```zig
pub const ExpansionRom = packed struct(u32) {
    enable: bool = false,
    _reserved1: u10 = 0,
    base_shifted: u21 = 0,
};
```

Rules:

- `ExpansionRom` is bit-cast from the `u32` read at offset `0x30`.
- `enable` (bit `[0]`) is RW. Software sets it to enable ROM decoding.
- `_reserved1` (bits `[10:1]`) is RsvdP. Round-trips unchanged.
- `base_shifted` (bits `[31:11]`) is the ROM base address shifted right by 11 (2 KiB alignment). Full base = `@as(u32, base_shifted) << 11`.
- Base-register programming (RMW that preserves `enable`, clears `_reserved1`, and writes `base_shifted`) is owned by `docs/specs/resources/programming.md`. Enable-bit orchestration is caller policy.

## Subsystem identifier `[std]`

```zig
pub const Subsystem = struct {
    vendor_id: u16,
    id: u16,
};
```

`Subsystem` groups the two 16-bit subsystem-identifier registers read as one 32-bit dword.

## `View` `[zpci]`

```zig
pub const View = struct {
    function: config.Function,

    pub fn init(function: config.Function) View;

    pub fn rawBar(self: View, index: usize) ConfigSpace.Error!u32;
    pub fn cardbusCisPointer(self: View) ConfigSpace.Error!u32;
    pub fn subsystemVendorId(self: View) ConfigSpace.Error!u16;
    pub fn subsystemId(self: View) ConfigSpace.Error!u16;
    pub fn expansionRomBase(self: View) ConfigSpace.Error!ExpansionRom;
    pub fn capabilitiesPointer(self: View) ConfigSpace.Error!u8;
    pub fn subsystem(self: View) ConfigSpace.Error!Subsystem;
    pub fn interruptLine(self: View) ConfigSpace.Error!u8;
    pub fn interruptPin(self: View) ConfigSpace.Error!u8;
    pub fn minGrant(self: View) ConfigSpace.Error!u8;
    pub fn maxLatency(self: View) ConfigSpace.Error!u8;

    pub fn setInterruptLine(self: View, value: u8) ConfigSpace.Error!void;
    pub fn setExpansionRomBase(self: View, value: u32) ConfigSpace.Error!void;

    /// Returns a `header.common.View` for the same `config.Function`.
    /// Convenience for callers holding a `type0.View` that need to
    /// reach common-header accessors (Command, Status, cache line size,
    /// BIST, capabilities pointer, interrupt line/pin).
    pub fn common(self: View) common.View;
};
```

Behavior rules:

- `rawBar(index)` asserts `index < bar_count` (programmer error) and reads `0x10 + 4 * index` through `config.Function.read32`.
- `rawBar` returns the raw `u32`. Decode of memory vs IO, prefetchability, 32/64-bit width, BAR pairing, and the sizing probe are owned by `docs/specs/bar.md`.
- `cardbusCisPointer` reads `0x28`.
- `subsystemVendorId` reads `0x2C` and returns the raw `u16`.
- `subsystemId` reads `0x2E` and returns the raw `u16`.
- `subsystem` reads `0x2C..=0x2F` as one `u32` and returns `Subsystem{ .vendor_id = @truncate(value), .id = @truncate(value >> 16) }`. One config read; equivalent to calling `subsystemVendorId` and `subsystemId` separately.
- `expansionRomBase` reads `0x30` and bit-casts to `ExpansionRom`.
- `capabilitiesPointer` reads `0x34`. Walking the list is owned by `docs/specs/capabilities/list.md`.
- `interruptLine` reads `0x3C`.
- `interruptPin` reads `0x3D` and returns the raw `u8`. Decoding to `INTA`/`INTB`/`INTC`/`INTD`/none is owned by an interrupt-routing spec.
- `minGrant` reads `0x3E`.
- `maxLatency` reads `0x3F`.
- `setInterruptLine(value)` writes `0x3C`. Caller policy decides what value is meaningful.
- `setExpansionRomBase(value)` writes the full 32-bit register at `0x30`. Enable-bit orchestration is caller policy; base-register programming (including RMW that preserves `enable`) is owned by `docs/specs/resources/programming.md`.
- `common()` returns a `header.common.View` for the same `config.Function`. No I/O.

`View` does not expose typed BAR writes, capability-pointer writes, subsystem-id writes, Min Gnt / Max Lat writes, or interrupt-pin writes. Those fields are either RO, BAR-managed, or programmed exclusively through `bar.md` / `resources/programming.md`.

## Validation behavior

- All reads and writes flow through `config.Function`, which delegates containment, natural-alignment, and width checks to `ConfigSpace`.
- `rawBar` asserts `index < bar_count` after public-shape validation. A misindexed BAR access is a programmer error, not a typed error.
- The view does not validate header kind. Dispatch at `config/space.md` ensures that the function actually advertises header type 0 before a `header.type0.View` is constructed.
- `expansionRomBase` returns the raw register including the enable bit. The caller decodes per `resources/programming.md`.

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

`src/header.zig` re-exports the type-0 module, its wire struct, and its typed registers:

```zig
pub const type0 = @import("header/type0.zig");
pub const Type0Header = type0.Type0Header;
pub const ExpansionRom = type0.ExpansionRom;
pub const Subsystem = type0.Subsystem;
```

Callers reach the view as `pci.header.type0.View` and the structs as `pci.header.Type0Header`, `pci.header.ExpansionRom`, `pci.header.Subsystem`.

## Usage

Endpoint dispatch and field reads:

```zig
const function = try pci.config.Function.validate(config, sbdf);
switch (try function.headerKind()) {
    .type0 => {
        const view = pci.header.type0.View.init(function);

        const bar0 = try view.rawBar(0);
        const bar1 = try view.rawBar(1);
        const subsys_vendor = try view.subsystemVendorId();
        const subsys = try view.subsystemId();
        const rom = try view.expansionRomBase();

        _ = bar0;
        _ = bar1;
        _ = subsys_vendor;
        _ = subsys;
        _ = rom;
    },
    .type1 => {
        // docs/specs/header/type1.md owns the bridge view.
    },
}
```

Program interrupt line:

```zig
try view.setInterruptLine(0x0B);
```

Atomic expansion-ROM base-and-enable write (the rest of the orchestration belongs to `resources/programming.md`):

```zig
const rom_base_and_enable: u32 = (computed_base & 0xFFFF_F800) | 0x0000_0001;
try view.setExpansionRomBase(rom_base_and_enable);
```

## Non-goals

- BAR decode, sizing, or programming policy.
- Capability-list walking, validation, or cycle handling.
- Subsystem-id catalog or semantic interpretation.
- Interrupt routing or MSI/MSI-X programming.
- Expansion-ROM orchestration order.
- Multifunction enumeration policy.
- Hidden retries, read-modify-write, or locking.

## Open questions

None owned by this spec.
