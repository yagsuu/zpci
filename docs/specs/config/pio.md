# PIO config access

Defines `config.Pio`, the x86 legacy PCI Configuration Mechanism #1 backend for `config.ConfigSpace`. PIO owns CF8/CFC address/data sequencing, conventional 256-byte config-window containment, segment-zero policy, and the serialization contract around the shared CF8 address latch. It consumes the x86_64 port-I/O primitive owned by `zstdx`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `Pio` and PIO-backed config-space behavior. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/bdf.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/config/ecam.md`

External dependency:

- `zstdx` `docs/specs/arch/x86_64.md` owns `stdx.arch.x86_64.Port`.

## Scope

Owned:

- `Pio` backend implementing the full read/write `ConfigSpace` surface.
- PCI Configuration Mechanism #1 CF8 address construction.
- CFC data-port selection.
- Read/write access for 8-, 16-, and 32-bit config widths.
- Conventional 256-byte config-window containment.
- Segment-zero policy for legacy PIO.
- Required serialization contract for CF8/CFC address/data pairs.
- Mapping PIO-specific containment failures into `ConfigSpace.Error`.

Deferred:

- The x86_64 port-I/O primitive itself, port instruction selection, target gating, and inline assembly (`zstdx` `docs/specs/arch/x86_64.md`).
- Firmware/platform policy for choosing PIO instead of ECAM.
- ECAM-vs-PIO fallback or selection logic.
- Function presence and header validation (`docs/specs/config/space.md`).
- Header, BAR, capability, resource, and interrupt programming policy.
- Non-x86_64 config mechanisms.

## Port dependency

`config.Pio` uses `stdx.arch.x86_64.Port`. zpci does not own a port-address type, port-I/O wrapper, or inline assembly.

Required `Port` surface (defined by `zstdx`):

```zig
stdx.arch.x86_64.Port.fromInt(value: u16) Port
Port.raw() u16

Port.in8() u8
Port.in16() u16
Port.in32() u32

Port.out8(value: u8) void
Port.out16(value: u16) void
Port.out32(value: u32) void
```

Target gating, supported-target predicate, and inline-asm semantics are owned by the `zstdx` spec.

## Public constants

```zig
pub const config_address_port = stdx.arch.x86_64.Port.fromInt(0xCF8);
pub const config_data_port_base = stdx.arch.x86_64.Port.fromInt(0xCFC);
pub const pio_config_window_size: usize = 0x100;
pub const supported_segment = core.SegmentId.from(0);
```

Rules:

- PIO supports only segment `0`.
- PIO supports only conventional PCI config offsets `0x00..=0xFF`.
- PCIe extended config offsets `0x100..=0xFFF` are not addressable through Configuration Mechanism #1.
- The CF8 and CFC port numbers are fixed by Configuration Mechanism #1.

## `Pio` backend `[zpci]`

```zig
pub const Pio = struct {
    pub fn init() Pio;
    pub fn configSpace(self: *Pio) ConfigSpace;
};
```

Rules:

- `Pio` is zero-sized; instances exist only as a stable context pointer for `ConfigSpace`.
- `Pio.init()` is infallible. It does not probe hardware.
- `configSpace()` returns a borrowed `ConfigSpace` handle whose context pointer refers to the `Pio` instance.
- `Pio` does not allocate, hold a lock, cache CF8 state, or own platform policy.
- Compiling code that calls `Pio` read/write paths requires an x86_64 target, because the underlying `stdx.arch.x86_64.Port` methods compile-error on other targets.

## Read/write surface

`Pio` implements the full `ConfigSpace` surface:

```zig
read8
read16
read32
write8
write16
write32
```

Rules:

- A PIO backend that cannot write is not a complete `ConfigSpace` implementation.
- `read8` / `write8` use 8-bit CFC data-port access.
- `read16` / `write16` use 16-bit CFC data-port access.
- `read32` / `write32` use 32-bit CFC data-port access.
- Byte/word accesses are not synthesized through a 32-bit read-modify-write sequence.
- `ConfigSpace` owns generic 4 KiB containment and natural-alignment checks.
- `Pio` adds the narrower 256-byte conventional-window check.

## Segment policy

PCI Configuration Mechanism #1 has no segment field.

Rules:

- `Pio` accepts only `sbdf.segment == supported_segment`.
- Any other segment returns `error.OutOfBounds`.
- `Pio` does not remap segment ids.
- `Pio` does not use caller-supplied segment descriptors.
- Multi-segment systems use ECAM or platform-specific mechanisms outside this spec.

## PIO window containment

PIO validates that the requested access is contained inside `[0x00, 0x100)`.

Required check:

```text
offset + width <= 0x100
```

Overflow while computing `offset + width` is `error.OutOfBounds`.

Rules:

- `read32(0xFC)` is valid.
- `read8(0xFF)` is valid.
- `read8(0x100)` returns `error.OutOfBounds` from PIO.
- `read16(0xFF)` is rejected as `error.UnalignedAccess` by `ConfigSpace` before PIO runs.
- `read32(0xFE)` is rejected as `error.UnalignedAccess` by `ConfigSpace` before PIO runs.

## CF8 address format `[std]`

PCI Configuration Mechanism #1 uses a 32-bit address written to port `0xCF8`.

```text
bit 31      enable = 1
bits 30..24 reserved = 0
bits 23..16 bus
bits 15..11 device
bits 10..8  function
bits 7..2   register dword number
bits 1..0   0
```

Address construction:

```zig
fn configAddress(bdf: core.Bdf, offset: usize) u32 {
    return 0x8000_0000
        | (@as(u32, bdf.bus) << 16)
        | (@as(u32, bdf.device) << 11)
        | (@as(u32, bdf.function) << 8)
        | @as(u32, @intCast(offset & 0xFC));
}
```

Rules:

- The enable bit is always set for a PIO config access.
- Reserved bits `30..24` are zero.
- The register field uses the dword-aligned offset: `offset & 0xFC`.
- The bottom two bits in CF8 are always zero.
- The byte/word lane is selected by the CFC data-port offset, not by CF8 bits `1..0`.

## CFC data-port selection `[std]`

The data port is selected from `0xCFC..=0xCFF` using the low two offset bits.

```zig
fn dataPort(offset: usize) stdx.arch.x86_64.Port {
    return stdx.arch.x86_64.Port.fromInt(config_data_port_base.raw() + @as(u16, @intCast(offset & 0x03)));
}
```

Examples:

| Offset | CF8 register field | Data port |
|---:|---:|---:|
| `0x00` | `0x00` | `0xCFC` |
| `0x01` | `0x00` | `0xCFD` |
| `0x02` | `0x00` | `0xCFE` |
| `0x03` | `0x00` | `0xCFF` |
| `0x04` | `0x04` | `0xCFC` |

Natural alignment from `ConfigSpace` ensures 16-bit accesses use ports `0xCFC` or `0xCFE`, and 32-bit accesses use port `0xCFC`.

## Read/write sequence

Read sequence:

```zig
config_address_port.out32(configAddress(sbdf.bdf, offset));
return dataPort(offset).inN();
```

Write sequence:

```zig
config_address_port.out32(configAddress(sbdf.bdf, offset));
dataPort(offset).outN(value);
```

`inN` and `outN` denote the matching width method on `stdx.arch.x86_64.Port` (`in8`/`in16`/`in32` or `out8`/`out16`/`out32`).

Rules:

- CF8 write and CFC access form one logical config transaction.
- No other CF8/CFC access may interleave between them.
- `Pio` does not cache the selected CF8 address.
- `Pio` writes CF8 before every CFC access.
- `Pio` does not coalesce adjacent config accesses.
- `Pio` does not perform hidden read-modify-write.

## Serialization contract

CF8 is a shared address latch. A CF8 write from another agent between this backend's CF8 write and CFC access corrupts the transaction.

Required contract:

- The CF8 write and CFC read/write must execute inside one serialized critical section with respect to every other CF8/CFC user.
- The caller owns that serialization.
- `Pio` does not create a package-global lock.
- `Pio` does not allocate lock state.
- `stdx.arch.x86_64.Port` methods are bare instruction wrappers and do not serialize against other CF8/CFC users.

## Endian behavior

PCI config space is little-endian. The initial PIO backend is x86_64-only; the supported target is little-endian.

Rules:

- Public `ConfigSpace` values are native-endian.
- `stdx.arch.x86_64.Port.inN` returns native integer values.
- `stdx.arch.x86_64.Port.outN` accepts native integer values.
- `Pio` does not use `zstdx.bytes.load` or `zstdx.bytes.store`.
- `Pio` does not use `zstdx.layout.Le(T)` storage wrappers.

If a future non-little-endian architecture-specific PIO mechanism is promoted, endian conversion belongs to that architecture-specific primitive or backend spec.

## Error behavior

PIO vtable functions return `ConfigSpace.Error`.

| Failure | Error |
|---|---|
| `sbdf.segment != supported_segment` | `error.OutOfBounds` |
| `offset + width > 0x100` | `error.OutOfBounds` |
| offset arithmetic overflow | `error.OutOfBounds` |
| backend cannot honor a validated width | `error.UnsupportedAccessWidth` |
| defensive detection of misalignment | `error.UnalignedAccess` |

In normal calls through `ConfigSpace`, generic function-window containment and natural alignment have already been validated before the PIO vtable function runs.

A conforming x86_64 PIO backend supports the public widths 1, 2, and 4. It should not return `UnsupportedAccessWidth` for those validated widths.

PIO does not return `AbsentFunction`; Vendor ID `0xFFFF` is a successful `read16` result at offset `0x00` and is interpreted by `config.Function`.

## Lifetime and concurrency

`Pio` is a zero-sized backend context.

Rules:

- `Pio` itself must outlive every `ConfigSpace` handle produced by `configSpace()`.
- `Pio` borrows nothing and owns nothing.
- The caller owns CF8/CFC serialization against other CF8/CFC users (`docs/specs/config/pio.md` §Serialization contract).
- The caller/platform owns ensuring PIO access is legal on the current machine.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `Pio.init` | never | never | none | none | none | none |
| `Pio.configSpace` | never | never | none | handle borrows `Pio` | none | none |
| PIO `read*` | never | port I/O only | O(1) segment/window check | none | caller-serialized CF8/CFC required | CF8 then CFC |
| PIO `write*` | never | port I/O only | O(1) segment/window check | config state on success | caller-serialized CF8/CFC required | CF8 then CFC |

## zstdx usage

Direct usage:

- `stdx.arch.x86_64.Port` for CF8/CFC port addresses and port instruction execution.

Not used by `Pio`:

- `zstdx.bytes.load` / `zstdx.bytes.store`.
- `zstdx.layout.Le(T)`.
- `zstdx.addr.VirtAddr` or `zstdx.addr.PhysAddr`.
- `zstdx.ranges.RangeSet` / `RangeMap`.

## Facade re-export `[zpci]`

`src/config.zig` re-exports `Pio`:

```zig
const pio = @import("config/pio.zig");

pub const Pio = pio.Pio;
```

Callers reach it as `zpci.config.Pio`.

## Usage

Create PIO-backed config access on x86_64:

```zig
var pio = zpci.config.Pio.init();
const config = pio.configSpace();
```

Validate a function on segment 0:

```zig
const sbdf = zpci.core.Sbdf.from(
    zpci.core.SegmentId.from(0),
    zpci.core.Bdf.from(0, 1, 0),
);

const function = try zpci.config.Function.validate(config, sbdf);
const vendor = try function.vendorId();
_ = vendor;
```

Conventional-window access:

```zig
const last_dword = try config.read32(sbdf, 0xFC);
const last_byte = try config.read8(sbdf, 0xFF);
_ = last_dword;
_ = last_byte;
```

Extended config space is not reachable through PIO:

```zig
_ = config.read8(sbdf, 0x100) catch |err| switch (err) {
    error.OutOfBounds => return,
    else => return err,
};
```

Nonzero segments are not reachable through PIO:

```zig
_ = config.read16(nonzero_segment_sbdf, 0x00) catch |err| switch (err) {
    error.OutOfBounds => return,
    else => return err,
};
```

## Non-goals

- ECAM fallback or discovery.
- ACPI/firmware policy for whether PIO is allowed.
- Segment support beyond segment 0.
- PCIe extended configuration space.
- A hidden global CF8/CFC lock.
- Port-I/O inline assembly details.
- Non-x86_64 port mechanisms.
- Function/header/BAR/capability/resource/interrupt policy.
- Hidden retries, allocation, tracing, or metrics.

## Open questions

None owned by this spec.
