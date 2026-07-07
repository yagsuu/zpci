# BAR memory accessor

Defines `memory.BarMemory`, the caller-supplied accessor for reads and writes to memory sitting behind a device BAR — MSI-X table storage, PBA storage, or any BAR-mapped region a zpci operation must program. `BarMemory` is not `ConfigSpace`; it is a separate I/O seam.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `BarMemory`, its error set, and its public API. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/bar.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- `BarMemory` accessor type.
- The explicit context-pointer plus vtable shape used by BAR-memory backends.
- 32-bit read and write methods: `read32`, `write32`.
- Accessor length reported through `len()`.
- Validation common to every access: length-relative containment and 32-bit natural alignment.
- Native integer semantics at the public API boundary.
- Lifetime, copying, allocation, waiting, and concurrency contracts for the accessor handle.
- Required behavior for host-testable byte-backed fakes at this boundary.

Deferred:

- BAR decode, prefetchability, 32-vs-64-bit width, and BAR sizing (`docs/specs/bar.md`).
- MSI-X table entry layout and programming order (`docs/specs/interrupts/msix.md`).
- Physical-to-virtual mapping, page-table setup, cache-attribute policy, and unmapping (caller-owned).
- Access widths other than 32-bit. MSI-X table entries and PBA words are strictly dword-aligned dword accesses. Wider or narrower access widths are a spec amendment when a concrete consumer needs them.

## Accessor model `[zpci]`

`BarMemory` is a borrowed handle to backend-owned storage. It stores an opaque backend context pointer, a pointer to a vtable of width-specific operations, and the byte length of the accessible region.

```zig
pub const BarMemory = struct {
    context: *anyopaque,
    vtable: *const VTable,
    len_bytes: usize,

    pub const Error = error{
        BarMemoryOutOfBounds,
        UnalignedAccess,
    };

    pub const VTable = struct {
        read32: *const fn (context: *anyopaque, offset: usize) Error!u32,
        write32: *const fn (context: *anyopaque, offset: usize, value: u32) Error!void,
    };

    pub fn init(context: *anyopaque, vtable: *const VTable, len_bytes: usize) BarMemory;

    pub fn len(self: BarMemory) usize;

    pub fn read32(self: BarMemory, offset: usize) Error!u32;
    pub fn write32(self: BarMemory, offset: usize, value: u32) Error!void;
};
```

Backends may expose convenience constructors (`FakeBarMemory.accessor()`, a firmware-produced UEFI-mapping wrapper, a VMM device-model wrapper). Those constructors return this `BarMemory` value.

## One read/write surface `[zpci]`

The initial accessor is read/write. A backend that cannot implement writes is not a complete `BarMemory` backend.

Reasons:

- MSI-X table programming needs writes.
- MSI-X table decode and read-back validation need reads.

A future read-only surface requires a spec amendment with a concrete consumer and an exact composition rule with `BarMemory`.

## Access widths and alignment

Supported public operation widths are exactly 4 bytes.

Natural alignment is required:

| Operation | Width | Alignment rule |
|---|---:|---|
| `read32`, `write32` | 4 | `offset % 4 == 0` |

Unaligned requests return `error.UnalignedAccess` after containment succeeds.

## Length-relative containment

Every public method validates containment inside `[0, len_bytes)` before invoking backend-specific I/O.

Required validation:

```text
offset + width <= len_bytes
```

Overflow while computing `offset + width` is `error.BarMemoryOutOfBounds`.

Validation order:

1. containment against `len_bytes`;
2. natural width alignment;
3. backend-specific I/O.

An access such as `read32(len_bytes - 3)` returns `error.BarMemoryOutOfBounds`, not `error.UnalignedAccess`, because the requested four-byte window overruns the region.

## Endian boundary

Public read methods return native-endian integer values. Public write methods accept native-endian integer values.

The accessor boundary is responsible for making little-endian BAR-memory storage appear as native integers to zpci callers.

Backend rules:

- Byte-backed fakes use `zstdx.bytes.load` and `zstdx.bytes.store` with `zstdx.layout.Le(u32)` for the dword payloads.
- MMIO-backed producers perform volatile 32-bit loads and stores; endianness follows the platform's MMIO conventions.
- Consumers of `BarMemory` see native `u32` values; they never see raw little-endian bytes.

## Error set

```zig
pub const Error = error{
    BarMemoryOutOfBounds,
    UnalignedAccess,
};
```

Variant semantics:

- `BarMemoryOutOfBounds` — the requested byte window is not contained inside `[0, len_bytes)`, or offset arithmetic overflowed.
- `UnalignedAccess` — the requested 4-byte access is not naturally aligned.

`BarMemory` does not return `OutOfBounds` or `UnsupportedAccessWidth`; those live on `ConfigSpace.Error` per `docs/specs/core/errors.md`.

## Backend contract

A vtable function is called only after the `BarMemory` public method has validated containment and alignment. Vtable functions may assume the offset shape is valid for their width.

Backend functions still return `BarMemory.Error` because backend-specific constraints may fail after shape validation (for example, a defensive re-check).

Backend requirements:

- never allocate;
- never sleep or block;
- do not access hidden globals except backend-owned hardware or buffer state explicitly reached through `context`;
- leave byte-backed storage unchanged when a write returns an error;
- preserve ordering and volatility rules required by the backend's platform;
- do not perform MSI-X table policy, PBA policy, or interrupt-programming policy.

## Ownership and lifetime

`BarMemory` borrows backend state. It does not own, unmap, deallocate, or reset that state.

Rules:

- `context` must outlive every `BarMemory` copy and every view or iterator holding it.
- `len_bytes` is fixed at `init` and does not change over the accessor's lifetime.
- Copying `BarMemory` copies the handle only; copies refer to the same backend context.
- Concurrent access uses the backend's contract. This spec adds no locking, atomics, fences, or synchronization.
- A backend may require external synchronization; that requirement is documented by the backend's platform or spec.
- A backend must not retain pointers derived from call arguments beyond the call.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `BarMemory.init` | never | never | O(1) | none | handle copy only | none |
| `BarMemory.len` | never | never | O(1) | none | handle copy only | none |
| `read32` | never | backend-defined non-sleeping I/O | O(1) validation + backend I/O | none | backend-defined | backend-defined |
| `write32` | never | backend-defined non-sleeping I/O | O(1) validation + backend I/O | written BAR-memory state on success | backend-defined | backend-defined |

## Byte-backed fake `[zpci]`

The host-test fake implements the same `BarMemory` contract as hardware-backed accessors.

```zig
pub const FakeBarMemory = struct {
    bytes: []u8,

    pub fn accessor(self: *FakeBarMemory) BarMemory;
};
```

Rules:

- storage is caller-owned bytes;
- `len_bytes` equals `bytes.len`;
- reads use `zstdx.bytes.load(zstdx.layout.Le(u32), bytes, offset)` and writes use `zstdx.bytes.store(zstdx.layout.Le(u32), bytes, offset, value)`;
- `zstdx.bytes.EndOfStream` from a defensive backend re-check maps to `error.BarMemoryOutOfBounds`;
- writes that fail validation or byte-slice containment leave storage unchanged;

## Sparse and responder backends `[zpci]`

The vtable seam supports dispatching, sparse, and responder-side backends without change:

- A VMM emulating MSI-X tables for many devices implements one `BarMemory` per device model. The vtable dispatches directly to the device's table storage.
- A UEFI firmware backend wraps a mapped virtual address and issues volatile 32-bit accesses.
- A host test uses `FakeBarMemory`.

None of these need distinct types at the zpci boundary. Callers consume `BarMemory`.

## Facade re-export `[zpci]`

`src/memory.zig` re-exports `BarMemory`:

```zig
const bar = @import("memory/bar.zig");

pub const BarMemory = bar.BarMemory;
```

`src/zpci.zig` re-exports the `memory` namespace facade. Callers reach the accessor as `zpci.memory.BarMemory` and the fake, when needed by tests, as the fake type exposed by the implementation module through the same facade.

## Usage

Firmware producer (mapped MMIO region):

```zig
const region = try firmware_map_bar_memory(bar4_base, table_bytes, .uncacheable);
defer firmware_unmap(region);

const table = zpci.memory.BarMemory.init(
    @ptrCast(region.context),
    &firmware_bar_memory_vtable,
    region.len,
);
```

Host test using the byte-backed fake:

```zig
var backing: [16]u8 = std.mem.zeroes([16]u8);
var fake = zpci.memory.FakeBarMemory{ .bytes = &backing };
const table = fake.accessor();

try table.write32(0x0, 0xFEE0_0000);
try table.write32(0x4, 0x0000_0000);
try table.write32(0x8, 0x0000_0021);
try table.write32(0xC, 0x0000_0000);

try std.testing.expectEqual(@as(u32, 0xFEE0_0000), try table.read32(0));
try std.testing.expectEqual(@as(u32, 0x0000_0021), try table.read32(8));
```

Rejection cases:

```zig
_ = table.read32(backing.len) catch |err| switch (err) {
    error.BarMemoryOutOfBounds => {},
    else => unreachable,
};

_ = table.read32(1) catch |err| switch (err) {
    error.UnalignedAccess => {},
    else => unreachable,
};
```

## Non-goals

- Mapping, unmapping, pinning, or changing cache attributes of BAR memory.
- Physical-to-virtual translation.
- Any width other than 32 bits.
- BAR decode, sizing, or prefetch policy.
- MSI-X table or PBA layout, ordering, and programming policy.
- Diagnostic out-parameters. Failures are reported through typed errors only.
- A `BarMemory.AnyError` union.

## Open questions

None owned by this spec.
