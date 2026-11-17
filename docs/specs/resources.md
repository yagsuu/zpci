# `pci.resources`

Resource requirements, aperture placement, bridge-window encoding, and programming.

## Values and requirements

| Value/operation | Contract |
| --- | --- |
| `Requirement` | Byte size/alignment, resource type, and target source. `Source.bar` names a low BAR slot; `rom` a function; `bridge` a function/window pair. |
| `Assignment` | Absolute base, requested requirement, and selected pool. |
| `Aperture.bounds` | Half-open byte range. Default pools are empty. Callers establish address width, hardware coverage, and non-overlap. |
| `Aperture.allocate()` | Positive size and power-of-two alignment required. Success consumes padding and the allocated range; no fit/overflow returns null without mutation. |
| `contains()` | Entire requested range fits; false for an empty aperture. |
| `Requirement.fromBar()` | Requires a sized BAR from the same function; absent/zero-sized returns null, missing size returns `UnsizedBar`. Alignment equals size. |
| `fromRom()` | Caller-supplied power-of-two size; zero returns null, otherwise non-prefetchable MMIO32 with alignment equal to size. Does not probe the ROM. |
| `fromBars()` | Allocated requirements in BAR order, filtering null entries; caller frees the slice. |

## `assign()`

Returns allocator-owned assignments from caller-supplied requirements and bridge
aggregates. Inputs remain unchanged; no hardware I/O. Errors release partial output.

| Caller requirement | Bound |
| --- | --- |
| Forest | Valid distinct roots with null parents; each non-null parent precedes its child and is a bridge. |
| Requirements | Positive size and power-of-two alignment; targets and types match the hardware. |
| Capacity | At most 65,535 nodes and 32 levels including roots; seven requirements per endpoint, five per bridge. Violations are programmer errors. |

Each root uses an independent copy of `Args.apertures`; addresses may overlap
across roots. Callers supply non-overlapping usable pools and coordinate shared
address domains.

### Placement

| Requirement type | Pool preference, left to right |
| --- | --- |
| `io` | `io` |
| `mmio32` | `mmio32` |
| `mmio32_prefetch` | `mmio32_prefetch`, `mmio32` |
| `mmio64` | `mmio64`, `mmio32` |
| `mmio64_prefetch` | `mmio64_prefetch`, `mmio32_prefetch`, `mmio64`, `mmio32` |

- Output is deterministic preorder in root/input-child order; within a node,
  descending alignment then size, preserving ties. Placement has no backtracking.
- Bases satisfy alignment and containment in the selected effective pool. Callers
  validate hardware encodability and physical availability.
- Descendants receive the parent's assigned bridge windows, classified by
  requirement type. The bridge's own BARs consume upstream space.
- `ResourceExhausted`: no eligible pool fits. `StorageExhausted`: requirement-count
  overflow. Allocator failures propagate; no partial assignment slice is returned.

## Bridge windows

`bridge.aggregate()` and `bridge.encode()` perform no I/O or input mutation.

| Operation/value | Contract |
| --- | --- |
| Aggregate | Up to three requirements in I/O, memory, prefetch order; ignores zero-sized children. Allocator is temporary workspace; result is a value. |
| Window sizing | Includes child alignment padding. Size rounds up to window alignment: at least 4 KiB for I/O, 1 MiB for memory, raised to the largest child alignment. |
| Non-prefetchable memory | Aggregates to MMIO32 even for 64-bit child BARs. |
| Prefetchable memory | MMIO32 if any child is 32-bit; otherwise MMIO64. |
| Encoding | Requires a bridge source and aligned base. Zero size disables the window; otherwise encodes inclusive `base + size - 1`. |
| Width | I/O selects 16/32-bit encoding; non-prefetchable memory must fit 32 bits; prefetch selects 32/64 bits from the assigned range. |

Aggregation arithmetic overflow returns `ResourceExhausted`; allocator failures
propagate. Encoding overflow, granularity, or width failure returns
`BridgeWindowUnencodable`. The caller rolls nested requirements up before assignment
and verifies bridge capabilities.

## `commit()`

The caller MUST quiesce devices and serialize configuration access. Assignments
must match actual BAR widths/slots and header formats, with aligned, encodable
addresses. Bus Master Enable remains unchanged.

Adjacent assignments with equal `Function` bindings form a commit group; input
order is preserved. Duplicate targets within a group are programmer errors.

- Saves affected registers, disables I/O and memory decode, programs BARs then ROM
  then bridge windows, and writes back saved Command. BAR writes use low-slot order.
- Preserves BAR attributes and ROM enable; clears ROM reserved bits. Narrow bridge
  encodings clear upper words. Omitted registers/windows remain untouched.
- Verifies successful writes by readback: exact for resource registers, masked for
  Command. Bus numbers remain unchanged.

### Failure state

| Stage/error | Result |
| --- | --- |
| Save/format failure | `ProgrammingWriteFailed`; no writes. |
| Initial decode-disable failure | `ProgrammingWriteFailed` or `ProgrammingReadbackMismatch`; no base writes or rollback. Command may have changed. |
| Programming/final Command restoration failure | Attempts reverse restoration of resource writes reported successful, then Command. Prior completed groups remain; processing stops at the failing group. |
| Rollback failure | Stops immediately, including before Command restoration if a base restore fails. `ProgrammingPartial` overrides the initiating failure. |

Backend/header/encoding failures map to `ProgrammingWriteFailed`; differing
readback returns `ProgrammingReadbackMismatch`. Successful rollback returns the
original error. Failed callbacks may change unrecorded registers. No automatic
retry is provided.

## References

- [Requirements and apertures](../../src/resources/module.zig), [assignment](../../src/resources/assignment.zig)
- [Aggregation/encoding](../../src/resources/bridge.zig), [programming](../../src/resources/programming.zig)
- [BAR sizing](bar.md), [header access](header.md), [wire values](core.md), [bus configuration](topology.md)
