# Topology tree

Defines `Tree`, the borrowed topology structure that names every present PCI/PCIe function discovered by enumeration or authored by a caller (VM emulation, tests). Owns `Node`, `NodeIndex`, `PreorderIterator`, `ChildrenIterator`, and the canonical builder `tree.intoScratch(nodes, roots)`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `Tree`, `Node`, `NodeIndex`, and both iterator types. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/bdf.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/config/ecam.md`
- `docs/specs/config/pio.md`
- `docs/specs/header/common.md`
- `docs/specs/header/type0.md`
- `docs/specs/header/type1.md`
- `docs/specs/topology/enumerate.md`
- `docs/specs/topology/bridge.md`
- `docs/specs/resources/assignment.md`
- `docs/specs/resources/bridge.md`

## Scope

Owned:

- `NodeIndex` — the `u16` index type for the tree's node array; the public constant `max_nodes`.
- `max_depth` — the public constant bounding the preorder iterator's fixed stack.
- `Node` — per-function record: caller-supplied fields (`sbdf`, borrowed `config.Function`, cached `config.HeaderKind`, `parent`) plus builder-computed link fields (`first_child`, `next_sibling`) defaulted to `null`.
- `Tree` — the borrowed structure: `nodes: []const Node`, `roots: []const NodeIndex`.
- `PreorderIterator` — DFS preorder over every root in `roots` order, subtree fully visited before moving to the next root.
- `ChildrenIterator` — direct-child iterator over one bridge's `first_child`/`next_sibling` chain.
- Lookup helpers: `node(index)`, `parentOf(index)`, `rootOfSegment(segment)`.
- `tree.intoScratch(nodes, roots)` — the canonical builder that computes `first_child`/`next_sibling` linkage and sorts `roots` in one linear pass.
- The two producer paths (enumeration and caller authoring) that share this shape.

Deferred:

- The enumeration algorithm that fills `Node`s from live hardware (`docs/specs/topology/enumerate.md`).
- Bridge bus-range/window traversal on top of `Tree` (`docs/specs/topology/bridge.md`).
- Any hardware snapshot or caching mode beyond `HeaderKind`. Nodes borrow `config.Function` and read live.
- Lookup by SBDF. Every current consumer walks the tree; a lookup helper is promoted only when a consumer needs it.
- Mutation in place. Structural changes (hot-plug add, hot-remove, re-parenting) require discarding the `Tree` and rebuilding from a fresh `[]Node`.
- Allocator-backed constructor. `Tree` is a borrowed structure; a `tree.intoAlloc` is added only when a consumer whose input size is unknowable at build time needs it, and that consumer does not yet exist.

## Producers `[zpci]`

Two paths produce a `Tree`. Both fill a `[]Node` with the caller-supplied fields and call `tree.intoScratch(nodes, roots)`:

- **Discovery** — `docs/specs/topology/enumerate.md` reads live config space, filters absent functions, orders discovered functions topologically, writes each into the next `nodes` slot (with `first_child` and `next_sibling` left at their defaults), and calls the builder over the filled prefix.
- **Authoring** — a caller (VM emulator, host test, responder-side stub) initializes a `[]Node` directly from a known topology, wraps a caller-implemented `config.ConfigSpace` (per `docs/specs/config/space.md` §Write discipline producer (6)), and calls the builder.

Rules:

- `Tree` is producer-agnostic. `Node.function` MAY carry any backing `ConfigSpace` — `Ecam`, `Pio`, a caller responder, or a byte-backed test fake. Downstream consumers MUST see one shape regardless of the producer path.
- Neither producer path is privileged in the type. The builder MUST validate topological order and compute linkage identically for both.

## `NodeIndex` `[zpci]`

```zig
pub const NodeIndex = u16;

pub const max_nodes: usize = std.math.maxInt(NodeIndex); // 65 535
pub const max_depth: u8 = 32;
```

Rules:

- `NodeIndex` is a type alias for `u16`, not a newtype wrapper. `Tree` MUST NOT mutate `nodes` after `intoScratch` returns; an index acquired at build time is therefore stable for the tree's lifetime, and callers MAY cache indices freely.
- `max_nodes` bounds one `Tree`. The upper bound covers ~8× a maximum-populated PCIe segment (256 buses × 32 devices × 8 functions = 65 536 per segment, only a small fraction populated in practice). A caller with more nodes across multiple segments still fits: `Tree` packs all segments into one `nodes` slice.
- `max_depth` bounds the `PreorderIterator`'s fixed stack. 32 is generous — PCIe bridge nesting rarely exceeds 8-16 in practice, and the entire stack is `max_depth × @sizeOf(NodeIndex)` = 64 bytes.

## `Node` `[zpci]`

```zig
pub const Node = struct {
    sbdf: core.Sbdf,
    function: config.Function,
    header_kind: config.HeaderKind,
    parent: ?NodeIndex,

    first_child: ?NodeIndex = null,
    next_sibling: ?NodeIndex = null,
};
```

Field roles:

- `sbdf`, `function`, `header_kind`, `parent` are the **caller-supplied fields**. Producers set these before calling `intoScratch`.
- `first_child` and `next_sibling` are **builder-computed fields**. Producers leave them at their default (`null`); the builder overwrites them. A caller-set value is overwritten unconditionally.

Rules:

- `sbdf` is the function's `core.Sbdf` (segment + BDF). Consumers MUST NOT expect `sbdf` to be re-read from `function` at consumption time; the two are independent fields the producer sets in lockstep.
- `function` is a borrowed `config.Function` carrying `ConfigSpace` + `Sbdf` per `docs/specs/config/space.md`. Every field access through `function` (`function.vendorId()`, `function.classCode()`, `function.read16(offset)`) MUST read live through the backing accessor.
- `header_kind` is the sole cached decoded field, a two-variant enum (`.type0`, `.type1`) per `docs/specs/config/space.md` §HeaderKind. Caching is safe because PCIe does not permit runtime mutation of the header-type value for a given function slot. Consumers MAY read `header_kind` freely without a config-space access; the alternative (re-reading `function.headerKind()` per visit) costs one config read per node-touch on the hot path.
- `parent`, when non-null, MUST satisfy `parent < self_index`. The builder enforces this on input and returns `error.InvalidTopology` on violation. Callers MAY rely on the invariant after `intoScratch` returns.
- After `intoScratch` returns: `first_child`, when non-null, MUST point to the lowest-index child of this node. Endpoints (`header_kind == .type0`) MUST have `first_child == null`; only bridges (`header_kind == .type1`) MAY have `first_child != null`. `next_sibling`, when non-null, MUST point to the next sibling under the same parent in `(bus, device, function)` ascending order.
- Producers MUST order sibling nodes so that siblings of a common parent appear in `(bus, device, function)` ascending input order. Discovery (`docs/specs/topology/enumerate.md`) emits nodes in DFS order (each subtree contiguously after its root); this satisfies the sibling-order rule. Authoring paths MUST match the sibling-order rule to obtain the intended sibling ordering; the global order of unrelated subtrees is not constrained.
- No decoded field other than `header_kind` is cached. Vendor ID, device ID, class code, BAR values, capability lists, PCIe capability version, and every writable register MUST be read live through `function.*` methods.

## Root set `[zpci]`

`Tree.roots` names one `NodeIndex` per root — an entry in `nodes` whose `parent == null`.

Rules:

- A root is any node with `parent == null`. Discovery typically produces one root per populated segment; authoring MAY produce multiple roots per segment (multi-domain root complex) or one root across multiple segments.
- `Tree.roots` MUST be ordered ascending by root's `sbdf` — specifically, by `(segment_id, bus, device, function)`. The builder sorts.
- A segment with no present functions MUST NOT contribute a root entry. `Tree.roots.len` MUST satisfy `Tree.roots.len ≤ Tree.nodes.len`.
- The builder MUST NOT synthesize a virtual root above segments. Multiple roots is the canonical shape.

## `tree.intoScratch(nodes, roots)` `[zpci]`

The canonical builder. Reads caller-supplied fields on every `nodes[i]`, computes `first_child`/`next_sibling` linkage in one linear pass, and populates `roots`.

```zig
pub const Error = error{
    StorageExhausted,
    InvalidTopology,
};

pub fn intoScratch(
    nodes: []Node,
    roots: []NodeIndex,
) Error!Tree;
```

Behavior:

1. If `nodes.len > max_nodes`, return `error.StorageExhausted`. `nodes` and `roots` are not modified.
2. Count roots: `root_count = count of nodes[i] where nodes[i].parent == null`. If `roots.len < root_count`, return `error.StorageExhausted`. `nodes` and `roots` are not modified.
3. Validate topological order: for each `nodes[i]` with `parent != null`, check `nodes[i].parent.? < i`. On violation, return `error.InvalidTopology`. `nodes` and `roots` are not modified.
4. Zero the link fields: for each `nodes[i]`, set `first_child = null` and `next_sibling = null` (overwriting any caller-supplied values).
5. Compute linkage in a single reverse pass over `nodes`: for `i` from `nodes.len - 1` down to `0`, if `nodes[i].parent` is `p`, set `nodes[i].next_sibling = nodes[p].first_child; nodes[p].first_child = i`. This produces `first_child`/`next_sibling` chains in ascending input order under each parent (the reverse pass front-inserts, and reverse-of-reverse restores forward order).
6. Populate `roots`: linear scan over `nodes`; append every index where `parent == null`. The scan preserves input order, which is already `(segment_input, bus, device, function)` ascending by producer contract.
7. Return `Tree{ .nodes = nodes[0..], .roots = roots[0..root_count] }`.

Rules:

- Complexity is `O(nodes.len)`. `intoScratch` MUST NOT allocate, perform I/O, or read config space.
- The returned `Tree` borrows both `nodes[0..]` and `roots[0..root_count]` from the caller's scratch slices. Callers MUST keep both slices live for the entire lifetime of the returned `Tree`.
- The caller MUST supply `roots` with `len >= root_count`. A safe upper bound is `nodes.len` (worst case: every function is its own root, a degenerate but legal topology). A tight bound is the count of `nodes[i]` where `parent == null`, computable in one linear pass by the caller.
- On any returned error, `intoScratch` MUST NOT modify `nodes` or `roots`.
- The builder overwrites `first_child` and `next_sibling` on every `nodes[i]`. Caller-supplied values in those fields are ignored; producers SHOULD leave them at the `null` default.
- The caller sizes `nodes` to the exact function count. Enumeration paths that over-allocate scratch during discovery slice down (`nodes[0..count]`) before calling `intoScratch`.

`intoScratch` returns `Error!Tree` because `StorageExhausted` and `InvalidTopology` are decided purely from inputs (no I/O). Naming per `docs/guidelines/conventions.md` §Constructors: `intoScratch` for scratch-backed collection producers.

## `Tree` `[zpci]`

```zig
pub const Tree = struct {
    nodes: []const Node,
    roots: []const NodeIndex,

    pub fn node(self: *const Tree, index: NodeIndex) *const Node;
    pub fn parentOf(self: *const Tree, index: NodeIndex) ?NodeIndex;
    pub fn rootOfSegment(self: *const Tree, segment: core.SegmentId) ?NodeIndex;

    pub fn preorder(self: *const Tree) PreorderIterator;
    pub fn preorderFrom(self: *const Tree, root: NodeIndex) PreorderIterator;
    pub fn children(self: *const Tree, bridge: NodeIndex) ChildrenIterator;
};
```

Rules:

- `node(index)` returns a pointer into `self.nodes` and asserts `index < self.nodes.len`. Callers MUST NOT pass an index past the tree's length; a violation is a programmer error caught by the assertion in debug builds.
- `parentOf(index)` returns `self.node(index).parent`. It asserts the same bound as `node`.
- `rootOfSegment(segment)` returns the first `roots[i]` whose `self.nodes[roots[i]].sbdf.segment == segment`, or `null` if no root exists for that segment. The lookup MUST be a linear scan over `self.roots`; no hash index is maintained.
- `preorder()` returns a `PreorderIterator` visiting every root in `self.roots` order. Each subtree MUST be fully visited before the iterator advances to the next root.
- `preorderFrom(root)` returns a `PreorderIterator` scoped to the subtree rooted at `root` and asserts `root < self.nodes.len`.
- `children(bridge)` returns a `ChildrenIterator` over the direct-child chain of `bridge`. Callers MUST NOT pass an endpoint; `children` asserts both `bridge < self.nodes.len` and `self.node(bridge).header_kind == .type1`.

`Tree` is a value type. Copies share the same borrowed slices; the underlying `nodes` and `roots` storage is owned by whatever produced them (the caller's scratch through `intoScratch`, or downstream storage the caller manages).

## `PreorderIterator` `[zpci]`

DFS preorder over one or more subtrees, using a fixed-capacity stack of `NodeIndex` values. No allocation.

```zig
pub const PreorderIterator = struct {
    tree: *const Tree,
    stack: [max_depth]NodeIndex,
    depth: u8,
    next_root: u16, // index into tree.roots; only used when iterating all roots
    single_root: bool, // true when constructed by preorderFrom

    pub const Item = struct { index: NodeIndex, node: *const Node };

    pub fn next(self: *PreorderIterator) ?Item;
};
```

Behavior:

- `next(self)` returns the next `Item{ .index, .node }` in DFS preorder, or `null` when the walk is exhausted.
- `preorder()`-produced iterators: on the first call, push `tree.roots[0]` and return `Item{ .index = tree.roots[0], .node = &tree.nodes[tree.roots[0]] }`. On each subsequent call, prefer descending to `first_child`; on a leaf, ascend via the stack and follow `next_sibling`; when the current subtree exhausts and `next_root < tree.roots.len`, push the next root and continue.
- `preorderFrom(root)`-produced iterators: same, but the walk terminates when the initial subtree exhausts; further roots are not visited.
- The internal stack holds ancestors of the current node from the current subtree's root down to (but not including) the current node. Depth MUST NOT exceed `max_depth`; a topology exceeding that bound is a programmer error and is enforced by assertion.

Rules:

- The iterator MUST NOT perform I/O. Every step is pointer arithmetic and stack manipulation.
- The iterator is single-thread. Two concurrent iterators over the same `Tree` MAY run independently, and each MUST hold its own stack.
- Any mutation of the underlying `nodes` slice invalidates the iterator. `Tree` publishes no mutation API; callers that reuse scratch across builds MUST discard the previous iterator before writing new nodes.

## `ChildrenIterator` `[zpci]`

Direct-child iterator over one bridge's `first_child`/`next_sibling` chain.

```zig
pub const ChildrenIterator = struct {
    tree: *const Tree,
    cursor: ?NodeIndex,

    pub const Item = PreorderIterator.Item;

    pub fn next(self: *ChildrenIterator) ?Item;
};
```

Behavior:

- `next(self)` returns `Item{ .index = cursor.?, .node = &tree.nodes[cursor.?] }`, advances `cursor` to `node.next_sibling`, and returns the item. Returns `null` when `cursor == null`.
- The iterator yields direct children only, in ascending `(bus, device, function)` order (the builder produces this order per §`tree.intoScratch`).

Rules:

- Constant space. `ChildrenIterator` MUST NOT allocate or maintain a stack.
- Single-thread; two concurrent `ChildrenIterator`s over the same bridge MAY run independently.
- Same invalidation contract as `PreorderIterator`: any mutation of the underlying `nodes` slice invalidates the iterator. Callers MUST NOT dereference an invalidated iterator.

## Errors

`Tree` and its iterators produce no typed errors.

- `tree.intoScratch` returns `error.StorageExhausted` and `error.InvalidTopology`; both MUST be decided from inputs alone without I/O.
- Index-bounds violations on `node`, `parentOf`, `rootOfSegment`, `preorderFrom`, and `children` are programmer errors and MUST be enforced by assertion rather than returned as typed errors, per `docs/specs/config/space.md` §Validation vs assertion.
- Passing an endpoint to `children` is a programmer error and MUST be enforced by assertion.
- Hardware read errors surface from `Node.function.*` calls the caller makes. Iterator methods MUST NOT read hardware and MUST NOT return `ConfigSpace.Error` variants.

`Tree` and iterator methods MUST NOT synthesize `zpci.Error` variants. The type-local `Error` set is `tree.Error = error{ StorageExhausted, InvalidTopology }`.

## Wire / layout invariants

None. `Tree`, `Node`, and both iterators are semantic types. `Node` is a plain struct (not `extern`); `config.Function` inside it is a borrowed handle.

Compile-time size assertions:

```zig
comptime {
    std.debug.assert(@sizeOf(NodeIndex) == 2);
    std.debug.assert(max_nodes == 65_535);
}
```

`@sizeOf(Node)` depends on the runtime representation of `config.Function`.

## View / borrowing behavior

- `Tree` borrows `nodes: []const Node` and `roots: []const NodeIndex` from the caller's scratch. Callers MUST keep both slices live for the entire lifetime of the returned `Tree`.
- `Node.function` is a borrowed `config.Function` that transitively borrows `ConfigSpace`. `Node.function` MUST NOT be used after the accessor's lifetime ends.
- The tree caches `HeaderKind` (fixed for the function slot). The tree MUST NOT cache any other decoded field; every hardware fact other than `HeaderKind` MUST be read live through `Node.function`.
- Every method of `Tree`, `PreorderIterator`, and `ChildrenIterator` MUST NOT allocate, retry, synchronize, or perform I/O.

## zstdx usage

Direct usage: none.

The tree owns bounded stack-sized iterator state (`[max_depth]NodeIndex` = 64 bytes) and borrows caller scratch. Neither pattern needs `zstdx.bits.BitSet`, `zstdx.core.Range`, or `zstdx.bytes.*`. `config.Function` handles all hardware reads through its own `ConfigSpace` seam.

## Facade re-export `[zpci]`

`src/topology.zig`:

```zig
pub const tree = @import("topology/tree.zig");
```

Callers reach the public surface as `zpci.topology.tree.Tree`, `zpci.topology.tree.Node`, `zpci.topology.tree.NodeIndex`, `zpci.topology.tree.PreorderIterator`, `zpci.topology.tree.ChildrenIterator`, `zpci.topology.tree.intoScratch`.

## Usage

**Discovery — zfw / firmware / kernel probing real hardware.** `topology.enumerate.intoScratch` fills a scratch `[]Node` from live config space, slices it to the actual function count, and calls the tree builder:

```zig
var ecam = try zpci.config.Ecam.from(&segments);

var nodes: [256]zpci.topology.tree.Node = undefined;
var roots: [8]zpci.topology.tree.NodeIndex = undefined;

const tree = try zpci.topology.enumerate.intoScratch(.{
    .config = ecam.configSpace(),
    .segments = &segments,
    .nodes = &nodes,
    .roots = &roots,
});

var it = tree.preorder();
while (it.next()) |item| {
    switch (item.node.header_kind) {
        .type0 => {
            // endpoint: size BARs, decode capabilities
            const view = zpci.bar.View.init(item.node.function, .type0);
            _ = view;
        },
        .type1 => {
            // bridge: iterate direct children for window aggregation
            var kids = tree.children(item.index);
            while (kids.next()) |child| { _ = child; }
        },
    }
}
```

**Authoring — zvm / VM emulating a PCIe topology.** The caller implements `config.ConfigSpace`, initializes `Node`s directly (leaving `first_child`/`next_sibling` at their `null` defaults), and calls the tree builder:

```zig
// vm_config implements zpci.config.ConfigSpace via producer (6) in config/space.md.
const cs: zpci.config.ConfigSpace = vm_config.configSpace();

var nodes = [_]zpci.topology.tree.Node{
    // Root bridge: virtual host-to-PCI bridge at 0000:00:00.0
    .{
        .sbdf = zpci.core.Sbdf.of(0, 0, 0, 0),
        .function = zpci.config.Function.unchecked(cs, zpci.core.Sbdf.of(0, 0, 0, 0)),
        .header_kind = .type1,
        .parent = null,
    },
    // Virtio-net endpoint under the root bridge
    .{
        .sbdf = zpci.core.Sbdf.of(0, 0, 1, 0),
        .function = zpci.config.Function.unchecked(cs, zpci.core.Sbdf.of(0, 0, 1, 0)),
        .header_kind = .type0,
        .parent = 0,
    },
    // Virtio-blk endpoint under the root bridge
    .{
        .sbdf = zpci.core.Sbdf.of(0, 0, 2, 0),
        .function = zpci.config.Function.unchecked(cs, zpci.core.Sbdf.of(0, 0, 2, 0)),
        .header_kind = .type0,
        .parent = 0,
    },
};

var roots: [1]zpci.topology.tree.NodeIndex = undefined;
const tree = try zpci.topology.tree.intoScratch(&nodes, &roots);

// VM stop-all: iterate every emulated device.
var it = tree.preorder();
while (it.next()) |item| { _ = item; }
```

**Structural change (hot-plug in either consumer).** Rebuild the tree; `Tree` publishes no mutation API.

```zig
// Add a device. Old tree is invalidated once new_nodes overwrites the scratch.
const new_tree = try zpci.topology.tree.intoScratch(&new_nodes, &roots);
_ = new_tree;
```

**Direct children of a bridge.** Bridge-window aggregation walks each bridge once.

```zig
var kids = tree.children(bridge_index);
while (kids.next()) |child| {
    // aggregate child's requirements into the bridge window
    _ = child;
}
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `intoScratch` | never | never | O(nodes.len) validation + O(nodes.len) linkage + O(nodes.len) root scan | none | pure over inputs | topological input order |
| `node` / `parentOf` | never | never | O(1) index bounds asserted | none | pure lookup | none |
| `rootOfSegment` | never | never | O(roots.len) linear scan | none | pure | roots order |
| `preorder` / `preorderFrom` / `children` | never | never | O(1) construction | none | pure | traversal order defined above |
| `PreorderIterator.next` | never | never | O(1) amortized; `max_depth` stack | ends when exhausted | single-thread | preorder |
| `ChildrenIterator.next` | never | never | O(1) | ends when exhausted | single-thread | child-list order |

Beyond `HeaderKind` copied at build time, methods MUST NOT introduce hidden caching, retry, logging, or diagnostics. The builder is deterministic: the same `nodes` input MUST produce the same `Tree` shape and iteration order.

## Required tests (category level)

- `unit:` empty nodes → `nodes.len == 0`, `roots.len == 0`, `preorder().next() == null`.
- `unit:` one root endpoint → one node, one root, `preorder()` yields it once.
- `unit:` bridge with two endpoint children → `preorder()` yields bridge, child A, child B in input order.
- `unit:` nested bridges → preorder yields parent bridge, child bridge, grandchild endpoints, then continues with the next sibling.
- `unit:` `children(bridge)` yields direct children only, not grandchildren.
- `unit:` `preorderFrom(subtree)` skips siblings and their descendants outside the subtree.
- `unit:` `rootOfSegment` returns the correct index for a populated segment and `null` for a segment with no roots.
- `unit:` `Tree.roots` is ordered by `(segment, bus, device, function)`.
- `unit:` multi-segment tree: two segments, each with a bridge and endpoints — two roots, per-segment locality preserved.
- `unit:` `Node` with `parent == self_index` → `error.InvalidTopology` (builder catches; not a programmer-error assertion because the builder validates inputs before touching them).
- `unit:` `Node` with `parent > self_index` (out of topological order) → `error.InvalidTopology`.
- `unit:` `nodes.len > max_nodes` → `error.StorageExhausted`, scratch untouched.
- `unit:` `roots.len < root_count` → `error.StorageExhausted`, scratch untouched.
- `unit:` caller-supplied `first_child` / `next_sibling` values are ignored (builder overwrites unconditionally).
- `unit:` authoring path with a responder-side `ConfigSpace` produces the same `Tree` shape as discovery over an equivalent byte-backed fake.
- `layout:` `NodeIndex` is exactly 2 bytes; `max_nodes` is 65 535; `max_depth` is 32.
- `malformed:` `children` on an endpoint node → programmer-error assertion (not a typed test).
- `malformed:` `node(index)` with `index >= nodes.len` → programmer-error assertion.

## Non-goals

- The enumeration algorithm that walks live config space and produces `Node` slots (`docs/specs/topology/enumerate.md`).
- Bridge bus-range or window traversal on top of `Tree` (`docs/specs/topology/bridge.md`).
- Any config-space I/O inside `Tree` or its iterators. Reads happen only through `Node.function` calls the caller makes.
- Snapshot or caching modes beyond `HeaderKind`.
- Mutation of the tree post-construction. Adding, removing, or re-parenting nodes requires discarding the tree and rebuilding.
- Lookup by SBDF.
- Serialization or deep copy of `Tree`.
- Allocator-backed constructor (`intoAlloc`). All current consumers know upper bounds at build time.
- Cross-`Tree` merging.
- Diagnostic out-parameters.

## Open questions

None owned by this spec.
