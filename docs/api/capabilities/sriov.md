# `pci.capabilities.sriov`

Uses [extended capability access](access.md). Construction checks the full extent
through Migration State Array. The extended capability version is unchecked;
reads remain live.

## `Capability.setAriHierarchy()`

The caller MUST select the device's lowest SR-IOV PF, exclude RC integrated
endpoints, and keep VFs disabled across all PFs. The method checks this PF's VF Enable.

Preserves other control bits and verifies a changed value by readback. An unchanged
value needs no write. Failed updates may leave changed hierarchy state.

## `Capability.reserveBuses(capacity)`

Probes geometry and returns the inclusive highest VF bus number. Capacity zero
returns the PF's bus. [Topology configuration](../topology.md) allocates bus ranges
and configures ancestor bridge ranges.

- Requires VF Enable clear and capacity no greater than TotalVFs. The caller owns
  serialization and establishes ARI hierarchy state before probing.
- Covers every activation count up to capacity, using each count's First VF Offset
  and VF Stride. The maximum bus span can occur below the selected capacity.
- Uses `PF RID + offset + stride * (count - 1)`, including device/function bits;
  rejects overflow beyond the 16-bit Routing ID.
- After the VF-enable check succeeds, zeroes NumVFs before probing and on completion
  or failure unless cleanup fails. NumVFs writes are verified by readback.
- VF Enable, VF Memory Space Enable, page size, and VF BARs remain unchanged.

## Configuration and routing

| API/value | Contract |
| --- | --- |
| `Capability.setNumVfs(count)` | Requires VF Enable clear and count ≤ TotalVFs; verifies by readback. Zero is valid. |
| `Capability.supportedPageSizes()` | Supported-size bitmap; `PageSizes.supports(size)` tests a selection. |
| `Capability.systemPageSize()` | Decodes one selected bit; zero or multiple bits return `InvalidValue`. |
| `Capability.setPageSize(size)` | Requires VF Enable clear and advertised support; verifies by readback. A page-size change invalidates BAR addresses and prior sizing/allocation data. |
| `PageSize.bytes()` | Bit index `n` represents `2^(n + 12)` bytes. |
| `Capability.routing()` | Snapshot of current NumVFs, First VF Offset, and Stride; checks count and Routing ID overflow. |
| `Routing.vf(index)` | Same segment as the PF; RID = `PF RID + first + stride * index`. Invalid index returns `OutOfBounds`. |

Refresh routing after count or ARI hierarchy changes.

## VF BARs

`Capability.bars()` binds the six VF BAR slots. Callers select page size before
probing and serialize sizing/programming.

| API/value | Contract |
| --- | --- |
| `Bars.read(index)` / `Bars.write(index, raw)` | Raw slot access; index must be below six. Writes require VF Enable clear. |
| `Bars.decode(index)` | Memory-only decode, including 64-bit pairs; size remains null. Zero returns an absent BAR. |
| `Bars.iterator()` | Ascending low slots, skipping 64-bit upper halves. |
| `Bars.probe(index)` | Requires VF Enable clear. Measures per-VF size and restores attempted writes, including writes whose callbacks failed. PF Command and SR-IOV Control remain unchanged. |
| `Bars.probeAll()` | Compact ascending result; previously probed slots are restored before proceeding. |
| Size/address | Size is per-VF. VF `i` uses `base + i * size`. [Resource requirements](../resources.md) reserve the aggregate aperture. |

BAR restoration attempts continue after a restore failure. Any failed restoration
returns `ProgrammingPartial`, overriding the initiating error.

## Activation

| API | Contract |
| --- | --- |
| `Capability.enable()` | Requires VF Enable clear, positive NumVFs ≤ TotalVFs, valid routing, and a supported selected page size. Sets VF Enable; preserves other Control bits. No readback or VF access. |
| `Capability.setMemoryEnabled(enabled)` | Changes VF Memory Space Enable only. |
| `Capability.disable()` | Clears VF Enable and VF Memory Space Enable. Ends at the write; no readback or NumVFs cleanup. |

Callers establish allocated VF capacity, bus coverage, PF dependencies, and
driver/IOMMU readiness. Configuration access to VFs waits for enable readiness.
After disable, SR-IOV register access waits for completion: one second or a
qualifying VF Disabled FRS. A failed disable write may already require this wait.
Backend errors can leave enable state changed.

## Failures

| Error | Condition/state |
| --- | --- |
| `ActiveVfs` | VF Enable set for an operation requiring disabled VFs; no writes or NumVFs normalization. |
| `InvalidValue` | Invalid count, unsupported/non-one-hot page selection, zero First VF Offset, or zero stride for multiple VFs. |
| `BusRangeExhausted` | Computed VF Routing ID exceeds 16 bits. Allocation-domain checks belong to the caller/topology. |
| `MalformedBar` | Invalid VF BAR encoding, pairing, or measured size. |
| `ProgrammingReadbackMismatch` | Hierarchy, NumVFs, or page-selection readback differs. |
| `ProgrammingPartial` | Bus-probe NumVFs cleanup or BAR restoration failed; overrides success and the initiating failure. |

After successful bus-probe cleanup, the original probe error propagates. A failure
before the VF-enable check completes does not attempt normalization. Other access
failures follow the [shared contract](access.md).

## References

- [Operations](../../../src/capabilities/sriov.zig), [wire values](../../../src/core/capabilities/sriov.zig)
- [PCI Express Base Specification 4.0](https://www.pedestrian.com.cn/_downloads/d2f2495e73c44b8c3a8dfd4c399f50f0/PCIE_V4.0.pdf), Chapter 9 (SR-IOV)
