# `pci.capabilities.msix`

Uses [standard capability access](access.md). Construction checks the complete
capability extent. Each location accessor validates its live BIR value.

## Capability and locations

| API/value | Contract |
| --- | --- |
| `Capability.numVectors()` | Live vector count: `table_size_minus_one + 1`, in 1–2048. |
| `Capability.control()` | Live typed Control read. |
| `Capability.updateControl(args)` | Non-atomic partial update; preserves unselected and reserved bits. Leaves table contents unchanged. |
| `BarLocation` | `bar` index 0–5 and expanded byte `offset`, aligned to eight bytes. BIR 6/7 returns `MalformedField`; BAR 0 at offset 0 is valid. |
| `Capability.table()`, `Capability.pba()` | Independent locations; may reference different BARs. |

Callers resolve each location and supply [BAR memory](../memory.md) whose offset
zero is the Table or PBA start. Vector allocation, message encoding, INTx/MSI
coordination, and update serialization are caller-owned. MSI and MSI-X cannot be
enabled simultaneously.

## Table and PBA

`Table.from()` and `Pba.from()` assert a count in 1–2048. Construction performs no
I/O; each access checks its bounds.

| API | Contract |
| --- | --- |
| `Table.spanBytes()` | `count * 16`. |
| `Pba.spanBytes()` | Readable dword span: `ceil(count / 32) * 4`. Hardware-region sizing is caller-owned. |
| `Table.read(index)` | Live `Entry` containing address, data, and mask state; multi-register reads are non-atomic. |
| `Table.program(index, args)` | Write address/data only. Requires effective masking; leaves Vector Control unchanged. |
| `Table.programAll(first_index, entries)` | Prevalidate the complete count and memory extent, then write payloads in ascending index order. Empty input performs no I/O. |
| `Table.setMasked(index, masked)` | Partial Vector Control update; preserve other bits, including reserved and steering-tag bits. |
| `Pba.pending(index)` | Read-only live pending bit for a valid vector. |
| `Pba.read(dword_index)` | Raw 32-bit word within the PBA accessor span, including padding bits. |

Programming arguments contain only address and data. Callers establish effective
masking through the entry mask or Function Mask before payload writes.

## Ordering

Callers arrange platform-required ordering, barriers, and completion between
masking, payload writes, and unmasking, including individual BAR accesses where
required. zpci provides no implicit fences, flushes, or completion operation.
Function Mask changes use configuration access; callers also coordinate ordering
between configuration and BAR accesses.

Masking and disabling do not synchronize already-delivered interrupts.

## Failures

Indices outside the Table/PBA accessor range return `OutOfBounds`. Complete entry
or dword accesses must fit the supplied memory; otherwise `BarMemoryOutOfBounds`
before I/O. Backend errors propagate unchanged.

Operations stop at the first failure without readback verification, rollback, or
retry. On batch failure, earlier writes remain effective, the failing write may
have taken effect, and subsequent writes are not attempted.

## References

- [Operations](../../../src/capabilities/msix.zig), [wire values](../../../src/core/capabilities/msix.zig)
- PCI Express Base Specification 6.0, §§6.1.4, 7.7.2.
