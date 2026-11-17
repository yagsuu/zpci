# `pci.config`

Configuration-space access, function binding, and ECAM/PIO backends.

## Access boundary

| API | Contract |
| --- | --- |
| `ConfigSpace.from()` | Binds caller context and callbacks without validation or I/O. |
| `read()` / `write()` | Accept absolute `core.Offset(u8/u16/u32)`; width follows the offset type. Raw and relative positions are rejected at compile time. |
| Backend callbacks | Receive raw byte positions already validated by the typed offset. Enforce backend coverage and width support; do not reinterpret register semantics. Direct calls must satisfy the same trusted-offset requirements. |
| Values/errors | Native-endian integers; the backend converts PCI byte order. `OutOfBounds`, `UnsupportedAccessWidth`, and `UnalignedAccess` propagate unchanged. |

Handles borrow backend state; callers keep it valid and own presence checks,
payload construction, and compound-operation synchronization. Primitive accesses
perform no readback, retries, or rollback. Failed writes may already have changed
hardware.

## Functions

| Operation | Contract |
| --- | --- |
| `Function.from()` | Bind an SBDF without reads or validation. |
| `tryFrom()` | Check Vendor ID first, then supported header format. `0xFFFF` returns `AbsentFunction` without reading header type; unsupported formats return `BadHeaderType`. |
| `format()` | Live Type 0/1 check, ignoring the multifunction bit. CardBus and unknown encodings return `BadHeaderType`. |
| Identification/register reads | Live register values; presence can change after construction. |
| Setters / `clearStatusBits()` | Write the supplied payload unchanged. Callers select ordinary fields, W1C bits, and triggers correctly. |
| `eql()` | Same SBDF, backend context, and callback table. |

## ECAM

| Value/operation | Contract |
| --- | --- |
| `Segment` | Configuration-access coverage: segment ID and inclusive bus range. `contains()` rejects invalid ranges. |
| `Ecam.Region.base` | Mapped address corresponding to the region's first bus. |
| `tryFrom(regions)` | Borrow the table. Reject empty input (`NoRegions`), invalid ranges (`InvalidBusRange`), or repeated IDs (`DuplicateSegment`), even for disjoint ranges. The caller supplies usable mappings. |
| `find(sbdf)` | Match segment ID; bus containment is checked during access. |
| Access | Require a matching segment and contained bus; address overflow returns `OutOfBounds` before memory access. |

Addresses use `(bus - first_bus) << 20 | device << 15 | function << 12 | offset`,
added to the region base. Reads/writes use the requested native width and PCI
little-endian encoding.

## PIO

- x86_64 mechanism 1: segment zero, conventional 256-byte window, ports CF8/CFC.
- Nonzero segments and extended accesses return `OutOfBounds` before port I/O.
  Otherwise, non-x86_64 targets return `UnsupportedAccessWidth`.
- The caller provides port-I/O permission and serializes each complete CF8/CFC
  address/data pair against every other user.

## References

- [Access abstraction](../../src/config/accessor.zig), [function operations](../../src/config/function.zig)
- [Segment coverage](../../src/config/segment.zig), [ECAM](../../src/config/ecam.zig), [PIO](../../src/config/pio.zig)
- [Typed offsets and wire values](core.md)
