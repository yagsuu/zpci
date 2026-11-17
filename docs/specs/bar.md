# `pci.bar`

Decodes BAR slots and measures sizes through temporary configuration writes.

## Values

| Value | Contract |
| --- | --- |
| `Bar.index` | Index of the BAR's low slot. |
| `Bar.type` | None, I/O, or memory; memory carries encoding width and prefetchability. |
| `base` / `size` | Byte address/length. Decode leaves size null; probing measures it. |
| `numSlots()` | Two for 64-bit memory, one otherwise; Type 0 has six slots, Type 1 two. |
| `Ref.from()` | Binds a function and index without I/O. Checks the generic six-slot bound only; callers supply a valid low slot for the actual header. |

## Decoding

| Operation | Contract |
| --- | --- |
| `Bars.from()` | Caller supplies the matching Type 0/1 format; no I/O or presence validation. |
| `tryFrom()` | Reads header type; unsupported formats return null. Backend errors propagate. |
| `decode(index)` | Reads one BAR, strips attribute bits from the base, and combines 64-bit pairs. No writes or sizing. |
| Iterator | Ascending low slots, skipping the upper half of 64-bit BARs. |

Indices must name valid low slots; callers exclude upper-half indices. Zero raw
words decode as none. Use sizing to inspect unassigned BARs.
Unsupported memory encodings, I/O reserved bit 1, and a 64-bit BAR without room
for its upper slot return `MalformedBar`.

## Sizing

The caller MUST quiesce the function and serialize access to its BARs and Command.
Bus Master Enable remains unchanged.

| Operation | Decode window |
| --- | --- |
| `probe(index)` | Disables the selected BAR's I/O or memory decode; preserves other Command bits. |
| `probeAll()` | Disables both decodes for the complete ascending-slot walk; returns a compact, allocation-free result. |

Probing saves BAR values, writes all ones, reads size masks, and attempts BAR
restoration before restoring Command. Returned bases are the saved addresses.
Zero probe low words, and zero I/O address masks, produce none. Each completed
BAR is restored before the batch proceeds.

### Failure state

| Failure | Result |
| --- | --- |
| Reads/validation before mutation | Error propagates; no probe writes. |
| Single-probe Command disable | Attempts saved Command restoration; no BAR writes. |
| Batch Command disable | Returns immediately without Command restoration. |
| BAR write/read or batch setup | Attempts restoration of BAR writes reported successful, then Command. Batch stops without returning partial results. |
| Probe failure plus restoration failure | Original error wins; hardware may remain partially restored. |
| Otherwise successful probe, failed restoration | `ProgrammingPartial`. |

Remaining BAR and Command restoration attempts continue after errors.
Writes and restoration have no verification readback; failed callbacks may already
have changed hardware.

## References

- [BAR access and sizing](../../src/bar.zig)
- [Wire encodings](../../src/core/bar.zig), [header access](header.md), [configuration access](config.md)
