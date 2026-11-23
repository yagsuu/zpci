# `pci.header`

Live Type 0/1 header access and decoded bridge windows.

## Access

| Operation | Contract |
| --- | --- |
| `Type0.from()` / `Type1.from()` | Bind a function without I/O or format validation; the caller selects the matching header type. |
| Reads | Live register values; common fields follow [Function access](config.md). Multi-register reads are non-atomic. |
| Setters | Mechanical writes, without feature checks, readback, or rollback. Earlier writes remain if a later access fails. |
| `Type0.rawBar(index)` / `Type1.rawBar(index)` | One raw slot; index must be below the header's slot count: six for Type 0, two for Type 1. No pairing or sizing. |
| `Type0.intrPin()` / `Type1.intrPin()` | Decodes none/INTA–INTD; other values return `MalformedField`. |

Callers select register payloads using [core wire policies](core.md) and coordinate
ROM decoding. ROM access includes the enable bit.

## Bus routing

| Value/operation | Contract |
| --- | --- |
| `BusRange.programmed()` | Tests `secondary != 0`. |
| `BusRange.forwards(bus)` | Secondary is nonzero and `Secondary <= bus <= Subordinate`. |
| `Type1.setBusRange()` | Writes Primary, Subordinate, then Secondary; preserves Secondary Latency Timer. Stops at the first failure without undoing earlier writes. |
| `Type1.disableBusRouting()` | Clears Secondary then Subordinate; Primary, Secondary Latency Timer, and memory/I/O decode bits remain unchanged. |

Callers supply bus numbers. [Topology configuration](topology.md) handles assignment,
readback, and cleanup.

## Bridge windows

| Value | Meaning |
| --- | --- |
| `Io.range` / `Memory.range` | Inclusive decoded addresses; null means inactive or unsupported encoding. |
| `Memory.Prefetch` | Optional window with an inclusive range and explicit `mem32`/`mem64` encoding width. Null means inactive or unsupported encoding. |
| `Io.contains()` / `Memory.contains()` / `Memory.Prefetch.contains()` | Entire byte request is covered; false for inactive windows, zero length, or overflow. |

- Limits include the last byte of the encoded granule: 4 KiB for I/O, 1 MiB for
  memory. Range comparisons use expanded byte addresses.
- I/O and prefetch base/limit formats must match and be supported. Narrow encodings
  ignore upper words; explicit `mem64` remains `mem64` below 4 GiB. Full-width
  inclusive prefetch ranges remain representable.
- `Type1.windows()` reads and decodes the three window groups. Null covers disabled
  ranges and rejected encodings. Decoded ranges are independent of Command decode bits.

## References

- [Type 0 access](../../src/header/type0.zig), [Type 1 access](../../src/header/type1.zig)
- [Window decoding](../../src/header/windows.zig), [wire encodings](../../src/core/bridge.zig)
