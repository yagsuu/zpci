# ECAM config access

Defines `config.Segment` and `config.Ecam`, the ECAM-backed implementation of `config.ConfigSpace`. ECAM owns mapped-aperture descriptors, segment/bus containment, PCIe ECAM address calculation, and volatile MMIO reads/writes for config-space access.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `Segment`, `Ecam`, and ECAM backend behavior. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/bdf.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/config/pio.md`
- `docs/specs/resources/programming.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- `Segment` descriptor for one caller-supplied ECAM aperture.
- `Ecam` backend implementing `ConfigSpace` over one or more caller-supplied `Segment` descriptors.
- Segment descriptor validation: `bus_start <= bus_end`.
- Multi-segment set validation: non-empty slice, no duplicate `SegmentId`.
- Access dispatch across the segment set by matching `sbdf.segment`.
- Access containment against the matched segment:
  - `sbdf.segment == segment.segment`;
  - `sbdf.bdf.bus` lies in `bus_start..=bus_end` inclusive.
- ECAM address calculation from segment base, `Bdf`, and function-window offset.
- Volatile MMIO reads and writes for 8-, 16-, and 32-bit config accesses.
- ECAM backend lifetime, ordering, and concurrency rules.

Deferred:

- ACPI MCFG parsing and segment discovery.
- Physical-to-virtual mapping and page-table/cache-attribute setup.
- PIO access (`docs/specs/config/pio.md`).
- Function presence and header validation (`docs/specs/config/space.md`).
- Header field decoding (`docs/specs/header/*.md`).
- BAR sizing, resource programming, and post-write read-back policy.
- MSI/MSI-X programming policy.
- Device reset, hotplug, or surprise-removal handling.
- Architecture-specific fence primitives unless promoted by an architecture or programming spec.

## Segment descriptor `[zpci]`

```zig
pub const Segment = struct {
    segment: core.SegmentId,
    base: zstdx.addr.VirtAddr,
    bus_start: u8,
    bus_end: u8,

    pub const Error = error{
        InvalidBusRange,
    };

    pub fn validate(self: Segment) Error!void;
    pub fn contains(self: Segment, sbdf: core.Sbdf) bool;

    /// Whole-bus-range segment: `bus_start = 0`, `bus_end = 0xFF`.
    /// Matches the common MCFG shape for a single-segment machine.
    pub fn whole(segment: core.SegmentId, base: zstdx.addr.VirtAddr) Segment;
};
```

`Segment` describes a mapped ECAM aperture supplied by the caller.

Rules:

- `base` is the mapped virtual address zpci reads/writes through.
- `base` is not a physical address.
- `base` uses `zstdx.addr.VirtAddr` to keep virtual and physical address domains distinct.
- zpci does not translate `zstdx.addr.PhysAddr` to `zstdx.addr.VirtAddr`.
- zpci does not map, unmap, pin, or change cache attributes for the aperture.
- `bus_start` and `bus_end` are inclusive.
- `validate()` returns `error.InvalidBusRange` when `bus_start > bus_end`.
- The caller guarantees the mapped virtual aperture covers every bus in `bus_start..=bus_end`.
- The caller guarantees the mapping has attributes suitable for config-space MMIO.

`Segment.contains(sbdf)` returns true only when both conditions hold:

```text
sbdf.segment == segment.segment
bus_start <= sbdf.bdf.bus <= bus_end
```

## `Ecam` backend `[zpci]`

```zig
pub const Ecam = struct {
    segments: []const Segment,

    pub const Error = Segment.Error || error{
        NoSegments,
        DuplicateSegment,
    };

    pub fn from(segments: []const Segment) Error!Ecam;
    pub fn configSpace(self: *Ecam) ConfigSpace;
    pub fn find(self: Ecam, sbdf: core.Sbdf) ?*const Segment;
};
```

`Ecam.from(segments)`:

1. rejects `segments.len == 0` with `error.NoSegments`;
2. calls `s.validate()` on each entry in slice order; the first failure returns `error.InvalidBusRange`;
3. rejects two entries with the same `SegmentId` value with `error.DuplicateSegment`;
4. stores the slice by value (pointer + length). The slice is borrowed; the caller owns the backing storage.

`configSpace()` returns a borrowed `ConfigSpace` handle whose context pointer refers to the `Ecam` instance.

`find(sbdf)` returns the first matching segment (linear scan of `segments` for `s.segment.eql(sbdf.segment)`) or `null`. It does not check bus containment; that is `Segment.contains`'s job. `find` is exposed so callers can inspect which aperture will service a given `Sbdf` without opening a config transaction.

Rules:

- The `Ecam` value must outlive every `ConfigSpace`, `Function`, view, or iterator derived from it.
- The `segments` slice storage must outlive the `Ecam`; `Ecam` does not copy or allocate.
- An `Ecam` value must not be moved after publishing a `ConfigSpace` handle unless the implementation stores the context in stable memory.
- Overlapping bus ranges are allowed only across different `SegmentId` values.
- `Ecam` does not own the MMIO mapping and does not release it.
- `Ecam` performs no allocation.
- `Ecam` performs no hidden locking, retry, logging, or caching.

## ConfigSpace vtable

`Ecam.configSpace()` returns a `ConfigSpace` with vtable entries for:

```zig
read8
read16
read32
write8
write16
write32
```

Each vtable function:

1. receives an `Sbdf` and function-window `offset` already shape-validated by `ConfigSpace`;
2. calls `Ecam.find(sbdf)` to locate the segment whose `SegmentId` matches `sbdf.segment`;
3. if no segment matches, returns `error.OutOfBounds`;
4. checks that the matched segment contains `sbdf.bdf.bus` in `bus_start..=bus_end`; otherwise returns `error.OutOfBounds`;
5. computes the ECAM virtual address using the matched segment's `base` and `bus_start`;
6. performs exactly one volatile MMIO access at the requested width.

A conforming `Ecam` backend supports every public `ConfigSpace` width: 1, 2, and 4 bytes.

## Address calculation `[std]`

ECAM uses the offset formulas owned by `docs/specs/core/bdf.md`.

For an access to `sbdf` and function-window `offset`:

```zig
fn ecamAddress(self: *Ecam, sbdf: core.Sbdf, offset: usize) ConfigSpace.Error!zstdx.addr.VirtAddr {
    const segment = self.find(sbdf) orelse return error.OutOfBounds;
    if (!segment.contains(sbdf)) return error.OutOfBounds;

    const register: u12 = @intCast(offset); // ConfigSpace already proved 0x000..=0xFFF.
    const byte_offset = sbdf.bdf.ecamOffset(segment.bus_start, register);
    return segment.base.add(@intCast(byte_offset)) catch return error.OutOfBounds;
}
```

Required formula:

```text
((bus - bus_start) << 20) |
(device << 15) |
(function << 12) |
register
```

Rules:

- Use `(bus - bus_start) << 20`, not `bus << 20`, where `bus_start` is the matched segment's `bus_start`.
- `bus - bus_start` is evaluated only after `Ecam.find` returns a segment and `Segment.contains(sbdf)` succeeds against it.
- `register` is the function-window offset `0x000..=0xFFF`.
- Multi-byte containment inside the 4 KiB function window is owned by `ConfigSpace`.
- Segment/bus containment is owned by `Ecam`.
- Address arithmetic overflow maps to `error.OutOfBounds`.

## Access width behavior

ECAM performs direct volatile MMIO at the requested width.

Rules:

- `read8` and `write8` perform one 8-bit MMIO access.
- `read16` and `write16` perform one naturally aligned 16-bit MMIO access.
- `read32` and `write32` perform one naturally aligned 32-bit MMIO access.
- `read8` and `read16` are not synthesized from `read32`.
- `write8` and `write16` are not synthesized through read-modify-write of a 32-bit register.
- `ConfigSpace` owns natural-alignment validation before ECAM is called.
- ECAM should not return `UnsupportedAccessWidth` for validated 8-, 16-, or 32-bit accesses.

No hidden read-modify-write is allowed because PCI config registers may have side-effect or write-one-to-clear fields.

## Endian and MMIO representation

Public ECAM reads return native-endian integers. Public ECAM writes accept native-endian integers.

PCI config-space storage is little-endian. ECAM owns the conversion between native integers and the little-endian MMIO byte order at the volatile access boundary.

Rules:

- `u8` accesses need no endian conversion.
- 16-bit reads perform one volatile 16-bit load and convert little-endian to native integer.
- 32-bit reads perform one volatile 32-bit load and convert little-endian to native integer.
- 16-bit writes convert native integer to little-endian and perform one volatile 16-bit store.
- 32-bit writes convert native integer to little-endian and perform one volatile 32-bit store.

Illustrative read shape:

```zig
fn read16(context: *anyopaque, sbdf: core.Sbdf, offset: usize) ConfigSpace.Error!u16 {
    const ecam: *Ecam = @ptrCast(@alignCast(context));
    const address = try ecam.ecamAddress(sbdf, offset);
    const ptr: *volatile u16 = @ptrFromInt(address.raw());
    const raw = ptr.*;
    return std.mem.littleToNative(u16, raw);
}
```

Illustrative write shape:

```zig
fn write32(context: *anyopaque, sbdf: core.Sbdf, offset: usize, value: u32) ConfigSpace.Error!void {
    const ecam: *Ecam = @ptrCast(@alignCast(context));
    const address = try ecam.ecamAddress(sbdf, offset);
    const ptr: *volatile u32 = @ptrFromInt(address.raw());
    ptr.* = std.mem.nativeToLittle(u32, value);
}
```

## Ordering and volatility

ECAM uses volatile MMIO loads and stores.

Rules:

- Each public ECAM read performs a volatile load.
- Each public ECAM write performs a volatile store.
- ECAM does not cache config values.
- ECAM does not coalesce adjacent accesses.
- ECAM does not add architecture fences by default.
- ECAM does not perform post-write read-back by default.
- ECAM does not lock around accesses by default.
- Resource-programming and interrupt-programming specs own operation-specific ordering beyond the individual volatile access.

Ownership examples:

- BAR sizing owns write-probe-restore sequencing.
- Resource programming owns command-register and bridge-window write ordering.
- MSI/MSI-X programming owns ordering around capability state and MSI-X table/PBA memory.
- Architecture specs own any required target-specific fence primitive if a later operation requires one.

## Error behavior

`Ecam.from(segments)` returns `Ecam.Error!Ecam`.

| Failure | Error |
|---|---|
| `segments.len == 0` | `error.NoSegments` |
| any `segment.bus_start > segment.bus_end` | `error.InvalidBusRange` |
| two entries with the same `SegmentId` value | `error.DuplicateSegment` |

ECAM vtable functions return `ConfigSpace.Error`.

| Failure | Error |
|---|---|
| no segment in the set matches `sbdf.segment` | `error.OutOfBounds` |
| matched segment does not contain `sbdf.bdf.bus` | `error.OutOfBounds` |
| ECAM address arithmetic overflow | `error.OutOfBounds` |
| backend cannot honor a validated width | `error.UnsupportedAccessWidth` |
| defensive detection of misalignment | `error.UnalignedAccess` |

In normal calls through `ConfigSpace`, offset containment and natural alignment have already been validated before the ECAM vtable function runs.

## Lifetime and concurrency

`Ecam` borrows a mapped MMIO aperture.

Rules:

- Caller owns aperture lifetime for every mapped `Segment` in the slice.
- Caller owns the `[]const Segment` storage; `Ecam` does not copy or reallocate.
- Caller owns mapping attributes and cacheability.
- Caller owns synchronization if the platform requires serialized config access.
- `Ecam` does not make the mapping safe after unmap, hot-unplug, or device removal.
- Concurrent reads/writes through the same `Ecam` follow the platform's MMIO rules; this spec adds no lock or atomic protocol.
- `ConfigSpace` handles produced by `configSpace()` borrow the `Ecam` by pointer.

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `Segment.validate` | never | never | O(1) bus-range check | none | caller-owned value | none |
| `Segment.contains` | never | never | O(1) segment/bus check | none | caller-owned value | none |
| `Ecam.from` | never | never | O(N) descriptor and duplicate-SegmentId scan | none | caller-owned value | none |
| `Ecam.find` | never | never | O(N) linear scan | none | caller-owned value | none |
| `Ecam.configSpace` | never | never | none | handle borrows `Ecam` | backend-defined | none |
| ECAM `read*` | never | volatile MMIO only | O(N) find + O(1) bus/address check | none | platform-defined | volatile load |
| ECAM `write*` | never | volatile MMIO only | O(N) find + O(1) bus/address check | config state on success | platform-defined | volatile store |

## zstdx usage

Direct usage:

- `zstdx.addr.VirtAddr` for mapped ECAM virtual addresses.
- `zstdx.addr.VirtAddr.add` for checked virtual-address arithmetic.

Not used directly by live ECAM MMIO:

- `zstdx.bytes.load` / `zstdx.bytes.store` — byte-buffer helpers, not volatile MMIO.
- `zstdx.layout.Le(T)` as a volatile pointer target — byte-stable storage with alignment 1, not a required single-width MMIO access type.
- `zstdx.addr.PhysAddr` — zpci does not translate physical ECAM bases.
- `zstdx.addr.Page` — ECAM does not own mapping/page policy.
- `zstdx.ranges.RangeSet` / `RangeMap` — not needed for one aperture access.

## Facade re-export `[zpci]`

`src/config.zig` re-exports ECAM types:

```zig
const ecam = @import("config/ecam.zig");

pub const Segment = ecam.Segment;
pub const Ecam = ecam.Ecam;
```

Callers reach them as `pci.config.Segment` and `pci.config.Ecam`.

## Usage

Single-segment aperture (slice of one):

```zig
const segments = [_]pci.config.Segment{
    .{
        .segment = pci.core.SegmentId.of(0),
        .base = zstdx.addr.VirtAddr.fromInt(mapped_ecam_base),
        .bus_start = 0,
        .bus_end = 255,
    },
};

var ecam = try pci.config.Ecam.from(&segments);
const config = ecam.configSpace();

const function = try pci.config.Function.validate(config, sbdf);
const vendor = try function.vendorId();
_ = vendor;
```

Multi-segment aperture:

```zig
const segments = [_]pci.config.Segment{
    .{
        .segment = pci.core.SegmentId.of(0),
        .base = zstdx.addr.VirtAddr.fromInt(seg0_base),
        .bus_start = 0,
        .bus_end = 0xFF,
    },
    .{
        .segment = pci.core.SegmentId.of(1),
        .base = zstdx.addr.VirtAddr.fromInt(seg1_base),
        .bus_start = 0,
        .bus_end = 0xFF,
    },
};

var ecam = try pci.config.Ecam.from(&segments);
const config = ecam.configSpace();
```

Segment-limited aperture (bus contribution starts at zero for `bus_start`):

```zig
const segments = [_]pci.config.Segment{
    .{
        .segment = pci.core.SegmentId.of(0),
        .base = zstdx.addr.VirtAddr.fromInt(mapped_ecam_base),
        .bus_start = 0x40,
        .bus_end = 0x7F,
    },
};
```

For bus `0x40`, the ECAM bus contribution is zero:

```text
(bus - bus_start) << 20 == (0x40 - 0x40) << 20 == 0
```

An `Sbdf` whose `SegmentId` is not in the set, or whose bus falls outside the matched segment's range, maps to `OutOfBounds`:

```zig
_ = config.read16(unknown_segment_sbdf, 0x00) catch |err| switch (err) {
    error.OutOfBounds => return null,
    else => return err,
};
```

Duplicate `SegmentId` values are rejected at construction:

```zig
const bad = [_]pci.config.Segment{
    .{ .segment = .of(0), .base = a, .bus_start = 0x00, .bus_end = 0x7F },
    .{ .segment = .of(0), .base = b, .bus_start = 0x80, .bus_end = 0xFF },
};
_ = pci.config.Ecam.from(&bad) catch |err| switch (err) {
    error.DuplicateSegment => {},
    else => unreachable,
};
```

## Non-goals

- ACPI MCFG parsing.
- Physical memory mapping.
- Cache-attribute or page-table management.
- PIO config access.
- Header decode beyond returning bytes through `ConfigSpace`.
- BAR sizing or resource assignment.
- MSI/MSI-X programming.
- Device reset, hotplug, or removal handling.
- Hidden locking, allocation, retries, tracing, or metrics.

## Open questions

None owned by this spec.
