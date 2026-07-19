# Common header

Defines the typed view of the first 64 bytes of PCI configuration space (`0x00..=0x3F`) that are layout-shared between header type 0 (endpoint) and header type 1 (PCI-PCI bridge). Owns the `CommonHeader` wire layout, the `Command` / `Status` packed-struct decodings, and `header.common.View` for typed reads/writes through `config.Function`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `CommonHeader`, `Command`, `Status`, and `header.common.View`. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/bdf.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/type0.md`
- `docs/specs/header/type1.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/interrupts/pin.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- `CommonHeader` `extern struct` covering the first 16 bytes (`0x00..=0x0F`) shared between every header type.
- `register` absolute config-space offsets and the packed `HeaderType` wire representation for responder-side byte materialization.
- `Command` and `Status` packed-struct decodings of the 16-bit Command and Status registers.
- `header.common.View`, a borrowed typed view over `config.Function`.
- Typed read/write helpers for command, status, BIST, cache line size, latency timer, capabilities pointer, interrupt line, and interrupt pin.
- Compile-time layout assertions for `CommonHeader`.

Deferred:

- Type-0-specific fields (`docs/specs/header/type0.md`).
- Type-1-specific fields (`docs/specs/header/type1.md`).
- Header-kind dispatch (`docs/specs/config/space.md`).
- BAR decode and sizing (`docs/specs/bar.md`).
- Capability-list traversal and cycle handling (`docs/specs/capabilities/list.md`).
- Interrupt routing / MSI / MSI-X programming (`docs/specs/interrupts/*.md`).
- Multifunction enumeration policy (`docs/specs/topology/enumerate.md`).

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness.

Rules:

- `CommonHeader` is `extern struct` with native integer fields.
- `Command` and `Status` are `packed struct(u16)` and bit-cast directly from a native-endian `u16` read.
- No `zstdx.layout.Le(uN)` wrapper is required in the wire layout.

## Wire layout `[std]`

```zig
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
};

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
```

Beyond the first 16 bytes, the rest of the common header (`0x10..=0x3F`) overlaps the type-0 and type-1 layouts. The following common offsets are exposed by `View` but not modeled as fields of `CommonHeader`:

| Offset | Field | Width |
|---:|---|---:|
| `0x34` | Capabilities pointer | 8 bits |
| `0x3C` | Interrupt line | 8 bits |
| `0x3D` | Interrupt pin | 8 bits |

The capabilities pointer is meaningful only when `Status.capabilities_list` is set; walking the list itself is owned by `docs/specs/capabilities/list.md`.

## Public wire declarations `[std]`

`header.common.register` exposes the absolute byte offsets for every field in
`CommonHeader` plus `capabilities_pointer`, `interrupt_line`, and
`interrupt_pin`; their values are the layout and table offsets above.

```zig
pub const HeaderType = packed struct(u8) {
    layout: u7,
    multifunction: bool,
};
```

`layout` preserves every raw seven-bit layout value. `config.Function` owns
validation and accepts only the type-0 and type-1 values.

## Command register `[std]`

```zig
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
```

Rules:

- `Command` is bit-cast from the `u16` read at offset `0x04`.
- Reserved bits round-trip unchanged on writes performed through `setCommand`.
- Writes to `command` are ordinary config writes; no read-modify-write is hidden inside `setCommand`.

## Status register `[std]`

```zig
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

    /// Mask with every RW1C sticky-error bit set. Passing this to
    /// `clearStatusBits` clears every latched error on one write.
    pub const all_sticky_errors: Status = .{
        .master_data_parity_error = true,
        .signaled_target_abort = true,
        .received_target_abort = true,
        .received_master_abort = true,
        .signaled_system_error = true,
        .detected_parity_error = true,
    };
};
```

Rules:

- `Status` is bit-cast from the `u16` read at offset `0x06`.
- The PCI Status register uses write-1-to-clear (RW1C) semantics for the sticky error/abort bits. The view exposes that through `clearStatusBits(bits: Status)`: writing a `Status` value with the bits to clear set to `true`. RW0 bits in the supplied value are written as `0` and have no effect.
- `clearStatusBits` performs a single 16-bit config write at offset `0x06` and does not perform a read-modify-write.

## BIST register `[std]`

```zig
pub const Bist = packed struct(u8) {
    completion_code: u4,
    _reserved4: u2 = 0,
    start: bool = false,
    capable: bool = false,
};
```

Rules:

- `Bist` is bit-cast from the `u8` read at offset `0x0F`.
- `capable` (bit `[7]`) is RO. When `false`, the register is entirely reserved.
- `start` (bit `[6]`) is RW. Software sets `start = true` to initiate self-test; hardware clears it on completion.
- `completion_code` (bits `[3:0]`) is RO. `0x0` means passed; non-zero is device-specific.
- Reserved bits (`_reserved4`) round-trip unchanged on writes performed through `setBist`.

## `View` `[zpci]`

```zig
pub const View = struct {
    function: config.Function,

    pub fn init(function: config.Function) View;

    pub fn vendorId(self: View) ConfigSpace.Error!core.VendorId;
    pub fn deviceId(self: View) ConfigSpace.Error!core.DeviceId;
    pub fn revisionId(self: View) ConfigSpace.Error!core.RevisionId;
    pub fn classCode(self: View) ConfigSpace.Error!core.ClassCode;

    pub fn command(self: View) ConfigSpace.Error!Command;
    pub fn setCommand(self: View, value: Command) ConfigSpace.Error!void;

    pub fn status(self: View) ConfigSpace.Error!Status;
    pub fn clearStatusBits(self: View, bits: Status) ConfigSpace.Error!void;

    pub fn cacheLineSize(self: View) ConfigSpace.Error!u8;
    pub fn setCacheLineSize(self: View, value: u8) ConfigSpace.Error!void;

    pub fn latencyTimer(self: View) ConfigSpace.Error!u8;
    pub fn setLatencyTimer(self: View, value: u8) ConfigSpace.Error!void;

    pub fn headerTypeByte(self: View) ConfigSpace.Error!u8;
    pub fn isMultifunction(self: View) ConfigSpace.Error!bool;

    pub fn bist(self: View) ConfigSpace.Error!Bist;
    pub fn setBist(self: View, value: Bist) ConfigSpace.Error!void;

    pub fn capabilitiesPointer(self: View) ConfigSpace.Error!u8;

    pub fn interruptLine(self: View) ConfigSpace.Error!u8;
    pub fn setInterruptLine(self: View, value: u8) ConfigSpace.Error!void;

    pub fn interruptPin(self: View) (ConfigSpace.Error || interrupts.Pin.Error)!interrupts.Pin;
};
```

Behavior rules:

- `vendorId`, `deviceId`, `revisionId`, `classCode` delegate to the underlying `config.Function`.
- `command()` reads `0x04` and bit-casts to `Command`.
- `setCommand(value)` bit-casts `value` to `u16` and writes `0x04`.
- `status()` reads `0x06` and bit-casts to `Status`.
- `clearStatusBits(bits)` bit-casts `bits` to `u16` and writes `0x06`.
- `cacheLineSize` / `setCacheLineSize` read/write `0x0C`.
- `latencyTimer` / `setLatencyTimer` read/write `0x0D`.
- `headerTypeByte` reads `0x0E`. `isMultifunction` returns the high bit.
- `bist` / `setBist` read/write `0x0F` and bit-cast to `Bist`.
- `capabilitiesPointer` reads `0x34` and returns the raw `u8`. Validity and traversal are owned by `docs/specs/capabilities/list.md`.
- `interruptLine` / `setInterruptLine` read/write `0x3C`.
- `interruptPin` reads `0x3D` and decodes the raw byte with `interrupts.Pin.from`; malformed values return `error.MalformedField`.

`View` does not validate function presence — `config.Function.validate` is responsible. `View` does not validate header kind — that decision drives the type-0/type-1 dispatch at the `config/space.md` boundary; both kinds reach a valid `header.common.View`.

## Validation behavior

- All reads and writes flow through `config.Function`, which delegates containment, natural-alignment, and width to `ConfigSpace`.
- `View` performs no extra offset arithmetic beyond hard-coded common offsets.
- Reserved bits in `Command` and `Status` are preserved by `setCommand` and ignored by `clearStatusBits` per the PCI spec semantics.
- The view does not interpret vendor id `0xFFFF` as absence; absence is handled by `config.Function.validate`.

## View / borrowing behavior

- `View` is a borrowed value: it stores a `config.Function`.
- `View` is copyable; copies share the same backend through `config.Function`.
- `View` does not allocate, retry, cache, or synchronize.
- Lifetime follows the underlying `ConfigSpace` backend.

## Error behavior

All public read/write methods return `ConfigSpace.Error`. No new error variants are introduced by this spec.

## zstdx usage

Direct usage: none.

## Facade re-export `[zpci]`

`src/header.zig` re-exports `common`, `CommonHeader`, `Command`, `Status`, and `Bist`:

```zig
pub const common = @import("header/common.zig");
pub const CommonHeader = common.CommonHeader;
pub const Command = common.Command;
pub const Status = common.Status;
pub const Bist = common.Bist;
```

Callers reach the view as `pci.header.common.View` and the structs as `pci.header.CommonHeader`, `pci.header.Command`, `pci.header.Status`, `pci.header.Bist`.

## Usage

Enable bus mastering and memory decode:

```zig
const function = try pci.config.Function.validate(config, sbdf);
const view = pci.header.common.View.init(function);

var cmd = try view.command();
cmd.io_space = false;
cmd.memory_space = true;
cmd.bus_master = true;
try view.setCommand(cmd);
```

Clear sticky error bits:

```zig
try view.clearStatusBits(pci.header.Status.all_sticky_errors);
```

Probe the capabilities pointer when the bit is set:

```zig
const status = try view.status();
if (status.capabilities_list) {
    const cap_ptr = try view.capabilitiesPointer();
    _ = cap_ptr; // walking owned by capabilities/list.md
}
```

Read interrupt pin and line:

```zig
const pin = try view.interruptPin();
const line = try view.interruptLine();
_ = pin;
_ = line;
```

## Non-goals

- Interrupt routing, swizzling, or platform interrupt-controller programming.
- Capability-list traversal.
- BAR decode or sizing.
- Header-kind dispatch.
- Multifunction enumeration policy.
- Class-code semantic interpretation (e.g., display vs bridge vs storage).
- BIST sequence orchestration.
- Hidden retries, read-modify-write, or locking.

## Open questions

None owned by this spec.
