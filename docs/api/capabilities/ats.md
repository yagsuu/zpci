# `pci.capabilities.ats`

Uses [extended capability access](access.md).

## Capability

Callers establish device trust, path support, and IOMMU translation/invalidation
handling before enabling ATS.

| API | Contract |
| --- | --- |
| `Capability.tryFrom()` | Checks through Control; version unchecked. |
| `Capability.capabilities()`, `Capability.control()` | Live register reads. |
| `Capability.updateControl()` | Non-atomic partial read-modify-write; preserves unselected and reserved bits. Feature support and lifecycle state are caller-checked. |

Configure [PASID controls](pasid.md) before enabling ATS. Disable ATS before
changing PASID controls.

A failed write can leave Control changed; no rollback.

## Values

| Value/API | Meaning |
| --- | --- |
| `Capabilities.Word.queue_depth` | Invalidation request capacity. Non-VF zero means 32; other values are literal. VF zero refers to the PF's queue. |
| `core.capabilities.ats.Stu.shift()` | Encoded value plus 12. |
| `core.capabilities.ats.Stu.bytes()` | `4096 << encoding` bytes; 4 KiB–8 TiB. |

For VFs, STU reads zero and the PF's STU applies. Callers configure the PF's STU
before VF use; each function has an independent ATS Enable.

## References

- [Operations](../../../src/capabilities/ats.zig), [wire values](../../../src/core/capabilities/ats.zig)
- PCI Express Base Specification 6.0, §10.5.1.
