# Errors

Defines the package-level `pci.core.Error` set, the type-local error-set policy, and the primitive-to-domain mapping rule used at every module boundary.

Markers: `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/bdf.md`

## Scope

Owned:

- the union of top-level public error categories that surface across multiple domains (`pci.core.Error`),
- the type-local error-set policy every module follows,
- the allocator-error union rule,
- the primitive-to-domain error mapping rule applied at module boundaries.

Deferred:

- per-domain error variant names (owned by each domain spec),
- diagnostic out-parameters (zpci does not define a `Diagnostic` type in the initial library).

## Policy `[zpci]`

- Each type and module owns its local error set. Local error sets are named `Type.Error` or, when the module exposes a single primary type, `Error` at module scope.
- Public APIs expose the narrowest useful error set. A function that can only fail one way does not return a union that suggests otherwise.
- Public APIs do not expose `anyerror`. Orchestration that legitimately fans across domains unions the type-local sets explicitly.
- Primitive errors from zstdx byte/range helpers and zpci identifier parsing are mapped into the owning module's domain error before crossing a public boundary. Raw primitive errors are not part of any public domain surface.
- Allocator failures remain `std.mem.Allocator.Error` and are unioned only by APIs that actually allocate.
- Error variant names describe the violated invariant, not the failing operation.
- Per-domain variants reuse common names already in `pci.core.Error` when their semantics match.

## Package error set `[zpci]`

`pci.core.Error` is the stable union of top-level public error categories used by more than one domain. It is not a replacement for type-local error sets.

```zig
//! Package error categories. Spec: docs/specs/core/errors.md.

pub const Error = error{
    OutOfBounds,
    AbsentFunction,
    BadHeaderType,
    MalformedField,
    MalformedCapability,
    MalformedBar,
    CycleDetected,
    UnsupportedRevision,
    UnsupportedCapability,
    StorageExhausted,
    ResourceExhausted,
    BridgeWindowUnencodable,
    BusRangeExhausted,
    UnsupportedAccessWidth,
    UnalignedAccess,
    InvalidIdentifier,
    InvalidRouting,
    BarMemoryOutOfBounds,
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};
```

Variant semantics:

- `OutOfBounds` — an offset, index, or slice failed a containment check inside an already-validated window.
- `AbsentFunction` — the addressed function returned vendor id `0xFFFF`. This is a typed result, not a malformed-input failure. Domains that need to distinguish absence from error return this variant rather than `MalformedField`.
- `BadHeaderType` — the common header reported a header type that the requested typed view does not match (for example, requesting `header.type1.View` of a type-0 function).
- `MalformedField` — a wire-typed field decoded outside its valid set or with a reserved bit set when the owning spec rejects it. First owner: `docs/specs/capabilities/pcie.md` for PCI Express capability register enum decodes. Additional owners promote a specific field and its invalid-value set through their own spec; the variant name stays generic so future header, capability, or interrupt decoders reuse it without inventing near-duplicates.
- `MalformedCapability` — a capability entry's id/version/length triple does not satisfy the owning spec's validity rules.
- `MalformedBar` — a BAR raw value, decoded width, or sizing read-back violates the owning spec's rules (for example, a 64-bit BAR whose upper-dword slot is itself a BAR header).
- `CycleDetected` — a capability or extended-capability walk encountered a previously-visited pointer; iteration aborts rather than looping.
- `UnsupportedRevision` — a capability or header version is outside the range the consuming module supports.
- `UnsupportedCapability` — a capability id reached a typed decoder that does not understand it, or a domain operation requires a capability the function does not advertise.
- `StorageExhausted` — a caller-supplied scratch slice was too small for the requested operation.
- `ResourceExhausted` — a resource pool (I/O, MMIO32, prefetchable MMIO32, MMIO64, prefetchable MMIO64) had insufficient space for the requested assignment.
- `BridgeWindowUnencodable` — a computed bridge window cannot be encoded into the type-1 base/limit fields (for example, a 64-bit prefetchable window on a bridge that does not support 64-bit prefetch).
- `BusRangeExhausted` — bridge traversal would require a bus number outside the segment's `bus_start..=bus_end` range.
- `UnsupportedAccessWidth` — a config-space read or write requested a width that the active accessor does not honor at the requested offset.
- `UnalignedAccess` — a config-space access violated the alignment rule owned by `docs/specs/config/accessor.md`.
- `InvalidIdentifier` — a `core/ids` constructor rejected input bytes.
- `InvalidRouting` — caller-supplied MSI or MSI-X routing inputs (message address, message data, vector identity) failed validation owned by the interrupt specs.
- `BarMemoryOutOfBounds` — an MSI-X table or PBA access fell outside the bounds exposed by the caller's `BarMemory` accessor.
- `ProgrammingReadbackMismatch` — **[safe: rolled back]** a deterministic programming step observed a post-write readback whose value does not match what was written, per the readback rule owned by `docs/specs/resources/programming.md`.
- `ProgrammingWriteFailed` — **[safe: rolled back]** a deterministic programming step's config write returned an accessor error mid-commit before any rollback logic ran.
- `ProgrammingPartial` — **[inconsistent]** rollback after a `ProgrammingReadbackMismatch` or `ProgrammingWriteFailed` itself observed a failed write; hardware is neither in the pre-commit state nor the requested post-commit state.

`pci.core.Error` does not include `std.mem.Allocator.Error`. Allocating APIs expose allocator errors explicitly in their return type.

## Type-local error sets `[zpci]`

Type-local sets stay narrow and name only the variants the operation can actually produce. They are subsets of `pci.core.Error` plus, where allowed, allocator errors.

Examples:

```zig
pub const Function = struct {
    pub const Error = error{
        OutOfBounds,
        AbsentFunction,
        BadHeaderType,
        UnsupportedAccessWidth,
        UnalignedAccess,
    };
};

pub const bar = struct {
    pub const Error = error{
        OutOfBounds,
        MalformedBar,
        UnsupportedAccessWidth,
        UnalignedAccess,
    };
};
```

Type-local sets:

- live next to the type or module that exposes them,
- name only variants the owning operation can produce,
- reuse the variant names from `pci.core.Error` when the semantics match,
- never introduce a new variant whose semantics are already covered by a `pci.core.Error` member.

## Allocating APIs `[zpci]`

zpci's read, decode, sizing, capability traversal, assignment-planning, and programming paths are non-allocating. They take caller scratch where storage is required.

When an API must allocate, it unions `std.mem.Allocator.Error` at the point of allocation:

```zig
pub fn intoAlloc(
    self: Enumerator,
    allocator: std.mem.Allocator,
) (Enumerator.Error || std.mem.Allocator.Error)!Tree;
```

Rules:

- `std.mem.Allocator.Error` is not folded into `pci.core.Error`.
- A type that exposes both scratch and allocator constructors uses distinct functions (`intoScratch`, `intoAlloc`) rather than a boolean mode parameter.
- Error paths do not allocate.

## Mapping rule `[zpci]`

A primitive failure maps into the owning module's domain error at the module boundary. The same primitive failure may map to different domain variants depending on which validation phase observed it.

| Source | Domain variant when crossing the boundary |
|---|---|
| `zstdx.bytes` `EndOfStream` raised by config byte-buffer access | `OutOfBounds` |
| `zstdx.bytes` `EndOfStream` raised by BAR-memory access | `BarMemoryOutOfBounds` |
| `zstdx.bytes` `EndOfStream` raised by capability byte-slice access | `MalformedCapability` |
| `zstdx.core.Range` `Overflow` or `OutOfBounds` raised by config offset validation | `OutOfBounds` |
| `zstdx.core.Range` `Overflow` or `OutOfBounds` raised by capability walk pointer check | `MalformedCapability` |
| `zstdx.core.Range` `Overflow` or `OutOfBounds` raised by bridge bus-range check | `BusRangeExhausted` |
| `zstdx.core.Range` `Overflow` or `OutOfBounds` raised by topology scratch slice | `StorageExhausted` |
| `zstdx.core.Range` `InvalidRange` raised by malformed external range input | the owning phase's malformed-input variant |
| `core/ids` identifier-constructor error | `InvalidIdentifier` or the type-local identifier error |
| `core/bdf` BDF construction with out-of-range device/function | `InvalidIdentifier` |
| accessor-internal width/alignment violation surfaced through `ConfigSpace` | `UnsupportedAccessWidth` or `UnalignedAccess` |

Mapping rules:

- The owning module performs the mapping; primitive errors do not escape unmapped.
- The choice of domain variant is decided by which validation phase observed the failure, not by the primitive that produced it.
- A mapping that would collapse two distinguishable failures into one variant is rejected; promote one of them to its own `pci.core.Error` member through a spec amendment.

## Facade re-export `[zpci]`

`src/core.zig` re-exports the package error set:

```zig
const errors = @import("core/errors.zig");

pub const Error = errors.Error;
```

`src/pci.zig` re-exports it through the `core` namespace facade (`pci.core.Error`). Public APIs continue to expose their type-local error sets in their return types; `pci.core.Error` is a convenience for callers that need a uniform top-level union.

## Source

```zig
//! Package error categories. Spec: docs/specs/core/errors.md.

pub const Error = error{
    OutOfBounds,
    AbsentFunction,
    BadHeaderType,
    MalformedField,
    MalformedCapability,
    MalformedBar,
    CycleDetected,
    UnsupportedRevision,
    UnsupportedCapability,
    StorageExhausted,
    ResourceExhausted,
    BridgeWindowUnencodable,
    BusRangeExhausted,
    UnsupportedAccessWidth,
    UnalignedAccess,
    InvalidIdentifier,
    InvalidRouting,
    BarMemoryOutOfBounds,
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};
```

Lives in `src/core/errors.zig`.

## Non-goals

- A `Diagnostic` out-parameter API. zpci reports failures through typed errors only in the initial library.
- A `pci.AnyError` superset of allocator + package errors. Callers union explicitly at the call site.
- An error variant per failing operation. Variants name violated invariants; operations are identified by the function that returned the error.

## Open questions

- The exact write order and rollback rules that produce `ProgrammingReadbackMismatch`, `ProgrammingWriteFailed`, and `ProgrammingPartial` are owned by `docs/specs/resources/programming.md`.
