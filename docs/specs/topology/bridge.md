# Topology bridge

Defines the read-only inspection surface for PCI-to-PCI bridges in a built `tree.Tree`. Owns two semantic decoders (`busRangeOf`, `windowStateOf`) and one topology-walk helper (`pathTo`), plus the semantic record types `BusRange`, `Window`, `PrefetchableWindow`, and `WindowState`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on bridge bus-range and window-state decoding as consumed by callers of `tree.Tree`. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/type1.md`
- `docs/specs/topology/tree.md`
- `docs/specs/topology/enumerate.md`
- `docs/specs/resources/bridge.md`
- `docs/specs/resources/assignment.md`
- `docs/specs/resources/programming.md`

## Scope

Owned:

- `BusRange` — decoded semantic record for a bridge's three programmed bus-number bytes.
- `Window` — decoded semantic record for one non-prefetchable (IO or memory) bridge window.
- `PrefetchableWindow` — decoded semantic record for the prefetchable memory bridge window, including 64-bit encoding detection.
- `WindowState` — grouped decoded state for all three bridge window kinds.
- `busRangeOf(node)` — reads the three bridge bus-number bytes and returns a `BusRange`.
- `windowStateOf(node)` — reads all bridge window registers and returns a `WindowState`.
- `pathTo(tree, index, scratch)` — walks `parent` links from a node up to a root, writing the ancestor chain root-first into caller scratch.
- The module-level `Error` set unioning `ConfigSpace.Error` with `error{StorageExhausted}`.

Deferred:

- Bridge-window requirement synthesis for assignment (`docs/specs/resources/bridge.md`).
- Wire encoding of base/limit registers for writes (`docs/specs/resources/bridge.md`).
- Bus-number assignment for unprogrammed bridges (`docs/specs/resources/bus.md`).
- Secondary-bus reset orchestration. No approved zpci spec owns this in the initial library.
- `bridge_control` register bit decoding beyond the raw read exposed by `docs/specs/header/type1.md`.
- Hot-plug event detection.
- ARI capability inspection (owned by `docs/specs/capabilities/pcie.md`; consumed by `docs/specs/topology/enumerate.md`).
- Any config-space writes.
- Reverse lookup from `Sbdf` to `NodeIndex` (deferred by `docs/specs/topology/tree.md`).
- Caching decoded state across calls.
- Diagnostic out-parameters.

## Layering `[zpci]`

`topology/bridge.md` is inspection-only. It reads current programmed bridge state from live config space through `tree.Node.function` and returns semantic records. It MUST NOT synthesize new state, program registers, or hold requirement records for assignment.

Layering constraints from `docs/specs/architecture.md`:

- `topology/` MUST NOT import `resources/`. Bridge-window **requirement** records (what a bridge SHOULD forward, computed from child needs) are owned by `docs/specs/resources/bridge.md` and are constructed by the caller composing `topology/bridge` with `resources/bridge` at the callsite.
- `topology/` MUST NOT import `bar` or `capabilities/`. Callers that want BAR or capability inspection compose those modules with `tree.Node.function` directly.
- `topology/bridge` MUST NOT write config space. Every method returns `Error` unioning `ConfigSpace.Error` only for reads.

## Public surface `[zpci]`

```zig
const tree = @import("tree.zig");

pub const BusRange = struct {
    primary: u8,
    secondary: u8,
    subordinate: u8,

    /// True when `secondary == 0` — the bridge's downstream is
    /// not programmed and `topology.enumerate` cannot recurse.
    pub fn isUnprogrammed(self: BusRange) bool;

    /// True when `bus` lies in `[secondary, subordinate]` and the
    /// range is programmed (`secondary != 0`).
    pub fn forwards(self: BusRange, bus: u8) bool;
};

pub const Window = struct {
    /// Inclusive byte base decoded from the bridge window registers.
    base: u64,
    /// Inclusive byte limit decoded from the bridge window registers.
    limit: u64,
    /// True when the bridge has a non-empty forwarding range configured
    /// (equivalently: the decoded base is <= decoded limit).
    enabled: bool,

    /// True when `enabled` and the closed range `[address, address + size - 1]`
    /// lies inside `[base, limit]`. Zero-size ranges return `false`.
    pub fn contains(self: Window, address: u64, size: u64) bool;
};

pub const PrefetchableWindow = struct {
    base: u64,
    limit: u64,
    /// True when both the base and limit low registers advertise 64-bit
    /// prefetchable addressing (low-nibble encoding == 0x1).
    is_64bit: bool,
    enabled: bool,

    /// Same containment rule as `Window.contains`.
    pub fn contains(self: PrefetchableWindow, address: u64, size: u64) bool;
};

pub const WindowState = struct {
    io: Window,
    memory: Window,
    prefetchable_memory: PrefetchableWindow,
};

pub const Error = ConfigSpace.Error || error{StorageExhausted};

pub fn busRangeOf(node: *const tree.Node) ConfigSpace.Error!BusRange;
pub fn windowStateOf(node: *const tree.Node) ConfigSpace.Error!WindowState;
pub fn pathTo(
    t: *const tree.Tree,
    index: tree.NodeIndex,
    scratch: []tree.NodeIndex,
) error{StorageExhausted}![]const tree.NodeIndex;
```

Rules:

- `BusRange`, `Window`, `PrefetchableWindow`, `WindowState` are semantic types, not wire types. They carry decoded values (bus numbers as `u8`, byte addresses as `u64`, `enabled` as `bool`), not raw register bytes.
- `Error` documents the module-level union. Individual functions narrow to a subset (`ConfigSpace.Error` for reads, `error{StorageExhausted}` for `pathTo`).
- Every method MUST NOT allocate, retry, log, synchronize, or cache decoded state.
- Every method is deterministic over a stable `ConfigSpace` snapshot.

## `busRangeOf` `[std]`

```zig
pub fn busRangeOf(node: *const tree.Node) ConfigSpace.Error!BusRange;
```

Behavior:

1. Assert `node.header_kind == .type1` in debug builds. Calling on an endpoint is a programmer error.
2. Read three bytes via `node.function.read8`:
   - `primary   = node.function.read8(0x18)`
   - `secondary = node.function.read8(0x19)`
   - `subordinate = node.function.read8(0x1A)`
3. Return `BusRange{ .primary, .secondary, .subordinate }`.

Rules:

- `busRangeOf` MUST NOT validate the returned values. A bridge with `secondary == 0` is a legitimate "unprogrammed" state that the caller inspects. `topology/enumerate.md` owns the four-part validity rule used during recursion; `busRangeOf` is unconstrained inspection.
- `busRangeOf` MUST propagate `ConfigSpace.Error` from any of the three reads.
- `busRangeOf` performs exactly three 8-bit config reads and no writes.

## `windowStateOf` `[std]`

```zig
pub fn windowStateOf(node: *const tree.Node) ConfigSpace.Error!WindowState;
```

Decodes the three bridge window kinds owned by `docs/specs/header/type1.md` into semantic byte-address records.

Behavior:

1. Assert `node.header_kind == .type1` in debug builds.
2. Read the IO window:
   - `io_base_lo = node.function.read8(0x1C)`.
   - `io_limit_lo = node.function.read8(0x1D)`.
   - `io_base_upper = node.function.read16(0x30)`.
   - `io_limit_upper = node.function.read16(0x32)`.
   - `io.base = (@as(u64, io_base_lo & 0xF0) << 8) | (@as(u64, io_base_upper) << 16)`.
   - `io.limit = (@as(u64, io_limit_lo & 0xF0) << 8) | 0xFFF | (@as(u64, io_limit_upper) << 16)`.
   - `io.enabled = (io_base_lo != 0 or io_limit_lo != 0) and io.base <= io.limit`.
3. Read the memory window:
   - `mem_base = node.function.read16(0x20)`.
   - `mem_limit = node.function.read16(0x22)`.
   - `memory.base = @as(u64, mem_base & 0xFFF0) << 16`.
   - `memory.limit = (@as(u64, mem_limit & 0xFFF0) << 16) | 0x000F_FFFF`.
   - `memory.enabled = mem_base <= mem_limit`.
4. Read the prefetchable memory window:
   - `pref_base_lo = node.function.read16(0x24)`.
   - `pref_limit_lo = node.function.read16(0x26)`.
   - `pref_is_64bit = (pref_base_lo & 0xF) == 0x1 and (pref_limit_lo & 0xF) == 0x1`.
   - If `pref_is_64bit`:
     - `pref_base_upper = node.function.read32(0x28)`.
     - `pref_limit_upper = node.function.read32(0x2C)`.
   - Else:
     - `pref_base_upper = 0`, `pref_limit_upper = 0`; the upper-32 registers MUST NOT be read.
   - `prefetchable_memory.base = (@as(u64, pref_base_lo & 0xFFF0) << 16) | (@as(u64, pref_base_upper) << 32)`.
   - `prefetchable_memory.limit = (@as(u64, pref_limit_lo & 0xFFF0) << 16) | 0x000F_FFFF | (@as(u64, pref_limit_upper) << 32)`.
   - `prefetchable_memory.is_64bit = pref_is_64bit`.
   - `prefetchable_memory.enabled = prefetchable_memory.base <= prefetchable_memory.limit`.
5. Return `WindowState{ .io, .memory, .prefetchable_memory }`.

Rules:

- `windowStateOf` MUST propagate `ConfigSpace.Error` from any read.
- `windowStateOf` performs 8 config reads for a 32-bit-only prefetchable bridge (2 × read8 + 2 × read16 for IO, 2 × read16 for memory, 2 × read16 for prefetchable low) and 10 reads for a 64-bit prefetchable bridge (adds 2 × read32 for prefetchable upper). No writes.
- `windowStateOf` MUST NOT read the prefetchable upper-32 registers when `pref_is_64bit == false`. Bridges without 64-bit prefetchable support MAY implement those offsets as reserved zeroes, so the skip avoids two wasted config accesses.
- `enabled` reflects the PCIe base-spec convention that `base > limit` disables forwarding. IO's `enabled` additionally rejects the "both low registers zero" unprogrammed encoding because a bridge with base == limit == 0 at reset is legitimately disabled, not forwarding `[0x0000, 0x0FFF]`.
- Disabled windows still populate `base` and `limit` from the raw wire values so a caller inspecting a partially-programmed bridge sees the encoded state, not a zeroed record. Callers MUST check `enabled` before treating `base`/`limit` as active forwarding bounds.
- `pref_is_64bit` requires BOTH low registers to advertise the 64-bit encoding. A bridge with `pref_base_lo[3:0] == 0x1` and `pref_limit_lo[3:0] == 0x0` (or vice versa) has an inconsistent wire encoding; `windowStateOf` MUST treat this as `is_64bit = false` and MUST NOT read the upper-32 registers.

## `pathTo` `[zpci]`

```zig
pub fn pathTo(
    t: *const tree.Tree,
    index: tree.NodeIndex,
    scratch: []tree.NodeIndex,
) error{StorageExhausted}![]const tree.NodeIndex;
```

Behavior:

1. Assert `index < t.nodes.len` in debug builds. A caller passing an out-of-bounds index is a programmer error.
2. Walk `parent` links from `index` upward, counting `depth`. Stop when a node's `parent == null` (root reached). `depth` includes both the starting node and the root.
3. If `depth > scratch.len`, return `error.StorageExhausted`. `scratch` MUST NOT be modified.
4. Write the chain into `scratch` root-first: `scratch[0] = <root index>`, `scratch[depth - 1] = index`.
5. Return `scratch[0..depth]`.

Rules:

- `pathTo` MUST NOT perform I/O. It walks in-memory `parent` links only.
- The chain length is bounded by `tree.max_depth`; a `scratch` of at least `tree.max_depth` elements is always sufficient.
- The returned slice borrows `scratch`; callers MUST keep `scratch` live for the returned slice's lifetime.
- `error.StorageExhausted` is the only typed error `pathTo` returns; a decision requiring hardware access would violate the "no I/O" rule and MUST NOT be added to this signature.
- `pathTo` MUST NOT filter by `header_kind`. Callers that want only bridges in the ancestor chain filter at the callsite via `t.node(idx).header_kind == .type1`.

## Errors

`Error` is the type-local module union:

```zig
pub const Error = ConfigSpace.Error || error{StorageExhausted};
```

Expanded: `error{ OutOfBounds, UnsupportedAccessWidth, UnalignedAccess, StorageExhausted }`.

Per-function narrower types:

- `busRangeOf` — `ConfigSpace.Error`.
- `windowStateOf` — `ConfigSpace.Error`.
- `pathTo` — `error{StorageExhausted}`.

Rules:

- `busRangeOf` and `windowStateOf` propagate `ConfigSpace.Error` from any config read. They do not synthesize new error variants and do not translate `ConfigSpace.Error` into any other domain variant.
- `pathTo` returns `error.StorageExhausted` only when the ancestor chain exceeds `scratch.len`. On this error `scratch` MUST NOT be modified.
- Programmer errors — `busRangeOf` / `windowStateOf` on an endpoint node, `pathTo` with `index >= t.nodes.len` — are enforced by assertion per `docs/specs/config/space.md` §Validation vs assertion. They are not typed errors.

## Wire / layout invariants

None owned by this spec. Bit-level layouts are owned by:

- `docs/specs/header/type1.md` — bus-number bytes at `0x18`/`0x19`/`0x1A`; window register groups at `0x1C`/`0x1D`/`0x30`/`0x32` (IO), `0x20`/`0x22` (memory), `0x24`/`0x26`/`0x28`/`0x2C` (prefetchable memory).
- `docs/specs/topology/tree.md` — `tree.Node`, `tree.NodeIndex`, `tree.max_depth`.

`bridge.md` decodes the wire values into semantic records. Semantic records are Zig-idiomatic structs, not `extern struct`s.

Compile-time size assertions:

```zig
comptime {
    std.debug.assert(@sizeOf(BusRange) == 3);
    std.debug.assert(@sizeOf(Window) == 24);
    std.debug.assert(@sizeOf(PrefetchableWindow) == 24);
}
```

## View / borrowing behavior

- `busRangeOf(node)` and `windowStateOf(node)` borrow `node.function`. Reads propagate through the borrowed `ConfigSpace`.
- `pathTo(t, index, scratch)` borrows `t.nodes[*].parent` and writes to caller `scratch`. The returned slice borrows `scratch`.
- No method retains references past return.
- Every method MUST NOT allocate, cache decoded state, retry, or synchronize.

## zstdx usage

Direct usage: none.

Bit-level offset math is `u8`/`u16`-bounded and needs no `zstdx.core.Range` wrapper. Bus-number and window reads flow through `config.Function.read*` directly. `pathTo` writes to caller scratch with no primitive shim.

## Facade re-export `[zpci]`

`src/topology.zig`:

```zig
pub const bridge = @import("topology/bridge.zig");
```

Callers reach the public surface as `zpci.topology.bridge.busRangeOf`, `zpci.topology.bridge.windowStateOf`, `zpci.topology.bridge.pathTo`, `zpci.topology.bridge.BusRange`, `zpci.topology.bridge.Window`, `zpci.topology.bridge.PrefetchableWindow`, `zpci.topology.bridge.WindowState`, and `zpci.topology.bridge.Error`.

## Usage

**Inspect current programmed state of a bridge:**

```zig
var it = tree.preorder();
while (it.next()) |n| {
    if (n.header_kind != .type1) continue;
    const range = try zpci.topology.bridge.busRangeOf(n);
    const state = try zpci.topology.bridge.windowStateOf(n);
    _ = range;
    _ = state;
}
```

**Walk ancestors of an endpoint (root first, endpoint last):**

```zig
var scratch: [zpci.topology.tree.max_depth]zpci.topology.tree.NodeIndex = undefined;
const chain = try zpci.topology.bridge.pathTo(&tree, endpoint_idx, &scratch);
for (chain) |idx| {
    const ancestor = tree.node(idx);
    _ = ancestor;
}
```

**Compose with assignment planning (caller orchestration; `resources/bridge.md` owns requirement synthesis, this spec only reports current state):**

```zig
// Walk endpoint's ancestor chain. For each bridge ancestor, inspect the
// current programmed memory window and decide whether a proposed base fits.
var scratch: [zpci.topology.tree.max_depth]zpci.topology.tree.NodeIndex = undefined;
const chain = try zpci.topology.bridge.pathTo(&tree, endpoint_idx, &scratch);
for (chain) |idx| {
    const anc = tree.node(idx);
    if (anc.header_kind != .type1) continue;
    const state = try zpci.topology.bridge.windowStateOf(anc);
    if (state.memory.enabled and
        proposed_base >= state.memory.base and
        proposed_base + size - 1 <= state.memory.limit)
    {
        // This ancestor forwards the proposed range.
        break;
    }
}
```

**Detect an unprogrammed bridge (secondary bus zero):**

```zig
const range = try zpci.topology.bridge.busRangeOf(bridge_node);
if (range.secondary == 0) {
    // Bridge has never been programmed; downstream absent from tree.
    // Assignment/programming: docs/specs/resources/programming.md.
}
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `busRangeOf` | never | 3 config reads | O(1); asserts `header_kind == .type1` | none | backend-defined | primary, secondary, subordinate |
| `windowStateOf` | never | 8 config reads (32-bit prefetchable) or 10 (64-bit prefetchable) | O(1); asserts `header_kind == .type1` | none | backend-defined | IO → memory → prefetchable |
| `pathTo` | never | never | O(depth); asserts `index < t.nodes.len` | none | pure lookup | root-first output |

Rules:

- Every method MUST NOT allocate, retry, log, or synchronize.
- Every method is single-thread over one `ConfigSpace`. Concurrent calls on distinct nodes MAY run through independent accessors; this spec makes no interleaving guarantee.
- Every method is deterministic over a stable `ConfigSpace` snapshot. Two calls on the same node with identical live state produce byte-identical semantic records.

## Required tests (category level)

- `unit:` `busRangeOf` on a bridge with primary=0, secondary=1, subordinate=1 returns those exact bytes.
- `unit:` `busRangeOf` on a bridge with `secondary == 0` returns `.secondary = 0` without erroring (unprogrammed is a legitimate state).
- `unit:` `busRangeOf` propagates `ConfigSpace.Error` from a failing read.
- `malformed:` `busRangeOf` on an endpoint node is a programmer-error assertion.
- `unit:` `windowStateOf` IO window with `io_base_lo = 0x20, io_limit_lo = 0x30, upper = 0` decodes to `io.base = 0x2000, io.limit = 0x3FFF, enabled = true`.
- `unit:` `windowStateOf` IO window with both low bytes zero decodes to `enabled = false`.
- `unit:` `windowStateOf` IO window with `io_base_upper = 0x0001, io_limit_upper = 0x0001` decodes to `io.base = 0x0001_2000, io.limit = 0x0001_3FFF`.
- `unit:` `windowStateOf` IO window with `base > limit` (disabled encoding after upper composition) decodes to `enabled = false`.
- `unit:` `windowStateOf` memory window with `mem_base = 0x2000, mem_limit = 0x3FF0` decodes to `memory.base = 0x2000_0000, memory.limit = 0x3FFF_FFFF, enabled = true`.
- `unit:` `windowStateOf` memory window with `mem_base = 0xFFF0, mem_limit = 0x0000` decodes to `enabled = false` (disabled encoding).
- `unit:` `windowStateOf` prefetchable 32-bit (`pref_base_lo[3:0] = 0x0, pref_limit_lo[3:0] = 0x0`) sets `is_64bit = false` and MUST NOT read `0x28` / `0x2C` (verified via read-recording fake).
- `unit:` `windowStateOf` prefetchable 64-bit (`pref_base_lo[3:0] = 0x1, pref_limit_lo[3:0] = 0x1, pref_base_upper = 0x0000_0004`) sets `is_64bit = true` and `prefetchable_memory.base >= 0x0000_0004_0000_0000`.
- `unit:` `windowStateOf` prefetchable inconsistent (`pref_base_lo[3:0] = 0x1, pref_limit_lo[3:0] = 0x0`) sets `is_64bit = false` and MUST NOT read upper-32 registers.
- `unit:` `windowStateOf` propagates `ConfigSpace.Error` from a failing read.
- `malformed:` `windowStateOf` on an endpoint node is a programmer-error assertion.
- `unit:` `pathTo` on a single-node tree (endpoint at index 0, no parent) returns `[0]`.
- `unit:` `pathTo` on a two-level tree (root bridge → endpoint) returns `[root, endpoint]` root-first.
- `unit:` `pathTo` on a five-level nested tree returns a five-element slice with correct ordering.
- `unit:` `pathTo` with `scratch.len < depth` returns `error.StorageExhausted` with scratch unmodified.
- `malformed:` `pathTo` with `index >= t.nodes.len` is a programmer-error assertion.
- `layout:` `BusRange` size is 3 bytes; `Window` size is 24 bytes; `PrefetchableWindow` size is 32 bytes.
- `unit:` Determinism: two calls on the same node/tree over a stable `ConfigSpace` snapshot produce identical semantic records.

## Non-goals

- Bridge-window requirement synthesis (`docs/specs/resources/bridge.md`).
- Wire encoding of window base/limit registers for writes.
- Bus-number assignment for unprogrammed bridges.
- Secondary-bus reset orchestration.
- `bridge_control` register bit decoding beyond the raw read exposed by `docs/specs/header/type1.md`.
- Hot-plug event detection.
- ARI capability inspection.
- Any config-space writes.
- Reverse lookup from `Sbdf` to `NodeIndex`.
- Caching decoded state across calls.
- Diagnostic out-parameters for failed reads or invalid programming states.

## Open questions

None owned by this spec.
