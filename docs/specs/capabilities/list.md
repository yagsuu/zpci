# Capability list

Defines the bounded, cycle-safe traversal of the standard PCI capability list rooted at the common header's capabilities pointer (`0x34`) and chained through each capability's `next` byte within the conventional 256-byte configuration window (`0x00..=0xFF`). Owns `Capability`, `capabilities.list.Iterator`, and a byte-window `capabilities.list.Cursor` used by per-capability specs.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on capability-list traversal. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/common.md`
- `docs/specs/capabilities/extended.md`
- `docs/specs/capabilities/pcie.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- `Capability` value identifying a list node by capability id and offset.
- Packed `Header` wire representation for a standard capability's ID and next-pointer bytes.
- `capabilities.list.Iterator` over one `config.Function`'s standard capability list.
- The `common.Status.capabilities_list` precondition.
- Pointer-range and alignment validation for the next pointer.
- Cycle detection via an inline `zstdx.bits.BitSet.Static(48)` on the iterator.
- Termination when the next pointer is `0` or when validation fails.
- `capabilities.list.Cursor` for typed byte access into a single capability's payload inside the conventional window.
- Mapping list/cursor failures to `MalformedCapability`.
- Standard capability id tags referenced elsewhere in zpci (`pci_express`, `msi`, `msi_x`).

Deferred:

- Extended capability list (`0x100..=0xFFF`) — `docs/specs/capabilities/extended.md`.
- Per-capability payload bit-field decoding — `docs/specs/capabilities/pcie.md`, `docs/specs/interrupts/msi.md`, `docs/specs/interrupts/msix.md`.
- Capability dispatch tables or registries — zpci has no object system; callers switch on `Capability.id`.
- Mutating the next-pointer chain.
- Caching the traversal across function reads.

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness. Multi-byte cursor reads return native integer values from `ConfigSpace`.

## Public constants

```zig
pub const standard = struct {
    pub const head_offset: u8 = 0x34;

    pub const window = struct {
        pub const range = stdx.core.InclusiveRange(u8).of(0x40, 0xFC);
        pub const step: u8 = 4;
        pub const slot_count: usize = 48;
    };
};

/// Byte offsets relative to a standard capability's base.
pub const register = struct {
    pub const id: u8 = 0x00;
    pub const next: u8 = 0x01;
};

/// Wire representation of a standard capability's two-byte header.
pub const Header = packed struct(u16) {
    id: u8,
    next: u8,
};
```

`Header` preserves raw pointer bits; `Iterator` owns next-pointer alignment,
range, and cycle validation.

`standard.window.slot_count` is the number of legal node positions in the
conventional capability window. The capability list cannot have more nodes
than positions; cycle detection therefore needs exactly that many bits of state.

## Capability tag

```zig
pub const Id = enum(u8) {
    pci_express = 0x10,
    msi = 0x05,
    msi_x = 0x11,
    _,
};

pub const Capability = struct {
    id: u8,
    offset: u8,

    pub fn idTag(self: Capability) Id;
};
```

Rules:

- `id` is the raw `u8` at the capability's `0x00` byte.
- `offset` is the start byte of the capability inside the conventional window.
- `idTag()` returns the typed `Id` enum, defaulting to the wildcard `_` for ids zpci does not name here.
- Vendor capabilities (`0x09`) and other non-zpci-owned ids are reported as-is; zpci does not interpret their payloads.

## Iterator `[zpci]`

```zig
pub const Error = ConfigSpace.Error || error{MalformedCapability};

pub const Iterator = struct {
    function: config.Function,
    head: ?u8,
    visited: zstdx.bits.BitSet.Static(cap_window_slot_count),

    pub fn validate(function: config.Function) Error!Iterator;
    pub fn next(self: *Iterator) Error!?Capability;

    /// Walks the list until the first capability with `id == target`.
    /// Returns `null` when the list terminates without a match; returns
    /// `error.MalformedCapability` when validation fails during the walk.
    pub fn find(self: *Iterator, target: Id) Error!?Capability;
};
```

`validate(function)` behavior:

1. Read `common.Status` via `function.read16(0x06)`.
2. If `Status.capabilities_list` is clear, return an iterator whose `head == null`.
3. Otherwise read the byte at `0x34`. Mask off the reserved low two bits per `[std]` and store the result in `head`. A masked value of `0` means "no list" and yields `head == null`.
4. `visited` is empty.

`next(self)` behavior:

1. If `self.head == null`, return `null`.
2. Let `p = self.head.?`.
3. Validate `cap_window_start <= p <= cap_window_end` and `p % cap_window_step == 0`. Otherwise return `error.MalformedCapability`.
4. Compute `slot = (p - cap_window_start) / cap_window_step`.
5. If `visited.isSet(slot)`, return `error.MalformedCapability`.
6. `visited.set(slot)` — this can never error because `slot < cap_window_slot_count` is established by step 3.
7. Read `id = function.read8(p)` and `raw_next = function.read8(p + 1)`. `ConfigSpace.Error` propagates directly.
8. Validate `raw_next & 0b11 == 0`. The two low bits are reserved and must be zero per `[std]`. A nonzero reserved encoding returns `error.MalformedCapability`.
9. Set `self.head` to `null` when `raw_next == 0`, otherwise to `raw_next`.
10. Return `Capability{ .id = id, .offset = p }`.

Termination guarantee:

- `visited` has exactly `cap_window_slot_count` bits.
- Step 6 sets a new slot on every successful yield. After `cap_window_slot_count` successful yields, every legal slot is set, and any further step must either point to a revisited slot (caught at step 5) or an out-of-range/misaligned address (caught at step 3). No separate step counter is necessary.

## Free helpers `[zpci]`

```zig
/// Constructs an `Iterator` and walks it for the first capability with
/// `id == target`. Convenience for callers who do not need the iterator
/// afterward. Equivalent to:
///
///     var it = try Iterator.validate(function);
///     return it.find(target);
pub fn find(function: config.Function, target: Id) Error!?Capability;
```

## Cursor `[zpci]`

```zig
pub const Cursor = struct {
    function: config.Function,
    base: u8,

    pub fn from(function: config.Function, base: u8) Error!Cursor;

    pub fn read8(self: Cursor, offset: u8) Error!u8;
    pub fn read16(self: Cursor, offset: u8) Error!u16;
    pub fn read32(self: Cursor, offset: u8) Error!u32;

    pub fn write8(self: Cursor, offset: u8, value: u8) Error!void;
    pub fn write16(self: Cursor, offset: u8, value: u16) Error!void;
    pub fn write32(self: Cursor, offset: u8, value: u32) Error!void;
};
```

`from(function, base)` validates that `cap_window_start <= base <= cap_window_end` and `base % cap_window_step == 0`. Otherwise `error.MalformedCapability`.

`read*/write*(offset, ...)` behavior:

1. Compute `absolute: usize = @as(usize, base) + @as(usize, offset)`.
2. Validate `absolute + width <= 0x100`. Otherwise `error.MalformedCapability`.
3. Validate `absolute % width == 0` for `width != 1`. Otherwise `error.MalformedCapability`.
4. Delegate to `function.readN(@intCast(absolute))` / `function.writeN(@intCast(absolute), value)`.

Notes:

- The cursor does not interpret payload bytes; per-capability specs own that.
- The cursor uses `MalformedCapability` rather than `ConfigSpace.Error.OutOfBounds` for its own range checks, because the failure observed here is "capability payload window overrun", not "config-space window overrun". A read that does pass cursor validation but fails the underlying `ConfigSpace` check returns `ConfigSpace.Error` directly.

## Validation behavior

Returns `MalformedCapability` for:

- Initial head pointer outside `[cap_window_start, cap_window_end]` (after masking reserved bits) and not `0`.
- Initial head pointer not multiple of `cap_window_step`.
- Subsequent next pointer outside `[cap_window_start, cap_window_end]`.
- Subsequent next pointer not multiple of `cap_window_step`.
- Subsequent next pointer with low two bits set (reserved must be zero).
- Cycle (a node visited twice within one traversal).
- Cursor: base outside conventional window or misaligned.
- Cursor: `offset` + width past `0x100` or misaligned for the requested width.

`ConfigSpace.Error` (`OutOfBounds`, `UnsupportedAccessWidth`, `UnalignedAccess`) propagates only from an accessor whose shape passed pre-validation but which the backend still rejects (e.g. unsupported width).

`Iterator` and `Cursor` never return `AbsentFunction`; presence is owned by `config.Function.validate`.

## Iterator and cursor borrowing

- Both store `config.Function` and small inline state.
- No allocation.
- Copies of an `Iterator` mid-traversal duplicate the visited set.
- Lifetime follows the underlying `ConfigSpace` backend.

## zstdx usage

Direct:

- `zstdx.bits.BitSet.Static(cap_window_slot_count)` for visited tracking on the iterator.

Not used:

- `zstdx.bytes.*` (config bytes flow through `ConfigSpace`).
- `zstdx.layout.Le(uN)` (no wire struct introduced here).
- `zstdx.core.Range` (offset math is already `u8`-bounded).
- `zstdx.ranges.RangeSet` / `RangeMap` (48 bits of state is too small to justify).

## Facade re-export `[zpci]`

`src/capabilities.zig`:

```zig
pub const list = @import("capabilities/list.zig");
```

Callers reach the public surface as `pci.capabilities.list.Iterator`, `pci.capabilities.list.Cursor`, `pci.capabilities.list.Capability`, and `pci.capabilities.list.Id`.

## Usage

Walk capabilities and dispatch by id:

```zig
const function = try pci.config.Function.validate(config, sbdf);
var it = try pci.capabilities.list.Iterator.validate(function);

while (try it.next()) |cap| {
    switch (cap.idTag()) {
        .pci_express => {}, // docs/specs/capabilities/pcie.md
        .msi         => {}, // docs/specs/interrupts/msi.md
        .msi_x       => {}, // docs/specs/interrupts/msix.md
        _            => {}, // ignored or handled by caller
    }
}
```

Read MSI-X Message Control through a cursor:

```zig
const cur = try pci.capabilities.list.Cursor.from(function, msix_cap.offset);
const message_control = try cur.read16(0x02);
_ = message_control;
```

Handle malformed list:

```zig
var it = try pci.capabilities.list.Iterator.validate(function);
while (true) {
    const maybe = it.next() catch |err| switch (err) {
        error.MalformedCapability => break,
        else => return err,
    };
    if (maybe) |_| {
        // process cap
    } else break;
}
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `Iterator.validate` | never | one or two config reads | head pointer validation | none | backend-defined | head then status |
| `Iterator.next` | never | up to two config reads per node | range / alignment / cycle | none | backend-defined | id then next |
| `Cursor.from` | never | never | base validation | none | backend-defined | none |
| `Cursor.read*` / `write*` | never | one config access | offset + width within `[base, 0x100)` | written bytes on write success | backend-defined | one access |

## Non-goals

- Extended capability list.
- Per-capability bit fields.
- Capability registry or dispatch tables.
- Cached traversal results.
- Modifying the next-pointer chain.
- Diagnostic out-parameters for cycle or range failures.

## Open questions

None owned by this spec.
