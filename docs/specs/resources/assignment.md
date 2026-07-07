# Resource assignment

Defines the pure allocation planner that consumes a caller-projected node list, a root-window aperture set, and per-node `Requirement`s, and returns a `Plan` naming one `Assignment` per input `Requirement`. Owns the `Node`, `NodeKind`, `NodeIndex`, `Input`, and `Plan` types, the DFS-preorder placement algorithm, the per-aperture requirement sort, the pool-preference order across the eligibility fallback chain, the effective sub-aperture at bridges, and the `intoScratch` / `sizeBound` entry points.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on the assignment algorithm, the pool-preference order, and the bridge sub-aperture composition. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/space.md`
- `docs/specs/bar.md`
- `docs/specs/resources/model.md`
- `docs/specs/resources/bridge.md`
- `docs/specs/resources/programming.md`
- `docs/specs/topology/tree.md`

## Scope

Owned:

- `NodeIndex`, `max_nodes`, `max_depth` — index and depth bounds.
- `NodeKind` — two-variant tag distinguishing endpoints from bridges.
- `Node` — flat per-function record carrying `parent`, `kind`, and pre-computed `requirements`.
- `Input` — the argument struct grouping `nodes`, `roots`, and `root_windows`.
- `Plan` — the returned record carrying `assignments`.
- `intoScratch(input, scratch) Error!Plan` — the DFS-preorder placement entry point.
- `sizeBound(nodes) usize` — upper-bound helper for sizing the `scratch` slice.
- The per-node requirement sort order (descending alignment, ties by descending size, stable by input order).
- The pool-preference chain per `Kind` used to walk `eligiblePools` at each placement site.
- The bridge sub-aperture composition rule that derives descendants' effective apertures from a bridge's placed window `Assignment`s.
- The DFS preorder in which `Assignment`s are emitted into `scratch`.

Deferred:

- Bridge-window `Requirement` aggregation (`docs/specs/resources/bridge.md`).
- `Requirement.fromBar` / `Requirement.fromExpansionRom` producers (`docs/specs/resources/model.md`).
- Config-space writes committing a `Plan` (`docs/specs/resources/programming.md`).
- Bus-number assignment for unprogrammed bridges (`docs/specs/resources/bus.md`).
- Secondary-bus reset orchestration. No approved zpci spec owns this in the initial library.
- Backtracking, best-fit, or multi-pass placement.
- Firmware-hint or preserve-existing-programming policy.
- Aperture-overlap detection between `RootWindows` fields (owned by `docs/specs/resources/model.md` §Aperture).
- Diagnostic out-parameters listing rejected requirements.
- Allocator-backed constructor (`intoAlloc`).
- Reverse lookup from an emitted `Assignment` to its source `Node`.

## Layering `[zpci]`

`resources/assignment` is a pure planner. It reads the input, writes into caller scratch, and returns a value. It MUST NOT perform I/O.

Layering constraints from `docs/specs/architecture.md`:

- `resources/` imports `core/`, `config/`, `header/`, and `bar`. This spec imports `resources/model.zig` for `Requirement`, `Assignment`, `Kind`, `Source`, `RootWindows`, `Aperture`, and `eligiblePools`.
- `resources/` MUST NOT import `topology/`. A caller that has a `tree.Tree` projects it into `[]const Node` at the callsite before calling `intoScratch`.
- `resources/` MUST NOT import `interrupts/` or `memory/`.
- `resources/assignment` MUST NOT write config space. Config writes belong to `docs/specs/resources/programming.md`, which consumes a `Plan`.

Composition contract:

- Bridge-window `Requirement`s in a bridge `Node.requirements` MUST be pre-computed by the caller via `resources.bridge.aggregateWindows` (`docs/specs/resources/bridge.md`).
- Endpoint BAR and expansion-ROM `Requirement`s MUST be pre-computed by the caller via `Requirement.fromBar` and `Requirement.fromExpansionRom` (`docs/specs/resources/model.md`).
- Assignment consumes `Requirement`s as opaque values; it does not classify them by source beyond what the sub-aperture composition rule requires (§Bridge sub-aperture composition).

## Public surface `[zpci]`

```zig
const model = @import("model.zig");

pub const Requirement = model.Requirement;
pub const Assignment = model.Assignment;
pub const Kind = model.Kind;
pub const Aperture = model.Aperture;
pub const RootWindows = model.RootWindows;
pub const Source = model.Source;

pub const NodeIndex = u16;
pub const max_nodes: usize = std.math.maxInt(NodeIndex);
pub const max_depth: u8 = 32;

pub const NodeKind = enum { endpoint, bridge };

pub const Node = struct {
    parent: ?NodeIndex,
    kind: NodeKind,
    requirements: []const Requirement,
};

pub const Input = struct {
    nodes: []const Node,
    roots: []const NodeIndex,
    root_windows: RootWindows,
};

pub const Plan = struct {
    assignments: []const Assignment,
};

pub const Error = error{
    ResourceExhausted,
    StorageExhausted,
};

pub fn intoScratch(input: Input, scratch: []Assignment) Error!Plan;
pub fn sizeBound(nodes: []const Node) usize;
```

Rules:

- `Requirement`, `Assignment`, `Kind`, `Aperture`, `RootWindows`, and `Source` are re-exports from `docs/specs/resources/model.md`. They are not owned by this spec.
- `NodeIndex` is a type alias for `u16`, not a newtype wrapper. Indices name positions in `Input.nodes`.
- `max_nodes = 65_535` bounds one `Plan`. This matches `docs/specs/topology/tree.md` §`NodeIndex`.
- `max_depth = 32` bounds the DFS stack; matches `docs/specs/topology/tree.md` §`max_depth`.
- `Node` is a value type. `Node.requirements` is a borrowed slice; the caller keeps it live for the duration of `intoScratch`.
- `Input.root_windows` is a value type; assignment copies it internally as the initial DFS frame.
- `Plan.assignments` borrows `scratch`; callers MUST keep `scratch` live for the returned `Plan`'s lifetime.
- Every method MUST NOT allocate, retry, log, synchronize, or perform I/O.
- Every method is deterministic. Same `Input` produces byte-identical `Plan.assignments`.

## `Node` `[zpci]`

```zig
pub const Node = struct {
    parent: ?NodeIndex,
    kind: NodeKind,
    requirements: []const Requirement,
};
```

Rules:

- `parent`, when non-null, MUST satisfy `parent < self_index`. Assignment enforces this by assertion on every non-root node; a violation is a programmer error.
- `parent`, when non-null, MUST reference a `Node` with `kind == .bridge`. Endpoints MUST NOT have children. Assignment enforces this by assertion during recursion.
- `kind == .endpoint` — `requirements` MAY contain `Requirement`s whose `source` variant is `.endpoint_bar` or `.endpoint_expansion_rom`. `requirements.len` is bounded by the header layout: at most 7 (six BAR requirements plus one expansion-ROM requirement).
- `kind == .bridge` — `requirements` MAY contain both bridge-BAR `Requirement`s (`source` variant `.endpoint_bar` for the type-1 header's two BAR slots) and bridge-window `Requirement`s (`source` variant `.bridge_window`). `requirements.len` is bounded by the header layout: at most 5 (two bridge BAR requirements plus three bridge window requirements).
- Sibling nodes under a common parent MUST appear in ascending `Input.nodes` slice order. Assignment iterates children in slice order; the caller decides sibling order by input placement.
- `requirements` is a borrowed slice. Assignment reads it in-place; it does not sort in place and does not retain the reference past return.

## `Input` `[zpci]`

```zig
pub const Input = struct {
    nodes: []const Node,
    roots: []const NodeIndex,
    root_windows: RootWindows,
};
```

Rules:

- `nodes.len <= max_nodes`. `intoScratch` returns `error.StorageExhausted` when this bound is violated by an internal count during placement, not by an upfront check on `nodes.len`; a violation of the bound before placement runs is a programmer error, not a typed error.
- `roots` names one `NodeIndex` per root — an entry in `nodes` whose `parent == null`. `roots` order controls the top-level DFS order in `Plan.assignments`.
- Every `roots[i]` MUST satisfy `roots[i] < nodes.len` and `nodes[roots[i]].parent == null`. Both are programmer-error assertions.
- `root_windows` describes the caller-supplied aperture set at the top of the DFS. Missing pools use `Aperture{ .kind = <name>, .base = 0, .size = 0 }` per `docs/specs/resources/model.md` §RootWindows.

## `Plan` `[zpci]`

```zig
pub const Plan = struct {
    assignments: []const Assignment,
};
```

Rules:

- `assignments` borrows `scratch`. Its length equals the total `Requirement`s reachable from `Input.roots`.
- `assignments` is ordered by DFS preorder over `Input.roots` (§DFS preorder). Within one node, `Assignment`s appear in the sort order defined by §Requirement sort.
- Each `Assignment.pool` satisfies `eligiblePools(assignment.requirement.kind).has(assignment.pool)` per `docs/specs/resources/model.md` §Eligibility.
- Each `Assignment.base` satisfies `pool_aperture.contains(base, requirement.size)` and `base % requirement.alignment == 0`, where `pool_aperture` is the effective aperture the placement drew from (§Effective apertures).

## Algorithm `[zpci]`

`intoScratch(input, scratch)` behavior:

1. Compute `required = sum of nodes[i].requirements.len for every `i` reachable from a root via `parent` links`. If `required > scratch.len`, return `error.StorageExhausted`. `scratch` MUST NOT be modified.
2. Initialize `out_len: usize = 0`.
3. For each `root` in `input.roots` in slice order:
   1. Push a fresh DFS frame containing a mutable copy of `input.root_windows`.
   2. Call `visit(root)` (§Visit routine).
4. Return `Plan{ .assignments = scratch[0..out_len] }`.

`visit(index)` behavior:

1. Let `node = &input.nodes[index]`.
2. If `node.parent != null`: assert `node.parent.? < index` and `input.nodes[node.parent.?].kind == .bridge`.
3. Sort a local copy of `node.requirements` per §Requirement sort into `sorted[0..node.requirements.len]`. The local buffer is fixed-capacity `[7]Requirement` (endpoint upper bound) or `[5]Requirement` (bridge upper bound).
4. For each `req` in `sorted[0..node.requirements.len]`:
   1. Attempt placement in the current DFS frame per §Placement. On failure, return `error.ResourceExhausted`.
   2. Write the resulting `Assignment` into `scratch[out_len]`. Increment `out_len`.
5. If `node.kind == .bridge`:
   1. Build a child frame per §Bridge sub-aperture composition using the just-emitted `Assignment`s.
   2. Push the child frame.
   3. For each `child_idx` in `input.nodes` in ascending order where `input.nodes[child_idx].parent == index`:
      - Assert depth < `max_depth` before descending.
      - Call `visit(child_idx)`.
   4. Pop the child frame.
6. Return.

Rules:

- Assignment MUST NOT allocate. All state lives in the fixed-capacity DFS frame stack (`[max_depth]RootWindows`) and per-node local sort buffer.
- Assignment MUST NOT perform I/O. Every field it reads comes from `input`; every field it writes goes to `scratch`.
- Assignment MUST be deterministic. Same `input` produces byte-identical `scratch[0..out_len]`.
- Assignment MUST NOT mutate `input.nodes`, `input.roots`, `input.root_windows`, or any `Node.requirements`.
- On `error.StorageExhausted` or `error.ResourceExhausted`, `scratch` contents up to the failing write are undefined; callers MUST NOT read the slice.

### Effective apertures `[zpci]`

The DFS frame carries five apertures, one per pool, matching `RootWindows`:

```zig
const Frame = struct {
    io: Aperture,
    mmio32: Aperture,
    mmio32_pref: Aperture,
    mmio64: Aperture,
    mmio64_pref: Aperture,
};
```

Each aperture tracks a live cursor: `base` advances forward and `size` shrinks as requirements are placed. A frame is a mutable copy scoped to one recursion level; the parent frame is preserved on the stack and restored on return.

The initial frame is `input.root_windows`. Descendant frames are derived per §Bridge sub-aperture composition.

### Requirement sort `[zpci]`

For each node, assignment sorts its `Requirement`s by:

1. Descending `alignment`.
2. Ties broken by descending `size`.
3. Ties broken by ascending `Input.nodes[index].requirements` input position (stable sort).

Rules:

- The sort operates on a local fixed-capacity copy; `Node.requirements` is not mutated.
- The sort is stable. The input-position tiebreaker guarantees byte-identical output for byte-identical inputs.
- Descending-alignment placement minimizes internal fragmentation: larger-alignment requirements land first, then smaller-alignment requirements pack into the remaining space without back-fitting the larger ones.

### Pool preference `[zpci]`

At each placement site, assignment walks the pool-preference chain for the requirement's `Kind` in the fixed order below. The first pool whose aperture has room wins. When every listed pool's aperture is empty or too small, placement returns `error.ResourceExhausted`.

| `Requirement.kind` | Pools attempted, in order |
|---|---|
| `.io` | `.io` |
| `.mmio32` | `.mmio32` |
| `.mmio32_pref` | `.mmio32_pref`, then `.mmio32` |
| `.mmio64` | `.mmio64`, then `.mmio32` |
| `.mmio64_pref` | `.mmio64_pref`, then `.mmio32_pref`, then `.mmio64`, then `.mmio32` |

Rules:

- Each row is a subset of `eligiblePools(kind)` per `docs/specs/resources/model.md` §Eligibility, ordered to prefer the natural (matching-kind) pool first, then narrower pools in decreasing preference.
- `.mmio32_pref` prefers a prefetchable pool over falling back to non-prefetchable, preserving the prefetch hint when the aperture is available.
- `.mmio64` and `.mmio64_pref` prefer a 64-bit pool over a 32-bit fallback, keeping above-4-GiB placement available when the caller supplies a 64-bit aperture.
- `.mmio64_pref` prefers prefetchable over non-prefetchable at each width, matching the `.mmio32_pref` policy.
- The recorded `Assignment.pool` is the pool that actually accepted the placement, not `requirement.kind`.

### Placement `[zpci]`

Given a requirement `req` and the current frame:

```
for pool in preference_chain(req.kind):
    aperture := frame[pool]
    if aperture.size == 0: continue
    base := align_up(aperture.base, req.alignment)
    end  := base + req.size
    if end overflows u64: continue
    if end > aperture.end(): continue
    frame[pool].base := end
    frame[pool].size := frame[pool].size - (end - aperture.base)
    return Assignment{ .requirement = req, .pool = pool, .base = base }
return error.ResourceExhausted
```

Rules:

- `align_up(x, a) = (x + a - 1) & ~(a - 1)`. Overflow of the intermediate sum causes the pool to be skipped, not an error propagated.
- `aperture.end()` is `aperture.base + aperture.size`, taken from the current mutable state (not the initial state).
- Advancing `aperture.base` past the placed range and shrinking `aperture.size` by the consumed span is a cursor bump. Padding for alignment is included in the consumed span.
- `pool` on the returned `Assignment` is the pool that succeeded, which MAY differ from `req.kind` under the fallback rules above.

### Bridge sub-aperture composition `[zpci]`

After placing a bridge node's own `Requirement`s in the current frame, the child frame is derived from the just-emitted `Assignment`s whose `requirement.source == .bridge_window`.

Start with an empty frame:

```
child.io          = Aperture{ .kind = .io,          .base = 0, .size = 0 }
child.mmio32      = Aperture{ .kind = .mmio32,      .base = 0, .size = 0 }
child.mmio32_pref = Aperture{ .kind = .mmio32_pref, .base = 0, .size = 0 }
child.mmio64      = Aperture{ .kind = .mmio64,      .base = 0, .size = 0 }
child.mmio64_pref = Aperture{ .kind = .mmio64_pref, .base = 0, .size = 0 }
```

For each just-emitted `Assignment` `A` whose `A.requirement.source == .bridge_window`, overwrite exactly one field per the table:

| `A.requirement.kind` | Field overwritten |
|---|---|
| `.io` | `child.io = Aperture{ .kind = .io, .base = A.base, .size = A.requirement.size }` |
| `.mmio32` | `child.mmio32 = Aperture{ .kind = .mmio32, .base = A.base, .size = A.requirement.size }` |
| `.mmio32_pref` | `child.mmio32_pref = Aperture{ .kind = .mmio32_pref, .base = A.base, .size = A.requirement.size }` |
| `.mmio64_pref` | `child.mmio64_pref = Aperture{ .kind = .mmio64_pref, .base = A.base, .size = A.requirement.size }` |

Rules:

- The `child.mmio64` field is always absent (`size == 0`). Type-1 bridges have no 64-bit non-prefetchable window per `docs/specs/header/type1.md`. `.mmio64` descendants fall back to `.mmio32` per the pool-preference chain.
- The overwrite uses `A.requirement.kind`, not `A.pool`. Fallback placement of a `.mmio32_pref` bridge window into an `.mmio32` parent aperture still populates `child.mmio32_pref`; the child's prefetchable semantic follows the bridge window's kind, not the parent's pool identity.
- `.mmio32_pref` and `.mmio64_pref` never both populate. A bridge produces at most one prefetchable window; the aggregation rule (`docs/specs/resources/bridge.md` §Kind mapping) collapses mixed-prefetchable children to `.mmio32_pref`.
- Non-bridge-window `Assignment`s (`source == .endpoint_bar` for a bridge BAR) MUST NOT contribute to the child frame. Bridge BARs are accessed from the bridge's primary side and consume the parent frame's aperture, not the sub-aperture.
- A bridge whose window requirements omit a given kind produces a child frame with that field empty. Descendants requiring that kind will exhaust unless the pool-preference chain finds a populated fallback.

### DFS preorder `[zpci]`

`Plan.assignments` is emitted in DFS preorder over `Input.roots`:

- For each root, the root node's `Assignment`s are emitted first (in the sort order defined by §Requirement sort).
- If the node is a bridge, its descendants' `Assignment`s follow contiguously in DFS preorder, before any subsequent root.
- Children of a bridge are visited in ascending `Input.nodes` slice order.

Rules:

- Programming (`docs/specs/resources/programming.md`) MUST NOT depend on the preorder positioning to identify a target register. It reads `Assignment.requirement.source` to dispatch.
- The preorder guarantee is a determinism aid: same `Input` yields the same emission sequence.

## `sizeBound` `[zpci]`

```zig
pub fn sizeBound(nodes: []const Node) usize {
    var total: usize = 0;
    for (nodes) |node| total += node.requirements.len;
    return total;
}
```

Rules:

- The result is an upper bound on `Plan.assignments.len`. When every node in `nodes` is reachable from a root in `Input.roots`, the bound is tight.
- Unreachable nodes contribute to the bound but not to the emitted plan. Callers MAY oversize `scratch` accordingly.
- `sizeBound` is `comptime`-callable when `nodes` is `comptime`-known.

## Errors

```zig
pub const Error = error{
    ResourceExhausted,
    StorageExhausted,
};
```

Variant sourcing:

- `ResourceExhausted` — placement observed a requirement whose entire pool-preference chain returned no aperture with room. The `zpci.Error` variant is defined by `docs/specs/core/errors.md`.
- `StorageExhausted` — the upfront `required > scratch.len` check failed. `scratch` is unmodified.

Rules:

- Assignment MUST NOT return `ConfigSpace.Error` or any I/O-derived variant. Placement is pure over inputs.
- `BridgeWindowUnencodable` is NOT in this set. Encodability is decided by `resources.bridge.encodeWindow` (`docs/specs/resources/bridge.md`), which runs after assignment. An assignment placing a memory-window base ≥ 4 GiB is a legitimate placement here; the encodability failure surfaces later.
- Programmer errors (out-of-range `NodeIndex`, `parent >= self_index`, endpoint with a child, exceeding `max_depth`) MUST be enforced by assertion per `docs/specs/config/space.md` §Validation vs assertion. They are not typed errors.
- On any returned error, `Plan` is not constructed. The caller sees only the error.

## Wire / layout invariants

None. `Node`, `NodeKind`, `Input`, and `Plan` are semantic types. `Assignment` layout is owned by `docs/specs/resources/model.md`.

Compile-time size assertions:

```zig
comptime {
    std.debug.assert(@sizeOf(NodeIndex) == 2);
    std.debug.assert(max_nodes == 65_535);
    std.debug.assert(max_depth == 32);
}
```

## View / borrowing behavior

- `Input.nodes` is a borrowed slice; assignment reads only.
- `Input.roots` is a borrowed slice; assignment reads only.
- `Input.root_windows` is a value; assignment copies it into the initial DFS frame.
- Every `Node.requirements` slice is borrowed transitively. Each `Requirement.source` in turn borrows `config.Function` (per `docs/specs/resources/model.md` §Source); lifetime follows the underlying `ConfigSpace` backend.
- `scratch: []Assignment` is borrowed; the returned `Plan.assignments` borrows the prefix.
- Assignment retains no references past return.
- Every method MUST NOT allocate, cache decoded state, retry, or synchronize.

## zstdx usage

Direct usage: none. Alignment math and cursor bookkeeping are `u64`-bounded and internal; the DFS frame stack is `[max_depth]Frame` on the internal recursion stack.

## Facade re-export `[zpci]`

`src/resources.zig`:

```zig
pub const assignment = @import("resources/assignment.zig");
```

Callers reach the public surface as `zpci.resources.assignment.intoScratch`, `zpci.resources.assignment.sizeBound`, `zpci.resources.assignment.Input`, `zpci.resources.assignment.Plan`, `zpci.resources.assignment.Node`, `zpci.resources.assignment.NodeKind`, `zpci.resources.assignment.NodeIndex`, and `zpci.resources.assignment.Error`.

## Usage

**Project a `tree.Tree` into an assignment `Input` (caller-side, since `resources/` does not import `topology/`):**

```zig
// Bottom-up: size every endpoint's BARs and every bridge's aggregated windows.
// The caller writes into a scratch []Requirement per node.

var per_node_reqs: [zpci.topology.tree.max_nodes][8]zpci.resources.model.Requirement = undefined;
var per_node_reqs_len: [zpci.topology.tree.max_nodes]usize = undefined;

// ... walk tree bottom-up:
//   endpoint node -> Requirement.fromBar / fromExpansionRom over bar.View.sizeAll output.
//   bridge node   -> resources.bridge.aggregateWindows(bridge.function, collected_descendant_reqs, &per_node_reqs[bridge_idx]).
// Then project:

var nodes: [zpci.topology.tree.max_nodes]zpci.resources.assignment.Node = undefined;
for (tree.nodes, 0..) |tnode, i| {
    nodes[i] = .{
        .parent = tnode.parent,
        .kind = switch (tnode.header_kind) { .type0 => .endpoint, .type1 => .bridge },
        .requirements = per_node_reqs[i][0..per_node_reqs_len[i]],
    };
}

const input = zpci.resources.assignment.Input{
    .nodes = nodes[0..tree.nodes.len],
    .roots = tree.roots,
    .root_windows = platform_windows,
};
```

**Size the plan scratch and run assignment:**

```zig
var plan_scratch: [zpci.resources.assignment.sizeBound(&nodes)]zpci.resources.model.Assignment = undefined;
const plan = try zpci.resources.assignment.intoScratch(input, &plan_scratch);
// plan.assignments.len <= plan_scratch.len.
```

**Handle exhaustion:**

```zig
const plan = zpci.resources.assignment.intoScratch(input, &plan_scratch) catch |err| switch (err) {
    error.ResourceExhausted => {
        // A requirement's entire pool-preference chain was empty or too small.
        // Caller widens root windows or rejects the topology.
        return err;
    },
    error.StorageExhausted => {
        // plan_scratch was too small for sizeBound(nodes). Grow the scratch.
        return err;
    },
};
```

**Feed the plan into programming and bridge-window encoding:**

```zig
for (plan.assignments) |a| {
    switch (a.requirement.source) {
        .endpoint_bar, .endpoint_expansion_rom => {
            // resources.programming writes the base into the BAR / ROM register.
        },
        .bridge_window => {
            const encoded = try zpci.resources.bridge.encodeWindow(a);
            // resources.programming writes the encoded wire values into the type-1 window registers.
            _ = encoded;
        },
    }
}
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `intoScratch` | never | never (no I/O) | O(N × R log R) sort + O(N × M) children scan, depth ≤ `max_depth` | none | single-thread over `Input` | DFS preorder per root; §Requirement sort within each node |
| `sizeBound` | never | never | O(N) | none | pure | none |

`N = nodes.len`; `R = max requirements per node` (bounded by header layout: ≤ 7 for endpoints, ≤ 5 for bridges); `M = mean siblings under one bridge`.

Rules:

- Both operations MUST NOT allocate, retry, log, synchronize, or perform I/O.
- Both operations MUST be single-thread-safe: they take value or const-slice inputs and produce fresh outputs. Concurrent calls with disjoint inputs run independently.
- Both operations MUST be deterministic. Same inputs produce byte-identical outputs.

## Required tests (category level)

**Placement:**

- `unit:` empty `Input.roots` → `Plan.assignments.len == 0`, no error.
- `unit:` single endpoint, single `.mmio32` BAR, sufficient `root_windows.mmio32` → one `Assignment`, `pool == .mmio32`.
- `unit:` single endpoint, `.mmio64_pref` BAR, `root_windows.mmio64_pref` populated → placement in `.mmio64_pref`.
- `unit:` single endpoint, `.mmio64_pref` BAR, no `.mmio64_pref` aperture, `.mmio32_pref` populated → falls back to `.mmio32_pref`.
- `unit:` single endpoint, `.mmio64_pref` BAR, only `.mmio32` populated → falls back to `.mmio32`.
- `unit:` single endpoint, `.mmio64` BAR, only `.mmio32` populated → falls back to `.mmio32`.
- `unit:` single endpoint, `.io` BAR, no `.io` aperture → `error.ResourceExhausted`.
- `unit:` requirement sort: three `.mmio32` BARs with alignments `[4 KiB, 1 MiB, 16 KiB]` in that input order → placed in `[1 MiB, 16 KiB, 4 KiB]` order.
- `unit:` requirement sort ties: two BARs of equal alignment, sizes `[64 KiB, 16 KiB]` → placed in size-descending order.
- `unit:` requirement sort stable: two BARs of equal alignment and equal size → placed in input order.
- `unit:` deterministic: two calls with identical `Input` produce byte-identical `Plan.assignments`.

**Bridge composition:**

- `unit:` single bridge with IO window, one IO endpoint child → bridge IO window placed in parent's `.io`; endpoint IO placed inside the window's byte range.
- `unit:` bridge with memory window + prefetchable window, mixed children → both windows placed in the parent; each descendant lands inside its matching window range.
- `unit:` nested bridge (grandchild endpoint) → grandchild's base is inside the outermost bridge's window range.
- `unit:` bridge with only a prefetchable window, a `.mmio32` grandchild → grandchild fails placement (no memory sub-aperture) → `error.ResourceExhausted`.
- `unit:` bridge with `.mmio32_pref` window, `.mmio64_pref` grandchild → grandchild eligibility falls through to `.mmio32_pref`; placement succeeds inside the bridge's window range.
- `unit:` bridge whose `.mmio32_pref` window fell back to parent's `.mmio32` → `child.mmio32_pref` populated (field decided by `requirement.kind`, not `Assignment.pool`); a `.mmio32_pref` grandchild places into `child.mmio32_pref`.
- `unit:` bridge BAR present alongside window requirements → bridge BAR consumes the parent frame; the child frame reflects only the window `Assignment`s.
- `unit:` `child.mmio64` is always empty regardless of the bridge's window set → a descendant `.mmio64` requirement falls back to `child.mmio32`.
- `unit:` DFS preorder: bridge with two child bridges → `Plan.assignments` orders `[bridge0-windows, child0-subtree, child1-subtree, ...]`.
- `unit:` sibling order: two children in input slice order → assignments emitted in that order under the parent.

**Exhaustion and storage:**

- `unit:` `scratch.len < sizeBound(nodes)` for a fully-reachable tree → `error.StorageExhausted`; `scratch` unmodified.
- `unit:` `scratch.len == 0` with non-empty `nodes` → `error.StorageExhausted`.
- `unit:` a leaf endpoint requirement exhausts every eligible pool → `error.ResourceExhausted`.
- `unit:` a bridge whose own window requirement exhausts the parent → `error.ResourceExhausted` before descending.
- `unit:` `Assignment.pool` matches `requirement.kind` when the natural pool has room; records the fallback pool when it does not.

**Malformed / programmer error (assertion):**

- `malformed:` `Node.parent >= self_index` → programmer-error assertion.
- `malformed:` `Node.parent` names an endpoint → programmer-error assertion during recursion.
- `malformed:` a root's `parent != null` → programmer-error assertion.
- `malformed:` DFS depth exceeds `max_depth` → programmer-error assertion in debug builds.

## Non-goals

- Bridge-window aggregation from children (`docs/specs/resources/bridge.md`).
- Config-space writes committing a `Plan` (`docs/specs/resources/programming.md`).
- Bus-number assignment for unprogrammed bridges (`docs/specs/resources/bus.md`).
- Backtracking or multi-pass allocation. A first-pass `error.ResourceExhausted` is final.
- Best-fit or segregated-fit heuristics.
- Firmware-hint or preserve-existing-programming policy.
- Aperture-overlap detection.
- Diagnostic out-parameters.
- Reverse lookup from `Assignment` to source `Node`.
- Allocator-backed constructor (`intoAlloc`).
- Serialization of `Plan`.
- Cross-`intoScratch` merging.

## Open questions

None owned by this spec.
