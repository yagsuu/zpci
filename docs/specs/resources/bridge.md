# Resource bridge

Defines the two pure operations on PCI-to-PCI bridge forwarding windows: **window aggregation** (`aggregateWindows`, children's `Requirement`s → up to three bridge-window `Requirement`s) and **window encoding** (`encodeWindow`, a bridge-window `Requirement` + its `Assignment` → wire values ready for programming). Owns the `EncodedWindow` union naming the four wire-encoding variants (IO, memory, prefetchable 32-bit, prefetchable 64-bit) and the encodability check that surfaces `BridgeWindowUnencodable`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on bridge-window aggregation math, the `EncodedWindow` variant shape, and the base-driven 32-bit vs 64-bit prefetchable encoding choice. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/space.md`
- `docs/specs/header/type1.md`
- `docs/specs/resources/model.md`
- `docs/specs/resources/assignment.md`
- `docs/specs/resources/programming.md`
- `docs/specs/topology/bridge.md`

## Scope

Owned:

- `aggregateWindows(bridge_function, children, out) AggregateError![]const Requirement` — produces up to three bridge-window `Requirement`s from a child requirement list.
- `encodeWindow(assignment) Error!EncodedWindow` — decodes one bridge-window `Assignment` into wire values.
- `EncodedWindow` union with four variants: `io`, `memory`, `prefetchable_memory_32`, `prefetchable_memory_64`.
- The four per-variant encoding structs and their field semantics.
- Aggregation kind mapping — how child `Kind`s combine into the aggregated `Requirement.kind`.
- Aggregation sizing math — descending-alignment greedy pack + final size-alignment to the window's granularity.
- Aggregation slot order — fixed IO / memory / prefetchable-memory output ordering.
- Encoding-time selection between 32-bit and 64-bit prefetchable variants (base-driven).
- Encodability failure surface — `BridgeWindowUnencodable`.

Deferred:

- Assignment algorithm (pool preference, placement search) — `docs/specs/resources/assignment.md`.
- Config-space writes and their ordering — `docs/specs/resources/programming.md`.
- Bridge sizing probe — bridges have no sizing probe; base/limit is programmed directly.
- Reading current programmed bridge windows — `docs/specs/topology/bridge.md` §`windowStateOf`.
- Bus-number aggregation (secondary/subordinate) — `docs/specs/resources/bus.md`.
- Bridge-control bit programming.
- Prefetchable BAR promotion or classification — owned by `docs/specs/resources/model.md` §Kind and §Requirement.
- Bridge capability probing (32-bit IO window support, etc.) — no consumer currently needs this.
- Rollback within `encodeWindow` — `encodeWindow` is pure over inputs and cannot partially fail.
- Diagnostic out-parameters for aggregation or encoding failures.
- Allocator-backed constructor.

## Layering `[zpci]`

`resources/bridge.md` provides the two pure operations that surround assignment:

- **Aggregation runs before assignment.** Children's endpoint requirements plus recursive bridge requirements roll up into the current bridge's window requirements. The output feeds the assignment planner.
- **Encoding runs after assignment.** The chosen `base` for a bridge-window `Requirement` is combined with its `alignment` and `size` to produce the wire values a programming commit will write.

Both operations MUST run without I/O. Both are pure over their inputs and produce deterministic outputs.

Layering constraints from `docs/specs/architecture.md`:

- `resources/` imports `core/`, `config/`, `header/`, and `bar`. This spec imports `resources/model.zig` for `Requirement`, `Assignment`, `Kind`, and `Source`; `config/` for `config.Function`; `core/` implicitly via `model`.
- `resources/` MUST NOT import `topology/` or `interrupts/` or `memory/`. Callers (a future `resources/assignment.md` orchestrator, or ad-hoc consumer code) compose this module with `topology/tree` externally.
- `resources/bridge` MUST NOT write config space. `encodeWindow` returns wire values; `programming` writes them.

## Public surface `[zpci]`

```zig
const model = @import("model.zig");

pub const Requirement = model.Requirement;
pub const Assignment = model.Assignment;
pub const Kind = model.Kind;
pub const Source = model.Source;

pub const Error = error{BridgeWindowUnencodable};
pub const AggregateError = error{StorageExhausted};
pub const AllErrors = Error || AggregateError;

pub const EncodedWindow = union(enum) {
    io: IoEncoding,
    memory: MemoryEncoding,
    prefetchable_memory_32: Prefetchable32Encoding,
    prefetchable_memory_64: Prefetchable64Encoding,

    pub const IoEncoding = struct {
        /// Value for config-space offset `0x1C`.
        /// Low nibble `[3:0]` = type (`0x0` = 16-bit, `0x1` = 32-bit);
        /// high nibble `[7:4]` = base bits `[15:12]`.
        base_lo: u8,
        /// Value for config-space offset `0x1D`.
        /// Same encoding as `base_lo` for the limit.
        limit_lo: u8,
        /// Value for config-space offset `0x30`.
        /// Base bits `[31:16]`. Zero when `is_32bit == false`.
        base_upper: u16,
        /// Value for config-space offset `0x32`.
        /// Limit bits `[31:16]`. Zero when `is_32bit == false`.
        limit_upper: u16,
        /// True when the low-nibble encoding is `0x1` and the upper-16
        /// registers carry the high half of the address.
        is_32bit: bool,
    };

    pub const MemoryEncoding = struct {
        /// Value for config-space offset `0x20`.
        /// Bits `[15:4]` = base bits `[31:20]`; bits `[3:0]` = 0.
        base: u16,
        /// Value for config-space offset `0x22`.
        /// Bits `[15:4]` = limit bits `[31:20]`; bits `[3:0]` = 0.
        limit: u16,
    };

    pub const Prefetchable32Encoding = struct {
        /// Value for config-space offset `0x24`.
        /// Bits `[15:4]` = base bits `[31:20]`; bits `[3:0]` = `0x0` (32-bit).
        base_lo: u16,
        /// Value for config-space offset `0x26`.
        /// Bits `[15:4]` = limit bits `[31:20]`; bits `[3:0]` = `0x0`.
        limit_lo: u16,
    };

    pub const Prefetchable64Encoding = struct {
        /// Value for config-space offset `0x24`.
        /// Bits `[15:4]` = base bits `[31:20]`; bits `[3:0]` = `0x1` (64-bit).
        base_lo: u16,
        /// Value for config-space offset `0x26`.
        /// Bits `[15:4]` = limit bits `[31:20]`; bits `[3:0]` = `0x1`.
        limit_lo: u16,
        /// Value for config-space offset `0x28`. Base bits `[63:32]`.
        base_upper: u32,
        /// Value for config-space offset `0x2C`. Limit bits `[63:32]`.
        limit_upper: u32,
    };
};

pub fn aggregateWindows(
    bridge_function: config.Function,
    children: []const Requirement,
    out: []Requirement,
) AggregateError![]const Requirement;

pub fn encodeWindow(assignment: Assignment) Error!EncodedWindow;
```

Rules:

- `Requirement`, `Assignment`, `Kind`, and `Source` are re-exports from `docs/specs/resources/model.md`. They are not owned by this spec; they appear here so callers reach the full bridge surface through one namespace.
- `EncodedWindow` and the four encoding structs are semantic types, not `extern struct`s. Fields carry decoded wire values that `resources/programming.md` writes verbatim to the offsets named in each doc comment.
- Every method MUST NOT allocate, retry, log, synchronize, or perform I/O. Both are pure functions of their value inputs.
- Both methods are deterministic. Same inputs MUST produce byte-identical outputs.

## `aggregateWindows` `[zpci]`

```zig
pub fn aggregateWindows(
    bridge_function: config.Function,
    children: []const Requirement,
    out: []Requirement,
) AggregateError![]const Requirement;
```

Behavior:

1. Partition `children` into three buckets by `kind` (§Kind mapping).
2. For each non-empty bucket, compute the aggregated `Requirement` per §Sizing math.
3. Write the aggregated `Requirement`s into `out` in the fixed slot order (§Slot order): IO first, memory second, prefetchable memory third. Empty buckets contribute no output slot.
4. If more aggregated `Requirement`s would be produced than `out.len` accepts, return `error.StorageExhausted` with `out` unmodified.
5. Return `out[0..count]`.

Rules:

- `aggregateWindows` MUST NOT perform I/O. `bridge_function` is captured in the output `Source.BridgeWindowSource.function`; it is not read.
- `aggregateWindows` MUST NOT allocate.
- `aggregateWindows` MUST be deterministic: same `children` slice (order-sensitive; see §Sizing math) produces byte-identical `out` prefix.
- The output slice borrows `out`; callers MUST keep `out` live for the returned slice's lifetime.
- `out.len < 3` is a legal input; the operation MUST return `error.StorageExhausted` only when the actual number of non-empty buckets exceeds `out.len`.
- Zero-size `children` entries (any child with `size == 0`) MUST be skipped. Model.md-compliant producers never emit such entries; the skip is defensive.

### Kind mapping `[zpci]`

Children partition into buckets by `Kind`:

| Child `Kind` | Bucket |
|---|---|
| `.io` | IO |
| `.mmio32` | Memory |
| `.mmio64` | Memory |
| `.mmio32_pref` | Prefetchable |
| `.mmio64_pref` | Prefetchable |

Aggregated `Requirement.kind` per bucket:

| Bucket | Contents | Aggregated `kind` |
|---|---|---|
| IO | any `.io` | `.io` |
| Memory | any `.mmio32` or `.mmio64` | `.mmio32` |
| Prefetchable | any `.mmio32_pref` child | `.mmio32_pref` |
| Prefetchable | only `.mmio64_pref` children (no `.mmio32_pref`) | `.mmio64_pref` |

Rationale:

- Non-prefetchable memory always aggregates to `.mmio32` because the type-1 memory window register (`0x20`/`0x22`) is 32-bit-only per PCIe. Child endpoint BARs handle their own 32/64-bit encoding independently of the bridge memory window's addressing width.
- Prefetchable memory stays `.mmio32_pref` when any child is `.mmio32_pref`, because a 32-bit prefetchable BAR cannot decode a base ≥ 4 GiB and would be stranded if the aggregate promoted above that threshold. Promotion to `.mmio64_pref` requires every prefetchable child to be `.mmio64_pref`. Assignment (`docs/specs/resources/assignment.md`) picks the pool; encoding (§`encodeWindow`) selects the 32-bit or 64-bit wire encoding from the resulting `Assignment.base`.
- IO and memory buckets are independent; a bridge MAY produce an IO window with no memory window and vice versa.

### Sizing math `[zpci]`

For each non-empty bucket, compute the aggregated `Requirement.size` and `Requirement.alignment`:

```
min_alignment := (if bucket == IO) bridge_io_alignment else bridge_memory_alignment
alignment    := max(min_alignment, max(child.alignment for child in bucket))

cursor := 0
for child in bucket sorted by descending child.alignment (ties by descending child.size):
    cursor := align_up(cursor, child.alignment)
    cursor := cursor + child.size

size := align_up(cursor, alignment)
```

Rules:

- The final size MUST satisfy `size >= alignment`, `size % alignment == 0`, and `size >= sum(child.size for child in bucket)`. These are the invariants `docs/specs/resources/model.md` §Alignment invariants requires for bridge-window `Requirement`s.
- The `min_alignment` reflects the bridge base/limit encoding's granularity: IO base/limit is 4 KiB (`bridge_io_alignment` = `0x1000`); memory and prefetchable-memory base/limit are 1 MiB (`bridge_memory_alignment` = `0x10_0000`). Constants are defined in `docs/specs/resources/model.md` §Public constants.
- **Descending-alignment sort** minimizes internal fragmentation: placing larger-alignment children first eliminates the need to pad after them.
- **Ties broken by descending size** guarantees deterministic packing when two children share the same alignment.
- The sort is stable within the bucket; `children` order determines tie-breaking beyond size.
- `align_up(x, a) = (x + a - 1) & ~(a - 1)`. Overflow of the intermediate sum is bounded by `u64` addressability; a single bucket exceeding `2^63` bytes is a pathological input and is treated as a `Requirement.size` overflow (not owned by this spec; producer responsibility).
- The aggregated `Requirement.source` MUST be `.{ .bridge_window = .{ .function = bridge_function, .window = <IO | memory | prefetchable_memory> } }`.

### Slot order `[zpci]`

The output slice orders non-empty buckets:

| Slot | Bucket | Present when |
|---|---|---|
| 0 | IO | any child in IO bucket |
| 1 | Memory | any child in Memory bucket |
| 2 | Prefetchable | any child in Prefetchable bucket |

Rules:

- `out[0]` is the IO requirement iff the IO bucket is non-empty.
- `out[0]` is the Memory requirement iff the IO bucket is empty and the Memory bucket is non-empty; otherwise the Memory requirement is at `out[1]`.
- Similar rule for Prefetchable — it slots after any non-empty preceding bucket.
- The returned slice length equals the count of non-empty buckets: 0, 1, 2, or 3.
- Programming (`docs/specs/resources/programming.md`) MUST NOT depend on slot indices; it reads `Requirement.source.bridge_window.window` to dispatch.

## `encodeWindow` `[zpci]`

```zig
pub fn encodeWindow(assignment: Assignment) Error!EncodedWindow;
```

Behavior:

1. Let `requirement = assignment.requirement`.
2. Assert `requirement.source == .bridge_window` (programmer error to call on any other source).
3. Assert `assignment.base % requirement.alignment == 0` (assignment guarantees this per `docs/specs/resources/model.md` §Assignment; `encodeWindow` verifies).
4. Compute `end := assignment.base + requirement.size - 1` (inclusive). Verify no `u64` overflow; on overflow, return `error.BridgeWindowUnencodable`.
5. Dispatch on `requirement.source.bridge_window.window`:
   - `.io` → §IO encoding.
   - `.memory` → §Memory encoding.
   - `.prefetchable_memory` → §Prefetchable encoding.

Rules:

- `encodeWindow` MUST NOT perform I/O. `assignment.pool` MAY be inspected but MUST NOT alter the wire encoding beyond what §Prefetchable encoding specifies.
- `encodeWindow` MUST NOT allocate.
- `encodeWindow` MUST be deterministic; same `assignment` produces byte-identical `EncodedWindow`.
- `encodeWindow` MUST NOT probe bridge capabilities. Whether the target bridge supports 32-bit IO or 64-bit prefetchable is decided by the wire encoding written; readback-mismatch detection is owned by `docs/specs/resources/programming.md`.

### IO encoding `[std]`

Given `base := assignment.base`, `end := base + requirement.size - 1`:

1. Verify `base <= 0xFFFF_FFFF` and `end <= 0xFFFF_FFFF`. Otherwise `error.BridgeWindowUnencodable`.
2. Verify `base % bridge_io_alignment == 0` and `(end + 1) % bridge_io_alignment == 0`. Otherwise `error.BridgeWindowUnencodable` (structural violation; aggregation should have guaranteed this).
3. Choose the wire variant:
   - `is_32bit := end > 0xFFFF`.
4. Compute the fields:
   - `base_lo := (@as(u8, @truncate(base >> 8)) & 0xF0) | (if (is_32bit) 0x1 else 0x0)`.
   - `limit_lo := (@as(u8, @truncate(end >> 8)) & 0xF0) | (if (is_32bit) 0x1 else 0x0)`.
   - `base_upper := if (is_32bit) @truncate(base >> 16) else 0`.
   - `limit_upper := if (is_32bit) @truncate(end >> 16) else 0`.
5. Return `EncodedWindow{ .io = .{ .base_lo, .limit_lo, .base_upper, .limit_upper, .is_32bit } }`.

Rules:

- Bridges that do not support 32-bit IO windows MUST reject the write at programming time via `ProgrammingReadbackMismatch`; `encodeWindow` does not probe. Rationale: base-driven selection is deterministic and pure; capability discovery would require a config read that would break `encodeWindow`'s purity.
- The high nibble of `base_lo` / `limit_lo` (`[7:4]`) carries base/limit bits `[15:12]`. The low nibble (`[3:0]`) carries the type. The 4 KiB granularity of `bridge_io_alignment` guarantees bits `[11:0]` of `base` are zero and bits `[11:0]` of `end` are `0xFFF`, so no low-nibble collision occurs.

### Memory encoding `[std]`

Given `base := assignment.base`, `end := base + requirement.size - 1`:

1. Verify `base <= 0xFFFF_FFFF` and `end <= 0xFFFF_FFFF`. Otherwise `error.BridgeWindowUnencodable`. The type-1 memory window register is 32-bit-only per PCIe.
2. Verify `base % bridge_memory_alignment == 0` and `(end + 1) % bridge_memory_alignment == 0`. Otherwise `error.BridgeWindowUnencodable`.
3. Compute the fields:
   - `base := @as(u16, @truncate(base >> 16)) & 0xFFF0`.
   - `limit := @as(u16, @truncate(end >> 16)) & 0xFFF0`.
4. Return `EncodedWindow{ .memory = .{ .base, .limit } }`.

Rules:

- Bits `[3:0]` of both `base` and `limit` MUST be zero on the wire. `0xFFF0` mask enforces this. The 1 MiB granularity of `bridge_memory_alignment` guarantees bits `[19:0]` of `base` are zero and bits `[19:0]` of `end` are `0xFFFFF`.
- `base_upper` / `limit_upper` do not exist for the memory window (only for prefetchable). A memory window MUST NOT span address ≥ 4 GiB; this is enforced at step 1.

### Prefetchable encoding `[std]`

Given `base := assignment.base`, `end := base + requirement.size - 1`:

1. Verify `base % bridge_memory_alignment == 0` and `(end + 1) % bridge_memory_alignment == 0`. Otherwise `error.BridgeWindowUnencodable`.
2. Choose the wire variant by base-driven rule:
   - `is_64bit := end > 0xFFFF_FFFF`.
3. If `is_64bit == false`:
   - Compute `base_lo := (@as(u16, @truncate(base >> 16)) & 0xFFF0) | 0x0`.
   - Compute `limit_lo := (@as(u16, @truncate(end >> 16)) & 0xFFF0) | 0x0`.
   - Return `EncodedWindow{ .prefetchable_memory_32 = .{ .base_lo, .limit_lo } }`.
4. If `is_64bit == true`:
   - Compute `base_lo := (@as(u16, @truncate(base >> 16)) & 0xFFF0) | 0x1`.
   - Compute `limit_lo := (@as(u16, @truncate(end >> 16)) & 0xFFF0) | 0x1`.
   - Compute `base_upper := @as(u32, @truncate(base >> 32))`.
   - Compute `limit_upper := @as(u32, @truncate(end >> 32))`.
   - Return `EncodedWindow{ .prefetchable_memory_64 = .{ .base_lo, .limit_lo, .base_upper, .limit_upper } }`.

Rules:

- The variant is decided by `end`, not by `assignment.pool`. Rationale: `assignment.pool` records which pool the base came from (per `docs/specs/resources/model.md` §Assignment), but a `.mmio32` fallback pool always yields `end <= 0xFFFF_FFFF`, so the base-driven rule and any pool-driven rule agree in the valid cases. Base-driven is one comparison; pool-driven is a switch.
- Low nibble `0x1` on both `base_lo` and `limit_lo` MUST agree in the 64-bit variant. `topology/bridge` §`windowStateOf` §D3 treats inconsistent low nibbles as 32-bit for read-back; `encodeWindow` never produces an inconsistent encoding.
- Bridges that do not support 64-bit prefetchable addressing MUST reject a 64-bit encoding at programming time via `ProgrammingReadbackMismatch`; `encodeWindow` does not probe.
- The `is_64bit == false` variant MUST NOT write `0x28` / `0x2C`; the encoding struct has no fields for them. `resources/programming.md` reads the variant tag to decide the write set.

## Errors

```zig
pub const Error = error{BridgeWindowUnencodable};
pub const AggregateError = error{StorageExhausted};
pub const AllErrors = Error || AggregateError;
```

Variant sourcing:

- `BridgeWindowUnencodable` — `encodeWindow` observed a base+size combination that overflows the target window's addressable range, an alignment mismatch after the assertion, or an integer overflow. The `zpci.Error` variant is defined by `docs/specs/core/errors.md`.
- `StorageExhausted` — `aggregateWindows` observed more non-empty buckets than `out.len` slots.

Rules:

- Neither function returns `ConfigSpace.Error`; neither performs I/O.
- Programmer errors (wrong `Source` variant, misaligned base, mismatched paired inputs to `encodeWindow`) MUST be enforced by assertion per `docs/specs/config/space.md` §Validation vs assertion. They are not typed errors.
- `encodeWindow` MUST NOT return partial results on error. `EncodedWindow` is returned by value; on error the caller receives only the error.
- `aggregateWindows` on error MUST NOT modify `out`.

## Wire / layout invariants

None owned. Bit-level layouts are owned by `docs/specs/header/type1.md`. The doc comments on each `EncodedWindow` variant field cite the type-1 offset the field maps to; programming (`docs/specs/resources/programming.md`) writes the fields verbatim without re-encoding.

Compile-time size assertions:

```zig
comptime {
    std.debug.assert(@sizeOf(EncodedWindow.IoEncoding) == 8);
    std.debug.assert(@sizeOf(EncodedWindow.MemoryEncoding) == 4);
    std.debug.assert(@sizeOf(EncodedWindow.Prefetchable32Encoding) == 4);
    std.debug.assert(@sizeOf(EncodedWindow.Prefetchable64Encoding) == 12);
}
```

## View / borrowing behavior

- `aggregateWindows` borrows `bridge_function` (embedded by value in each output `Requirement`'s `Source.BridgeWindowSource.function`) and `children` (read-only). Written `Requirement`s in `out` transitively borrow the same `config.Function` (and the `ConfigSpace` handle inside it). Callers MUST keep the accessor and `out` live for the returned slice's lifetime.
- `encodeWindow` is pure over value inputs. Its output does not borrow the input `Requirement` or `Assignment`; every field of `EncodedWindow` is a copied wire value.

## zstdx usage

Direct usage: none. Alignment math (`align_up`, mask-and-shift) is `u64`-bounded and needs no `zstdx.core.Range` wrapper. Sort is a bounded in-place descending-alignment stable sort over the caller-supplied `children` bucket partition.

## Facade re-export `[zpci]`

`src/resources.zig`:

```zig
pub const bridge = @import("resources/bridge.zig");
```

Callers reach the public surface as `zpci.resources.bridge.aggregateWindows`, `zpci.resources.bridge.encodeWindow`, `zpci.resources.bridge.EncodedWindow`, `zpci.resources.bridge.Error`, `zpci.resources.bridge.AggregateError`, and the encoding structs.

## Usage

**Aggregate one bridge's children into window requirements:**

```zig
// A future resources/assignment.md orchestrator walks the tree bottom-up.
// For each bridge node, it collects the descendant requirements and calls:
var out: [3]zpci.resources.model.Requirement = undefined;
const window_reqs = try zpci.resources.bridge.aggregateWindows(
    bridge_node.function,
    descendant_reqs,
    &out,
);
// window_reqs.len is 0, 1, 2, or 3.
```

**Encode a placed bridge-window requirement for programming:**

```zig
// After assignment picks a base for a bridge-window requirement:
const encoded = try zpci.resources.bridge.encodeWindow(asgmt);
switch (encoded) {
    .io => |io| {
        // programming writes:
        //   config.write8(bridge_sbdf, 0x1C, io.base_lo);
        //   config.write8(bridge_sbdf, 0x1D, io.limit_lo);
        //   config.write16(bridge_sbdf, 0x30, io.base_upper);
        //   config.write16(bridge_sbdf, 0x32, io.limit_upper);
        _ = io;
    },
    .memory => |mem| {
        _ = mem;
    },
    .prefetchable_memory_32 => |p32| {
        // No writes to 0x28 / 0x2C for the 32-bit variant.
        _ = p32;
    },
    .prefetchable_memory_64 => |p64| {
        _ = p64;
    },
}
```

**Detect unencodable placement early:**

```zig
const encoded = zpci.resources.bridge.encodeWindow(asgmt) catch |err| switch (err) {
    error.BridgeWindowUnencodable => {
        // Assignment placed the base in a range the target window can't encode
        // (e.g., memory-window base ≥ 4 GiB). Reject the placement.
        return err;
    },
};
_ = encoded;
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `aggregateWindows` | never | never (no I/O) | O(N log K) bucket sort + fixed alignment math | none | pure over inputs | fixed IO / memory / prefetchable slot order |
| `encodeWindow` | never | never | O(1) | none | pure over inputs | none |

Rules:

- Both operations MUST NOT allocate, retry, log, synchronize, or perform I/O.
- Both operations MUST be single-thread-safe: they take value or const-slice inputs and produce fresh outputs. Concurrent calls with disjoint inputs run independently.
- Both operations MUST be deterministic. Same inputs produce byte-identical outputs.

## Required tests (category level)

**Aggregation:**

- `unit:` empty `children` → `out[0..0]`, no error.
- `unit:` one IO child of size 4 KiB, alignment 4 KiB → one IO requirement, `size = 0x1000`, `alignment = 0x1000`, `source.bridge_window.window == .io`.
- `unit:` one non-prefetchable memory child of size 64 KiB → one memory requirement, `size = 0x10_0000` (rounded to bridge granularity), `alignment = 0x10_0000`.
- `unit:` mixed `.mmio32` and `.mmio64` non-prefetchable children → one memory requirement with `kind = .mmio32`.
- `unit:` only `.mmio32_pref` children → one prefetchable requirement with `kind = .mmio32_pref`.
- `unit:` only `.mmio64_pref` children → one prefetchable requirement with `kind = .mmio64_pref`.
- `unit:` mixed `.mmio32_pref` + `.mmio64_pref` children → one prefetchable requirement with `kind = .mmio32_pref` (any 32-bit-prefetchable child forces the 32-bit aggregate).
- `unit:` mixed IO + memory + prefetchable children → three requirements in the fixed slot order.
- `unit:` mixed IO + prefetchable (no non-prefetchable memory) → two requirements at slots 0 and 1.
- `unit:` descending-alignment packing: children with alignments `[4 KiB, 1 MiB, 16 KiB]` → aggregated `size` is smaller than a naive input-order pack would produce.
- `unit:` alignment ≥ bridge granularity: single 512-byte IO child → aggregated `alignment = 0x1000` (bridge IO granularity).
- `unit:` `out.len == 2` with three non-empty buckets → `error.StorageExhausted`, `out` unmodified.
- `unit:` `out.len == 0` with any non-empty bucket → `error.StorageExhausted`, `out` unmodified.
- `unit:` zero-size child entry is skipped (defensive).
- `unit:` deterministic output: two calls with identical `children` produce byte-identical `out` prefix.
- `unit:` `Source.BridgeWindowSource.function` on every output `Requirement` equals the passed-in `bridge_function`.

**Encoding:**

- `unit:` IO 16-bit: `base = 0x2000`, `size = 0x1000` → `IoEncoding{ .base_lo = 0x20, .limit_lo = 0x30, .base_upper = 0, .limit_upper = 0, .is_32bit = false }`.
- `unit:` IO 32-bit: `base = 0x0001_2000`, `size = 0x1000` → `IoEncoding{ .base_lo = 0x21, .limit_lo = 0x31, .base_upper = 0x0001, .limit_upper = 0x0001, .is_32bit = true }`.
- `unit:` IO overflow (`end > 0xFFFF_FFFF`) → `error.BridgeWindowUnencodable`.
- `unit:` IO misaligned base (`base % 0x1000 != 0`) → programmer-error assertion (not typed).
- `unit:` Memory: `base = 0x2000_0000`, `size = 0x0010_0000` → `MemoryEncoding{ .base = 0x2000, .limit = 0x200F }`.
- `unit:` Memory overflow (`end > 0xFFFF_FFFF`) → `error.BridgeWindowUnencodable`.
- `unit:` Prefetchable 32-bit: `base = 0xD000_0000`, `size = 0x1000_0000` → `Prefetchable32Encoding{ .base_lo = 0xD000, .limit_lo = 0xDFF0 }`. Low nibble = `0x0`.
- `unit:` Prefetchable 64-bit: `base = 0x1_0000_0000`, `size = 0x1000_0000` → `Prefetchable64Encoding` with `base_lo` low nibble `0x1`, `limit_lo` low nibble `0x1`, `base_upper = 0x0000_0001`, `limit_upper = 0x0000_0001`.
- `unit:` Prefetchable crossing 4 GiB (`base < 4 GiB, end > 4 GiB`) → `Prefetchable64Encoding` selected.
- `unit:` Prefetchable near-max: `base = 0xFFFF_FFFF_F000_0000`, `size = 0x0010_0000` → `Prefetchable64Encoding` with high-half `base_upper == 0xFFFF_FFFF`, `limit_upper == 0xFFFF_FFFF`.
- `unit:` u64 overflow: `base + size` wraps → `error.BridgeWindowUnencodable`.
- `malformed:` `encodeWindow` on non-bridge-window `Source` (e.g., `endpoint_bar`) → programmer-error assertion.
- `layout:` `IoEncoding` size == 8 bytes; `MemoryEncoding` size == 4 bytes; `Prefetchable32Encoding` size == 4 bytes; `Prefetchable64Encoding` size == 12 bytes.
- `unit:` Deterministic encoding: same `assignment` produces byte-identical `EncodedWindow`.

## Non-goals

- Assignment algorithm (pool preference, placement search): `docs/specs/resources/assignment.md`.
- Config-space writes and their ordering: `docs/specs/resources/programming.md`.
- Reading current programmed bridge windows: `docs/specs/topology/bridge.md`.
- Bridge sizing probe (bridges have no sizing probe analogous to BAR sizing).
- Bus-number aggregation (secondary/subordinate bus numbers).
- Bridge-control bit programming.
- Prefetchable-BAR promotion (`.mmio32_pref` etc.): owned by `docs/specs/resources/model.md` §Kind.
- Probing bridge capabilities (32-bit IO window support, 64-bit prefetchable support): no consumer currently needs this; capability failures surface at programming time via `ProgrammingReadbackMismatch`.
- Rollback within `encodeWindow`: `encodeWindow` is pure and cannot partially fail.
- Diagnostic out-parameters.
- Allocator-backed constructor.

## Open questions

None owned by this spec.
