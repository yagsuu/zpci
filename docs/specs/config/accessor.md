# Config-space accessor

Defines `config.ConfigSpace`, the single public I/O seam for PCI configuration-space reads and writes. The accessor contract covers width-specific operations, 4 KiB function-window containment, access alignment, endian conversion at the accessor boundary, and backend lifetime rules.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on the `ConfigSpace` accessor type, its error set, and its public API. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/core/bdf.md`
- `docs/specs/core/ids.md`
- `docs/specs/config/space.md`
- `docs/specs/config/ecam.md`
- `docs/specs/config/pio.md`
- `docs/specs/bar.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- `ConfigSpace` accessor type.
- The explicit context-pointer plus vtable shape used by config-space backends.
- Width-specific config read methods: `read8`, `read16`, `read32`.
- Width-specific config write methods: `write8`, `write16`, `write32`.
- The accessor-local error set.
- Validation common to every config access: 4 KiB function-window containment and natural width alignment.
- Native integer semantics at the public API boundary.
- Lifetime, copying, allocation, waiting, and concurrency contracts for the accessor handle.
- Required behavior for ECAM, PIO, and byte-backed test implementations at this boundary.
- `TestConfigSpace` byte-backed host-test implementation with single-function and multi-function-dispatch constructors.

Deferred:

- Function presence and header-type validation (`docs/specs/config/space.md`).
- ECAM segment descriptor validation, address calculation from segment base, and ECAM memory-ordering rules (`docs/specs/config/ecam.md`).
- PIO CF8/CFC port mechanics, serialization, and segment policy (`docs/specs/config/pio.md`).
- Header register layout and typed field access (`docs/specs/header/*.md`).
- BAR sizing policy and decode-disable behavior (`docs/specs/bar.md`).
- Capability pointer policy, cycle detection, and per-capability payload validation (`docs/specs/capabilities/*.md`).
- Resource and interrupt programming order, rollback, and post-write read-back policy (`docs/specs/resources/*.md`, `docs/specs/interrupts/*.md`).
- MSI-X table/PBA BAR-memory access. BAR memory is not config space and uses a separate accessor.

## Accessor model `[zpci]`

`ConfigSpace` is a borrowed handle to backend-owned state. It stores an opaque backend context pointer and a pointer to a vtable of width-specific operations.

```zig
pub const ConfigSpace = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        OutOfBounds,
        UnsupportedAccessWidth,
        UnalignedAccess,
    };

    pub const VTable = struct {
        read8: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize) Error!u8,
        read16: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize) Error!u16,
        read32: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize) Error!u32,

        write8: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize, value: u8) Error!void,
        write16: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize, value: u16) Error!void,
        write32: *const fn (context: *anyopaque, sbdf: core.Sbdf, offset: usize, value: u32) Error!void,
    };

    pub fn init(context: *anyopaque, vtable: *const VTable) ConfigSpace {
        return .{ .context = context, .vtable = vtable };
    }

    pub fn read8(self: ConfigSpace, sbdf: core.Sbdf, offset: usize) Error!u8;
    pub fn read16(self: ConfigSpace, sbdf: core.Sbdf, offset: usize) Error!u16;
    pub fn read32(self: ConfigSpace, sbdf: core.Sbdf, offset: usize) Error!u32;

    pub fn write8(self: ConfigSpace, sbdf: core.Sbdf, offset: usize, value: u8) Error!void;
    pub fn write16(self: ConfigSpace, sbdf: core.Sbdf, offset: usize, value: u16) Error!void;
    pub fn write32(self: ConfigSpace, sbdf: core.Sbdf, offset: usize, value: u32) Error!void;
};
```

Backends may expose convenience constructors such as `Ecam.configSpace()` or `TestConfigSpace.configSpace()`, but those constructors return this `ConfigSpace` value. Facades do not wrap, allocate, validate, or select backends.

`ConfigSpace` is the only public function-pointer seam for config-space I/O. Views and iterators store `ConfigSpace` plus an `Sbdf` and walk state; they never store ECAM, PIO, or test-backend-specific pointers directly.

## One read/write surface `[zpci]`

The initial accessor is read/write. A backend that cannot implement writes is not a complete `ConfigSpace` backend.

Reasons:

- BAR sizing needs write-probe-restore access.
- Resource programming needs config writes.
- MSI/MSI-X programming needs config writes.
- A separate read-only accessor adds a second public I/O seam before a concrete zpci consumer needs it.

A future read-only surface requires a spec amendment with a concrete consumer and an exact composition rule with `ConfigSpace`.

## Addressed function

Every operation addresses exactly one PCI function by `core.Sbdf` plus a byte offset inside that function's 4 KiB configuration window.

Rules:

- `sbdf` identifies the segment, bus, device, and function. It does not imply the function is present.
- `offset` is a byte offset inside the addressed function window.
- The accessor does not validate bus-range containment against an ECAM segment; ECAM owns that check.
- The accessor does not interpret vendor id `0xFFFF`; `config/space.md` owns absence handling.

## Access widths and alignment

Supported public operation widths are exactly 1, 2, and 4 bytes.

Natural alignment is required:

| Operation | Width | Alignment rule |
|---|---:|---|
| `read8`, `write8` | 1 | any contained offset |
| `read16`, `write16` | 2 | `offset % 2 == 0` |
| `read32`, `write32` | 4 | `offset % 4 == 0` |

zpci does not synthesize unaligned config accesses from smaller reads or writes. Unaligned requests return `error.UnalignedAccess` after containment succeeds.

A backend that cannot honor an aligned, contained operation's width returns `error.UnsupportedAccessWidth`. Width support is a backend capability failure, not a caller-shape failure.

## Function-window containment

Every public method validates containment inside the 4 KiB PCIe function configuration window before invoking backend-specific I/O.

Required range:

```text
[0x000, 0x1000)
```

Required validation:

```text
offset + width <= 0x1000
```

Overflow while computing `offset + width` is `error.OutOfBounds`.

Validation order:

1. containment in `[0x000, 0x1000)`;
2. natural width alignment;
3. backend width support and backend-specific I/O.

Therefore an access such as `read32(sbdf, 0xFFF)` returns `error.OutOfBounds`, not `error.UnalignedAccess`, because the requested four-byte window overruns the function window.

The implementation may use `zstdx.core.Range(usize)` for this check:

```zig
fn validateAccess(offset: usize, width: usize) ConfigSpace.Error!void {
    const Range = zstdx.core.Range(usize);
    const window = Range{ .start = 0, .end = 0x1000 };
    const access = Range.fromStartLen(offset, width) catch return error.OutOfBounds;

    if (!window.containsRange(access)) return error.OutOfBounds;
    if (width == 2 and offset % 2 != 0) return error.UnalignedAccess;
    if (width == 4 and offset % 4 != 0) return error.UnalignedAccess;
}
```

`width` is fixed by the public method. Passing any width other than 1, 2, or 4 to an internal helper is a programmer error.

## Endian boundary

Public read methods return native-endian integer values. Public write methods accept native-endian integer values.

The accessor boundary is responsible for making PCI config-space little-endian storage appear as native integers to zpci callers.

Backend rules:

- Byte-backed test implementations use `zstdx.bytes.load` and `zstdx.bytes.store` with `zstdx.layout.Le(u16)` or `zstdx.layout.Le(u32)` for multi-byte values.
- ECAM and PIO specs own their hardware load/store details, but they expose the same native-integer behavior through `ConfigSpace`.
- Header, BAR, capability, resource, and interrupt modules consume native integers or typed wire/storage wrappers through their owning specs; they do not perform raw backend I/O.

## Error set

```zig
pub const Error = error{
    OutOfBounds,
    UnsupportedAccessWidth,
    UnalignedAccess,
};
```

Variant semantics:

- `OutOfBounds` — the requested byte window is not contained inside the 4 KiB function configuration window, or offset arithmetic overflowed.
- `UnsupportedAccessWidth` — the backend cannot honor an otherwise valid 1-, 2-, or 4-byte access at the requested location.
- `UnalignedAccess` — the requested 2- or 4-byte access is not naturally aligned.

The accessor does not return `AbsentFunction`; vendor id `0xFFFF` is a successful `read16` result at offset `0x00`. `config/space.md` owns presence validation.

The accessor does not return `MalformedField`, `MalformedCapability`, `MalformedBar`, `StorageExhausted`, or `BarMemoryOutOfBounds`. Those variants are produced by the domain that interprets the bytes or storage surface.

## Backend contract

A vtable function is called only after the `ConfigSpace` public method has validated containment and alignment. Vtable functions may assume the offset shape is valid for their width.

Backend functions still return `ConfigSpace.Error` because backend-specific width support or low-level constraints may fail after shape validation.

Backend requirements:

- never allocate;
- never sleep or block;
- do not access hidden globals except backend-owned hardware or buffer state explicitly reached through `context`;
- leave byte-backed storage unchanged when a write returns an error;
- preserve ordering and volatility rules required by the backend's owning spec;
- do not interpret vendor id `0xFFFF` as an error;
- do not perform BAR sizing, resource programming policy, interrupt policy, or capability traversal.

## Ownership and lifetime

`ConfigSpace` borrows backend state. It does not own, close, unmap, deallocate, or reset that state.

Rules:

- `context` must outlive every `ConfigSpace` copy and every view/iterator holding it.
- Copying `ConfigSpace` copies the handle only; copies refer to the same backend context.
- Concurrent access uses the backend's contract. This spec adds no locking, atomics, fences, or synchronization.
- A backend may require external synchronization; that requirement is documented by the backend spec.
- A backend must not stash pointers to caller stack temporaries during a read/write call unless its owning spec explicitly allows it.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `ConfigSpace.init` | never | never | O(1) | none | handle copy only | none |
| `read8`, `read16`, `read32` | never | backend-defined non-sleeping I/O | O(1) validation + backend I/O | none | backend-defined | backend-defined |
| `write8`, `write16`, `write32` | never | backend-defined non-sleeping I/O | O(1) validation + backend I/O | written config state on success | backend-defined | backend-defined |

The accessor contract itself introduces no hidden allocation, global state, synchronization, or buffering.

## Testing `TestConfigSpace` `[zpci]`

`pci.testing.config.TestConfigSpace` is the canonical host-test backend for `ConfigSpace`. It implements the same accessor contract as hardware-backed accessors while staying out of the production `pci.config` namespace.

```zig
pub const TestConfigSpace = struct {
    pub const Entry = struct {
        sbdf: core.Sbdf,
        bytes: []u8,
    };

    /// Single-function test backend. `bytes.len` must be exactly 4096.
    pub fn initSingle(sbdf: core.Sbdf, bytes: []u8) TestConfigSpace;

    /// Multi-function test backend dispatched by `Sbdf`. Each `entries[i].bytes.len`
    /// must be exactly 4096.
    pub fn init(entries: []Entry) TestConfigSpace;

    pub fn configSpace(self: *TestConfigSpace) ConfigSpace;
};
```

The code block specifies the test backend's API shape, not its internal storage representation.

Callers reach this type as `pci.testing.config.TestConfigSpace`.

Rules:

- storage is caller-owned bytes; `initSingle` takes one 4 KiB slice, `init` takes a slice of `Entry` where each entry carries one 4 KiB slice;
- multi-function dispatch by `Sbdf`: `read*`/`write*` look up `entries[i].sbdf.eql(sbdf)` in slice order; the first match services the access;
- an addressed `Sbdf` with no matching entry returns bytes containing vendor id `0xFFFF` on `read16(sbdf, 0x00)`, `0xFF`-filled bytes on other reads, and drops writes silently — mirrors the sparse/responder-backend rule that absence is signaled through the wire value, not through `error.OutOfBounds`;
- reads and writes use `zstdx.bytes.load`, `zstdx.bytes.store`, `zstdx.layout.Le(u16)`, and `zstdx.layout.Le(u32)` for multi-byte fields;
- `zstdx.bytes.EndOfStream` from a defensive backend re-check maps to `ConfigSpace.Error.OutOfBounds`;
- writes that fail validation or byte-slice containment leave storage unchanged.

## Sparse and responder backends `[zpci]`

The vtable seam supports dispatching and sparse backends without change. Real consumers include:

- ECAM- and PIO-backed producers used by firmware and drivers;
- `pci.testing.config.TestConfigSpace` byte-backed test backends used by host tests;
- **responder-side dispatchers**: VMMs emulating PCI devices, or model-based test scaffolds that answer config transactions per emulated device.

None of these need distinct types at the zpci boundary. Callers consume `ConfigSpace`.

Responder rules:

- A responder implements exactly one `ConfigSpace` per segment (or per set of segments it services). Dispatch by `Sbdf` happens inside the responder's vtable functions.
- A responder that has no device at the addressed `Sbdf` returns Vendor ID `0xFFFF` on `read16(sbdf, 0x00)`. It does **not** return `error.OutOfBounds`. Absence is signaled through the wire value, not through an accessor error, per §Addressed function.
- A responder returns `error.OutOfBounds` only for containment failures inside the 4 KiB function window (already validated by `ConfigSpace`) or for identity-shape failures the accessor spec defines.
- A responder implements writes that mutate its own storage. A `write32` to an emulated device's Command register updates the responder's shadow state; the device model decides what side effect (if any) that mutation triggers.

Sparse and dispatching backends implement the same vtable and never allocate per-function backing storage.

## Facade re-export `[zpci]`

`src/config.zig` re-exports `ConfigSpace`:

```zig
const accessor = @import("config/accessor.zig");

pub const ConfigSpace = accessor.ConfigSpace;
```

Callers reach it as `pci.config.ConfigSpace`.

`TestConfigSpace` is intentionally not re-exported from `src/config.zig`; callers use `pci.testing.config.TestConfigSpace`.

## Usage

Create an accessor from a backend:

```zig
var ecam = try pci.config.Ecam.from(segment);
const config = ecam.configSpace();
```

Read vendor id:

```zig
const raw_vendor = try config.read16(sbdf, 0x00);
const vendor = pci.core.VendorId.from(raw_vendor);
```

Presence is not decided by the accessor:

```zig
if (vendor.isAbsent()) {
    return error.AbsentFunction; // owned by config/space.md
}
```

Read and update command register bits:

```zig
const command = try config.read16(sbdf, 0x04);
try config.write16(sbdf, 0x04, command | 0x0004); // Bus Master Enable
```

Byte-backed test read implementation:

```zig
fn read16(context: *anyopaque, sbdf: pci.core.Sbdf, offset: usize) ConfigSpace.Error!u16 {
    const backend: *TestConfigSpace = @ptrCast(@alignCast(context));
    const bytes = try backend.functionBytes(sbdf);
    return (zstdx.bytes.load(zstdx.layout.Le(u16), bytes, offset) catch return error.OutOfBounds).native();
}
```

## Non-goals

- A generic device, driver, or capability registry.
- A read-only public accessor surface in the initial scope.
- Synthesizing unaligned or unsupported-width accesses from smaller operations.
- Mapping vendor id `0xFFFF` to absence.
- ECAM segment discovery or ACPI MCFG parsing.
- PIO port primitive ownership.
- BAR-memory access for MSI-X tables/PBA.
- Resource, interrupt, bridge-window, or command-register programming policy.
- Hidden locking, retry, caching, tracing, metrics, or allocation.

## Open questions

None owned by this spec.
