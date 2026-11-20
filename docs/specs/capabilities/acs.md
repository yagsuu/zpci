# `pci.capabilities.acs`

## Capability

Callers establish feature support, port applicability, and isolation policy.

| API | Contract |
| --- | --- |
| `Capability.tryFrom()` | Checks through Control; revision unchecked. |
| `Capability.capabilities()`, `Capability.control()` | Live register reads. |
| `Capability.updateControl()` | Non-atomic partial read-modify-write; preserves unselected and reserved bits. |

## Egress

| API | Contract |
| --- | --- |
| `Capability.egress()` | `null` when unsupported. Size zero decodes to 256 bits. Validates the full dword extent; retains the observed length. |
| `Egress.len()` | Bit count, 1–256, as `u9`. |
| `Egress.read(index)` | One bit from a dword read. |
| `Egress.set(index, value)` | Dword read-modify-write; preserves other bits. |
| `Egress.fill(value)` | Direct full-dword writes; partial final dword preserves unused upper bits. |

Indices outside the vector return `OutOfBounds` before access.

Vector writes are non-atomic and leave Control unchanged. Writes have no
readback; hardwired-zero bits can remain clear.

### Bit selection

| Context | Bit selection |
| --- | --- |
| Root/Downstream Port | Port Number. |
| Multifunction device, ARI disabled | Function Number. |
| ARI, ACS Function Groups disabled | Function Number modulo vector length. |
| ARI, ACS Function Groups enabled | Function Group, bits 0–7; remaining bits unused. |

Set bits block or redirect requests according to ACS Control. Callers coordinate
ARI groups and synchronize routing changes.

## Failures

Operations stop at the first failure; earlier writes remain. No rollback or
retries. See the [shared failure contract](access.md).

## References

- [Operations](../../../src/capabilities/acs.zig), [wire values](../../../src/core/capabilities/acs.zig)
- [ARI groups](ari.md)
