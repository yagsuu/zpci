# `pci.capabilities.msi`

Uses [standard capability access](access.md). Construction checks the required
layout extent. Count-dependent operations validate vector encodings; register reads
use live Control.

## Access

| API/value | Contract |
| --- | --- |
| `VectorCount.count()` | Returns 1, 2, 4, 8, 16, or 32; reserved encodings return `MalformedField`. |
| `Capability.control()` | Live typed Control read. |
| `Capability.updateControl(args)` | Non-atomic partial update; preserves unselected and reserved bits. Feature support and lifecycle sequencing are caller-checked. |
| `Capability.address()`, `Capability.data()` | Select the 32/64-bit layout from live Control; 32-bit addresses zero-extend. |
| `Capability.extData()` | Requires extended-data support. |
| `Capability.mask()`, `Capability.pending()` | Require per-vector masking support; pending is read-only. |
| `Capability.routing()` | Non-atomic payload and supported optional-register reads. Extended data reflects the supported register even when its enable is clear. |

Callers supply message encoding, allocate vectors, coordinate INTx/MSI-X, and
serialize updates. MSI and MSI-X cannot be enabled simultaneously.

## Programming

`Capability.program(args)` requires MSI disabled. All input and extent checks
precede writes.

| Input | Validation |
| --- | --- |
| `num_vectors` | Known encoding no greater than advertised capacity. |
| `address` | Fits 32 bits when the function lacks 64-bit support. |
| `data` | Low `log2(requested vector count)` bits clear. |
| `mask` | Non-null requires masking support; null preserves the current mask. Supplied bits are forwarded unchanged. |
| `ext_data` | Non-null requires extended-data support and enables its use. Null clears extended-data enable. |

Programming writes the optional initial mask, address/data, and routing-related
Control fields. MSI remains disabled; unselected Control bits and Command remain
unchanged. Callers activate delivery with `Capability.updateControl()`.

| API | Contract |
| --- | --- |
| `Capability.setMask()` | Replace the complete 32-bit mask; requires masking support. |
| `Capability.setMasked()` | Change one mask bit; requires masking support and an index below advertised capacity. |

Unsupported optional reads/masks and invalid mask indices are programmer errors.
Masking and disabling do not synchronize in-flight interrupts.

## Failures

| Error | Condition |
| --- | --- |
| `InvalidState` | MSI enabled during `Capability.program()`; no writes. |
| `MalformedField` | Reserved vector-count encoding. |
| `InvalidRouting` | Unsupported or inconsistent routing arguments. |
| `MalformedCapability` | Required extent outside the capability window. |

Backend errors propagate unchanged. Operations stop at the first failure; earlier
writes remain effective and the failing write may have taken effect. No automatic
readback, rollback, retry, or synchronization.

## References

- [Operations](../../../src/capabilities/msi.zig), [wire values](../../../src/core/capabilities/msi.zig)
- PCI Express Base Specification 6.0, §§6.1.4, 7.7.1.
