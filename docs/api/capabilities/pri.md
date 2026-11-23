# `pci.capabilities.pri`

Uses [extended capability access](access.md).

## Capability

| API | Contract |
| --- | --- |
| `Capability.tryFrom()` | Checks through Request Allocation; version unchecked. |
| `Capability.control()`, `Capability.status()` | Live register reads. |
| `Capability.updateControl()` | Non-atomic partial read-modify-write; preserves unselected and reserved bits, suppresses Reset. Enable prerequisites are caller-checked. |
| `Capability.ackStatus(observed, fields)` | Acknowledges only selected W1C flags set in the supplied observation. |
| `Capability.requestCapacity()`, `Capability.requestAllocation()` | Outstanding Page Request message counts as `u32`. |
| `Capability.setRequestAllocation(value)` | Requires Enable clear and value ≤ capacity. Zero is valid; excess values are rejected. |
| `Capability.reset()` | Requires Enable clear. Resets request credits and pending state; preserves other Control bits. |

Allocation is shared across the function's PASIDs. For SR-IOV, callers bind the
PF's PRI capability; the PF and its VFs share the interface and allocation.

## Enable and stop

Callers prepare page-request handling before enable. Enable requires `stopped`;
the transition clears Stopped, Response Failure, and Unexpected PRG Index flags.
Capture required diagnostics before re-enabling.

Clearing Enable stops new requests. Continue servicing outstanding requests until
`stopped` is set; the flag is meaningful only while Enable is clear. For SR-IOV,
Stopped covers the PF and all associated VFs.

Reset discards pending request state. Callers coordinate outstanding host-side
requests before reset. Reset has no completion polling or readback.

## Responses

When `response_pasid_required` is set, PRG Responses carry a PASID if the
corresponding requests carried one. When clear, responses carry no PASID.
Acknowledging an error flag does not recover the interface.

## Failures

| Error | Condition |
| --- | --- |
| `InvalidState` | Enable set during allocation or reset; no write. |
| `InvalidValue` | Allocation exceeds capacity; no write. |

Backend errors propagate without rollback. A failed write can leave allocation,
enable state, or request bookkeeping changed.

## References

- [Operations](../../../src/capabilities/pri.zig), [wire values](../../../src/core/capabilities/pri.zig)
- PCI Express Base Specification 6.0, §10.5.2.
