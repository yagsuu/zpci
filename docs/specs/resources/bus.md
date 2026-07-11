# Resource bus numbers

Defines the pure DFS numbering and commit step that writes the three bus-number bytes (`primary_bus_number` at `0x18`, `secondary_bus_number` at `0x19`, `subordinate_bus_number` at `0x1A`) on type-1 bridges. Owns the `Bridge`, `BridgeIndex`, `Input` types, the depth-first numbering algorithm bounded by a caller-supplied segment aperture, the batched write order that preserves descendant reachability, input-wide readback/rollback discipline, and the failure boundary for partially-restored commits.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on bus-number numbering, write order, and rollback discipline. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/type1.md`
- `docs/specs/resources/programming.md`
- `docs/specs/topology/enumerate.md`

## Scope

Owned:

- `commit(input) Error!void` — the one entry point that numbers and programs bus numbers on a caller-projected bridge set.
- `Bridge`, `BridgeIndex`, `max_bridges`, `max_depth`, `Input`.
- The depth-first numbering algorithm bounded by `Input.bus_end`.
- The batched write order: save all bridges, write all subordinates, write all primaries, then write secondaries in reverse DFS order.
- The save-then-write-then-verify discipline with input-wide rollback on failure.
- The failure boundary: successful rollback restores every journaled byte; failed rollback returns `ProgrammingPartial` and leaves touched bridge state unspecified.

Deferred:

- Reading current programmed state to decide skip-vs-overwrite. `commit` overwrites unconditionally.
- Multi-segment input in one call. Callers loop across segments.
- Extending a parent bridge's `subordinate_bus_number` as new subtrees are discovered later. Callers orchestrate via repeated `commit` calls with rebuilt inputs.
- Handle updating: `commit` does not touch caller-held `config.Function` values.
- Bridge-control programming, including secondary-bus reset orchestration. No approved zpci spec owns secondary-bus reset in the initial library.
- Diagnostic out-parameters identifying the failing bridge.
- Concurrent commits.

## Layering `[zpci]`

`resources/bus` is the only zpci module that writes bus-number registers.

Layering constraints from `docs/specs/architecture.md`:

- `resources/` imports `core/`, `config/`, `header/`, and `bar`. This spec imports `config/space.zig` for `config.Function` and `core/errors.zig` for the reused `zpci.Error` variants.
- `resources/` MUST NOT import `topology/`. Callers holding a `topology.tree.Tree` project it into `Input` at the callsite by filtering `.type1` header kinds and remapping parent indices into `BridgeIndex` positions.
- `resources/` MUST NOT import `interrupts/` or `memory/`.
- `commit` MUST NOT allocate. Save state lives in a fixed-size per-bridge frame on the internal recursion stack.

## Public surface `[zpci]`

```zig
const config = @import("../config.zig");

pub const BridgeIndex = u16;
pub const max_bridges: usize = std.math.maxInt(BridgeIndex);
pub const max_depth: u8 = 32;

pub const Bridge = struct {
    parent: ?BridgeIndex,
    function: config.Function,
};

pub const Input = struct {
    bridges: []const Bridge,
    roots: []const BridgeIndex,
    root_primary_bus: u8,
    bus_end: u8,
};

pub const Error = error{
    BusRangeExhausted,
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};

pub fn commit(input: Input) Error!void;
```

Rules:

- `BridgeIndex` is a type alias for `u16`, not a newtype wrapper. Indices name positions in `Input.bridges`.
- `max_bridges = 65_535` bounds one commit; `max_depth = 32` bounds the DFS stack. Both match `docs/specs/topology/tree.md`.
- `Bridge` is a value type. `Bridge.function` is a borrowed `config.Function`; lifetime follows the underlying `ConfigSpace` backend.
- `Input` values are consumed by value; assignment does not retain the reference.
- `commit` returns `void` on success; every returned error is one of the four variants above, each defined by `docs/specs/core/errors.md`.
- `commit` MUST NOT allocate, retry, log, or synchronize.
- `commit` MUST be deterministic on stable hardware: same `input` produces the same numbering and the same write / readback sequence.
- On success, any caller-held `config.Function` handle whose target bridge's bus number changed becomes invalid. See §Handle invalidation.

## `Bridge` `[zpci]`

```zig
pub const Bridge = struct {
    parent: ?BridgeIndex,
    function: config.Function,
};
```

Rules:

- `parent`, when non-null, MUST satisfy `parent < self_index` in `Input.bridges`. Programmer error.
- `parent`, when non-null, MUST reference another `Bridge` in `Input.bridges`. Endpoints do not appear in this input; callers project only type-1 header kinds.
- `function` is a borrowed handle to the bridge's `config.Function`. `commit` reads and writes offsets `0x18`, `0x19`, `0x1A` through it.

## `Input` `[zpci]`

```zig
pub const Input = struct {
    bridges: []const Bridge,
    roots: []const BridgeIndex,
    root_primary_bus: u8,
    bus_end: u8,
};
```

Rules:

- `bridges` MUST be in DFS preorder: for every non-root entry `bridges[i]`, `bridges[i].parent.? < i`. `commit` asserts this on every entry.
- `bridges.len <= max_bridges`.
- `roots` names one `BridgeIndex` per root — an entry whose `parent == null`. `roots` order controls the numbering order across root-level bridges.
- Every `roots[i]` MUST satisfy `roots[i] < bridges.len` and `bridges[roots[i]].parent == null`. Both are programmer-error assertions.
- `root_primary_bus` is the primary bus number every root-level bridge inherits (equivalently, the segment's `bus_start` for the segment this commit targets).
- `bus_end` is the inclusive upper bound on secondary and subordinate bus numbers. Matches the segment's `bus_end`.
- `root_primary_bus <= bus_end`. Programmer-error assertion.

## Algorithm `[zpci]`

`commit(input)` runs two phases.

### Phase 1 — DFS numbering `[zpci]`

Pure computation over `input`. No config-space access.

1. Assert every `Bridge.parent`, when non-null, satisfies `parent < self_index`.
2. Assert every root's `parent == null`.
3. Initialize `counter: u8 = input.root_primary_bus`.
4. Walk `input.bridges` in DFS preorder. For each bridge `b` at index `i`:
   1. If `counter == input.bus_end`, return `error.BusRangeExhausted`.
   2. `counter += 1`. Record `b.secondary = counter`.
   3. Record `b.primary = if (b.parent == null) input.root_primary_bus else recorded_secondary_of(b.parent.?)`.
   4. Recurse into `b`'s children in ascending `Input.bridges` slice order.
   5. On return from recursion, record `b.subordinate = counter`.
5. Produce a per-bridge triple `(primary, secondary, subordinate)` in DFS preorder.

Rules:

- Phase 1 MUST NOT perform I/O. On `error.BusRangeExhausted`, no hardware state has changed.
- The recorded triples live on the internal recursion stack for the duration of `commit`; they are not exposed as a `Plan`.
- Depth in the DFS walk MUST NOT exceed `max_depth`. In debug builds a violation is a programmer-error assertion; real PCIe hierarchies do not approach 32 levels.
- Determinism: same `input` produces byte-identical triples.

### Phase 2 — Batched commit `[zpci]`

`commit` uses the triples recorded in Phase 1 and preserves descendant bridge reachability by deferring every `secondary_bus_number` write until no descendant handle is needed.

Behavior:

1. **Save phase** — read the three bytes at `0x18`, `0x19`, `0x1A` for every bridge in `Input.bridges` DFS preorder. A read failure returns `ProgrammingWriteFailed`; no writes issued.
2. **Subordinate phase** — for every bridge in DFS preorder, write `subordinate_bus_number` at `0x1A`; readback under §Readback discipline.
3. **Primary phase** — for every bridge in DFS preorder, write `primary_bus_number` at `0x18`; readback.
4. **Secondary phase** — for every bridge in reverse DFS preorder, write `secondary_bus_number` at `0x19`; readback.

Rules:

- Deferring `secondary_bus_number` writes keeps each bridge reachable through its caller-supplied `config.Function` until every descendant has been programmed.
- Reverse DFS for the secondary phase flips child routing before parent routing, so parent writes cannot invalidate unprogrammed descendants.
- Bus-number registers are not decode-gated. `commit` MUST NOT touch the `Command` register.
- Each write is immediately followed by a readback at the same offset and width.

### Readback discipline `[zpci]`

After every write in Phase 2 (including rollback writes), programming issues an 8-bit read at the same offset and compares against the value just written. Rules:

- A read failure during readback returns `ProgrammingWriteFailed` and triggers §Rollback.
- A comparison mismatch returns `ProgrammingReadbackMismatch` and triggers §Rollback.
- Bus-number registers are fully writable per PCI/PCIe; comparison is full-byte equality with no masking.

### Rollback `[zpci]`

When Phase 2 returns an error, `commit` attempts to restore every journaled write in reverse phase order:

1. Restore written `secondary_bus_number` bytes in DFS preorder.
2. Restore written `primary_bus_number` bytes in reverse DFS preorder.
3. Restore written `subordinate_bus_number` bytes in reverse DFS preorder.

For each restore:

1. Write the saved byte to the same offset.
2. Readback and compare against the saved value under §Readback discipline.
3. If the restore write or restore-readback fails, ABORT further rollback and return `ProgrammingPartial` immediately.

After every journaled write is successfully restored, `commit` returns the original error (`ProgrammingWriteFailed` or `ProgrammingReadbackMismatch`).

Rules:

- Rollback is input-wide because Phase 2 batches writes by register to preserve descendant reachability.
- Rollback MUST NOT retry a failed restore. A single failure aborts rollback with `ProgrammingPartial`.
- The save-phase read failure needs no rollback because no writes were issued.

### Failure boundary `[zpci]`

On failure during Phase 2:

- If rollback succeeds, every journaled bridge byte is restored to its pre-commit value and `commit` returns the original error.
- If rollback fails, `commit` returns `ProgrammingPartial` and any bridge touched before the rollback failure may be in an unspecified state.
- Writes from phases that had not started, or later entries in the failing phase, are not attempted.

Rules:

- `commit` does not expose which bridge or phase failed. A caller that needs to identify the failing bridge inspects live hardware state after `commit` returns.

## Post-commit invariants `[zpci]`

A successful `commit` establishes the following on every bridge in `Input.bridges`:

- `secondary_bus_number != 0`.
- `secondary_bus_number > primary_bus_number`.
- `secondary_bus_number <= input.bus_end`.
- `secondary_bus_number <= subordinate_bus_number`.

These match the four conditions `docs/specs/topology/enumerate.md` §Bridge recursion checks before descending into a bridge's downstream bus. A subsequent `topology.enumerate.intoScratch` call over the same segments therefore recurses into every programmed subtree.

Rules:

- Failed commits do not establish post-commit invariants. After successful rollback, every journaled byte has its pre-commit value; after `ProgrammingPartial`, any touched bridge byte is unspecified.

## Handle invalidation `[zpci]`

`commit` does not update caller-held `config.Function` handles. Any handle whose target bridge's bus number changed (its own `secondary`, or a descendant's routing through a re-numbered bus) MUST be treated as invalid by the caller. Callers re-enumerate via `topology.enumerate.intoScratch` to obtain fresh handles.

## Errors

```zig
pub const Error = error{
    BusRangeExhausted,
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};
```

Variant sourcing:

- `BusRangeExhausted` — Phase 1 computed a `secondary_bus_number` that would exceed `input.bus_end`. No hardware state changed. The `zpci.Error` variant is defined by `docs/specs/core/errors.md`.
- `ProgrammingReadbackMismatch` — a readback comparison in Phase 2 observed a value that does not match what was written. Rollback ran successfully.
- `ProgrammingWriteFailed` — a `ConfigSpace` read or write returned an accessor error during the save phase or a Phase 2 write, before rollback started. Rollback ran successfully. Save-phase read failures also map here.
- `ProgrammingPartial` — a rollback write or rollback readback itself failed. Hardware is neither in the pre-commit state nor the planned post-commit state.

Rules:

- Bus-number programming MUST NOT synthesize other `zpci.Error` variants. `ConfigSpace.Error` values are mapped to `ProgrammingWriteFailed` at the point of the failing access.
- Programmer errors (misordered `Input.bridges`, root's `parent != null`, `bus_end < root_primary_bus`, `max_depth` exceeded) MUST be enforced by assertion per `docs/specs/config/space.md` §Validation vs assertion. They are not typed errors.

## Wire / layout invariants

None owned. The three bus-number registers at `0x18`/`0x19`/`0x1A` are owned by `docs/specs/header/type1.md`.

## View / borrowing behavior

- `input.bridges` and `input.roots` are borrowed slices; `commit` reads only.
- Each `Bridge.function` transitively borrows a `config.Function`; lifetime follows the underlying `ConfigSpace` backend.
- The per-bridge save frame (three bytes) lives on the internal recursion stack; discarded on bridge return.
- Phase 1's per-bridge triple records live on the internal recursion stack; discarded on `commit` return.
- No allocation, no cross-call caching.

## zstdx usage

None. `u8` counters and per-bridge save state fit on the internal stack.

## Facade re-export `[zpci]`

`src/resources.zig`:

```zig
pub const bus = @import("resources/bus.zig");
```

Callers reach the public surface as `zpci.resources.bus.commit`, `zpci.resources.bus.Bridge`, `zpci.resources.bus.Input`, `zpci.resources.bus.BridgeIndex`, `zpci.resources.bus.max_bridges`, `zpci.resources.bus.max_depth`, and `zpci.resources.bus.Error`.

## Usage

**Project a `tree.Tree` into a bus-number `Input` (caller-side, since `resources/` does not import `topology/`):**

```zig
// Filter the tree to type-1 bridges only and remap parent indices to BridgeIndex positions.

var bridges: [zpci.topology.tree.max_nodes]zpci.resources.bus.Bridge = undefined;
var tree_to_bridge: [zpci.topology.tree.max_nodes]?zpci.resources.bus.BridgeIndex = .{null} ** zpci.topology.tree.max_nodes;

var bridge_count: usize = 0;
for (tree.nodes, 0..) |tnode, i| {
    if (tnode.header_kind != .type1) continue;
    const bridge_parent: ?zpci.resources.bus.BridgeIndex = if (tnode.parent) |p| tree_to_bridge[p] else null;
    bridges[bridge_count] = .{ .parent = bridge_parent, .function = tnode.function };
    tree_to_bridge[i] = @intCast(bridge_count);
    bridge_count += 1;
}

var roots: [zpci.topology.tree.max_nodes]zpci.resources.bus.BridgeIndex = undefined;
var root_count: usize = 0;
for (bridges[0..bridge_count], 0..) |b, i| {
    if (b.parent == null) {
        roots[root_count] = @intCast(i);
        root_count += 1;
    }
}
```

**Commit bus numbers for one segment:**

```zig
try zpci.resources.bus.commit(.{
    .bridges = bridges[0..bridge_count],
    .roots = roots[0..root_count],
    .root_primary_bus = segment.bus_start,
    .bus_end = segment.bus_end,
});
```

**Handle failures:**

```zig
zpci.resources.bus.commit(input) catch |err| switch (err) {
    error.BusRangeExhausted => {
        // Segment's bus range is too small for the observed bridge tree.
        return err;
    },
    error.ProgrammingReadbackMismatch, error.ProgrammingWriteFailed => {
        // A specific bridge did not accept the write. Rollback restored that bridge;
        // prior bridges in the input are still programmed. Caller re-enumerates and
        // decides recovery policy.
        return err;
    },
    error.ProgrammingPartial => {
        // Rollback itself failed. Affected bridge is in an unknown state; prior
        // bridges in the input are still programmed.
        return err;
    },
};

// After success, re-enumerate to obtain fresh config.Function handles that reflect
// the new bus routing.
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `commit` | never | backend-defined non-sleeping I/O; O(N × 6) config accesses per bridge (3 reads + 3 writes + 3 readbacks) | O(N) DFS numbering; O(N) recursion depth ≤ `max_depth` | caller-held `config.Function` handles referencing re-numbered bridges are invalidated on success; pre-commit state on rollback-success; unspecified on `ProgrammingPartial` | single-thread over one `ConfigSpace` | DFS preorder per input; per-bridge subordinate → primary → secondary |

Rules:

- `commit` MUST NOT allocate, retry, log, or synchronize.
- `commit` MUST run single-threaded over one `ConfigSpace`. Concurrent commits on disjoint inputs through the same `ConfigSpace` are caller policy.
- `commit` MUST be deterministic on stable hardware: same `input` produces the same write / readback sequence.

## Required tests (category level)

**DFS numbering (pure):**

- `unit:` empty `Input.roots` → success, no writes.
- `unit:` single root bridge, no children → primary = `root_primary_bus`, secondary = `root_primary_bus + 1`, subordinate = secondary.
- `unit:` root with one child bridge → root `{primary=0, secondary=1, subordinate=2}`, child `{primary=1, secondary=2, subordinate=2}` (using `root_primary_bus = 0`).
- `unit:` root with three sibling child bridges → root's secondary = 1, subordinate = 4; children secondaries 2, 3, 4 in DFS order.
- `unit:` deep chain (5 nested bridges) → sequential secondaries; each bridge's subordinate equals the deepest descendant's secondary.
- `unit:` two root-level bridges → first root `{secondary=1, subordinate=X}`, second root `{secondary=X+1, subordinate=Y}`.
- `unit:` `bus_end = 5`, root plus chain of 6 bridges → `BusRangeExhausted` before any write.
- `unit:` `bus_end == root_primary_bus` (empty available range) with any non-empty roots → `BusRangeExhausted`.
- `unit:` deterministic: two calls with identical `Input` produce identical triples on each bridge.

**Writes and readback:**

- `unit:` single bridge, all writes succeed → save captures the three saved bytes; write order is subordinate, primary, secondary; each readback matches the written value.
- `unit:` overwrite of already-programmed bridge → writes overwrite unconditionally; readback matches new values; saved values equal the pre-existing programmed bytes.
- `unit:` multi-bridge tree → save phase visits DFS preorder; subordinate and primary phases write DFS preorder; secondary phase writes reverse DFS preorder.
- `unit:` `commit` never touches offset `0x04` (`Command`).

**Failure and rollback:**

- `unit:` save-phase read failure at any bridge → `ProgrammingWriteFailed`; no writes issued.
- `unit:` subordinate write failure → rollback restores prior subordinate writes; returns `ProgrammingWriteFailed` if restore succeeds.
- `unit:` primary write failure → rollback restores written primaries and subordinates; returns `ProgrammingWriteFailed` if restore succeeds.
- `unit:` secondary write failure → rollback restores written secondaries, primaries, and subordinates; returns `ProgrammingWriteFailed` if restore succeeds.
- `unit:` subordinate readback mismatch → rollback attempts subordinate restore; returns `ProgrammingReadbackMismatch`.
- `unit:` primary readback mismatch → rollback restores subordinate; returns `ProgrammingReadbackMismatch`.
- `unit:` secondary readback mismatch → rollback restores primary then subordinate; returns `ProgrammingReadbackMismatch`.
- `unit:` rollback write failure during recovery → returns `ProgrammingPartial`; no further restores attempted.
- `unit:` rollback readback mismatch during recovery → returns `ProgrammingPartial`.
- `unit:` multi-bridge failure after earlier phase writes → rollback restores every journaled write; later entries in the failing phase and later phases are not attempted.

**Post-commit invariants (integration):**

- `integration:` after successful `commit`, a subsequent `topology.enumerate.intoScratch` over the same segments recurses into every subtree programmed by this call. Every programmed bridge satisfies the four conditions in `docs/specs/topology/enumerate.md` §Bridge recursion.

**Malformed / programmer error (assertion):**

- `malformed:` `Bridge.parent >= self_index` → programmer-error assertion.
- `malformed:` a root's `parent != null` → programmer-error assertion.
- `malformed:` non-root `Bridge` whose parent points at a bridge appearing later in `Input.bridges` → programmer-error assertion.
- `malformed:` `roots[i] >= bridges.len` → programmer-error assertion.
- `malformed:` `bridges[roots[i]].parent != null` → programmer-error assertion.
- `malformed:` `bus_end < root_primary_bus` → programmer-error assertion.
- `malformed:` DFS depth exceeds `max_depth` → programmer-error assertion in debug builds.

## Non-goals

- Reading current programmed state to decide skip-vs-overwrite.
- Multi-segment input in one call.
- Extending a parent bridge's subordinate as new subtrees are discovered later.
- Bridge-control programming and secondary-bus reset orchestration.
- Diagnostic out-parameters identifying the failing bridge.
- Handle updating on caller-held `config.Function` values.
- Concurrent commits.
- Retry on transient failures.

## Open questions

None owned by this spec.
