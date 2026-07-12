# Config function view

Defines `config.Function`, the borrowed per-function view over one PCI configuration-space function. It owns function presence validation, header-kind dispatch, common identifier reads, and convenience reads/writes scoped to one `core.Sbdf`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on the `Function` type, function-window constants, presence validation, and header-kind dispatch. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/bdf.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/ecam.md`
- `docs/specs/config/pio.md`
- `docs/specs/header/common.md`
- `docs/specs/header/type0.md`
- `docs/specs/header/type1.md`
- `docs/specs/topology/enumerate.md`

## Scope

Owned:

- `function_window_size` constant for the PCIe 4 KiB function configuration window.
- Fixed common config offsets needed before header specs are available.
- `HeaderKind` dispatch enum for type-0 endpoint and type-1 bridge headers.
- `Function` borrowed view (`ConfigSpace` + `core.Sbdf`).
- Presence validation via Vendor ID at offset `0x00`.
- Header-kind validation via Header Type at offset `0x0E`.
- Common identifier reads: Vendor ID, Device ID, Revision ID, Class Code.
- Width-specific convenience reads and writes scoped to one function.
- `AbsentFunction` and `BadHeaderType` mapping at the function-validation boundary.

Deferred:

- Config-space backend representation and raw read/write validation (`docs/specs/config/accessor.md`).
- ECAM aperture descriptors, bus-range containment, and address calculation (`docs/specs/config/ecam.md`).
- PIO port mechanics and segment policy (`docs/specs/config/pio.md`).
- Common-header bitfields, command/status decoding, and register-level programming helpers (`docs/specs/header/common.md`).
- Type-0 and type-1 header field views (`docs/specs/header/type0.md`, `docs/specs/header/type1.md`).
- BAR decode and sizing (`docs/specs/bar.md`).
- Capability traversal and cycle detection (`docs/specs/capabilities/*.md`).
- Multifunction enumeration policy (`docs/specs/topology/enumerate.md`).

## Fixed offsets `[std]`

This spec uses the following PCI configuration-space offsets:

| Offset | Field | Width |
|---:|---|---:|
| `0x00` | Vendor ID | 16 bits |
| `0x02` | Device ID | 16 bits |
| `0x08` | Revision ID | 8 bits |
| `0x09` | Programming Interface | 8 bits |
| `0x0A` | Subclass | 8 bits |
| `0x0B` | Base Class | 8 bits |
| `0x0E` | Header Type | 8 bits |

No `extern struct` is introduced here. Reads go through `ConfigSpace`; multi-byte little-endian conversion is handled at the accessor boundary.

## Public constants and types

```zig
pub const function_window_size: usize = 0x1000;

pub const HeaderKind = enum {
    type0,
    type1,
};
```

`HeaderKind` is the dispatch result after masking the multifunction bit out of the Header Type register. Richer header-type bitfield modeling belongs to `docs/specs/header/common.md`.

## `Function` view `[zpci]`

```zig
pub const Function = struct {
    config: ConfigSpace,
    sbdf: core.Sbdf,

    pub const Error = ConfigSpace.Error || error{
        AbsentFunction,
        BadHeaderType,
    };

    pub fn validate(config: ConfigSpace, sbdf: core.Sbdf) Error!Function;
    pub fn unchecked(config: ConfigSpace, sbdf: core.Sbdf) Function;

    pub fn read8(self: Function, offset: usize) ConfigSpace.Error!u8;
    pub fn read16(self: Function, offset: usize) ConfigSpace.Error!u16;
    pub fn read32(self: Function, offset: usize) ConfigSpace.Error!u32;

    pub fn write8(self: Function, offset: usize, value: u8) ConfigSpace.Error!void;
    pub fn write16(self: Function, offset: usize, value: u16) ConfigSpace.Error!void;
    pub fn write32(self: Function, offset: usize, value: u32) ConfigSpace.Error!void;

    pub fn vendorId(self: Function) ConfigSpace.Error!core.VendorId;
    pub fn deviceId(self: Function) ConfigSpace.Error!core.DeviceId;
    pub fn revisionId(self: Function) ConfigSpace.Error!core.RevisionId;
    pub fn classCode(self: Function) ConfigSpace.Error!core.ClassCode;

    pub fn headerKind(self: Function) Error!HeaderKind;
    pub fn isMultifunction(self: Function) ConfigSpace.Error!bool;
};
```

`Function` is a borrowed view. It does not cache bytes, allocate storage, own hardware state, or perform hidden synchronization.

## Validation and construction discipline

### Constructors

`Function` has exactly two public constructors. Struct-literal construction (`.{ .config = …, .sbdf = … }`) is a programmer error in normal code; the fields remain public so views can compose over `Function` values by reading `config` and `sbdf` directly.

- `Function.validate(config, sbdf)` — establishes the "present + valid header type" invariant. See §Validate below.
- `Function.unchecked(config, sbdf)` — returns `Function{ .config = config, .sbdf = sbdf }` without touching config space. The returned value satisfies **no** presence or header-type invariant. Reserved for:
  - responder-side dispatchers (VMMs emulating PCI devices) that receive a config access keyed by `(Sbdf, offset)` and want a value to route through the same `Function`/View machinery;
  - unit tests that assert on identity or offset arithmetic without opening a config transaction.

### Validate

`Function.validate(config, sbdf)` validates the function address at the config-space semantic level.

Required behavior:

1. Read Vendor ID at offset `0x00` with `config.read16(sbdf, 0x00)`.
2. If the value is `0xFFFF`, return `error.AbsentFunction`.
3. Read Header Type at offset `0x0E` with `config.read8(sbdf, 0x0E)`.
4. Mask off bit 7 before dispatch.
5. Accept masked value `0x00` as `HeaderKind.type0`.
6. Accept masked value `0x01` as `HeaderKind.type1`.
7. Return `error.BadHeaderType` for every other masked value.
8. Return `Function{ .config = config, .sbdf = sbdf }` on success.

Validation does not cache the vendor id or header type. Later reads observe current hardware/backend state.

Presence is checked only by `validate`. The `vendorId()` method reads and returns a `core.VendorId`; it does not translate a later `0xFFFF` read into `AbsentFunction`.

### Invariant scope

A `Function` returned by `validate` satisfies, **at the moment of the call**, `read16(0x00) != 0xFFFF` and `read8(0x0E) & 0x7F ∈ {0x00, 0x01}`.

Rules:

- The invariant is a point-in-time observation. Later reads may observe surprise-removal, hot-unplug, or config-state mutation by another agent. Consumers of `Function` do not treat the invariant as persistent.
- A `Function` produced by `unchecked` satisfies neither invariant.
- Views composed on `Function` (`header.common.View`, `header.type0.View`, `header.type1.View`, `bar.View`, `capabilities.list.Iterator`, `capabilities.extended.Iterator`) accept any `Function` value. They do not re-validate presence or header type; they read live bytes and return whatever the accessor returns.

## Header Type semantics

The Header Type byte is interpreted only far enough to dispatch to an owning header module.

```text
bit 7     multifunction flag
bits 0..6 header layout value
```

Rules:

- `headerKind()` masks bit 7 before comparing the layout value.
- `headerKind()` returns `error.BadHeaderType` when the masked value is not `0x00` or `0x01`.
- `isMultifunction()` returns true when bit 7 is set.
- Multifunction enumeration policy belongs to `docs/specs/topology/enumerate.md`.
- Common-header field modeling belongs to `docs/specs/header/common.md`.

## Common identifier reads

Identifier methods perform direct config reads and wrap the result in the owning core identifier type.

```zig
pub fn vendorId(self: Function) ConfigSpace.Error!core.VendorId {
    return core.VendorId.from(try self.read16(0x00));
}

pub fn deviceId(self: Function) ConfigSpace.Error!core.DeviceId {
    return core.DeviceId.from(try self.read16(0x02));
}

pub fn revisionId(self: Function) ConfigSpace.Error!core.RevisionId {
    return core.RevisionId.from(try self.read8(0x08));
}

pub fn classCode(self: Function) ConfigSpace.Error!core.ClassCode {
    const pif = try self.read8(0x09);
    const sub = try self.read8(0x0A);
    const base = try self.read8(0x0B);
    return core.ClassCode.from(base, sub, pif);
}
```

`ClassCode.from(base, sub, pif)` follows `docs/specs/core/ids.md`: base class first, subclass second, programming-interface third.

These methods do not validate class-code semantics. Class-specific policy belongs to the consuming module.

## Scoped reads and writes

`Function.read*` and `Function.write*` call the stored `ConfigSpace` with the stored `Sbdf`.

Required behavior:

```zig
pub fn read16(self: Function, offset: usize) ConfigSpace.Error!u16 {
    return self.config.read16(self.sbdf, offset);
}
```

Rules:

- `ConfigSpace` owns function-window containment, natural alignment, backend width support, and endian conversion.
- `Function` adds no extra offset validation beyond selecting its `Sbdf`.
- Writes through `Function` are ordinary config-space writes. The owning higher-level spec decides whether a write is allowed in a read path.
- `Function` does not hide BAR sizing, resource programming, MSI/MSI-X programming, or command-register policy.

### Write discipline

`Function.read*` is unrestricted; any caller may read any offset inside the function's 4 KiB window.

`Function.write*` is reserved for the producers listed below. Every other call site is a discipline violation. The most common wrong-shape write — a bare `function.write8(0x18, …)` on a type-0 function targeting what the caller believes is a bridge field — is not asserted at runtime; it is a code-review rule.

Legitimate producers of `Function.write*`:

1. **BAR sizing probe** — `bar.zig` (`docs/specs/bar.md`), inside the save → all-ones → restore sequence and the batch decode-disable variant.
2. **Resource programming commit** — `resources/programming.zig` (`docs/specs/resources/programming.md`).
3. **MSI capability programming** — `interrupts/msi.zig` (`docs/specs/interrupts/msi.md`).
4. **MSI-X capability programming** — `interrupts/msix.zig` (`docs/specs/interrupts/msix.md`).
5. **Typed setter helpers** under `header/common.zig`, `header/type0.zig`, `header/type1.zig`, and the `capabilities/list.zig` / `capabilities/extended.zig` cursors — each of which is itself an owner-policed call site for one field or byte window.
6. **Responder-side dispatchers** (VMMs emulating PCI devices) and byte-backed fakes in tests. A responder writing through its own emulated `ConfigSpace` mutates the responder's own storage, not a real device.

`Function` is not the surface that owns command-register programming policy, BAR base writes, bridge-window programming, or interrupt programming. Those are all owned by the named modules above; `Function.write*` is the primitive they use, not the API they expose.

## Errors

`Function.Error` is:

```zig
ConfigSpace.Error || error{
    AbsentFunction,
    BadHeaderType,
}
```

Variant ownership:

- `OutOfBounds`, `UnsupportedAccessWidth`, `UnalignedAccess` come from `ConfigSpace`.
- `AbsentFunction` is produced by `Function.validate` when Vendor ID is `0xFFFF`.
- `BadHeaderType` is produced by `Function.validate` and `Function.headerKind` when the masked Header Type value is unsupported.

`Function` does not return `MalformedField` for unsupported header kind because `BadHeaderType` is the narrower package-level variant for this validation phase.

## Ownership and lifetime

A `Function` value borrows the backend context through its `ConfigSpace` field.

Rules:

- `Function` is copyable by value.
- Copies refer to the same backend context.
- The backend context must outlive every `Function` value.
- `Function` does not allocate and does not own resources.
- `Function` does not synchronize concurrent accesses.
- Device removal or config-state mutation by the caller/platform can invalidate assumptions made by earlier validation.
- A `Function` produced by `unchecked` satisfies no presence or header-type invariant; views composed on top of it observe live bytes without re-validation.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `validate` | never | backend-defined non-sleeping I/O | two config reads | none | backend-defined | backend-defined |
| `unchecked` | never | never | O(1) | none | handle copy only | none |
| `read*` | never | backend-defined non-sleeping I/O | delegated to `ConfigSpace` | none | backend-defined | backend-defined |
| `write*` | never | backend-defined non-sleeping I/O | delegated to `ConfigSpace` | written config state on success | backend-defined | backend-defined |
| identifier reads | never | backend-defined non-sleeping I/O | delegated to `ConfigSpace` | none | backend-defined | backend-defined |
| `headerKind` / `isMultifunction` | never | backend-defined non-sleeping I/O | delegated to `ConfigSpace` | none | backend-defined | backend-defined |

The view adds no hidden caching, allocation, retry, tracing, logging, locking, or backend selection.

## zstdx usage

`Function` does not directly use zstdx primitives in the initial design.

Reason:

- offset containment and byte access are delegated to `ConfigSpace` and its backends;
- identifier wrapping is owned by zpci `core/ids`;
- header dispatch is a PCI semantic check over one byte.

## Facade re-export `[zpci]`

`src/config.zig` re-exports `Function`:

```zig
const space = @import("config/space.zig");

pub const Function = space.Function;
```

Callers reach it as `pci.config.Function`.

## Usage

Validate a function and read identifiers:

```zig
const function = try pci.config.Function.validate(config, sbdf);

const vendor = try function.vendorId();
const device = try function.deviceId();
const class = try function.classCode();

_ = vendor;
_ = device;
_ = class;
```

Route by header kind:

```zig
switch (try function.headerKind()) {
    .type0 => {
        // docs/specs/header/type0.md owns the endpoint view.
    },
    .type1 => {
        // docs/specs/header/type1.md owns the bridge view.
    },
}
```

Treat absence as a non-error result at enumeration call sites:

```zig
const function = pci.config.Function.validate(config, sbdf) catch |err| switch (err) {
    error.AbsentFunction => return null,
    else => return err,
};
```

Dispatch on a caller-known identity without probing (responder-side / test):

```zig
const function = pci.config.Function.unchecked(config, sbdf);
// no presence or header-type invariant; live reads observe whatever the
// backend returns for this Sbdf, including 0xFFFF for absent functions.
const raw_vendor = try function.read16(0x00);
_ = raw_vendor;
```

Scoped config read/write:

```zig
const command = try function.read16(0x04);
try function.write16(0x04, command | 0x0004);
```

## Non-goals

- A cached config-space snapshot.
- A generic parser over config bytes.
- Header common/type0/type1 typed views.
- Capability traversal.
- BAR decode or sizing.
- Multifunction enumeration policy.
- Device-driver dispatch or binding.
- Resource or interrupt programming policy.
- Hidden retries, locks, allocation, logging, or diagnostics.

## Open questions

None owned by this spec.
