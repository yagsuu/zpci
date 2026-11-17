# `pci.interrupts.msi`

MSI routing, enable control, and optional per-vector masking.

## Access and values

Uses [standard capability access](../capabilities/access.md). Construction validates
the advertised vector encoding and required layout extent. Reads and programming
use live Control. Multi-register payload reads are non-atomic.

| Value/operation | Contract |
| --- | --- |
| `VectorCount` | Encodes 1, 2, 4, 8, 16, or 32 vectors. `count()` rejects reserved encodings with `MalformedField`. |
| `address()` / `data()` | Select the 32/64-bit layout from live Control; 32-bit addresses zero-extend. |
| `extData()` | Caller must check extended-data capability first; unsupported use is a programmer error. |
| `mask()` / `pending()` | Require per-vector masking support. A set mask bit suppresses that vector; pending is read-only. |
| `readRouting()` | Read payload and supported mask/data registers. `control()` provides enable state. |

Callers supply platform message encoding, allocate vectors, coordinate INTx/MSI-X,
and serialize updates.

## `program(routing)`

| Input | Validation |
| --- | --- |
| `num_vectors` | Known encoding no greater than advertised capacity. |
| `address` | Must fit 32 bits when the function lacks 64-bit support. |
| `data` | Low `log2(requested vector count)` bits clear. |
| `initial_mask` | Non-null requires masking support; null preserves the current mask. Supplied bits are forwarded unchanged. |
| `ext_data` | Non-null exactly when extended data is supported; successful programming enables it when supplied. |

Invalid encodings return `MalformedField`; other rejected inputs return
`InvalidRouting`. Validation reads Control and precedes writes. Required-extent
failure during programming maps to `ProgrammingWriteFailed`.

Programming disables MSI before changing payload, applies any initial mask before
address/data, and enables MSI last with the requested vector count. Unselected
Control bits, including reserved bits, are preserved. Command is unchanged.

| Other write | Effect |
| --- | --- |
| `disable()` | Clear enable only; preserve payload, mask, and other Control bits. |
| `setMask()` | Replace the complete 32-bit mask; requires masking support. |
| `setVectorMasked()` | Change one bit; requires masking support and index below advertised capacity. |

Mask support/index violations are programmer errors enforced by assertions.
Mask/disable operations do not wait for in-flight interrupts.

## Programming failures

These rules also apply to [MSI-X writes](msix.md).

| Failure | Result |
| --- | --- |
| Validation/bounds | No writes; reads may already have occurred. |
| Save read | `ProgrammingWriteFailed`; no writes. |
| Write/readback access | `ProgrammingWriteFailed`; attempt rollback. |
| Differing readback | `ProgrammingReadbackMismatch`; attempt rollback. |
| Restore write/readback | `ProgrammingPartial`; stop restoration and override the initiating error. |

Every successful write and restore is checked by full-width readback. Rollback
restores writes reported successful in reverse order; success returns the original
error. Failed callbacks may change unrecorded registers. Failure can leave changed
registers and enabled/unmasked interrupts. No automatic retry is provided.
Read-only operations propagate access errors unchanged.

## References

- [Operations](../../../src/interrupts/msi.zig), [wire values](../../../src/core/capabilities/msi.zig)
- [Write verification and recovery](../../../src/interrupts/programming.zig)
