# `pci.capabilities.ari`

ARI endpoint capability and function-group controls.

Uses [extended capability access](access.md). Construction checks the extent
through Control. The extended capability version is unchecked; reads remain live.

| Value/operation | Contract |
| --- | --- |
| Next Function Number | Next PF's eight-bit function number; zero terminates. SR-IOV supplies VF addresses. |
| `Capability.updateControl()` | Non-atomic partial update; preserves unselected and reserved bits. Callers check group support and selection. |

Upstream PCIe Device Control 2 controls ARI forwarding.
[Topology configuration](../topology.md) negotiates forwarding and rejects missing
or non-increasing PF links.

## References

- [Operations](../../../src/capabilities/ari.zig), [wire values](../../../src/core/capabilities/ari.zig)
- [PCIe control updates](pcie.md), [SR-IOV geometry](sriov.md)
