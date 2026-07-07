# BAR decode and sizing

Defines `bar.Kind`, `bar.Entry`, `bar.View`, `bar.Iterator`, and `bar.BarRef`. This is the single source of truth for how raw BAR slots are decoded, how 32-bit and 64-bit BARs pair, and how the spec-mandated save/probe/restore sizing sequence runs.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on BAR decode and sizing. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/common.md`
- `docs/specs/header/type0.md`
- `docs/specs/header/type1.md`
- `docs/specs/resources/model.md`
- `docs/specs/resources/assignment.md`
- `docs/specs/resources/programming.md`
- `docs/specs/resources/bridge.md`

## Scope

Owned:

- `Kind` decode union over BAR slot contents (`none`, `Io`, `Memory`).
- `Entry` returned by the iterator and individual gets, carrying the low-slot index, slot count, and decoded `Kind`.
- 32-bit and 64-bit memory BAR handling, including 64-bit slot pairing.
- `View` per-function BAR view keyed by header layout (`type0` or `type1`).
- `Iterator` over `View` that advances correctly past 64-bit pairs.
- BAR sizing probe: save → decode-disable → write all-ones → read back → restore BAR → restore Command.
- Decode-disable orchestration through `header.common.View` (`command.io_space` / `command.memory_space`).
- `BarRef` borrowed reference used by resource programming for the eventual base write.
- Mapping decode/sizing failures to `MalformedBar` and post-probe restore failures to `ProgrammingPartial`.

Deferred:

- Raw `u32` BAR reads through the header layout — owned by `docs/specs/header/type0.md` and `docs/specs/header/type1.md`.
- Resource assignment, prefetchable promotion, conflict resolution — `docs/specs/resources/model.md` and `docs/specs/resources/assignment.md`.
- Final base writes for BARs as part of resource programming — `docs/specs/resources/programming.md`. `bar.zig` owns the sizing write/restore; resource programming owns the assignment write.
- Bridge memory/IO/prefetchable **windows** (bridge windows are not BARs even though they live in the type-1 header) — `docs/specs/resources/bridge.md`.
- Expansion-ROM base address sizing and enable orchestration — `docs/specs/resources/programming.md`.

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness. `Kind.Memory.base`/`size` are stored as native `u64` integers reconstructed from up to two 32-bit config reads.

## Decode model `[std]`

A BAR is one or two 32-bit slots in the header:

- 32-bit memory BAR: 1 slot.
- 64-bit memory BAR: 2 consecutive slots (low half then high half).
- IO BAR: 1 slot.
- Unimplemented BAR: 1 slot, reads `0x00000000` after decode-disable.

BAR low-slot bit decoding:

| Bit(s) | Meaning |
|---:|---|
| `0` | `0` = memory BAR, `1` = IO BAR |
| Memory `2..1` | `0b00` = 32-bit, `0b10` = 64-bit, `0b01` reserved → `MalformedBar`, `0b11` reserved → `MalformedBar` |
| Memory `3` | prefetchable bit |
| Memory base | bits `31..4` |
| IO bit `1` | reserved, must be `0` |
| IO base | bits `31..2` |

`Kind` reflects these:

```zig
pub const Kind = union(enum) {
    none,
    io: Io,
    memory: Memory,

    pub const Io = struct {
        base: u32,
        size: u32, // 0 if not sized; set by View.size or zero for View.get
    };

    pub const Memory = struct {
        base: u64,
        size: u64, // 0 if not sized
        width: Width,
        prefetchable: bool,
    };

    pub const Width = enum { bits_32, bits_64 };
};
```

Rules:

- `View.get(index)` returns `Kind` with `size = 0` (it does not probe).
- `View.size(index)` returns `Kind` with the probed `size`.
- 64-bit memory BARs combine the two 32-bit slots: `base = (high << 32) | (low & ~0xF)`. The `0..3` decode bits are masked off when forming `base`.
- IO BARs mask off bits `1..0` when forming `base`.
- Unimplemented BARs report `Kind.none` and `slot_count = 1`.

## Entries and slot counting

```zig
pub const Entry = struct {
    index: usize,      // low slot index in the header's bar array
    slot_count: usize, // 1 or 2; 2 only for 64-bit memory BARs
    kind: Kind,
};
```

Rules:

- A 32-bit BAR or unimplemented BAR has `slot_count == 1`.
- A 64-bit memory BAR has `slot_count == 2` and reserves `index..index + 1`.
- `Iterator.next()` advances by `slot_count`, so the high slot of a 64-bit pair is never returned as a separate entry.
- A 64-bit BAR whose low slot is the last slot in the array (`index + 1 == count`) yields `MalformedBar`.

## `View` `[zpci]`

```zig
pub const Layout = enum { type0, type1 };

pub const View = struct {
    function: config.Function,
    layout: Layout,

    pub fn init(function: config.Function, layout: Layout) View;

    /// Reads the function's header kind through `header.common.View`
    /// and picks the layout. Returns `null` when the header kind has
    /// no BARs (currently unreachable — every zpci-supported header
    /// kind has BARs, but the accessor is forward-compatible).
    pub fn of(function: config.Function) config.ConfigSpace.Error!?View;

    pub fn count(self: View) usize;
    pub fn iterator(self: View) Iterator;
    pub fn get(self: View, index: usize) Error!Entry;
    pub fn size(self: View, index: usize) Error!Entry;
    pub fn sizeAll(self: View, scratch: []Entry) Error![]Entry;

    /// Constructs a `BarRef` naming the low slot at `index`. Asserts
    /// `index < count()` and asserts `index` is not the high half of
    /// a 64-bit memory BAR (programmer error).
    pub fn ref(self: View, index: usize) BarRef;
};

pub const Iterator = struct {
    pub fn next(self: *Iterator) Error!?Entry;
};

/// Upper bound on `View.count()` across every supported layout. Callers
/// stack-allocating `[max_entries]Entry` are sized for either layout.
pub const max_entries: usize = 6;

pub const BarRef = struct {
    function: config.Function,
    layout: Layout,
    index: usize,
    /// Slot count of the BAR at `index`: `1` for IO / 32-bit-memory /
    /// unimplemented, `2` for 64-bit-memory. Captured at `View.ref`
    /// construction so resource programming can decide dword count
    /// without re-decoding.
    slot_count: usize,
};

Rules:

- `count()` returns `6` for `.type0` and `2` for `.type1`. The constants `header.type0.bar_count` and `header.type1.bridge_bar_count` define these.
- `get(index)` asserts `index < count()` and asserts `index` is not the high half of a 64-bit memory BAR occupying `(index - 1, index)` (programmer error). Callers using `Iterator` or `sizeAll` never trip this; callers that index by number must skip the high half after decoding the low.
- `size(index)` asserts the same invariants as `get(index)` before running the per-slot sizing probe.
- `sizeAll(scratch)` probes every BAR under a single decode-disable window; see §Batch sizing.
- `ref(index)` asserts `index < count()` and asserts `index` is not the high half of a 64-bit memory BAR (programmer error). The returned `BarRef` captures the BAR's `layout` and `slot_count` so resource programming can decide dword count without re-decoding.
- The `Iterator` walks slots in order; it never reads the high slot of a 64-bit pair as a separate `Entry`.

## Sizing probe `[std]`

For a BAR at low-slot `index`:

```
0.  offset_low      = bar_offset(layout, index)
1.  save_low        = read32(offset_low)
2.  is_io           = (save_low & 1) == 1
3.  is_64           = (!is_io) and ((save_low >> 1) & 0b11 == 0b10)
4.  save_high       = if is_64 read32(offset_low + 4) else 0
5.  command_before  = common.command()
6.  command_disable = command_before with .io_space cleared (io) or .memory_space cleared (mem)
7.  setCommand(command_disable)
8.  write32(offset_low, 0xFFFFFFFF)
9.  if is_64 write32(offset_low + 4, 0xFFFFFFFF)
10. probed_low      = read32(offset_low)
11. probed_high     = if is_64 read32(offset_low + 4) else 0
12. write32(offset_low, save_low)
13. if is_64 write32(offset_low + 4, save_high)
14. setCommand(command_before)
15. compute size from probed values per the bar kind
```

Rules:

- The probe requires `index` to name the **low slot** of a BAR. `View` asserts, when `index > 0`, that slot `index - 1` decoded as a non-64-bit-memory BAR (i.e., the current slot is not the high half of a 64-bit pair). This is a programmer error, not a typed error.
- Steps 12–14 (restore BAR low, restore BAR high if 64-bit, restore Command) run even on error.
- The first error encountered in steps 5–11 is returned to the caller after restoration is attempted.
- If steps 12–14 themselves fail after a successful steps 5–11, the spec returns `ProgrammingPartial`: the probe succeeded but the restore that would return hardware to its pre-probe state itself failed.
- If steps 5–11 fail and step 12, 13, or 14 also fails, the original error from 5–11 is returned; the restore failure does not change the returned error.
- Probed low values that are `0x00000000` indicate the BAR is not implemented: `Kind.none`, `size = 0`, `slot_count = 1`.
- For implemented BARs, size is computed by masking decode bits and inverting:
  - Memory 32-bit: `size = (~(probed_low & 0xFFFF_FFF0)) + 1`.
  - Memory 64-bit: `size = (~((probed_high << 32) | (probed_low & 0xFFFF_FFF0))) + 1`.
  - IO: `size = (~(probed_low & 0xFFFF_FFFC)) + 1` truncated to `u32`.
- An IO BAR whose `probed_low` masks to zero after the all-ones probe is unimplemented; the result is `Kind.none`.

## Decode-disable orchestration `[std]`

Rules:

- For IO BARs, clear `Command.io_space` for steps 7–14.
- For memory BARs (32-bit or 64-bit), clear `Command.memory_space`.
- `size(index)` clears exactly one of `Command.io_space` or `Command.memory_space`, matching the addressed BAR's kind.
- `sizeAll(scratch)` clears **both** `Command.io_space` and `Command.memory_space` for the whole walk, unconditionally.
- The view does not skip decode-disable based on prior state; it always reads and writes Command around the probe (per-slot for `size`, once around the whole walk for `sizeAll`).
- `size(index)` is self-contained; each call opens and closes its own decode-disable window.

## Batch sizing `[zpci]`

`sizeAll(scratch)` probes every BAR the view exposes under a single decode-disable window.

Argument shape:

- `scratch.len < count()` returns `error.StorageExhausted` **before** any config I/O runs. Command is not touched on this failure.

Sequence:

```
 0. command_before  = common.command()
 1. command_disable = command_before with .io_space=false and .memory_space=false
 2. setCommand(command_disable)
 3. i = 0; out_len = 0
 4. while i < count():
      a. save_low  = read32(bar_offset(layout, i))
      b. is_io     = (save_low & 1) == 1
      c. is_64     = (!is_io) and ((save_low >> 1) & 0b11 == 0b10)
      d. save_high = if is_64 read32(bar_offset(layout, i) + 4) else 0
      e. write32(bar_offset(layout, i), 0xFFFFFFFF)
      f. if is_64 write32(bar_offset(layout, i) + 4, 0xFFFFFFFF)
      g. probed_low  = read32(bar_offset(layout, i))
      h. probed_high = if is_64 read32(bar_offset(layout, i) + 4) else 0
      i. write32(bar_offset(layout, i), save_low)
      j. if is_64 write32(bar_offset(layout, i) + 4, save_high)
      k. compute the Entry per the BAR kind; push into scratch[out_len]
      l. out_len += 1; i += slot_count
 5. setCommand(command_before)
 6. return scratch[0..out_len]
```

Rules:

- Command is written exactly twice per call: once at step 2 (disable), once at step 5 (restore).
- The per-BAR probe body (steps 4a–4k) is the same as `size(index)` minus the Command reads/writes at steps 5–7 and 14 of the per-slot sequence.
- `sizeAll` respects 64-bit pairing the same way `Iterator` does: `slot_count` from the decoded low slot advances `i`. The returned slice length equals the number of Entry values written, which is `count()` minus the number of 64-bit pairs.
- Restore-on-error: if any step in 4a–4k returns an error at BAR K, the implementation attempts to restore every already-probed BAR's low (and high, if 64-bit) slot in reverse walk order, then executes step 5 (restore Command), then returns the first observed error.
- If a restore step (any 4i/4j attempted on already-probed BARs during error recovery, or step 5) itself fails after a successful probe of at least one BAR, the call returns `ProgrammingPartial` per §Sizing probe.
- On any error return, the contents of `scratch` are undefined; the caller must not read the slice.
- `sizeAll` observes live hardware; it does not cache or snapshot.
- `sizeAll` performs no allocation and holds no state between calls.

Ordering guarantees:

- Every BAR probe runs with both decode bits clear.
- Command is restored exactly once, after all BAR slots have been restored (or after error-recovery restores have been attempted).
- No BAR probe reorders across another BAR probe within one call; the walk is strictly ascending by low-slot index.

Cost vs. `size(index)`:

| Pattern | Config accesses per implemented BAR | Command accesses per call |
|---|---:|---:|
| `size(index)` | 4 (or 6 for 64-bit) | 4 |
| `sizeAll(scratch)` | 4 (or 6 for 64-bit) | 4 (whole call) |

For an endpoint with N implemented BARs, `sizeAll` saves `(N - 1) × 4` Command accesses.

## Validation behavior

Returns `MalformedBar` for:

- Memory BAR with reserved type encoding `0b01` in bits `2..1`.
- Memory BAR with type encoding `0b11` in bits `2..1`.
- IO BAR with reserved bit `1` set.
- 64-bit memory BAR whose low slot is the last slot in the array (no room for the high half).
- 64-bit memory BAR whose high slot has decode bits set (it must be raw upper-32 bits).

Returns `ProgrammingPartial` when the post-probe restore fails after a successful probe (per-slot or batched).

Returns `ConfigSpace.Error` (`OutOfBounds`, `UnsupportedAccessWidth`, `UnalignedAccess`) when a config-space read or write fails. `bar.zig` does not synthesize narrower accesses; it relies on `ConfigSpace` width semantics.

Returns `StorageExhausted` from `sizeAll` when `scratch.len < count()`.

`bar.Error` is:

```zig
pub const Error = ConfigSpace.Error || error{
    MalformedBar,
    ProgrammingPartial,
    StorageExhausted,
};
```

## View / borrowing behavior

- `View`, `Iterator`, and `BarRef` borrow `config.Function`. They do not allocate.
- The view caches nothing across calls. Each method reads live.
- `BarRef` is small and copyable; resource programming may store it without retaining the iterator.
- Lifetime follows the underlying `ConfigSpace` backend.

## zstdx usage

Direct: none.

- Containment, alignment, and width checks come from `ConfigSpace`.
- BAR offset arithmetic is fixed by `header/type0.md` and `header/type1.md`.
- Sizing math uses Zig integer ops only.
- No `zstdx.bytes`, `zstdx.layout.Le`, `zstdx.core.Range`, or `zstdx.ranges` are required.

`MalformedBar` is mapped at the bar boundary; no `zstdx.bytes.EndOfStream` or `zstdx.core.Range` errors leak.

## Facade re-export `[zpci]`

`src/bar.zig` is the bar module itself; `src/zpci.zig` re-exports it:

```zig
pub const bar = @import("bar.zig");
```

Callers reach the public surface as `zpci.bar.View`, `zpci.bar.Iterator`, `zpci.bar.Entry`, `zpci.bar.Kind`, `zpci.bar.BarRef`, and `zpci.bar.Error`.

## Usage

Decode all BARs on a type-0 function:

```zig
const function = try zpci.config.Function.validate(config, sbdf);
if ((try function.headerKind()) != .type0) return;

const view = zpci.bar.View.init(function, .type0);
var it = view.iterator();
while (try it.next()) |entry| {
    switch (entry.kind) {
        .none => {},
        .io => |io| std.log.info("bar {d}: io base 0x{x}", .{ entry.index, io.base }),
        .memory => |mem| std.log.info(
            "bar {d}: mem base 0x{x} width {s} {s}",
            .{
                entry.index,
                mem.base,
                @tagName(mem.width),
                if (mem.prefetchable) "prefetchable" else "non-prefetchable",
            },
        ),
    }
}
```

Size BAR 0:

```zig
const sized = try view.size(0);
switch (sized.kind) {
    .none => {},
    .io => |io| std.log.info("bar0 io size 0x{x}", .{io.size}),
    .memory => |mem| std.log.info("bar0 mem size 0x{x}", .{mem.size}),
}
```

Size every BAR under one decode-disable window:

```zig
var scratch: [zpci.header.type0.bar_count]zpci.bar.Entry = undefined;
const entries = try view.sizeAll(&scratch);
for (entries) |entry| switch (entry.kind) {
    .none => {},
    .io => |io| std.log.info("bar {d}: io size 0x{x}", .{ entry.index, io.size }),
    .memory => |mem| std.log.info(
        "bar {d}: mem size 0x{x} width {s} {s}",
        .{
            entry.index,
            mem.size,
            @tagName(mem.width),
            if (mem.prefetchable) "prefetchable" else "non-prefetchable",
        },
    ),
};
```

Take a `BarRef` for resource programming:

```zig
const ref = view.ref(0);
_ = ref; // passed to resources.programming.commit
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `View.init` | never | never | none | none | borrowed | none |
| `View.iterator` / `next` | never | config I/O only | per-slot decode | none | backend-defined | per-slot reads |
| `View.get` | never | config I/O only | O(1) | none | backend-defined | one or two reads |
| `View.size` | never | config I/O only | O(1) | restored BAR + Command | backend-defined | save → disable → probe → restore |
| `View.sizeAll` | never | config I/O only | O(count) probes + one decode-disable window | restored BARs + Command | backend-defined | disable → probes → restores → enable |
| `View.ref` | never | never | none | none | borrowed | none |

## Non-goals

- Resource assignment, plan generation, conflict resolution.
- Final base writes outside the sizing restore.
- Bridge memory/IO/prefetchable window decode.
- Expansion-ROM sizing or enable orchestration.
- Cached BAR snapshots.
- Hidden retries beyond a single restore attempt.
- Diagnostic out-parameters for restore failures.

## Open questions

None owned by this spec.
