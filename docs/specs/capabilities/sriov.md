# `pci.capabilities.sriov`

PF controls and VF bus-capacity probing without VF activation.

Uses [extended capability access](access.md). Construction checks the full extent
through Migration State Array. The extended capability version is unchecked;
reads remain live.

## `setAriHierarchy()`

The caller MUST select the device's lowest SR-IOV PF, exclude RC integrated
endpoints, and keep VFs disabled across all PFs. The method checks this PF's VF Enable.

Preserves other control bits and verifies a changed value by readback. An unchanged
value needs no write. Failed updates may leave changed hierarchy state.

## `reserveBuses(capacity)`

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

## Failures

| Error | Condition/state |
| --- | --- |
| `ActiveVfs` | This PF has VF Enable set; no writes or NumVFs normalization. |
| `InvalidValue` | Capacity exceeds TotalVFs, zero First VF Offset, or zero stride for multiple VFs. |
| `BusRangeExhausted` | Computed VF Routing ID exceeds the supported range. Root allocation-domain checks belong to topology. |
| `ProgrammingReadbackMismatch` | Hierarchy/NumVFs readback differs. |
| `ProgrammingPartial` | Final NumVFs zeroing cannot be established; overrides both success and the initiating failure. |

After successful zero cleanup, the original probe error propagates. A failure
before the VF-enable check completes does not attempt normalization. Other access
failures follow the [shared contract](access.md).

## References

- [Operations](../../../src/capabilities/sriov.zig), [wire values](../../../src/core/capabilities/sriov.zig)
- [PCI Express Base Specification 4.0](https://www.pedestrian.com.cn/_downloads/d2f2495e73c44b8c3a8dfd4c399f50f0/PCIE_V4.0.pdf), Chapter 9 (SR-IOV)
