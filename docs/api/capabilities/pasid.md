# `pci.capabilities.pasid`

Uses [extended capability access](access.md).

## Capability

Callers establish supported features, PASID routing, and IOMMU process contexts.

| API | Contract |
| --- | --- |
| `Capability.tryFrom()` | Checks through Control; version unchecked. |
| `Capability.capabilities()`, `Capability.control()` | Live register reads. |
| `Capability.updateControl()` | Non-atomic partial read-modify-write; preserves unselected and reserved bits. Feature support and ATS state are caller-checked. |

A failed write can leave Control changed; no rollback.

`max_width` is the supported PASID bit width: 0–20. Width `n` permits PASIDs
`0..2^n - 1` inclusive; zero permits PASID zero only. Raw reads retain encodings above 20.

## Configuration

Change PASID controls only while [ATS](ats.md) is disabled. Enable optional
execute, privileged, and translated-request controls only when advertised and
supported by the platform.

For SR-IOV, callers bind the PF's PASID capability; VFs share its configuration.
Coordinate ATS disable across the PF and associated VFs before changing shared
PASID controls.

## References

- [Operations](../../../src/capabilities/pasid.zig), [wire values](../../../src/core/capabilities/pasid.zig)
- PCI Express Base Specification 6.0, §7.8.9.
