# `pci.capabilities.dsn`

Read-only Device Serial Number access.

Uses [extended capability access](access.md).

| Operation | Contract |
| --- | --- |
| `Capability.tryFrom()` | Checks the complete 12-byte extent. The capability version is unchecked. |
| `Capability.serial()` | Reads the live 64-bit register value in PCI register ordering, without EUI-64 byte swapping. Zero and all ones remain valid return values. Backend read failures propagate. |

## References

- [Operations](../../../src/capabilities/dsn.zig), [wire values](../../../src/core/capabilities/dsn.zig)
- PCI Express Base Specification 6.0, §7.9.3.
