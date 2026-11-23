# `pci.interrupts.msix`

MSI-X capability controls, vector-table programming, and pending-bit reads.

## Capability and locations

Uses [standard capability access](../capabilities/access.md). Construction checks
the complete capability extent and both BIR values. Control, Table, and PBA reads
remain live.

| Value/operation | Contract |
| --- | --- |
| Vector count | `table_size_minus_one + 1`, in 1–2048. |
| `Location` | BAR index 0–5 and expanded byte offset, aligned to eight bytes. BIR 6/7 returns `MalformedField`; BAR 0 at offset 0 is valid. |
| `Capability.table()` / `Capability.pba()` | Independent locations; may reference different BARs. |
| `Capability.enable()` / `Capability.disable()` | Change enable only; preserve function mask and other Control bits. The table remains unchanged. |
| `Capability.setFunctionMask()` | Change the MSI-X function mask; enable remains unchanged. |

The caller resolves each location and supplies [BAR memory](../memory.md) whose
offset zero is the Table or PBA start. Callers provide usable BAR mappings, allocate
vectors, encode controller-specific messages, coordinate INTx/MSI, and serialize updates.

## Table and PBA views

`Table.from()` and `Pba.from()` assert a count in 1–2048. Construction is I/O-free;
each access checks its bounds. Counts remain as supplied. BAR operations use the
memory backend.

| Operation | Contract |
| --- | --- |
| `Table.spanBytes()` | `count * 16`. |
| `Pba.spanBytes()` | Readable dword span: `ceil(count / 32) * 4`. Hardware-region sizing is caller-owned. |
| `Table.read(index)` | Live address/data/mask; multi-register reads are non-atomic. |
| `Pba.pending(index)` | Read-only live pending bit for a valid vector. |
| `Pba.read(dword_index)` | Raw 32-bit word within the PBA accessor span, including any padding bits. |

Vector indices outside the supplied count return `InvalidRouting`. Complete entry
or dword accesses must fit the supplied memory; otherwise `BarMemoryOutOfBounds`
before I/O. Read failures propagate unchanged.

## Table programming

| Operation | Success |
| --- | --- |
| `Table.program(index, entry)` | Mask the vector before address/data writes; apply `entry.masked` last. Preserve reserved Vector Control bits. Address/data are caller-encoded 64/32-bit payloads. |
| `Table.setMasked(index, masked)` | Change only the mask bit; preserve address/data and reserved bits. |
| `Table.programAll(first_index, entries)` | Program contiguous entries in ascending order; each reaches its requested final mask before the next begins. Empty input performs no I/O. |

Nonempty batches check the complete requested count and memory extent before I/O.
Capability enable and Function Mask remain unchanged. Entry programming accepts
any current enable/mask state; callers hold Function Mask for batch-wide suppression.

### Failure state

Each entry/control update follows the
[write verification and recovery rules](msi.md#programming-failures).
Save-read failure leaves that entry untouched; later failures attempt rollback of
its successful writes.

On batch failure, prior entries remain committed, the failing entry may remain
partially programmed, and later entries are untouched.

## References

- [Operations](../../../src/interrupts/msix.zig), [wire values](../../../src/core/capabilities/msix.zig)
- [Write verification and recovery](../../../src/interrupts/programming.zig)
