# Resource model

Defines the pool taxonomy, per-node requirement records, root-window apertures, per-node assignment records, and the hard eligibility table used by resource assignment. Owns the five-variant `Kind` enum (`io`, `mmio32`, `mmio32_pref`, `mmio64`, `mmio64_pref`), `Aperture`, `RootWindows`, `Source`, `Requirement`, `Assignment`, and the pure `eligiblePools` truth table.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on the five-pool taxonomy, the eligibility truth table, and the shape of `Requirement` / `Aperture` / `RootWindows` / `Assignment`. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/type0.md`
- `docs/specs/header/type1.md`
- `docs/specs/bar.md`
- `docs/specs/resources/assignment.md`
- `docs/specs/resources/programming.md`
- `docs/specs/resources/bridge.md`

## Scope

Owned:

- The closed `Kind` enum naming the five pools (`io`, `mmio32`, `mmio32_pref`, `mmio64`, `mmio64_pref`).
- `EligibleSet` packed set and the `eligiblePools(kind)` pure function.
- `Aperture` (one pool window supplied by the caller) with `contains` / `end` / `isEmpty` helpers.
- `RootWindows` (five apertures) with `get(kind)` lookup.
- `Source` tagged union identifying what a requirement decodes back to (endpoint BAR, endpoint expansion ROM, bridge window).
- `Requirement` (kind, size, alignment, source) plus producer helpers `Requirement.fromBar` and `Requirement.fromExpansionRom`.
- `Assignment` (requirement, pool, base) — the per-node placement record consumed by resource programming.
- Alignment invariants for BAR / expansion-ROM / bridge-window requirements.
- The public constants `bridge_io_alignment` and `bridge_memory_alignment`.

Deferred:

- The assignment algorithm and pool-preference order (`docs/specs/resources/assignment.md`).
- Bridge-window requirement aggregation from children (`docs/specs/resources/bridge.md`).
- Programming commit, deterministic write order, and rollback (`docs/specs/resources/programming.md`).
- Firmware-hint policy or preserve-existing-programming policy. Firmware hints are not carried on `Requirement` in the initial library; promoting them is a spec amendment when a real consumer exists.
- Aperture-overlap detection. Callers own the address-space policy across pools; assignment allocates strictly within one aperture's range.
- Platform aperture discovery (MCFG, ACPI, DT).
- Diagnostic out-parameters.

## Kind `[zpci]`

The five-variant closed enum owned by this spec:

```zig
pub const Kind = enum(u3) {
    io,
    mmio32,
    mmio32_pref,
    mmio64,
    mmio64_pref,
};
```

Rules:

- The enum is closed (no wildcard `_`). Adding a variant is a spec amendment.
- The `u3` backing lets `EligibleSet` pack to a single byte and lets an `[Kind.count]Aperture` array be trivially indexable if a future spec wants one.
- The names match the vocabulary already fixed by `docs/specs/core/errors.md` §`ResourceExhausted`.

## Eligibility `[std] + [zpci]`

`EligibleSet` is the hard-eligibility set — the pools a requirement of a given kind may physically be placed in without violating PCI addressing semantics.

```zig
pub const EligibleSet = packed struct(u5) {
    io: bool = false,
    mmio32: bool = false,
    mmio32_pref: bool = false,
    mmio64: bool = false,
    mmio64_pref: bool = false,

    pub fn has(self: EligibleSet, kind: Kind) bool;
};

pub fn eligiblePools(kind: Kind) EligibleSet;
```

Truth table (this spec is the sole authority):

| `kind` | eligible pools |
|---|---|
| `.io` | `{ io }` |
| `.mmio32` | `{ mmio32 }` |
| `.mmio32_pref` | `{ mmio32_pref, mmio32 }` |
| `.mmio64` | `{ mmio32, mmio64 }` |
| `.mmio64_pref` | `{ mmio64_pref, mmio32_pref, mmio64, mmio32 }` |

Rules:

- `eligiblePools` is a `comptime`-callable pure function; the truth table is the sole source of truth.
- Assignment order — which of the eligible pools the planner attempts first — is owned by `docs/specs/resources/assignment.md`. This spec expresses only physical legality.
- A 32-bit memory requirement (`.mmio32`, `.mmio32_pref`) is never eligible for a 64-bit pool: a 32-bit BAR cannot decode a base ≥ 4 GiB. This is enforced by the table above, not by a runtime check on `base`.
- A prefetchable memory requirement is eligible for both prefetchable and non-prefetchable pools. Loss of the prefetch optimization is a platform performance concern, not a correctness rule.
- An IO requirement is eligible only for the IO pool.
- `.mmio64` and `.mmio64_pref` may fall back into `.mmio32` / `.mmio32_pref` when the caller provides no 64-bit aperture. Assignment records the actual `pool` used on the resulting `Assignment` (§Assignment); the underlying requirement's `kind` is unchanged and drives programming.

## Aperture `[zpci]`

One pool window supplied by the caller.

```zig
pub const Aperture = struct {
    kind: Kind,
    base: u64,
    size: u64,

    /// Canonical empty aperture of the given kind.
    pub fn absent(kind: Kind) Aperture;

    /// Non-empty aperture from `[base, base + size)`.
    pub fn range(kind: Kind, base: u64, size: u64) Aperture;

    pub fn isEmpty(self: Aperture) bool;
    pub fn end(self: Aperture) u64;
    pub fn contains(self: Aperture, base: u64, size: u64) bool;
};
```

Rules:

- `absent(kind)` returns `Aperture{ .kind = kind, .base = 0, .size = 0 }`.
- `range(kind, base, size)` returns `Aperture{ .kind = kind, .base = base, .size = size }`.
- `isEmpty()` returns `true` iff `size == 0`.
- `end()` returns `base + size`. The caller supplies apertures whose `base + size` does not overflow `u64`; a caller-supplied wraparound is a programmer-error precondition, not a typed error.
- `contains(base, size)` returns `true` iff `self.size > 0 and base >= self.base and (base + size) <= self.end() and (base + size) does not overflow u64`. A `size == 0` argument is a programmer error (assignment never asks about a zero-sized placement); `contains` treats it as `true` when `base` is inside the aperture, since a zero-sized point is trivially contained.
- `size == 0` is the canonical "pool absent" state. Assignment reports `ResourceExhausted` when it needs a pool of that kind and every eligible aperture is empty.
- Overlap detection between apertures is not owned by this spec. Two apertures with overlapping `[base, end)` ranges are legal on the input side; assignment never allocates into more than one aperture per requirement, so overlap does not compromise correctness.

## RootWindows `[zpci]`

Five apertures, one per pool, always present as fields.

```zig
pub const RootWindows = struct {
    io: Aperture = .absent(.io),
    mmio32: Aperture = .absent(.mmio32),
    mmio32_pref: Aperture = .absent(.mmio32_pref),
    mmio64: Aperture = .absent(.mmio64),
    mmio64_pref: Aperture = .absent(.mmio64_pref),

    pub fn get(self: RootWindows, kind: Kind) Aperture;
};
```

Rules:

- Each field's `kind` MUST equal the field name. A caller construction that mismatches is a programmer error; `RootWindows` performs no runtime check.
- Missing pools are represented with `Aperture.absent(<kind>)` (or the equivalent `Aperture{ .kind = <name>, .base = 0, .size = 0 }`). There is no optional aperture; `size == 0` is the canonical empty state.
- `get(kind)` returns the field whose `kind` equals the argument. The lookup is a `switch` over five variants and constant-time.
- `RootWindows` is a value type. Every field defaults to `Aperture.absent(<name>)`, so callers with fewer than five apertures MAY use a partial initializer such as `RootWindows{ .mmio32 = .range(.mmio32, base, size) }` and let absent pools default.

## Source `[zpci]`

A `Requirement` carries a `Source` that identifies the config-space object the requirement decodes back to. Programming needs this to know which registers to write; no separate lookup table is required.

```zig
pub const Source = union(enum) {
    endpoint_bar: bar.BarRef,
    endpoint_expansion_rom: config.Function,
    bridge_window: BridgeWindowSource,

    pub const BridgeWindow = enum(u2) { io, memory, prefetchable_memory };

    pub const BridgeWindowSource = struct {
        function: config.Function,
        window: BridgeWindow,
    };
};
```

Rules:

- `endpoint_bar` carries a `bar.BarRef` — already `{ function, index }` per `docs/specs/bar.md`.
- `endpoint_expansion_rom` carries the endpoint's `config.Function`. The register offset is fixed at `0x30` for type-0 and `0x38` for type-1 per `docs/specs/header/type0.md` / `docs/specs/header/type1.md`; programming resolves it from the header kind.
- `bridge_window` carries `{ function, window }`. `window` selects among the three type-1 window register groups (`0x1C..=0x1D+0x30..=0x33` for IO, `0x20..=0x23` for memory, `0x24..=0x27+0x28..=0x2F` for prefetchable memory). 64-bit prefetchable is a variant of `prefetchable_memory`, not a fourth window; programming decides whether to write the upper-32 registers based on the `Assignment.base` and `Requirement.size` fitting into 32 bits.
- `Source` is copyable and value-typed. It borrows the `config.Function` inside; lifetime follows the underlying `ConfigSpace` backend.

## Requirement `[zpci]`

```zig
pub const Requirement = struct {
    kind: Kind,
    size: u64,
    alignment: u64,
    source: Source,

    pub fn fromBar(function: config.Function, entry: bar.Entry) ?Requirement;
    pub fn fromExpansionRom(function: config.Function, size: u32) ?Requirement;

    /// Batch equivalent of `fromBar`: walks `entries` in order and
    /// appends every non-`null` `Requirement` into `out`. Returns the
    /// borrowed prefix. Returns `error.StorageExhausted` when `out.len`
    /// is smaller than the number of Requirements produced (upper bound
    /// `entries.len`).
    pub fn fromBarSlice(
        function: config.Function,
        entries: []const bar.Entry,
        out: []Requirement,
    ) error{StorageExhausted}![]Requirement;
};
```

Rules:

- `kind` names the preferred pool derived from the BAR / ROM / bridge facts. It is not overwritten by fallback placement; `Assignment.pool` records the actual pool used.
- `size` is measured in bytes.
- `alignment` is measured in bytes.
- `source` identifies the config-space object; programming reads it back to decide the write plan.

### `fromBar(function, entry) ?Requirement`

A pure map from `bar.Entry` to `Requirement`:

| `entry.kind` | result |
|---|---|
| `.none` | `null` |
| `.io` with `size == 0` | `null` |
| `.io` with `size > 0` | `.{ .kind = .io, .size, .alignment = size, .source = .{ .endpoint_bar = bar.BarRef.init(function, entry.index) } }` |
| `.memory` with `size == 0` | `null` |
| `.memory` with `width = .bits_32` and not prefetchable | `.{ .kind = .mmio32, ... }` |
| `.memory` with `width = .bits_32` and prefetchable | `.{ .kind = .mmio32_pref, ... }` |
| `.memory` with `width = .bits_64` and not prefetchable | `.{ .kind = .mmio64, ... }` |
| `.memory` with `width = .bits_64` and prefetchable | `.{ .kind = .mmio64_pref, ... }` |

In every non-`null` case: `size = entry.kind.size`, `alignment = size`, `source = .{ .endpoint_bar = bar.BarRef.init(function, entry.index) }`.

Rules:

- Returns `null` for unimplemented BARs (`entry.kind == .none`) and for pathological zero-sized memory/IO BARs (defensive: a spec-compliant sizing probe reports `.none` for unimplemented BARs, not `.memory` / `.io` with size 0).
- Assumes `entry` was produced by `bar.View.size` / `bar.View.sizeAll` on the same `function`. A mismatch is a programmer error, not a typed failure.
- `entry.slot_count` (1 or 2) is not stored on the requirement — the wire encoding follows from `kind` (`.mmio64` / `.mmio64_pref` write two dwords, all other kinds write one). Programming reads it back from `kind`, not from the requirement.

### `fromExpansionRom(function, size) ?Requirement`

A pure map from expansion-ROM sizing to `Requirement`:

- Returns `null` when `size == 0`.
- Returns `.{ .kind = .mmio32, .size = size, .alignment = size, .source = .{ .endpoint_expansion_rom = function } }` otherwise.

Rules:

- Expansion ROM is always non-prefetchable 32-bit memory per the PCI base specification's expansion-ROM base-address register semantics.
- `size` is a `u32` because the ROM base register is 32 bits; the resulting `Requirement.size` is zero-extended to `u64`.
- Producing the ROM `size` is owned by `docs/specs/resources/programming.md`; `fromExpansionRom` is the pure conversion.

### Alignment invariants

Requirement producers state alignment correctly; the model does not normalize.

- **BAR requirements** (`fromBar`): `size` is a power of two and `alignment == size`. This matches the natural-alignment requirement PCI imposes on BARs.
- **Expansion-ROM requirements** (`fromExpansionRom`): `size` is a power of two and `alignment == size`. PCI mandates natural alignment for expansion ROM base.
- **Bridge-window requirements** (owned by `docs/specs/resources/bridge.md`, not this spec): `size >= alignment`, `size % alignment == 0`, and no power-of-two constraint on `size` (bridge base/limit encodes any multiple of the window's granularity). `alignment >= bridge_io_alignment` for IO windows and `alignment >= bridge_memory_alignment` for memory / prefetchable-memory windows; `alignment` may be larger to satisfy the largest child requirement's alignment.

The `Requirement` type does not enforce which invariant applies; producers must state correct values. The two invariants are compatible with one `size`/`alignment` pair — BAR requirements happen to satisfy both because `size == alignment` implies `size % alignment == 0`.

## Assignment `[zpci]`

Per-node placement record consumed by resource programming.

```zig
pub const Assignment = struct {
    requirement: Requirement,
    pool: Kind,
    base: u64,
};
```

Rules:

- `requirement` is the record produced by `fromBar` / `fromExpansionRom` / bridge-window aggregation.
- `pool` records which pool the base was actually allocated from. `pool` MUST satisfy `eligiblePools(requirement.kind).has(pool)`. Assignment enforces this invariant when it constructs an `Assignment`; the model does not re-check.
- `base` is the chosen base address in the pool's aperture range. It satisfies `pool_aperture.contains(base, requirement.size)` and `base % requirement.alignment == 0`.
- `pool` may differ from `requirement.kind` under the fallback rules in §Eligibility. Programming ignores `pool` and drives its behavior from `requirement.kind` (which decides wire encoding) and `requirement.source` (which decides register offsets). `pool` exists for observability and testability — asserting a fallback occurred is one field lookup, not a range comparison against the assignment's aperture.
- `Assignment` is a value type. Its container (a plan or an array shaped by the topology) is owned by `docs/specs/resources/assignment.md`.

## Public constants `[std]`

Bridge-window alignment granularities are named here because the model's alignment invariants cite them.

```zig
pub const bridge_io_alignment: u64 = 0x1000;        // 4 KiB
pub const bridge_memory_alignment: u64 = 0x10_0000; // 1 MiB
```

Rules:

- These are structural PCI facts (base/limit encoding granularity), not encoding policy. `docs/specs/resources/bridge.md` owns the wire encoding.
- `bridge_io_alignment` reflects the 8-bit IO base/limit register's granularity (4 KiB per unit).
- `bridge_memory_alignment` reflects the 16-bit memory base/limit register's granularity (1 MiB per unit); prefetchable-memory windows share the same lower-16-bit encoding.

## Errors

`resources.model` produces no typed errors.

- `fromBar` returns `?Requirement` (`null` for unimplemented / zero-sized).
- `fromExpansionRom` returns `?Requirement` (`null` for `size == 0`).
- `eligiblePools` is pure; it cannot fail.
- `Aperture.contains` / `end` / `isEmpty` and `RootWindows.get` are pure; they cannot fail.

`ResourceExhausted`, `BridgeWindowUnencodable`, and the programming variants are owned by the assignment, bridge-window, and programming specs respectively; `docs/specs/core/errors.md` fixes the vocabulary. No error variant is owned here.

## View / borrowing behavior

- Every type in this spec is a value: `Kind`, `EligibleSet`, `Aperture`, `RootWindows`, `Source`, `Requirement`, `Assignment`.
- `Source` and `Requirement` transitively borrow `config.Function` through `endpoint_bar`, `endpoint_expansion_rom`, and `bridge_window.function`. Lifetime follows the underlying `ConfigSpace` backend.
- The model does not allocate, cache, retry, or synchronize.
- All producers (`fromBar`, `fromExpansionRom`) and all inspectors (`eligiblePools`, `Aperture.contains`, `RootWindows.get`) are `comptime`-callable when their runtime arguments are `comptime`-known.

## zstdx usage

Direct usage: none.

The five-pool taxonomy, alignment discipline, and eligibility table are PCI-domain-specific and do not delegate to zstdx primitives. `Aperture.contains` is a bounded `u64` range check that does not need `zstdx.core.Range`; the model owns its own overflow rule (§Aperture).

## Facade re-export `[zpci]`

`src/resources.zig`:

```zig
pub const model = @import("resources/model.zig");
```

Callers reach the public surface as `zpci.resources.model.Kind`, `zpci.resources.model.Requirement`, `zpci.resources.model.RootWindows`, `zpci.resources.model.Assignment`, `zpci.resources.model.eligiblePools`, etc.

## Usage

Build requirements from a sized-BAR walk:

```zig
const function = try zpci.config.Function.validate(config, sbdf);
const view = zpci.bar.View.init(function, .type0);

var entries: [zpci.header.type0.bar_count]zpci.bar.Entry = undefined;
const sized = try view.sizeAll(entries[0..view.count()]);

var reqs: [zpci.header.type0.bar_count + 1]zpci.resources.model.Requirement = undefined;
var req_count: usize = 0;

for (sized) |entry| {
    if (zpci.resources.model.Requirement.fromBar(function, entry)) |req| {
        reqs[req_count] = req;
        req_count += 1;
    }
}

// Expansion ROM: size the ROM (per docs/specs/resources/programming.md), then:
if (zpci.resources.model.Requirement.fromExpansionRom(function, rom_size)) |req| {
    reqs[req_count] = req;
    req_count += 1;
}
```

Inspect eligibility for a 64-bit prefetchable BAR:

```zig
const elig = zpci.resources.model.eligiblePools(.mmio64_pref);
// elig.mmio64_pref == true
// elig.mmio32_pref == true
// elig.mmio64 == true
// elig.mmio32 == true
// elig.io == false
```

Describe caller-supplied root apertures:

```zig
const windows = zpci.resources.model.RootWindows{
    .io          = .{ .kind = .io,          .base = 0x0000_1000,       .size = 0x0000_F000 },
    .mmio32      = .{ .kind = .mmio32,      .base = 0xC000_0000,       .size = 0x1000_0000 },
    .mmio32_pref = .{ .kind = .mmio32_pref, .base = 0xD000_0000,       .size = 0x1000_0000 },
    .mmio64      = .{ .kind = .mmio64,      .base = 0x0000_0080_0000_0000, .size = 0x0000_0080_0000_0000 },
    .mmio64_pref = .{ .kind = .mmio64_pref, .base = 0,                 .size = 0 }, // absent
};
```

Read back a placement:

```zig
const a: zpci.resources.model.Assignment = plan.assignments[0];
switch (a.requirement.source) {
    .endpoint_bar => |ref| {
        _ = ref.function;
        _ = ref.index;
    },
    .endpoint_expansion_rom => |func| {
        _ = func;
    },
    .bridge_window => |src| {
        _ = src.function;
        _ = src.window;
    },
}

// Assert a specific fallback happened (test discipline):
// try std.testing.expectEqual(zpci.resources.model.Kind.mmio32_pref, a.pool);
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `Requirement.fromBar` | never | never | O(1) | none | pure | none |
| `Requirement.fromExpansionRom` | never | never | O(1) | none | pure | none |
| `eligiblePools` | never | never | O(1) | none | pure | none |
| `Aperture.contains` / `end` / `isEmpty` | never | never | O(1) `u64` range check | none | pure | none |
| `RootWindows.get` | never | never | O(1) five-way switch | none | pure | none |
| `EligibleSet.has` | never | never | O(1) | none | pure | none |

No hidden caching, retry, logging, or diagnostics. Every helper is `comptime`-callable when its runtime arguments are `comptime`-known.

## Non-goals

- The assignment algorithm and pool-preference order (`docs/specs/resources/assignment.md`).
- Bridge-window requirement aggregation from children (`docs/specs/resources/bridge.md`).
- Programming commit, deterministic write order, and rollback (`docs/specs/resources/programming.md`).
- Firmware-hint or preserve-existing-programming policy.
- Aperture-overlap detection.
- Platform aperture discovery (MCFG, ACPI, DT).
- Diagnostic out-parameters.
- Non-power-of-two sizes or non-natural alignments on endpoint BARs or expansion ROMs.
- A `Plan` container type shaped by topology (owned by `resources/assignment.md`).

## Open questions

None owned by this spec.
