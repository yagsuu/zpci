# `pci.capabilities` access

Standard and extended list traversal, with typed access relative to a bound node.

## Lists

| Contract | Standard | Extended |
| --- | --- | --- |
| Node offsets | `0x40..0xFC`, four-byte aligned | `0x100..0xFFC`, four-byte aligned |
| Empty list | Status capability bit clear or masked head zero | Initial header at `0x100` is zero or all ones |
| Head | Header capability pointer; low two bits ignored | Fixed at `0x100` |
| Termination | Next pointer zero | Next offset zero |
| Entry | ID and absolute byte offset | ID, raw version, and absolute byte offset |

- `Iterator.tryFrom()` binds traversal; `next()` follows pointer order, which may
  move backwards. Revisited nodes and invalid offsets return `MalformedCapability`.
  Standard next-pointer low bits must be zero.
- Unknown IDs remain representable. `find()` returns the first matching entry or
  null; iterator `find()` consumes from its current position. A match leaves the
  remaining tail unvisited.
- Traversal is allocation-free and read-only. Callers validate function presence
  and payloads. Backend failures propagate, including unavailable extended access.

## Bound registers

| Operation/value | Contract |
| --- | --- |
| `Registers.tryFrom(function, base)` | Validate node range/alignment; no header or capability-ID check. |
| `read()` / `write()` | Accept `core.RelativeOffset(u8/u16/u32)` only; rebase to the function and delegate the native integer access. |
| Complete access bound | Standard: below `0x100`; extended: below `0x1000`. Overrun returns `MalformedCapability` before backend access. |
| `contains()` | Check the configuration-window bound without I/O. Callers establish payload layout and backend coverage. |

Capability length and next-node boundaries are unchecked. Callers select offsets
for the bound layout and own payload selection, readback, retries, and recovery.
Writes delegate to the backend.

Capability-specific `tryFrom(function, entry)` requires an entry for that function
with the matching ID, enforced by assertion. Each owner checks its required extent
and metadata. `find(function)` traverses and binds the first match. Shared access
and backend errors propagate.

## References

- [Standard access](../../../src/capabilities/standard.zig), [extended access](../../../src/capabilities/extended.zig)
- [Configuration boundary](../config.md), [typed offsets and wire values](../core.md)
