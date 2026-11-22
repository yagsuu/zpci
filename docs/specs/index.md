# API contracts

Package module: `pci`.

| Namespace | Contract |
| --- | --- |
| `pci.core` | [Identities, wire values, typed offsets](core.md) |
| `pci.config` | [Configuration access, functions, ECAM, PIO](config.md) |
| `pci.header` | [Live headers and decoded bridge windows](header.md) |
| `pci.bar` | [BAR decoding and sizing](bar.md) |
| `pci.capabilities` | [List/register access](capabilities/access.md), [PCIe](capabilities/pcie.md), [PM](capabilities/pm.md), [ARI](capabilities/ari.md), [SR-IOV](capabilities/sriov.md), [AER](capabilities/aer.md), [ACS](capabilities/acs.md), [DPC](capabilities/dpc.md), [DSN](capabilities/dsn.md) |
| `pci.memory` | [BAR-memory access](memory.md) |
| `pci.resources` | [Placement, bridge encoding, programming](resources.md) |
| `pci.interrupts` | [MSI](interrupts/msi.md), [MSI-X](interrupts/msix.md) |
| `pci.topology` | [Enumeration, cold configuration, trees](topology.md) |
| `pci.testing` | [Host-test accessors and fixture guidance](../guidelines/testing.md) |

## Shared boundaries

- `core` owns canonical representations without I/O. Operational namespaces own
  access and policy; each operation defines its feature checks.
- Configuration access uses `ConfigSpace`; BAR-memory access uses `BarMemory`.
  Absolute configuration offsets, capability-relative offsets, and BAR byte
  positions are distinct domains.
- Checked APIs report invalid input through errors. Callers satisfy the input,
  feature, and platform prerequisites stated by trusted constructors and
  mechanical updates.
- Runtime dependencies flow toward canonical types and access abstractions.
  Keep test backends inside test code; production imports must not depend on them.
  [Build modules](../../build/modules.zig) define named imports; sibling files
  belong to their namespace owner.
- Platform discovery, usable resource domains, vector allocation/controller
  encoding, DMA/IOMMU setup, driver binding, and complete reset/power/VF lifecycle
  policy remain caller-owned.

## Development

- [Source conventions](../guidelines/conventions.md)
- [Testing](../guidelines/testing.md)
- [Contract writing](../guidelines/spec-writing.md)
