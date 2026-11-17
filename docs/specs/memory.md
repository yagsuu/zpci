# `pci.memory`

Bounded 32-bit access to backend-owned BAR memory.

| API/value | Contract |
| --- | --- |
| `BarMemory.from()` | Bind context, callbacks, and byte length without I/O or mapping validation. |
| `read32()` / `write32()` | BAR-relative byte offset; require the complete four-byte access inside `len`, aligned to four bytes. Bounds errors precede alignment errors. |
| Rejected access | `BarMemoryOutOfBounds` or `UnalignedAccess` before any callback, including overflowing offsets and zero-length regions. |
| Backend | Performs the actual access and PCI little-endian conversion; errors propagate unchanged. The accessor adds no volatile access, barriers, readback, or rollback. |

The handle borrows backend state. Callers provide valid backing resources,
serialize device-specific compound operations, and resolve MSI-X table/PBA
offsets within the selected BAR.

## References

- [BAR-memory accessor](../../src/memory/bar.zig)
- [Configuration access](config.md), [BAR decoding](bar.md)
