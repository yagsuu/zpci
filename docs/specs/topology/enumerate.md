# Topology enumerate

Defines `topology.enumerate.intoScratch`, the read-only walk over caller-supplied ECAM/PIO segments that discovers every present PCI/PCIe function, fills a caller-supplied `[]tree.Node` scratch, and returns an assembled `tree.Tree`. Owns the multi-segment scan policy, the bridge-recursion policy, the multifunction and ARI probes, and the emission order.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on the enumeration algorithm, the ARI gating rule, the bridge-recursion validity rule, and the DFS emission order. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/bdf.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/config/ecam.md`
- `docs/specs/config/pio.md`
- `docs/specs/header/common.md`
- `docs/specs/header/type1.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/capabilities/pcie.md`
- `docs/specs/topology/tree.md`
- `docs/specs/topology/bridge.md`
- `docs/specs/resources/programming.md`

## Scope

Owned:

- `intoScratch(input) Error!tree.Tree` — the enumeration entry point.
- `Input` — the argument struct carrying `config`, `segments`, and the two scratch slices.
- `sizeBound(segments) usize` — upper-bound helper for sizing the `nodes` scratch.
- Multi-segment scan policy: all segments visited in one call, one `tree.Tree` returned covering all populated segments.
- Bridge recursion policy: follow the firmware-programmed `secondary_bus_number` iff it satisfies the validity rule; otherwise emit the bridge node without descending.
- Multifunction discovery policy: probe function 0 first; probe functions 1..7 only when the header-type multifunction bit is set.
- ARI-aware function-space policy: on buses whose parent bridge has PCIe `DeviceControl2.ari_forwarding_enable` set, walk `0..256` functions on device 0 only.
- Absent-function handling: `vendor_id == 0xFFFF` is a normal skip, not an error.
- Unsupported-header handling: type-2 (CardBus) is skipped without emitting a node.
- Depth bounding at `tree.max_depth`.
- Emission order: DFS from each segment's `bus_start`, per-device multifunction walk, bridge subtrees emitted contiguously after their bridge root.

Deferred:

- Bus-number assignment for bridges whose `secondary_bus_number` is unprogrammed (`docs/specs/resources/bus.md`).
- BAR sizing on discovered functions (`docs/specs/bar.md`); called by consumers on emitted nodes.
- Bridge-window aggregation (`docs/specs/resources/bridge.md`).
- Any config-space writes.
- Hot-plug detection after `intoScratch` returns; consumers rebuild the tree.
- Type-2 CardBus header decode (no zpci consumer).
- Firmware-hint preservation across enumeration.
- Allocator-backed constructor (`intoAlloc`); the scratch upper bound is knowable via `sizeBound`.
- Diagnostic out-parameters listing skipped functions (per `docs/specs/core/errors.md` §Non-goals).

## Public surface `[zpci]`

```zig
const tree = @import("tree.zig");

pub const Node = tree.Node;
pub const NodeIndex = tree.NodeIndex;

pub const Error = tree.Error || ConfigSpace.Error;

pub const Input = struct {
    config: config.ConfigSpace,
    segments: []const config.Segment,
    nodes: []Node,
    roots: []NodeIndex,
};

pub fn intoScratch(input: Input) Error!tree.Tree;
pub fn sizeBound(segments: []const config.Segment) usize;
```

Rules:

- `Input` groups the four parameters (config accessor, segments, node scratch, root scratch). Callers construct it as a struct literal at the callsite.
- `intoScratch` returns `Error!tree.Tree`. On success, the returned `Tree` borrows `input.nodes[0..count]` and `input.roots[0..root_count]`; callers MUST keep both slices live for the tree's lifetime.
- `sizeBound(segments)` returns a caller-safe upper bound on `nodes.len`. `roots` MAY be sized to the same bound; a tight `roots` bound is one per populated segment, but callers rarely precompute populated-segment counts.
- The `Error` set unions `tree.Error` (`StorageExhausted`, `InvalidTopology`) with `ConfigSpace.Error` (`OutOfBounds`, `UnsupportedAccessWidth`, `UnalignedAccess`). `InvalidTopology` cannot arise in practice because enumeration emits `parent < self_index` by construction; it appears in the union because `tree.intoScratch` may in principle return it.
- `AbsentFunction` and `BadHeaderType` are caught internally and translated into "skip this function." They MUST NOT surface from `intoScratch`.

## Multi-segment scan `[zpci]`

`intoScratch` visits every segment in `input.segments` in slice order, in one call, and returns one `tree.Tree` covering all populated segments.

Rules:

- Segments MUST be visited in `input.segments` slice order. Emission order within one segment follows §Emission order.
- A segment with no present functions MUST contribute zero nodes. `tree.Tree.roots` names one entry per **populated** segment.
- A single-segment caller supplies a length-1 slice.
- Cross-segment ordering in `tree.Tree.roots` is decided by `tree.intoScratch`, which sorts by `(segment_id, bus, device, function)`. This spec does not resort.

## Multifunction discovery `[zpci]`

For every `(bus, device)` pair enumerate visits, it probes function 0 first. Sibling functions 1..7 are probed only when the multifunction bit is set on the header-type byte at offset `0x0E` of function 0.

Rules:

- Enumeration MUST call `config.Function.validate(config, Sbdf.of(seg, bus, device, 0))` before probing any function `> 0` on that device.
- `AbsentFunction` from function 0 MUST cause the whole device to be skipped; functions 1..7 MUST NOT be probed.
- `BadHeaderType` from function 0 MUST cause the whole device to be skipped; functions 1..7 MUST NOT be probed. (Type-2 CardBus is the practical case; behavior is the same for any unknown header type.)
- After successfully validating function 0, enumeration MUST read `Function.isMultifunction()` (bit 7 of the header-type byte). This value MAY be cached from the same read that produced `header_kind`; the implementation SHOULD combine both.
- If the multifunction bit is clear, enumeration MUST NOT probe functions 1..7 on that device.
- If the multifunction bit is set, enumeration MUST probe functions 1..7 in ascending order. Each probe is a separate `Function.validate`. `AbsentFunction` on a sibling MUST cause that function to be skipped without affecting later siblings.
- `BadHeaderType` on a sibling MUST cause that function to be skipped without affecting later siblings.

## ARI-aware function-space `[std]`

PCIe defines Alternative Routing-ID Interpretation (ARI): when the parent bridge has `DeviceControl2.ari_forwarding_enable` set, the downstream bus uses a flat 8-bit function-space on device 0 only. Devices 1..31 do not exist in ARI mode.

Rules:

- ARI mode applies to a **child bus** based on the **parent bridge's** capability. Root buses (no parent bridge) MUST use classic mode.
- Before recursing from a bridge into its `secondary_bus_number`, enumeration MUST determine ARI mode for the child bus by inspecting the bridge's PCIe capability:
  - Walk the bridge function's standard capability list per `docs/specs/capabilities/list.md`.
  - If a PCI Express capability (`id == 0x10`) is present and the bridge is v2+ (per `docs/specs/capabilities/pcie.md` §Version rules), read `DeviceControl2` at capability offset `+0x28`.
  - `ari_forwarding_enable` is bit 5 of `DeviceControl2` per `docs/specs/capabilities/pcie.md`.
- If the bridge has no PCIe capability, or the PCIe capability is v1 only, or the capability list is malformed, enumeration MUST fall back to classic mode for the child bus without propagating the error. Config-space read failures during ARI detection still propagate per §Errors.
- In ARI mode on a child bus: enumeration MUST probe `(bus, 0, 0..256)` and MUST NOT probe devices `1..31`. Functions 1..255 in ARI mode are siblings under a common device-0 record; no separate "multifunction bit" is consulted (ARI removes that gating).
- In classic mode: enumeration probes `(bus, 0..32, 0)` then §Multifunction discovery on each present device.

## Bridge recursion `[zpci]`

For each type-1 (PCI-to-PCI bridge) function enumeration discovers, it reads `secondary_bus_number` and `subordinate_bus_number` from the bridge's type-1 header (offsets `0x19` and `0x1A` per `docs/specs/header/type1.md`). Recursion into the downstream bus proceeds only when the bridge's programmed bus numbers satisfy the validity rule below.

Rules:

- Enumeration MUST emit the bridge node before deciding recursion. The bridge node exists in `Tree.nodes` regardless of whether its downstream is walked.
- Recursion into `secondary_bus` MUST proceed iff ALL of:
  1. `secondary_bus != 0` (a value of `0` means the bridge is unprogrammed);
  2. `secondary_bus > current_bus` (loop guard; a bridge on bus `N` cannot forward to bus `≤ N`);
  3. `secondary_bus <= current_segment.bus_end` (containment in the segment aperture);
  4. `secondary_bus <= subordinate_bus_number` (the bridge claims to forward to at least this bus).
- When any condition fails, enumeration MUST NOT recurse into `secondary_bus`. The bridge is emitted; its downstream is absent from the tree. This is the "unprogrammed bridge" case; downstream discovery requires `docs/specs/resources/bus.md` to program bus numbers, followed by re-enumeration.
- `ConfigSpace.Error` from the bus-number reads MUST propagate.
- Recursion depth MUST NOT exceed `tree.max_depth`. In debug builds a violation is a programmer-error assertion. In release builds, exceeding the bound MUST cause the over-depth subtree to be skipped without returning an error; enumeration continues with the next sibling.
- Enumeration MUST NOT perform any config-space writes during bridge recursion.

## Emission order `[zpci]`

Emission is DFS from each segment's `bus_start`. For each segment, in `input.segments` slice order:

1. Walk `seg.bus_start` with `parent = null`, `depth = 0`, `ari_mode = false`.
2. Within one bus walk (ARI or classic; see §ARI-aware function-space and §Multifunction discovery), functions are probed in ascending order. Each emitted function's node is written to the next scratch slot. If the function is a bridge and the bridge's `secondary_bus` is valid per §Bridge recursion, the recursive walk into that secondary bus emits its subtree contiguously after the bridge node.

Consequences:

- Siblings under a common parent bridge appear contiguously in bus/device/function ascending order when no bridge descendant separates them. When a sibling is itself a bridge, its descendants are emitted between it and the next sibling; the next sibling still satisfies `next_sibling` linkage per `docs/specs/topology/tree.md` because `tree.intoScratch` links siblings by `parent` regardless of the interposing descendants.
- Root-bus siblings from different segments are separated by their subtrees. `tree.intoScratch` sorts `Tree.roots` by `(segment_id, bus, device, function)`; global root ordering is decided there, not here.
- `parent < self_index` holds by DFS construction: a child is emitted only during recursion from its parent, after the parent's slot is claimed.

## Algorithm `[zpci]`

`intoScratch(input)` behavior:

1. Initialize `count: usize = 0`.
2. For each `seg` in `input.segments` (slice order): call `walkBus(seg, seg.bus_start, parent = null, depth = 0, ari_mode = false)`.
3. Call `tree.intoScratch(input.nodes[0..count], input.roots)` and return its result.

`walkBus(seg, bus, parent, depth, ari_mode)` behavior:

1. Assert `depth < tree.max_depth` in debug. In release, if `depth >= tree.max_depth`, return without walking.
2. If `ari_mode`:
   1. For `f` in `0..256`:
      1. Call `emit(seg, bus, device = 0, function = f, parent, depth)`. If it returns `error.StorageExhausted`, propagate.
3. Else (classic mode):
   1. For `d` in `0..32`:
      1. Call `probe(seg, bus, d, function = 0, parent, depth)`:
         - Let `res = Function.validate(input.config, Sbdf.of(seg.segment, bus, d, 0))`.
         - On `error.AbsentFunction` or `error.BadHeaderType`: return without emitting.
         - On `ConfigSpace.Error`: propagate.
         - Otherwise: proceed to §emit-and-recurse below, treating the validated function as `(d, 0)`.
      2. If `probe` emitted a function-0 node and its header-type byte has the multifunction bit set: for `f` in `1..8`, call `emit(seg, bus, device = d, function = f, parent, depth)`. Skips on `AbsentFunction` / `BadHeaderType`; propagate `ConfigSpace.Error`.

`emit(seg, bus, device, function, parent, depth)` behavior:

1. Let `sbdf = Sbdf.of(seg.segment, bus, device, function)`.
2. Let `res = Function.validate(input.config, sbdf)`.
3. On `error.AbsentFunction` or `error.BadHeaderType`: return without emitting.
4. On `ConfigSpace.Error`: propagate.
5. Otherwise:
   1. If `count == input.nodes.len`, return `error.StorageExhausted`.
   2. Let `my_idx = count`.
   3. Set `input.nodes[my_idx] = .{ .sbdf = sbdf, .function = res, .header_kind = res.headerKind() catch unreachable, .parent = parent }`. The `catch unreachable` is safe because `Function.validate` already accepted the header-type byte.
   4. `count += 1`.
   5. If `input.nodes[my_idx].header_kind == .type1`:
      1. Read `secondary_bus = res.read8(0x19)` and `subordinate_bus = res.read8(0x1A)`. Propagate `ConfigSpace.Error`.
      2. If §Bridge recursion validity holds for `(bus, secondary_bus, subordinate_bus, seg)`:
         - Determine `child_ari_mode = try ariForwardingEnabled(res)`; `ariForwardingEnabled` translates malformed-list cases to `false` but propagates `ConfigSpace.Error`.
         - Call `walkBus(seg, secondary_bus, parent = my_idx, depth = depth + 1, ari_mode = child_ari_mode)`.

`ariForwardingEnabled(bridge_function)` behavior:

1. Walk the bridge's standard capability list via `capabilities.list.Iterator.validate(bridge_function)`. Propagate `ConfigSpace.Error`; treat `MalformedCapability` as "no ARI" and return `false`.
2. For each `Capability`, check `idTag() == .pci_express`. Skip others.
3. On the first PCIe capability found:
   1. Read `Capabilities` at `cap.offset + 0x02` as a `u16`. Propagate `ConfigSpace.Error`.
   2. Let `version = bits [3:0]` of that value.
   3. If `version < 2`, return `false` (no `DeviceControl2` register).
   4. Read `DeviceControl2` at `cap.offset + 0x28` as a `u16`. Propagate `ConfigSpace.Error`.
   5. Return `(DeviceControl2 >> 5) & 1 == 1` (bit 5 = `ari_forwarding_enable`).
4. If the list ends without a PCIe capability, return `false`.

Rules:

- The recursive `walkBus`/`emit` pair reads config space through `input.config` and never writes.
- `emit` MUST NOT write to `input.nodes[i].first_child` or `input.nodes[i].next_sibling`; those fields are computed by `tree.intoScratch`.
- The final call `tree.intoScratch(input.nodes[0..count], input.roots)` performs bounds and topological-order checks; enumeration relies on it for `StorageExhausted` on `input.roots.len` insufficiency.
- Determinism: with a stable `ConfigSpace` snapshot, the same `input` produces the same `Tree`.

## `sizeBound` `[zpci]`

`sizeBound(segments)` returns an upper bound on the `nodes.len` a caller must supply to `intoScratch` for the given segment list.

```zig
pub fn sizeBound(segments: []const config.Segment) usize {
    var total: usize = 0;
    for (segments) |seg| {
        const bus_count: usize = @as(usize, seg.bus_end) - @as(usize, seg.bus_start) + 1;
        total = @min(total + bus_count * 256, tree.max_nodes);
        if (total == tree.max_nodes) break;
    }
    return total;
}
```

Rules:

- The `* 256` per bus covers both function-space shapes: classic `32 devices × 8 functions = 256` and ARI `1 device × 256 functions = 256`. Whichever mode a bus uses, the per-bus slot cap is 256.
- The result is capped at `tree.max_nodes` (`65 535`). Segments whose sum exceeds the cap MUST be sized to the cap; further recursion into over-cap subtrees returns `StorageExhausted` from `emit`.
- `sizeBound` is `comptime`-callable when `segments` is `comptime`-known, so consumers MAY use it in `var nodes: [sizeBound(&segments)]Node = undefined;` when the segment set is compile-time-known.
- `sizeBound` is an upper bound, not a tight bound. The actual `count` is typically much smaller; unused scratch is trimmed by `tree.intoScratch` returning `nodes[0..count]`.
- Callers MAY size `roots` to `sizeBound(segments)` as well; the tight bound (one per populated segment) requires knowing which segments are populated, which enumeration itself decides. A safe over-allocation is fine — `tree.intoScratch` returns `roots[0..root_count]`.

## Errors

`Error` is the type-local set:

```zig
pub const Error = tree.Error || ConfigSpace.Error;
```

Expanded: `error{ StorageExhausted, InvalidTopology, OutOfBounds, UnsupportedAccessWidth, UnalignedAccess }`.

Variant sourcing:

- `StorageExhausted` — `input.nodes.len` insufficient during emission, or `input.roots.len` insufficient at `tree.intoScratch` time.
- `InvalidTopology` — not returned in practice; present in the union because `tree.intoScratch` may return it.
- `OutOfBounds`, `UnsupportedAccessWidth`, `UnalignedAccess` — propagate from `input.config.readN` when the backend reports a real I/O failure.

Rules:

- `AbsentFunction` MUST be caught internally and translated into "skip this function." Enumeration MUST NOT surface it.
- `BadHeaderType` MUST be caught internally and translated into "skip this function." Enumeration MUST NOT surface it.
- `MalformedCapability` from `ariForwardingEnabled` MUST be caught internally and translated into `ari_forwarding_enable = false`. Enumeration MUST NOT surface it.
- `ConfigSpace.Error` from any config read MUST propagate, including reads during ARI detection when the underlying accessor fails (as distinct from a merely malformed capability list, which is handled).
- On any propagated error, `input.nodes` up to the failing emission slot MAY contain valid data; callers MUST NOT interpret the partial contents. The returned `Tree` value is invalid.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `intoScratch` | never | backend-defined non-sleeping I/O; O(N) config reads worst case | O(N) emission + O(N) `tree.intoScratch` linkage; depth `≤ tree.max_depth` | none | single-thread over one `ConfigSpace` | DFS emission per segment; roots sorted by `tree.intoScratch` |
| `sizeBound` | never | never | O(segments.len) | none | pure | none |

Rules:

- Enumeration MUST NOT allocate, retry, log, or synchronize.
- Enumeration MUST run in a single caller thread with a single `ConfigSpace`. Concurrent enumeration of the same segments through different accessors is caller policy; this spec makes no guarantees about interleaved config reads.
- Enumeration MUST NOT introduce hidden caching. Every hardware fact consumed by consumers on the returned `Tree` (vendor id, class code, BARs, capabilities) MUST be read live through `Node.function` per `docs/specs/topology/tree.md` §Node.

## Wire / layout invariants

None. `enumerate` owns no wire types. Every bit-level layout it consumes is already owned by `docs/specs/header/common.md` (header-type byte, multifunction bit), `docs/specs/header/type1.md` (bus-number fields), and `docs/specs/capabilities/pcie.md` (`Capabilities.version`, `DeviceControl2.ari_forwarding_enable`). Reads MUST go through the accessor and specs above; enumeration does not restate the bit positions.

## View / borrowing behavior

- `Input.config` is a borrowed `ConfigSpace` handle; enumeration MUST NOT retain it past return.
- `Input.segments` is a borrowed slice; enumeration MUST NOT retain it past return.
- `Input.nodes` and `Input.roots` are borrowed scratch; enumeration writes into them during the call and returns a `tree.Tree` that borrows the same slices. Callers MUST keep both slices live for the returned tree's lifetime.
- Emitted `Node.function` values carry the same `ConfigSpace` handle as `Input.config`. All views composed on those `Function` values borrow the accessor.
- Enumeration MUST NOT allocate, cache decoded state beyond the `Node` fields per `docs/specs/topology/tree.md`, retry, or synchronize.

## zstdx usage

Direct usage: none.

Enumeration uses fixed-size internal recursion (`tree.max_depth` deep, `tree.max_depth × @sizeOf(Frame)` bytes on the stack). Config reads flow through the caller-supplied `ConfigSpace`. Neither pattern needs `zstdx.bits.BitSet`, `zstdx.core.Range`, or `zstdx.bytes.*`.

## Facade re-export `[zpci]`

`src/topology.zig`:

```zig
pub const enumerate = @import("topology/enumerate.zig");
```

Callers reach the public surface as `zpci.topology.enumerate.intoScratch`, `zpci.topology.enumerate.sizeBound`, `zpci.topology.enumerate.Input`, and `zpci.topology.enumerate.Error`.

## Usage

**Single segment, single-pass discovery** — the common firmware/kernel case:

```zig
var ecam = try zpci.config.Ecam.from(&segments);

var nodes: [zpci.topology.enumerate.sizeBound(&segments)]zpci.topology.tree.Node = undefined;
var roots: [zpci.topology.enumerate.sizeBound(&segments)]zpci.topology.tree.NodeIndex = undefined;

const tree = try zpci.topology.enumerate.intoScratch(.{
    .config = ecam.configSpace(),
    .segments = &segments,
    .nodes = &nodes,
    .roots = &roots,
});

var it = tree.preorder();
while (it.next()) |n| {
    _ = n; // dispatch on n.header_kind; read live via n.function
}
```

**Multi-segment discovery:**

```zig
const segments = [_]zpci.config.Segment{
    .{ .segment = zpci.core.SegmentId.of(0), .base = seg0_base, .bus_start = 0x00, .bus_end = 0xFF },
    .{ .segment = zpci.core.SegmentId.of(1), .base = seg1_base, .bus_start = 0x00, .bus_end = 0x3F },
};
var ecam = try zpci.config.Ecam.from(&segments);

// Runtime scratch sizing when segments are not compile-time-known.
const upper = zpci.topology.enumerate.sizeBound(&segments);
const nodes = try allocator.alloc(zpci.topology.tree.Node, upper);
defer allocator.free(nodes);
const roots = try allocator.alloc(zpci.topology.tree.NodeIndex, upper);
defer allocator.free(roots);

const tree = try zpci.topology.enumerate.intoScratch(.{
    .config = ecam.configSpace(),
    .segments = &segments,
    .nodes = nodes,
    .roots = roots,
});
_ = tree;
```

**Unprogrammed bridge — enumeration emits the bridge, skips its downstream:**

```zig
// After the caller programs bus numbers via docs/specs/resources/bus.md,
// they re-run enumerate.intoScratch with the same scratch to discover
// the downstream tree.
const tree_after_programming = try zpci.topology.enumerate.intoScratch(.{
    .config = ecam.configSpace(),
    .segments = &segments,
    .nodes = &nodes,
    .roots = &roots,
});
_ = tree_after_programming;
```

**Hot-plug rebuild — same scratch, fresh tree:**

```zig
// Hot-plug event fired; discard the old tree and re-enumerate.
const new_tree = try zpci.topology.enumerate.intoScratch(.{
    .config = ecam.configSpace(),
    .segments = &segments,
    .nodes = &nodes,
    .roots = &roots,
});
_ = new_tree;
```

## Required tests (category level)

- `unit:` empty segments → `Tree{ .nodes = &.{}, .roots = &.{} }`.
- `unit:` single segment with no present functions → empty tree.
- `unit:` single endpoint at `(seg, bus_start, 0, 0)` → one node, one root.
- `unit:` bridge with `secondary_bus > bus_start` and one downstream endpoint → 2 nodes; endpoint `parent == 0` (bridge's index).
- `unit:` bridge with `secondary_bus == 0` → bridge emitted, no recursion, endpoint absent from tree.
- `unit:` bridge with `secondary_bus == current_bus` → bridge emitted, no recursion (loop guard).
- `unit:` bridge with `secondary_bus > seg.bus_end` → bridge emitted, no recursion.
- `unit:` bridge with `secondary_bus > subordinate_bus` → bridge emitted, no recursion.
- `unit:` multi-segment (2 segments, 1 endpoint each) → 2 nodes, 2 roots, `Tree.roots` sorted by segment id.
- `unit:` multifunction device with functions 0/2/4 present → 3 nodes emitted; siblings 1/3/5-7 skipped via `AbsentFunction`.
- `unit:` device with mf bit clear on function 0 → functions 1..7 not probed (verify via read-recording fake).
- `unit:` `AbsentFunction` on function 0 → whole device skipped; functions 1..7 not probed.
- `unit:` `BadHeaderType` (type-2 CardBus) on function 0 → whole device skipped without emission or error.
- `unit:` `BadHeaderType` on a non-zero function → that function skipped; other siblings unaffected.
- `unit:` ARI mode: parent bridge has `DevCtl2.ari_forwarding_enable = 1`; downstream bus has functions 0/1/9/255 present on device 0 → 4 nodes emitted; devices 1..31 not probed.
- `unit:` ARI-capable parent bridge with `ari_forwarding_enable = 0` → classic mode used.
- `unit:` Parent bridge has PCIe capability but `version == 1` → classic mode (no `DevCtl2`).
- `unit:` Parent bridge has no PCIe capability → classic mode.
- `unit:` Malformed capability list on parent bridge → classic mode (no error propagated).
- `unit:` `ConfigSpace.Error` during a header read propagates.
- `unit:` `ConfigSpace.Error` during ARI detection propagates (as distinct from `MalformedCapability`, which does not).
- `unit:` `input.nodes.len` insufficient during emission → `StorageExhausted`.
- `unit:` `input.roots.len` insufficient → `StorageExhausted` via `tree.intoScratch`.
- `unit:` 3-level nested bridges → parent chain correct via `preorder`; each `parent` points to the immediately-enclosing bridge's index.
- `unit:` DFS emission order: subtree contents appear contiguously after their bridge; sibling under a common parent may be separated by a subtree.
- `unit:` `sizeBound` for single segment `bus_start..=bus_end` returns `(bus_end - bus_start + 1) * 256`.
- `unit:` `sizeBound` for multi-segment sums correctly; caps at `tree.max_nodes` when exceeded.
- `unit:` Determinism: two calls with the same `input` over a stable `ConfigSpace` snapshot produce identical `Tree.nodes` byte-for-byte.

## Non-goals

- Bus-number assignment for unprogrammed bridges (`docs/specs/resources/bus.md`).
- BAR sizing during enumeration (`docs/specs/bar.md`; consumers call on emitted nodes).
- Bridge-window aggregation (`docs/specs/resources/bridge.md`).
- Any config-space writes.
- Type-2 CardBus decode.
- Hot-plug detection after `intoScratch` returns; consumers rebuild the tree.
- Firmware-hint preservation.
- Allocator-backed constructor.
- Diagnostic out-parameters listing skipped functions.
- Persistence or serialization of the tree.
- Cross-`intoScratch` merging of partial results.

## Open questions

None owned by this spec.
