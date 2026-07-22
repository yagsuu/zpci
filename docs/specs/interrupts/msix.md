# MSI-X capability

Defines the typed view of the Extended Message Signaled Interrupt capability identified by capability id `0x11` in the standard capability list, and its two programming surfaces: the Message Control byte in config space, and per-vector Table and Pending Bit Array entries in BAR memory. Owns the wire layout of Message Control, the Table Offset / BIR and PBA Offset / BIR encodings, `VectorControl`, `VectorEntry`, `interrupts.msix.View`, the per-entry self-masking write sequence in `View.programEntry` and `View.programEntries`, the RMW commit sequences in `View.enable`, `View.disable`, `View.setFunctionMask`, and `View.setVectorMask`, and the `readEntry`, `vectorPending`, and `pendingDword` read surfaces.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `interrupts.msix.View`, `VectorEntry`, `VectorControl`, `MessageControl`, `TableLocation`, and `PbaLocation`. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/bar.md`
- `docs/specs/memory/bar.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/interrupts/msi.md`

## Scope

Owned:

- Public constants naming each MSI-X register's byte offset in config space and every table-entry field's byte offset in BAR memory.
- `MessageControl` packed struct decoding of the 16-bit Message Control register at capability offset `0x02`.
- `VectorControl` packed struct decoding of the 32-bit Vector Control dword at table entry offset `0xC`.
- `TableLocation` and `PbaLocation` decoded from the Table Offset / BIR and PBA Offset / BIR registers.
- `VectorEntry` value carrying `address`, `data`, and `masked`.
- `interrupts.msix.View`, a borrowed typed view over `config.Function` scoped to one MSI-X capability instance.
- `View.find` and `View.validate` constructors, snapshot queries, live config-space and BAR-memory reads, `View.enable`, `View.disable`, `View.setFunctionMask`, `View.setVectorMask`, `View.programEntry`, and `View.programEntries`.
- Snapshot fixing of `table_size_minus_one`, `TableLocation`, and `PbaLocation` at `validate`.
- Reserved-bit preservation policy for Message Control and Vector Control writes.
- Self-masking write sequence in `programEntry`: mask vector, write address / data, unmask per `entry.masked`.
- Per-entry atomicity in `programEntries` with per-entry rollback and cross-entry commit boundary.
- Save-then-write-then-verify commit discipline with per-view rollback in every write surface.
- Routing-input validation: `vector_index < tableSize()` bounds on every write and read that accepts a vector index; `first_index + entries.len <= tableSize()` for batch writes.
- BAR-memory containment validation: table region `[table_offset, table_offset + table_size * 16)`, PBA region `[pba_offset, pba_offset + ceil(table_size / 32) * 4)`.

Deferred:

- MSI capability (`docs/specs/interrupts/msi.md`).
- BAR mapping, unmapping, cache-attribute policy, physical-to-virtual translation (caller-owned via `docs/specs/memory/bar.md`).
- BAR base resolution (`docs/specs/bar.md`).
- Command-register programming, including `interrupt_disable` orchestration (`docs/specs/header/common.md`).
- Vector allocation strategy (caller policy).
- Message-address encoding for a specific interrupt controller (LAPIC, x2APIC, GIC).
- Cross-function MSI-X coordination.
- Pending-bit acknowledgement policy. Pending Bit Array is read-only; hardware clears bits on interrupt delivery.
- Function-level reset before MSI-X programming.
- Retry on transient failures.
- Diagnostic out-parameters.
- Concurrent commits on one `ConfigSpace` or one `BarMemory`.
- Batch reads of the entire PBA or the entire table.
- Cross-batch atomicity in `programEntries`. Callers wanting the entire batch masked during the write use `setFunctionMask(true)` before and `setFunctionMask(false)` after.

## Layering `[zpci]`

`interrupts/msix` is the only zpci module that programs MSI-X capability registers, table entries, or Vector Control bits.

Layering constraints from `docs/specs/architecture.md`:

- `interrupts/` imports `core/`, `config/`, `capabilities/`, and `memory/`. This spec imports `capabilities/list.zig` for `list.Iterator`, `list.Cursor`, and `list.Capability`; `config/space.zig` for `config.Function` and `config.ConfigSpace`; `memory/bar.zig` for `memory.BarMemory`.
- `interrupts/` MUST NOT import `resources/`, `topology/`, `bar`, or `header/`. Callers resolve the Table BIR and PBA BIR to concrete BAR bases via `docs/specs/bar.md` at the callsite, then construct `memory.BarMemory` accessors per `docs/specs/memory/bar.md`.
- `View.programEntry`, `View.programEntries`, `View.setVectorMask`, `View.enable`, `View.disable`, and `View.setFunctionMask` MUST NOT allocate. Save state lives in a fixed-size frame on the internal stack.

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness. `MessageControl` and `VectorControl` bit-cast from native `u16` / `u32` reads; `TableLocation` and `PbaLocation` are decoded from native `u32` reads.

## Public constants `[std]`

```zig
pub const cap_id: u8 = 0x11;

pub const register = struct {
    pub const message_control: u8 = 0x02;
    pub const table_offset_bir: u8 = 0x04;
    pub const pba_offset_bir: u8 = 0x08;
};

pub const entry = struct {
    pub const message_address_lo: usize = 0x0;
    pub const message_address_hi: usize = 0x4;
    pub const message_data: usize = 0x8;
    pub const vector_control: usize = 0xC;
};

pub const table_entry_size: usize = 16;
pub const pba_bits_per_dword: usize = 32;
pub const max_table_size: u16 = 2048;
```

Rules:

- `message_control`, `table_offset_bir`, and `pba_offset_bir` are byte offsets relative to `capability.offset` in config space.
- `message_address_lo`, `message_address_hi`, `message_data`, and `vector_control` are byte offsets relative to the start of one table entry in BAR memory.
- `table_entry_size` is fixed by PCI r5.0.
- `max_table_size` is fixed by the width of the `table_size_minus_one` field (`u11`); the maximum encoded value `0x7FF` corresponds to `2048` entries.

## `MessageControl` `[std]`

```zig
pub const MessageControl = packed struct(u16) {
    table_size_minus_one: u11 = 0,
    _reserved11: u3 = 0,
    function_mask: bool = false,
    msix_enable: bool = false,
};
```

Rules:

- `MessageControl` is bit-cast from the `u16` read at `capability.offset + register.message_control`.
- `_reserved11` (bits `[13:11]`) is `RsvdP` per PCI base r5.0. `View.enable`, `View.disable`, and `View.setFunctionMask` preserve these bits from the saved value.
- `table_size_minus_one` (bits `[10:0]`) is RO. Actual table size equals `table_size_minus_one + 1`, in the range `1..=2048`.
- `function_mask` (bit `[14]`) is RW. When `true`, every vector is masked regardless of per-vector `VectorControl.masked`.
- `msix_enable` (bit `[15]`) is RW. Master enable.
- Every field defaults to its zero-bit value, so `MessageControl{}` encodes `0x0000`.

## `VectorControl` `[std]`

```zig
pub const VectorControl = packed struct(u32) {
    masked: bool = false,
    _reserved1: u31 = 0,
};
```

Rules:

- `VectorControl` is bit-cast from the `u32` read at `entry_base + entry.vector_control`.
- `_reserved1` (bits `[31:1]`) is `RsvdP` per PCI base r5.0. `View.programEntry`, `View.programEntries`, and `View.setVectorMask` preserve these bits from the saved value.
- `masked` (bit `[0]`) is RW.
- Every field defaults to its zero-bit value, so `VectorControl{}` encodes `0x0000_0000`.

## `TableLocation` and `PbaLocation` `[std]`

```zig
pub const TableLocation = struct {
    bir: u3,
    offset: u32,
};

pub const PbaLocation = struct {
    bir: u3,
    offset: u32,
};
```

Rules:

- `bir` is decoded from bits `[2:0]` of the Table Offset / BIR or PBA Offset / BIR register. Valid values are `0..=5`; `6` and `7` are reserved.
- `offset` is the register value with the low 3 bits cleared. The offset is 8-byte aligned per PCI r5.0.
- `TableLocation.bir == 6` or `TableLocation.bir == 7` in `View.validate` returns `error.MalformedField`.
- `PbaLocation.bir == 6` or `PbaLocation.bir == 7` in `View.validate` returns `error.MalformedField`.
- Table BIR and PBA BIR MAY differ; the caller supplies the appropriate `BarMemory` per operation.

## `VectorEntry` `[zpci]`

```zig
pub const VectorEntry = struct {
    address: u64,
    data: u32,
    masked: bool,
};
```

Rules:

- `address` is the full 64-bit message-address value in native byte order. MSI-X is always 64-bit addressable per PCI r5.0; no 32-bit-only variant exists.
- `data` is the 32-bit message-data value in native byte order. Unlike MSI, MSI-X data is full `u32`; hardware does not overwrite low bits for multi-vector encoding.
- `masked` is the desired final `VectorControl.masked` state after `programEntry` returns.

## `View` `[zpci]`

```zig
pub const View = struct {
    function: config.Function,
    base: u8,
    control_snapshot: MessageControl,
    table_location: TableLocation,
    pba_location: PbaLocation,

    pub const ReadError = error{
        MalformedCapability,
        MalformedField,
        BarMemoryOutOfBounds,
        UnalignedAccess,
    } || config.ConfigSpace.Error;

    pub const ProgramError = error{
        MalformedField,
        InvalidRouting,
        BarMemoryOutOfBounds,
        UnalignedAccess,
        ProgrammingReadbackMismatch,
        ProgrammingWriteFailed,
        ProgrammingPartial,
    };

    pub fn find(function: config.Function) ReadError!?View;
    pub fn validate(function: config.Function, capability: list.Capability) ReadError!View;

    pub fn tableSize(self: View) u16;
    pub fn tableLocation(self: View) TableLocation;
    pub fn pbaLocation(self: View) PbaLocation;

    /// Byte length of the table region: `tableSize() * table_entry_size`.
    /// Convenience for sizing the `BarMemory` a caller passes as
    /// `table_memory`.
    pub fn tableSpanBytes(self: View) usize;

    /// Byte length of the PBA region: `ceil(tableSize() / 32) * 4`.
    /// Convenience for sizing the `BarMemory` a caller passes as
    /// `pba_memory`.
    pub fn pbaSpanBytes(self: View) usize;

    pub fn messageControl(self: View) ReadError!MessageControl;
    pub fn enabled(self: View) ReadError!bool;
    pub fn functionMasked(self: View) ReadError!bool;

    pub fn readEntry(self: View, table_memory: memory.BarMemory, vector_index: u11) ReadError!VectorEntry;
    pub fn vectorPending(self: View, pba_memory: memory.BarMemory, vector_index: u11) ReadError!bool;
    pub fn pendingDword(self: View, pba_memory: memory.BarMemory, dword_index: usize) ReadError!u32;

    pub fn enable(self: View) ProgramError!void;
    pub fn disable(self: View) ProgramError!void;
    pub fn setFunctionMask(self: View, masked: bool) ProgramError!void;

    pub fn programEntry(self: View, table_memory: memory.BarMemory, vector_index: u11, vector_entry: VectorEntry) ProgramError!void;
    pub fn programEntries(self: View, table_memory: memory.BarMemory, first_index: u11, entries: []const VectorEntry) ProgramError!void;
    pub fn setVectorMask(self: View, table_memory: memory.BarMemory, vector_index: u11, masked: bool) ProgramError!void;
};
```

Rules:

- `View` is a value type storing `config.Function`, the capability base offset, and three cached snapshot values (`control_snapshot`, `table_location`, `pba_location`) captured at `validate`.
- `control_snapshot` supplies `table_size_minus_one` without re-reading Message Control. Software-writable bits (`msix_enable`, `function_mask`) MUST be read live via `messageControl`, `enabled`, or `functionMasked`.
- `table_location` and `pba_location` are fixed at `validate` and MUST NOT be re-read. PCI r5.0 §6.8.2 fixes Table Offset / BIR and PBA Offset / BIR for the lifetime of a function instance.
- Every method that accepts `memory.BarMemory` documents in its parameter name what region the caller MUST supply. `table_memory` MUST be a `BarMemory` whose `[0, len())` covers the table region — the caller constructs it starting at `table_location.offset` with length `>= tableSpanBytes()`. `pba_memory` MUST be a `BarMemory` whose `[0, len())` covers the PBA region — starting at `pba_location.offset` with length `>= pbaSpanBytes()`. Callers with a single `BarMemory` covering both regions (same BIR, common case) construct that accessor once and pass it to both parameters; every offset the view issues is relative to the passed accessor's base.
- Every method MUST NOT allocate, retry, log, or synchronize.
- `View` is copyable. Copies share the same `config.Function` and observe the same live state.

### `find` `[zpci]`

`find(function)` walks the standard capability list rooted at `common.Status.capabilities_list` and returns a `View` for the first capability whose id is `cap_id`.

1. Construct `capabilities.list.Iterator.validate(function)`.
2. For each yielded `Capability`, if `capability.id == cap_id`, delegate to `validate(function, capability)` and return the result.
3. If iteration completes without finding `cap_id`, return `null`.

Rules:

- `find` returns `null` when the function has no MSI-X capability.
- `find` propagates `MalformedCapability` from the iterator when the capability list is malformed.
- `find` propagates `MalformedField` from `validate` when the MSI-X capability's Table BIR or PBA BIR is reserved (`6` or `7`).
- `find` propagates `ConfigSpace.Error` from any config read during traversal or validation.

### `validate` `[zpci]`

`validate(function, capability)` constructs a `View` from a specific capability entry.

1. Assert `capability.id == cap_id`. Programmer error.
2. Read `MessageControl` via `function.read16(capability.offset + register.message_control)`.
3. Read Table Offset / BIR via `function.read32(capability.offset + register.table_offset_bir)`; decode into `TableLocation`. If `bir == 6` or `bir == 7`, return `error.MalformedField`.
4. Read PBA Offset / BIR via `function.read32(capability.offset + register.pba_offset_bir)`; decode into `PbaLocation`. If `bir == 6` or `bir == 7`, return `error.MalformedField`.
5. Return `View{ .function = function, .base = capability.offset, .control_snapshot = message_control, .table_location = table_location, .pba_location = pba_location }`.

Rules:

- `capability.id != cap_id` is a programmer error and MUST be enforced by assertion. It is not a typed error.
- `validate` performs exactly three config reads.
- `validate` MUST NOT re-read any of the three snapshot registers after the initial reads.

### Snapshot queries

Rules:

- `tableSize()` returns `@as(u16, self.control_snapshot.table_size_minus_one) + 1`. Result is in `1..=2048`.
- `tableLocation()` returns `self.table_location`.
- `pbaLocation()` returns `self.pba_location`.
- `tableSpanBytes()` returns `@as(usize, self.tableSize()) * table_entry_size`.
- `pbaSpanBytes()` returns `((@as(usize, self.tableSize()) + pba_bits_per_dword - 1) / pba_bits_per_dword) * 4`.
- Snapshot queries perform no config or BAR-memory access.

### Live config-space reads

Rules:

- `messageControl()` reads at `self.base + register.message_control` and bit-casts to `MessageControl`.
- `enabled()` returns `self.messageControl()`'s `msix_enable` bit. Performs one config read.
- `functionMasked()` returns `self.messageControl()`'s `function_mask` bit. Performs one config read.

### Live BAR-memory reads

Rules:

- `readEntry(table_memory, vector_index)` requires `table_memory.len() >= (@as(usize, vector_index) + 1) * table_entry_size`. A violation returns `error.BarMemoryOutOfBounds` before any I/O.
- `readEntry` performs four `read32` calls at `vector_index * 16 + {0x0, 0x4, 0x8, 0xC}`, reconstructs `address = (address_hi << 32) | address_lo`, and returns `VectorEntry{ .address = ..., .data = data, .masked = (vector_control_raw & 1) != 0 }`.
- `vectorPending(pba_memory, vector_index)` requires `vector_index < self.tableSize()`. A violation returns `error.InvalidRouting`.
- `vectorPending` computes `dword_index = vector_index / pba_bits_per_dword`, `bit_index = vector_index % pba_bits_per_dword`, and returns `(pba_memory.read32(dword_index * 4) & (1 << bit_index)) != 0`.
- `pendingDword(pba_memory, dword_index)` requires `dword_index * 4 + 4 <= pba_memory.len()`. A violation returns `error.BarMemoryOutOfBounds` before I/O.
- `pendingDword` returns `pba_memory.read32(dword_index * 4)`.
- Every method that reads BAR memory propagates `BarMemory.Error` variants (`BarMemoryOutOfBounds`, `UnalignedAccess`) directly.
- Every method that reads BAR memory MUST NOT perform any config-space access.

## Config-space writes `[zpci]`

### `enable` `[zpci]`

`enable()` sets `msix_enable = true` while preserving every other Message Control bit.

Sequence:

1. Read Message Control into `saved_control`.
2. Compute `new_control = saved_control` with `msix_enable = true`.
3. Write Message Control; readback.

Rules:

- `enable` performs one read, one write, and one readback.
- `enable` preserves `_reserved11`, `table_size_minus_one`, and `function_mask`.
- On write or readback `ConfigSpace.Error`, return `error.ProgrammingWriteFailed`. On readback mismatch, return `error.ProgrammingReadbackMismatch`. The single-write failure requires no rollback.
- `enable` is idempotent: `enable` on an already-enabled view still issues the write; readback observes the unchanged value.

### `disable` `[zpci]`

`disable()` clears `msix_enable` while preserving every other Message Control bit.

Sequence mirrors `enable` with `msix_enable = false`.

Rules:

- `disable` performs one read, one write, and one readback.
- `disable` preserves `_reserved11`, `table_size_minus_one`, and `function_mask`.
- `disable` does not touch table entries or Vector Control.
- On failure, `disable` returns the corresponding error without rollback.
- `disable` is idempotent.

### `setFunctionMask` `[zpci]`

`setFunctionMask(masked)` sets `function_mask = masked` while preserving every other Message Control bit.

Sequence:

1. Read Message Control into `saved_control`.
2. Compute `new_control = saved_control` with `function_mask = masked`.
3. Write Message Control; readback.

Rules:

- `setFunctionMask` performs one read, one write, and one readback.
- `setFunctionMask` preserves `_reserved11`, `table_size_minus_one`, and `msix_enable`.
- `setFunctionMask` does not touch table entries or Vector Control.
- On failure, `setFunctionMask` returns the corresponding error without rollback.

## BAR-memory writes `[zpci]`

### `programEntry` `[zpci]`

`programEntry(table_memory, vector_index, vector_entry)` writes one table entry using a self-masking sequence that keeps the target vector masked from before the address / data writes until after the caller's final `vector_entry.masked` value is committed.

Preconditions:

1. `vector_index < self.tableSize()`. Violation returns `error.InvalidRouting`.
2. `table_memory.len() >= (@as(usize, vector_index) + 1) * table_entry_size`. Violation returns `error.BarMemoryOutOfBounds`.

Sequence:

1. **Save phase** — read the four dwords at the entry's offsets `0x0`, `0x4`, `0x8`, `0xC` into a stack-local save frame. Any read failure returns `error.ProgrammingWriteFailed`; no writes issued.
2. **Mask phase** — compute `masked_vector_control = saved_vector_control` with `masked = true`. Write Vector Control; readback. On failure, run §Rollback and return the original error.
3. **Address low phase** — write `@truncate(vector_entry.address)` to `entry.message_address_lo`; readback. On failure, §Rollback and return the original error.
4. **Address high phase** — write `@truncate(vector_entry.address >> 32)` to `entry.message_address_hi`; readback. On failure, §Rollback and return the original error.
5. **Data phase** — write `vector_entry.data` to `entry.message_data`; readback. On failure, §Rollback and return the original error.
6. **Unmask phase** — compute `final_vector_control = saved_vector_control` with `masked = vector_entry.masked`. Write Vector Control; readback. On failure, §Rollback and return the original error.

### Rollback

Rules:

- Rollback restores every previously-written dword in reverse write order. Each restore write is followed by a readback and compared against the saved value.
- A restore-phase write or restore-readback failure returns `error.ProgrammingPartial` immediately; further restores are abandoned.
- On successful rollback, `programEntry` returns the original error that triggered rollback.
- Rollback MUST NOT retry a failed restore.
- Rollback does not touch registers outside the save frame.

Rules for the sequence:

- Steps 2 and 6 both write Vector Control. The mask-phase value forces the target vector masked regardless of the caller's requested `vector_entry.masked`. The unmask-phase value applies the caller's final choice while `_reserved1` bits are preserved from the saved value.
- The self-masking sequence permits `programEntry` to run against any pre-state of Message Control (`msix_enable` on or off; `function_mask` on or off). No caller precondition is required beyond snapshot bounds.

### `programEntries` `[zpci]`

`programEntries(table_memory, first_index, entries)` writes a contiguous range of table entries starting at `first_index`.

Preconditions:

1. `entries.len == 0` returns `void` without I/O.
2. `first_index + entries.len - 1 < self.tableSize()`. Violation returns `error.InvalidRouting`.
3. `table_memory.len() >= (@as(usize, first_index) + entries.len) * table_entry_size`. Violation returns `error.BarMemoryOutOfBounds`.
4. `first_index + entries.len` MUST NOT overflow `usize`. Violation is a programmer-error assertion.

Sequence:

1. For each `i` in `0..entries.len`, call the `programEntry` sequence for `vector_index = first_index + i` and `vector_entry = entries[i]`.
2. On failure at index `K`: entries `first_index..first_index + K - 1` remain programmed with their `entries[i]` state; entry `first_index + K` is rolled back per `programEntry`'s rollback; entries `first_index + K + 1..first_index + entries.len - 1` are not attempted.

Rules:

- `programEntries` provides per-entry atomicity. Each entry is masked before its address / data writes and unmasked after per its own `entries[i].masked`. Between entries, entry `K-1` is fully committed with `entries[K-1].masked` before entry `K` begins.
- Cross-batch atomicity is not owned by this method. Callers that require every entry to remain masked throughout the batch set `function_mask = true` via `setFunctionMask(true)` before calling `programEntries`, then clear `function_mask` afterward.
- Failure at entry `K` returns the same error `programEntry` would have returned at that entry.
- `programEntries` MUST reuse a single 16-byte save frame across iterations; it MUST NOT allocate aggregate storage proportional to `entries.len`.

### `setVectorMask` `[zpci]`

`setVectorMask(table_memory, vector_index, masked)` sets Vector Control's `masked` bit without touching the address or data dwords.

Preconditions:

1. `vector_index < self.tableSize()`. Violation returns `error.InvalidRouting`.
2. `table_memory.len() >= (@as(usize, vector_index) + 1) * table_entry_size`. Violation returns `error.BarMemoryOutOfBounds`.

Sequence:

1. Read the Vector Control dword into `saved_vector_control`.
2. Compute `new_vector_control = saved_vector_control` with `masked = masked`.
3. Write Vector Control; readback.

Rules:

- `setVectorMask` performs one read, one write, and one readback.
- `setVectorMask` preserves `_reserved1`.
- On write failure or readback mismatch, `setVectorMask` runs a single restore write with readback; a restore failure returns `error.ProgrammingPartial`; a successful restore returns the original error.
- `setVectorMask` does not touch address, data, or Message Control.

## Errors

```zig
pub const ReadError = error{
    MalformedCapability,
    MalformedField,
    BarMemoryOutOfBounds,
    UnalignedAccess,
} || config.ConfigSpace.Error;

pub const ProgramError = error{
    MalformedField,
    InvalidRouting,
    BarMemoryOutOfBounds,
    UnalignedAccess,
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};
```

Variant sourcing:

- `MalformedCapability` — `find` propagates it from `capabilities.list.Iterator` when the capability list is malformed. The `pci.core.Error` variant is defined by `docs/specs/core/errors.md`.
- `MalformedField` — `Table Offset / BIR` or `PBA Offset / BIR` decoded to a reserved BIR (`6` or `7`) during `validate`.
- `InvalidRouting` — `vector_index >= tableSize()` or `first_index + entries.len > tableSize()` in any write or read that accepts a vector index. Returned before any I/O.
- `BarMemoryOutOfBounds` — the requested region overruns `table_memory.len()` or `pba_memory.len()`; propagates from `memory.BarMemory` for I/O-level bounds failures.
- `UnalignedAccess` — propagates from `memory.BarMemory` when the accessor rejects a misaligned dword access. Every zpci-issued BAR-memory access uses natural `u32` alignment, so this variant surfaces only for a malformed `TableLocation.offset` or `PbaLocation.offset` decoded from a device that violates PCI r5.0 alignment.
- `ProgrammingReadbackMismatch` — a readback comparison in `enable`, `disable`, `setFunctionMask`, `programEntry`, `programEntries`, or `setVectorMask` observed a value that does not match what was written. Rollback ran successfully where applicable.
- `ProgrammingWriteFailed` — a `ConfigSpace.Error` or `memory.BarMemory.Error` occurred during the save phase or a write phase. Rollback ran successfully where applicable.
- `ProgrammingPartial` — a rollback write or rollback readback itself failed. Hardware is neither in the pre-commit state nor the planned post-commit state.
- `ConfigSpace.Error` — propagated by `find`, `validate`, and every live config-space read. Programming operations map `ConfigSpace.Error` to `ProgrammingWriteFailed` at the point of failure and do not propagate `ConfigSpace.Error` directly.

Rules:

- Programmer errors (calling `validate` with a non-MSI-X capability, `first_index + entries.len` overflowing `usize`, misusing snapshot queries) MUST be enforced by assertion. They are not typed errors.
- `ProgramError` MUST NOT include `MalformedCapability` or `ConfigSpace.Error`. Program operations assume `View.validate` succeeded.

## Wire / layout invariants

None owned as `extern struct`. `MessageControl` and `VectorControl` are `packed struct(uN)`, bit-cast from native `uN` reads.

Compile-time size assertions:

```zig
comptime {
    std.debug.assert(@sizeOf(MessageControl) == 2);
    std.debug.assert(@bitSizeOf(MessageControl) == 16);
    std.debug.assert(@sizeOf(VectorControl) == 4);
    std.debug.assert(@bitSizeOf(VectorControl) == 32);
    std.debug.assert(table_entry_size == 16);
    std.debug.assert(max_table_size == 2048);
}
```

Reserved bits (`_reserved11` in `MessageControl`, `_reserved1` in `VectorControl`) round-trip byte-for-byte on every write performed through this spec's write surfaces.

## View / borrowing behavior

- `View` stores `config.Function`, `u8`, `MessageControl`, `TableLocation`, and `PbaLocation` inline.
- `View.function` is a borrowed handle; lifetime follows the underlying `ConfigSpace` backend.
- `memory.BarMemory` parameters are borrowed values; lifetime follows the caller's mapping policy.
- `VectorEntry` is a plain value; write methods consume it by value.
- The save frame in `programEntry` (four `u32` values) lives on the internal stack; discarded on return.
- `programEntries` reuses one save frame across iterations; total stack use is fixed regardless of `entries.len`.
- No allocation.
- Copies of a `View` are independent value copies of the same `config.Function` handle and cached snapshots.

## zstdx usage

None. `u32` dword values, `u16` control values, and the fixed-size save frame fit natively.

## Facade re-export `[zpci]`

`src/interrupts.zig`:

```zig
pub const msix = @import("interrupts/msix.zig");
```

Callers reach the public surface as `pci.interrupts.msix.View`, `pci.interrupts.msix.VectorEntry`, `pci.interrupts.msix.VectorControl`, `pci.interrupts.msix.MessageControl`, `pci.interrupts.msix.TableLocation`, `pci.interrupts.msix.PbaLocation`, `pci.interrupts.msix.cap_id`, `pci.interrupts.msix.register`, `pci.interrupts.msix.entry`, and `pci.interrupts.msix.table_entry_size`.

## Usage

**Discover MSI-X and program a fresh multi-vector bring-up:**

```zig
const view = try pci.interrupts.msix.View.find(function) orelse return error.NoMsix;

const table_loc = view.tableLocation();
const table_memory = try caller_map_bar(table_loc.bir, table_loc.offset, view.tableSpanBytes());

const entries = [_]pci.interrupts.msix.VectorEntry{
    .{ .address = 0xFEE0_0000, .data = 0x30, .masked = false },
    .{ .address = 0xFEE0_1000, .data = 0x31, .masked = false },
    // ... more vectors ...
};

try view.programEntries(table_memory, 0, &entries);
try view.enable();
```

**Reroute one vector at runtime:**

```zig
try view.programEntry(table_memory, 5, .{
    .address = new_target_address,
    .data = new_target_data,
    .masked = false,
});
```

**Mask one vector during a drain, then unmask:**

```zig
try view.setVectorMask(table_memory, 3, true);
// ... drain ...
try view.setVectorMask(table_memory, 3, false);
```

**Poll one vector's pending state:**

```zig
const pba_loc = view.pbaLocation();
const pba_memory = if (pba_loc.bir == table_loc.bir)
    table_memory
else
    try caller_map_bar(pba_loc.bir, pba_loc.offset, view.pbaSpanBytes());

if (try view.vectorPending(pba_memory, 3)) {
    // service interrupt
}
```

**Poll many vectors efficiently:**

```zig
const dword_count = view.pbaSpanBytes() / 4;
for (0..dword_count) |i| {
    const dword = try view.pendingDword(pba_memory, i);
    if (dword == 0) continue;
    var bits = dword;
    while (bits != 0) {
        const bit = @ctz(bits);
        const vector = i * pci.interrupts.msix.pba_bits_per_dword + bit;
        // service vector
        bits &= bits - 1;
    }
}
```

**Read current state during driver reload:**

```zig
if (try view.enabled()) {
    for (0..view.tableSize()) |i| {
        const current = try view.readEntry(table_memory, @intCast(i));
        _ = current;
    }
}
```

**Batch reprogramming with cross-batch atomicity:**

```zig
try view.setFunctionMask(true);
try view.programEntries(table_memory, 0, &new_entries);
try view.setFunctionMask(false);
```

**Handle programming failures:**

```zig
view.programEntry(table_memory, 5, entry) catch |err| switch (err) {
    error.InvalidRouting => return err,
    error.BarMemoryOutOfBounds, error.UnalignedAccess => return err,
    error.MalformedField => return err,
    error.ProgrammingReadbackMismatch, error.ProgrammingWriteFailed => return err,
    error.ProgrammingPartial => return err,
};
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `View.find` | never | O(N) config reads (N ≤ 48 capability slots) | capability-list traversal per `docs/specs/capabilities/list.md` | none | backend-defined | list order |
| `View.validate` | never | three config reads | capability id + Message Control + Table BIR + PBA BIR | none | backend-defined | Message Control, Table BIR, PBA BIR |
| Snapshot queries (`tableSize`, `tableLocation`, `pbaLocation`) | never | never | snapshot lookup | none | pure | none |
| Live config reads (`messageControl`, `enabled`, `functionMasked`) | never | one config read per call | offset math within capability | none | backend-defined | one register per call |
| Live BAR-memory reads (`readEntry`) | never | four BAR-memory reads per call | table containment | none | backend-defined | address low, address high, data, vector control |
| Live PBA reads (`vectorPending`, `pendingDword`) | never | one BAR-memory read per call | PBA containment | none | backend-defined | one dword per call |
| `View.enable`, `View.disable`, `View.setFunctionMask` | never | 1 read + 1 write + 1 readback | Message Control | on success: one Message Control bit changed | single-thread over one `ConfigSpace` | RMW Message Control |
| `View.setVectorMask` | never | 1 read + 1 write + 1 readback; up to 1 restore write + readback | Vector Control containment | on success: one Vector Control bit changed; on rollback-success: pre-commit state; on `ProgrammingPartial`: unspecified | single-thread over one `BarMemory` | RMW Vector Control |
| `View.programEntry` | never | O(5 × 2) BAR-memory accesses per entry | table containment | on success: one entry programmed with `entry`; on rollback-success: pre-commit state for that entry; on `ProgrammingPartial`: unspecified | single-thread over one `BarMemory` | mask → address low → address high → data → unmask |
| `View.programEntries` | never | O(N × 5 × 2) BAR-memory accesses for `N = entries.len` | table containment (whole range) | on success: `entries.len` entries programmed; on failure at K: entries `first_index..first_index + K - 1` committed, entry `first_index + K` rolled back, entries `first_index + K + 1..` untouched | single-thread over one `BarMemory` | per-entry serial per `programEntry` sequence |

Rules:

- Every write is immediately followed by a readback at the same offset and width.
- Every write MUST run single-threaded over the corresponding `ConfigSpace` or `BarMemory`. Concurrent operations on the same function are caller policy.
- Every operation MUST be deterministic on stable hardware: same inputs produce the same read / write / readback sequence.

## Required tests (category level)

**View decode:**

- `unit:` valid MSI-X capability, table and PBA in same BAR → `find` returns non-null; `tableLocation` and `pbaLocation` share `bir`; snapshot fields correct.
- `unit:` valid MSI-X capability, table BIR `4` and PBA BIR `5` → both locations decoded independently.
- `unit:` `Table BIR == 6` → `validate` returns `error.MalformedField`.
- `unit:` `Table BIR == 7` → `validate` returns `error.MalformedField`.
- `unit:` `PBA BIR == 6` → `validate` returns `error.MalformedField`.
- `unit:` `PBA BIR == 7` → `validate` returns `error.MalformedField`.
- `unit:` `table_size_minus_one == 0` → `tableSize` returns `1`.
- `unit:` `table_size_minus_one == 0x7FF` → `tableSize` returns `2048`.
- `unit:` `find` on a function with no capability list → returns `null`.
- `unit:` `find` on a function whose capability list contains no `cap_id` → returns `null`.
- `unit:` `find` on a function whose capability list has a cycle → returns `error.MalformedCapability`.
- `unit:` `validate` called on a non-MSI-X capability → programmer-error assertion.

**Live reads:**

- `unit:` `messageControl` reads at capability offset `0x02`.
- `unit:` `enabled` on `msix_enable = true` → returns `true`.
- `unit:` `functionMasked` on `function_mask = true` → returns `true`.
- `unit:` `readEntry` reads four dwords at `table_offset + vector_index * 16` and reconstructs `address = (hi << 32) | lo`.
- `unit:` `readEntry` with `vector_index * 16` extending past `table_memory.len()` → returns `error.BarMemoryOutOfBounds` before I/O.
- `unit:` `vectorPending` on a device with vector 5 pending in PBA dword 0 bit 5 → returns `true`.
- `unit:` `vectorPending` with `vector_index >= tableSize()` → returns `error.InvalidRouting`.
- `unit:` `pendingDword` at valid offset → returns the raw dword.
- `unit:` `pendingDword` past `pba_memory.len()` → returns `error.BarMemoryOutOfBounds`.

**Config-space writes:**

- `unit:` `enable` on a disabled view → write sets `msix_enable = true`; readback matches; other bits preserved.
- `unit:` `enable` on an enabled view → idempotent; write still issued; readback matches.
- `unit:` `disable` on an enabled view → write sets `msix_enable = false`; other bits preserved.
- `unit:` `setFunctionMask(true)` → write sets `function_mask = true`; `msix_enable` preserved.
- `unit:` `setFunctionMask(false)` → write clears `function_mask`; `msix_enable` preserved.
- `unit:` `enable` write failure → `error.ProgrammingWriteFailed`.
- `unit:` `enable` readback mismatch → `error.ProgrammingReadbackMismatch`.
- `unit:` `_reserved11` preserved across `enable`, `disable`, `setFunctionMask` (bit-for-bit).

**BAR-memory writes — `programEntry`:**

- `unit:` `programEntry` on `msix_enable = false` view → succeeds; write sequence is mask, address low, address high, data, unmask.
- `unit:` `programEntry` on `msix_enable = true` view → succeeds; self-masking sequence keeps target vector masked from step 2 through step 6.
- `unit:` `programEntry` on `function_mask = true` view → succeeds; sequence unchanged.
- `unit:` `programEntry` with `vector_entry.masked = true` → final Vector Control write has `masked = true`.
- `unit:` `programEntry` with `vector_entry.masked = false` → final Vector Control write has `masked = false`.
- `unit:` `programEntry` with `vector_index >= tableSize()` → `error.InvalidRouting`; no I/O.
- `unit:` `programEntry` with `table_memory.len()` too small → `error.BarMemoryOutOfBounds`; no I/O.
- `unit:` `programEntry` preserves `_reserved1` from the saved Vector Control value.
- `unit:` `programEntry` save-phase read failure → `error.ProgrammingWriteFailed`; no writes issued.
- `unit:` `programEntry` mask-phase write failure → rollback attempts to restore Vector Control; returns `error.ProgrammingWriteFailed`.
- `unit:` `programEntry` address-low write readback mismatch → rollback restores address-low then Vector Control; returns `error.ProgrammingReadbackMismatch`.
- `unit:` `programEntry` data write failure → rollback restores address-high, address-low, Vector Control; returns `error.ProgrammingWriteFailed`.
- `unit:` `programEntry` unmask-phase readback mismatch → rollback restores data, address-high, address-low, Vector Control; returns `error.ProgrammingReadbackMismatch`.
- `unit:` `programEntry` rollback write failure → `error.ProgrammingPartial`; further restores abandoned.

**BAR-memory writes — `programEntries`:**

- `unit:` `programEntries` with `entries.len == 0` → returns `void` without I/O.
- `unit:` `programEntries` writes N entries in ascending order; each entry follows the `programEntry` sequence.
- `unit:` `programEntries` with `first_index + entries.len > tableSize()` → `error.InvalidRouting`; no I/O.
- `unit:` `programEntries` with insufficient `table_memory.len()` → `error.BarMemoryOutOfBounds`; no I/O.
- `unit:` `programEntries` failure at entry K → entries `first_index..first_index + K - 1` remain programmed; entry `first_index + K` rolled back; entries beyond untouched.
- `unit:` `programEntries` allocates no aggregate storage: internal save frame size independent of `entries.len`.
- `unit:` deterministic: two `programEntries` calls with identical inputs on identical fakes produce byte-identical write sequences.

**BAR-memory writes — `setVectorMask`:**

- `unit:` `setVectorMask(_, _, true)` writes Vector Control with `masked = true`; `_reserved1` preserved; readback matches.
- `unit:` `setVectorMask(_, _, false)` writes with `masked = false`.
- `unit:` `setVectorMask` write failure → rollback restores saved Vector Control; returns `error.ProgrammingWriteFailed`.
- `unit:` `setVectorMask` readback mismatch → rollback restores; returns `error.ProgrammingReadbackMismatch`.
- `unit:` `setVectorMask` with `vector_index >= tableSize()` → `error.InvalidRouting`; no I/O.
- `unit:` `setVectorMask` does not touch address, data, or Message Control.

**Cross-BIR:**

- `integration:` device with table BIR `4` and PBA BIR `5`; caller supplies distinct `BarMemory` accessors; `programEntry` reaches only `table_memory`; `pendingDword` reaches only `pba_memory`.
- `unit:` passing `pba_memory` (smaller than table region) to `programEntry` → `error.BarMemoryOutOfBounds` before I/O.

**Malformed / programmer error (assertion):**

- `malformed:` `View` constructed on a non-MSI-X capability then used → programmer-error assertion at `validate`.
- `malformed:` `first_index + entries.len` overflowing `usize` → programmer-error assertion.

## Non-goals

- MSI capability (`docs/specs/interrupts/msi.md`).
- BAR mapping, unmapping, or cache-attribute policy (`docs/specs/memory/bar.md`).
- BAR base resolution (`docs/specs/bar.md`).
- Command-register programming, including `interrupt_disable` orchestration.
- Vector allocation strategy.
- Message-address encoding for a specific interrupt controller.
- Cross-function MSI-X coordination.
- Pending-bit acknowledgement or clearing policy.
- Function-level reset before MSI-X programming.
- Retry on transient failures.
- Diagnostic out-parameters identifying which register failed rollback.
- Concurrent commits on one `ConfigSpace` or one `BarMemory`.
- Batch reads of the entire PBA or the entire table.
- Cross-batch atomicity within `programEntries`.
- Whole-list `View.findAll` batch discovery.
- `View` methods that assume table BIR and PBA BIR are the same.

## Open questions

None owned by this spec.
