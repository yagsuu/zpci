# Extended capability list

Defines the bounded, cycle-safe traversal of the PCI Express **extended capability list** rooted at config offset `0x100` and chained through 32-bit headers whose next-pointer field lives in bits `[31:20]`. Owns `ExtCapability`, `capabilities.extended.Iterator`, and `capabilities.extended.Cursor`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on extended capability-list traversal. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/capabilities/pcie.md`

## Scope

Owned:

- Constants for the extended window (`0x100..=0xFFC`) and the dword-aligned step.
- `ExtCapability` value: id (`u16`), version (`u4`), offset (`u16`).
- `capabilities.extended.Iterator` over one `config.Function`'s extended capability list.
- Termination rules:
  - Head dword at `0x100` of `0xFFFF_FFFF` (function does not implement extended config) or `0x0000_0000` (no extended capabilities) → empty list.
  - Next-offset of `0` → terminator.
- Pointer-range and alignment validation: `0x100 <= p <= 0xFFC` and `p % 4 == 0`.
- Cycle detection via inline `zstdx.bits.BitSet.Static(ext_window_slot_count)` keyed on `(p - 0x100) / 4`.
- `capabilities.extended.Cursor` for typed byte access into a single extended capability's payload inside the extended window.
- Mapping list/cursor failures to `MalformedCapability`.

Deferred:

- Per-capability bit-level decode (AER, ARI, ATS, ACS, PRI, PASID, SR-IOV, DOE, and other extended services) in the initial library.
- Vendor-defined extended-capability semantics.
- Capability dispatch tables or registries.
- Mutating the next-offset chain.
- Caching the traversal across function reads.

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness. Multi-byte cursor reads return native integer values from `ConfigSpace`.

## Public constants

```zig
pub const ext_window_start: u16 = 0x100;
pub const ext_window_end: u16 = 0xFFC;
pub const ext_window_step: u16 = 4;

pub const ext_window_slot_count: usize =
    @intCast(((ext_window_end - ext_window_start) / ext_window_step) + 1); // 960
```

`ext_window_slot_count` is the number of legal node positions in the extended capability window. The list cannot have more nodes than positions; cycle detection therefore needs exactly `ext_window_slot_count` bits of state.

## Extended capability header `[std]`

A 32-bit dword at `p`:

| Bits | Field |
|---:|---|
| `15..0` | `id` |
| `19..16` | `version` |
| `31..20` | `next_offset` (byte offset to the next capability, dword-aligned) |

Rules:

- A `next_offset` of `0` is the terminator.
- A `next_offset` outside `[0x100, 0xFFC]` is `MalformedCapability`.
- A `next_offset % 4 != 0` is `MalformedCapability`.
- A head dword of `0xFFFF_FFFF` indicates the function does not implement extended config. Treated as an empty list.
- A head dword of `0x0000_0000` indicates no extended capabilities. Treated as an empty list.

## Extended capability tag

```zig
pub const Id = enum(u16) {
    // No extended capability ids are named; all ids fall through to the wildcard.
    _,
};

pub const ExtCapability = struct {
    id: u16,
    version: u4,
    offset: u16,

    pub fn idTag(self: ExtCapability) Id;
};
```

Rules:

- `id` is the low 16 bits of the header dword at `offset`.
- `version` is bits `[19:16]` of the header dword.
- `offset` is the start of the extended capability inside the extended window.
- `idTag()` always returns the wildcard `Id` case; callers switch on the raw `id` value.

## Iterator `[zpci]`

```zig
pub const Error = ConfigSpace.Error || error{MalformedCapability};

pub const Iterator = struct {
    function: config.Function,
    head: ?u16,
    visited: zstdx.bits.BitSet.Static(ext_window_slot_count),

    pub fn validate(function: config.Function) Error!Iterator;
    pub fn next(self: *Iterator) Error!?ExtCapability;

    /// Walks the list until the first extended capability with
    /// `id == target`. Returns `null` when the list terminates
    /// without a match.
    pub fn find(self: *Iterator, target: u16) Error!?ExtCapability;
};
```

`validate(function)` behavior:

1. Read the head dword via `function.read32(ext_window_start)`.
2. If the dword is `0xFFFF_FFFF` or `0x0000_0000`, return an iterator whose `head == null`.
3. Otherwise set `head = ext_window_start` (the head dword is itself the first capability header) and start with `visited` empty.

`next(self)` behavior:

1. If `self.head == null`, return `null`.
2. Let `p = self.head.?`.
3. Validate `ext_window_start <= p <= ext_window_end` and `p % ext_window_step == 0`. Otherwise return `error.MalformedCapability`.
4. Compute `slot = (p - ext_window_start) / ext_window_step`.
5. If `visited.isSet(slot)`, return `error.MalformedCapability`.
6. `visited.set(slot)` — cannot error because `slot < ext_window_slot_count` is established by step 3.
7. Read `hdr = function.read32(p)`. `ConfigSpace.Error` propagates directly.
8. Extract:
   - `id: u16 = @truncate(hdr)`
   - `version: u4 = @intCast((hdr >> 16) & 0xF)`
   - `raw_next: u16 = @intCast((hdr >> 20) & 0xFFF)`
9. Set `self.head` to `null` when `raw_next == 0`, otherwise to `raw_next`.
10. Return `ExtCapability{ .id, .version, .offset = p }`.

Termination guarantee:

- `visited` has exactly `ext_window_slot_count` bits.
- Step 6 sets a new slot on every successful yield. After `ext_window_slot_count` successful yields, every legal slot is set, and any further step must either point to a revisited slot (caught at step 5) or an out-of-range/misaligned address (caught at step 3). No separate step counter is necessary.

## Free helpers `[zpci]`

```zig
/// Constructs an `Iterator` and walks it for the first extended
/// capability with `id == target`. Equivalent to:
///
///     var it = try Iterator.validate(function);
///     return it.find(target);
pub fn find(function: config.Function, target: u16) Error!?ExtCapability;
```

## Cursor `[zpci]`

```zig
pub const Cursor = struct {
    function: config.Function,
    base: u16,

    pub fn from(function: config.Function, base: u16) Error!Cursor;

    pub fn read8(self: Cursor, offset: u16) Error!u8;
    pub fn read16(self: Cursor, offset: u16) Error!u16;
    pub fn read32(self: Cursor, offset: u16) Error!u32;

    pub fn write8(self: Cursor, offset: u16, value: u8) Error!void;
    pub fn write16(self: Cursor, offset: u16, value: u16) Error!void;
    pub fn write32(self: Cursor, offset: u16, value: u32) Error!void;
};
```

`from(function, base)` validates that `ext_window_start <= base <= ext_window_end` and `base % ext_window_step == 0`. Otherwise `error.MalformedCapability`.

`read*/write*(offset, ...)` behavior:

1. Compute `absolute: usize = @as(usize, base) + @as(usize, offset)`.
2. Validate `absolute + width <= 0x1000`. Otherwise `error.MalformedCapability`.
3. Validate `absolute % width == 0` for `width != 1`. Otherwise `error.MalformedCapability`.
4. Delegate to `function.readN(@intCast(absolute))` / `function.writeN(@intCast(absolute), value)`.

Notes:

- The cursor does not interpret payload bytes; per-capability specs own that.
- The cursor uses `MalformedCapability` rather than `ConfigSpace.Error.OutOfBounds` for its own range checks.

## Validation behavior

Returns `MalformedCapability` for:

- Subsequent next pointer outside `[ext_window_start, ext_window_end]`.
- Subsequent next pointer not multiple of `ext_window_step`.
- Cycle within one traversal.
- Cursor: base outside extended window or misaligned.
- Cursor: `offset` + width past `0x1000` or misaligned for the requested width.

`ConfigSpace.Error` (`OutOfBounds`, `UnsupportedAccessWidth`, `UnalignedAccess`) propagates only from accessor-side reads/writes.

`Iterator` and `Cursor` never return `AbsentFunction`; presence is owned by `config.Function.validate`.

## Iterator and cursor borrowing

- Both store `config.Function` and small inline state.
- `BitSet.Static(ext_window_slot_count)` on the iterator is 120 bytes.
- No allocation.
- Lifetime follows the underlying `ConfigSpace` backend.

## zstdx usage

Direct:

- `zstdx.bits.BitSet.Static(ext_window_slot_count)` for cycle detection.

Not used:

- `zstdx.bytes.*` (config bytes flow through `ConfigSpace`).
- `zstdx.layout.Le(uN)` (no wire struct introduced here).
- `zstdx.core.Range` (offset math is already `u16`-bounded).
- `zstdx.ranges.RangeSet` / `RangeMap`.

## Facade re-export `[zpci]`

`src/capabilities.zig`:

```zig
pub const extended = @import("capabilities/extended.zig");
```

Callers reach the public surface as `pci.capabilities.extended.Iterator`, `pci.capabilities.extended.Cursor`, `pci.capabilities.extended.ExtCapability`, and `pci.capabilities.extended.Id`.

## Usage

Walk extended capabilities:

```zig
const function = try pci.config.Function.validate(config, sbdf);
var it = try pci.capabilities.extended.Iterator.validate(function);

while (try it.next()) |cap| {
    _ = cap; // initial library does not decode extended payloads
}
```

Cursor read:

```zig
const cur = try pci.capabilities.extended.Cursor.from(function, cap.offset);
const word_at_4 = try cur.read32(4);
_ = word_at_4;
```

Handle malformed list:

```zig
var it = try pci.capabilities.extended.Iterator.validate(function);
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
| `Iterator.validate` | never | one config read | head value validation | none | backend-defined | head |
| `Iterator.next` | never | one config read per node | range / alignment / cycle | none | backend-defined | header dword |
| `Cursor.from` | never | never | base validation | none | backend-defined | none |
| `Cursor.read*` / `write*` | never | one config access | offset + width within `[base, 0x1000)` | written bytes on write success | backend-defined | one access |

## Non-goals

- Decoding AER, ATS, ACS, PRI, PASID, SR-IOV, DOE, or any other extended-capability payload.
- Vendor-defined extended-capability interpretation.
- Capability registry / dispatch tables.
- Diagnostic out-parameters for cycle or range failures.
- Cached traversals.
- Modifying the next-offset chain.

## Open questions

None owned by this spec.
