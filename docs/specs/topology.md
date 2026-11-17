# `pci.topology`

Discovers configured hierarchies or assigns bus numbers during cold configuration.

## Values

| Value | Contract |
| --- | --- |
| `Root.buses` | Inclusive, caller-owned allocation domain; start is the root bus. Same-segment domains must be disjoint. |
| `NodeId` | Index local to one tree. |
| `Node.subtree_end` | Exclusive end of the contiguous preorder subtree, including the node. |
| `Node.bus_range` | Configured bridge's inclusive Secondary–Subordinate range, including reservations. |
| `Node.vfs` | Reserved PF capacity and inclusive `bus_end`. Null means uninspected; zero capacity means inspected without a VF reservation. |
| `max_depth` | Discovery depths 0–31; root bus is depth zero. Existing-tree traversal supports all stored depths. |

## `enumerate()`

- Read-only; starts at each supplied `Segment.buses.start`. Supply roots separately.
- Skips absent functions and unsupported headers. Conventional scanning requires
  Function 0's multifunction bit before probing siblings.
- Bridge descent requires `0 < Secondary`, `current bus < Secondary <= segment end`,
  and `Secondary <= Subordinate`.
- Observes upstream ARI forwarding and probes all 256 function numbers in ARI mode.
  Missing or unusable PCIe metadata falls back to conventional routing; backend
  failures propagate.
- Returns an allocated tree with `bus_range` and `vfs` unset. Allocation, depth,
  storage-limit, or backend failure releases temporary storage and returns no tree.

## `configure()`

The caller MUST own the allocation domains and quiesce their devices with VFs
disabled.

- Rejects invalid or overlapping roots before hardware access. Assignment starts
  at each root's first bus and stays within its domain.
- Checks visible PFs for enabled VFs before enabling ARI forwarding, and newly
  reachable PFs before changing SR-IOV hierarchy state.
- Closes stale sibling routes before allocation. Final ranges cover descendants
  and reserved VF buses without overlapping sibling allocations.
- Programs Primary/Secondary/Subordinate, preserves Secondary Latency Timer, and
  verifies writes by readback. Temporary Subordinate ranges narrow before success.
- Returns an allocated tree with final SBDFs. BARs, address windows, Command, and
  VF Enable remain unchanged. Callers handle device reset and link readiness.

### ARI

| Policy | Forwarding |
| --- | --- |
| `.preserve` | Unchanged. |
| `.enable_supported` | Enable when Function 0 has ARI and the upstream port supports forwarding. Never disable existing forwarding. |

ARI discovery follows the PF-only Next Function Number chain; missing linked
functions/capabilities or non-increasing links are malformed. VF addressing uses
SR-IOV separately. Sets ARI Capable Hierarchy on each device's lowest SR-IOV PF to
match routing, except RC integrated endpoints.

### VF capacity

| Policy | Per-PF capacity |
| --- | --- |
| `.advertised` | TotalVFs. |
| `.none` | Zero. |
| `.limit = n` | `min(n, TotalVFs)`. |

- Reserves the largest bus span across activation counts up to capacity; offset
  and stride can depend on NumVFs. Overlapping PF spans reserve their union.
- Probing leaves NumVFs zero on success and failure unless cleanup fails.

### Failure

| Error | Meaning |
| --- | --- |
| `ActiveVfs` | Enabled VFs observed. |
| `MalformedCapability` | Malformed capability data or ARI chain. |
| `InvalidValue` | Invalid root range/overlap or VF geometry. |
| `BusRangeExhausted` | Routing ID overflow or insufficient bus capacity. |
| `ProgrammingReadbackMismatch` | Write readback differs. |
| `ProgrammingPartial` | Cleanup incomplete, including NumVFs zeroing; overrides the initiating failure. |

All failures return no tree. Allocation can fail after hardware changes.
Cleanup attempts to close recorded routes descendants-first. Original bus numbers,
ARI forwarding, and SR-IOV hierarchy state may remain changed. Undiscovered hardware
can retain prior state. Saved downstream addresses may become unusable.

## Tree access

Traversal performs no hardware I/O.

| Operation | Result |
| --- | --- |
| `nodes()` | Discovery-order preorder storage. |
| `preorder()` | SBDF-sorted roots, each subtree in discovery order. |
| `preorderFrom(id)` | Selected node and descendants. |
| `children(id)` | Immediate children; requires Type 1. |
| `root(segment)` | First matching root; use `roots` for all matches. |
| `pathTo(allocator, id)` | Allocated root-to-node path, endpoints included; caller frees it. |

IDs must belong to the queried tree. Storage/pointers remain stable until
`deinit()` with the creating allocator, which invalidates IDs and iterators.
Stored metadata remains unchanged after hardware changes. `Node.function` accesses
live state through a borrowed backend.

## References

- [Public namespace](../../src/topology/module.zig)
- [Enumeration](../../src/topology/enumerate.zig)
- [Configuration](../../src/topology/configure.zig)
- [Tree](../../src/topology/tree.zig)
- [ARI](capabilities/ari.md), [SR-IOV probing](capabilities/sriov.md)
- [PCI Express Base Specification 4.0](https://www.pedestrian.com.cn/_downloads/d2f2495e73c44b8c3a8dfd4c399f50f0/PCIE_V4.0.pdf),
  §6.13 (ARI) and Chapter 9 (SR-IOV).
