# Resource programming

Defines the pure commit step that consumes a `Plan` from `resources/assignment` and writes BAR bases, expansion ROM bases, and bridge window registers to config space. Owns the per-function write order, the save-then-write-then-verify discipline, the RMW rules that preserve BAR type bits and the expansion ROM enable bit, the decode-disable orchestration around the base writes, the per-function rollback on failure, and the mapping from failure modes to `ProgrammingReadbackMismatch`, `ProgrammingWriteFailed`, and `ProgrammingPartial`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on programming write order, readback verification, and per-function rollback. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

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
- `docs/specs/bar.md`
- `docs/specs/resources/model.md`
- `docs/specs/resources/assignment.md`
- `docs/specs/resources/bridge.md`

## Scope

Owned:

- `commit(plan) Error!void` — the one entry point that programs a `Plan` into hardware.
- Per-function write order: save → disable decode → BARs → expansion ROM → bridge windows → restore decode.
- The save discipline: read every register the commit will overwrite before touching Command.
- Readback verification of every write, using masked comparison for `Command` and full-width comparison for BAR / ROM / window registers.
- RMW rule for BAR bases that preserves hardware-fixed type bits.
- RMW rule for the expansion ROM base register that preserves the enable bit and clears reserved bits `[10:1]`.
- The bridge-window register set written per `EncodedWindow` variant, including zeroing the upper registers of the 16-bit IO and 32-bit prefetchable variants.
- The decode-disable / restore-decode dance that brackets every function's base writes.
- The per-function rollback that runs on any write-phase or restore-decode failure.
- The failure boundary across functions: prior successful commits remain, the failing function is rolled back per §Rollback, subsequent plan entries are not attempted.

Deferred:

- Bus-number programming for unprogrammed bridges (`docs/specs/resources/bus.md`).
- Command-register programming beyond decode-disable / restore (`docs/specs/header/common.md`).
- Bridge-control programming (`docs/specs/header/type1.md`).
- Expansion ROM enable-bit programming (`docs/specs/header/type0.md` / `docs/specs/header/type1.md` helpers).
- Secondary-bus reset orchestration.
- MSI / MSI-X programming (`docs/specs/interrupts/msi.md`, `docs/specs/interrupts/msix.md`).
- Whole-plan rollback. Rollback is per-function only.
- Retry on transient failures.
- Diagnostic out-parameters identifying the failing function.
- Concurrent commits.

## Layering `[zpci]`

`resources/programming` is the only zpci module that writes BAR bases, expansion ROM bases, or bridge window registers.

Layering constraints from `docs/specs/architecture.md`:

- `resources/` imports `core/`, `config/`, `header/`, and `bar`. This spec imports `resources/model.zig`, `resources/assignment.zig`, `resources/bridge.zig`, `config/space.zig`, `header/common.zig`, `header/type0.zig`, and `header/type1.zig`.
- `resources/` MUST NOT import `topology/`, `interrupts/`, or `memory/`.
- Programming MUST NOT allocate. Save state lives in a fixed-size per-function frame on the internal recursion stack.

## Public surface `[zpci]`

```zig
const assignment = @import("assignment.zig");
const model = @import("model.zig");

pub const Plan = assignment.Plan;
pub const Assignment = model.Assignment;

pub const Error = error{
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};

pub fn commit(plan: Plan) Error!void;
```

Rules:

- `Plan` is a re-export from `docs/specs/resources/assignment.md`. This spec does not own the `Plan` shape.
- `commit` returns `void` on success; every returned error is one of the three programming variants defined by `docs/specs/core/errors.md`.
- `commit` MUST NOT allocate, retry, log, or synchronize.
- `commit` MUST be deterministic on stable hardware: same `plan` produces the same write / readback sequence.

## Function grouping `[zpci]`

`Plan.assignments` is emitted in DFS preorder per `docs/specs/resources/assignment.md` §DFS preorder. Every `Assignment.requirement.source` names a target `config.Function`:

- `.endpoint_bar` — `source.endpoint_bar.function`.
- `.endpoint_expansion_rom` — `source.endpoint_expansion_rom`.
- `.bridge_window` — `source.bridge_window.function`.

`commit` walks `plan.assignments` in order and groups consecutive entries that share a `config.Function` into one per-function commit block. Rules:

- Since assignment emits one node's requirements contiguously and each node maps to one `config.Function`, one plan function group is one contiguous slice.
- Function equality compares the `ConfigSpace` handle and `Sbdf` inside `config.Function` for equality.
- The first `Assignment` in a function group determines the target function; subsequent entries in the group MUST reference the same function. Programming asserts this on every entry.

## Header kind `[zpci]`

Programming needs the target function's header kind to resolve BAR and expansion ROM offsets:

- Type-0 BAR offsets: `0x10`, `0x14`, `0x18`, `0x1C`, `0x20`, `0x24` (`docs/specs/header/type0.md`).
- Type-1 BAR offsets: `0x10`, `0x14` (`docs/specs/header/type1.md`).
- Type-0 expansion ROM base: `0x30` (`docs/specs/header/type0.md`).
- Type-1 expansion ROM base: `0x38` (`docs/specs/header/type1.md`).

`commit` reads `function.headerKind()` once per function group as the first read of the save phase. Rules:

- `.endpoint_bar` on a type-1 function: the `BarRef.index` MUST be `< 2`; programming asserts.
- `.endpoint_bar` on a type-0 function: the `BarRef.index` MUST be `< 6`; programming asserts.
- `.bridge_window` on a type-0 function is a programmer error and MUST be enforced by assertion.
- `.endpoint_expansion_rom` is valid on either header kind; the offset is `0x30` for type-0 and `0x38` for type-1.

## Per-function commit sequence `[zpci]`

For each function group:

1. **Read `HeaderKind`** — `function.headerKind()`. Errors from this read return `ProgrammingWriteFailed`; no state changed.
2. **Save phase** — read every register the write phase will overwrite (§Save phase). A read failure returns `ProgrammingWriteFailed`; no state changed.
3. **Disable phase** — read `Command`, mask out `io_space` and `memory_space`, write the result, readback (§Readback discipline). Any error returns `ProgrammingWriteFailed` or `ProgrammingReadbackMismatch`; no rollback needed because Command was the only write.
4. **Write phase** — write BAR bases, expansion ROM base, and bridge window registers in the fixed order §Write phase. Every write is followed by a readback. On any error, run §Rollback and return the original error (or `ProgrammingPartial` if rollback fails).
5. **Restore-decode phase** — write the original `Command` value, readback. On any error, run §Rollback over the BAR / ROM / window writes only (Command state after this step is what rollback attempts to restore, but rollback itself is a further Command write; if the initial restore-decode fails, all base writes are correct but decode state is not, and rollback attempts to reverse the base writes to return to pre-commit state).

Rules:

- The order of writes inside the write phase is fixed by §Write phase and does not depend on `Plan.assignments` order within the function group.
- Every write MUST be immediately followed by a readback at the same offset and width. There is no batched-readback mode.
- If any step returns `ProgrammingPartial`, `commit` propagates it immediately and does not attempt subsequent function groups.

## Save phase `[zpci]`

Save reads run through the target function's `ConfigSpace` handle. For one function group, the save frame captures:

- `command_before` — the current `Command` register (16 bits at offset `0x04` per `docs/specs/header/common.md`).
- For each `Assignment` with `source == .endpoint_bar`:
  - The BAR low dword (`function.read32(bar_offset)`).
  - For a 64-bit memory BAR (`assignment.requirement.source.endpoint_bar.slot_count == 2`), additionally the BAR high dword (`function.read32(bar_offset + 4)`). `BarRef.slot_count` is authoritative; programming does not re-decode from the saved low dword.
- For each `Assignment` with `source == .endpoint_expansion_rom`:
  - The expansion ROM base dword (`function.read32(rom_offset)`).
- For each `Assignment` with `source == .bridge_window`, all registers the write phase will touch for that window's variant per §Write phase. The variant is determined by calling `resources.bridge.encodeWindow(assignment)` and inspecting the tag; the encoding itself is discarded and recomputed in the write phase.

Rules:

- Save reads use the widths native to each register (`read32` for BARs and ROM; `read8` / `read16` / `read32` for bridge windows per §Write phase).
- A save-phase read failure returns `ProgrammingWriteFailed` immediately. No writes have been issued; no rollback is needed.
- The save frame is stack-allocated. Its upper bound per function is fixed by header layout: at most six BAR low dwords + six BAR high dwords + one ROM dword + three window register groups + one Command word.
- `bridge.encodeWindow` is called both in the save phase (to determine the variant and thus the save read set) and in the write phase (to produce wire values). Its purity guarantees identical results.

## Write phase `[zpci]`

For one function group, the write phase runs in this fixed order:

1. **BAR writes.** For each `.endpoint_bar` `Assignment` in ascending `BarRef.index` order:
   - Compute `new_low` per §BAR RMW.
   - `function.write32(bar_offset, new_low)`; readback.
   - For 64-bit memory BARs, `function.write32(bar_offset + 4, @truncate(assignment.base >> 32))`; readback.
2. **Expansion ROM write.** For each `.endpoint_expansion_rom` `Assignment` (at most one per function per `docs/specs/header/type0.md` / `docs/specs/header/type1.md`):
   - Compute `new_rom` per §Expansion ROM RMW.
   - `function.write32(rom_offset, new_rom)`; readback.
3. **Bridge window writes.** For each `.bridge_window` `Assignment` in ascending window-offset order (`.io` at `0x1C`, `.memory` at `0x20`, `.prefetchable_memory` at `0x24`):
   - Call `resources.bridge.encodeWindow(assignment)`; propagate `error.BridgeWindowUnencodable` as `ProgrammingWriteFailed` (assignment produced an unencodable placement).
   - Write the register set for the returned variant per §Bridge window register set. Each write is followed by a readback.

Rules:

- BAR index order and window offset order are stable across runs regardless of `Plan.assignments` ordering within the group.
- Multiple `Assignment`s with the same BAR index or the same window kind on one function is a programmer error and MUST be enforced by assertion.
- A `.bridge_window` `Assignment` on a type-0 function is a programmer error and MUST be enforced by assertion.
- Each write in the phase is journaled onto the rollback stack §Rollback in the order it succeeds. A readback mismatch or write error consults the journal to undo.

### BAR RMW `[std]`

For a memory BAR (`(saved_low & 0x1) == 0`):

```
new_low = (saved_low & 0x0000_000F) | (@as(u32, @truncate(assignment.base)) & 0xFFFF_FFF0)
```

For an IO BAR (`(saved_low & 0x1) == 1`):

```
new_low = (saved_low & 0x0000_0003) | (@as(u32, @truncate(assignment.base)) & 0xFFFF_FFFC)
```

For the high dword of a 64-bit memory BAR (no RMW; the high dword carries only base bits):

```
new_high = @as(u32, @truncate(assignment.base >> 32))
```

Rules:

- The low-4-bit mask on a memory BAR preserves the type (bit 0), width (bits 2..1), and prefetchable (bit 3) encoding from the saved value.
- The low-2-bit mask on an IO BAR preserves the type indicator (bit 0) and the reserved bit 1.
- Assignment guarantees `assignment.base` is naturally aligned to `requirement.alignment`, so the masks never truncate meaningful base bits.
- 64-bit memory BAR pairs are identified by the saved low dword, not by the `Assignment.pool` (a `.mmio64` requirement may have been placed into an `.mmio32` fallback pool, but the hardware still expects the 64-bit two-slot wire encoding as advertised in the low dword's type bits).

### Expansion ROM RMW `[std]`

```
new_rom = (saved_rom & 0x0000_0001) | (@as(u32, @truncate(assignment.base)) & 0xFFFF_F800)
```

Rules:

- Bit 0 (`expansion_rom_enable`) is preserved from the saved value. Enabling or disabling the ROM decode after programming is caller policy through the header helper defined by `docs/specs/header/type0.md` / `docs/specs/header/type1.md`.
- Bits `[10:1]` are reserved by the PCI base specification and written as zero.
- Bits `[31:11]` carry the base address; assignment aligns `requirement.alignment` to a power-of-two ≥ `0x800`, so no meaningful base bits are truncated.
- The register offset is `0x30` on a type-0 function and `0x38` on a type-1 function (§Header kind).

### Bridge window register set `[std]`

The register set written per `EncodedWindow` variant is fixed. Every row writes ALL registers in the group; the 16-bit IO and 32-bit prefetchable rows write zero to the upper registers to normalize the wire encoding.

| Variant | Writes (ascending offset order) |
|---|---|
| `.io`, `is_32bit == false` | `write8(0x1C, base_lo)`, `write8(0x1D, limit_lo)`, `write16(0x30, 0)`, `write16(0x32, 0)` |
| `.io`, `is_32bit == true` | `write8(0x1C, base_lo)`, `write8(0x1D, limit_lo)`, `write16(0x30, base_upper)`, `write16(0x32, limit_upper)` |
| `.memory` | `write16(0x20, base)`, `write16(0x22, limit)` |
| `.prefetchable_memory_32` | `write16(0x24, base_lo)`, `write16(0x26, limit_lo)`, `write32(0x28, 0)`, `write32(0x2C, 0)` |
| `.prefetchable_memory_64` | `write16(0x24, base_lo)`, `write16(0x26, limit_lo)`, `write32(0x28, base_upper)`, `write32(0x2C, limit_upper)` |

Rules:

- The zero writes to `0x30/0x32` (IO 16-bit) and `0x28/0x2C` (prefetchable 32-bit) prevent stale upper-bit state from producing a wire address that partially decodes above the intended window.
- The save phase captures the same register set the write phase writes, so rollback restores exactly what was overwritten.
- The `EncodedWindow` field-to-offset mapping is owned by `docs/specs/resources/bridge.md` §Public surface; programming reads the tag and field values verbatim.

## Readback discipline `[zpci]`

Every write in the disable phase, write phase, and restore-decode phase is followed by a readback at the same offset and width. Compare rules:

- **BAR low dword** — read `u32` at the BAR offset; compare against the value written. Full-width comparison.
- **BAR high dword** (64-bit memory) — read `u32` at `bar_offset + 4`; compare against the written value.
- **Expansion ROM** — read `u32` at the ROM offset; compare against the written value. The enable bit is RMW-preserved so the comparison matches.
- **Bridge window register** — read at the width the register uses (`u8` for `0x1C`/`0x1D`, `u16` for `0x30`/`0x32`/`0x20`/`0x22`/`0x24`/`0x26`, `u32` for `0x28`/`0x2C`); compare against the written value.
- **Command register** — read `u16` at offset `0x04`; compare with a mask restricted to the six writable bits programming sets or clears: `io_space`, `memory_space`, `bus_master`, `interrupt_disable`, `parity_error_response`, `serr_enable`. Bits outside the mask (status bits, reserved bits, RO bits) MUST NOT participate in the compare.

Rules:

- A read failure during readback returns `ProgrammingWriteFailed` and triggers §Rollback (the write succeeded but its verification could not be established).
- A comparison mismatch returns `ProgrammingReadbackMismatch` and triggers §Rollback.
- The Command compare mask is derived from `docs/specs/header/common.md` §Command flag word; programming defines the mask as a private constant containing only bits it writes.

## Rollback `[zpci]`

When the write phase or restore-decode phase returns an error, programming attempts to restore every previously-written register in reverse order.

For each journaled write in reverse:

1. Write the saved value to the same offset at the same width.
2. Readback and compare against the saved value under the same rules as §Readback discipline.
3. If the restore write or restore-readback fails, ABORT further rollback and return `ProgrammingPartial` immediately.

After every base register is successfully restored, restore Command last:

1. Write `command_before` to `Command`.
2. Readback under the masked-compare rule.
3. If this write or its readback fails, return `ProgrammingPartial`.

Rules:

- Rollback is per-function. Prior committed function groups in the plan are NOT reverted.
- Rollback of the restore-decode failure at step 5 (§Per-function commit sequence) reverses the entire write phase's base register writes, then attempts one more Command write to restore `command_before`. If either the reversal or the final Command restore fails, `ProgrammingPartial` propagates.
- The original error (the one that triggered rollback) is what `commit` returns when rollback completes successfully. If rollback itself fails at any point, `ProgrammingPartial` is what propagates.
- Rollback MUST NOT retry a failed restore. A single failure aborts rollback.

## Failure boundary across function groups `[zpci]`

`commit` walks function groups in DFS preorder. On failure at group K:

- Groups `0..K-1` remain committed with their planned state.
- Group K has been rolled back per §Rollback (`ProgrammingReadbackMismatch` / `ProgrammingWriteFailed`) or is in an unknown state (`ProgrammingPartial`).
- Groups `K+1..N-1` are not attempted.

Rules:

- `commit` does NOT attempt whole-plan rollback of prior successful function groups.
- The failure mode returned to the caller identifies which failure semantics apply to group K. Which function K is is not surfaced via a return value or diagnostic; a caller that needs to identify the failing function inspects live hardware state after `commit` returns.
- The caller decides whether to re-plan and re-commit or to reset the affected function.
- A subsequent `commit` targeting a function that returned `ProgrammingPartial` on a prior call is UB from this spec's perspective; the caller MUST reset the function externally (e.g., function-level reset) before including it in another `commit`. A subsequent `commit` on a plan that does NOT reference the affected function is well-defined.

## Errors

```zig
pub const Error = error{
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};
```

Variant sourcing:

- `ProgrammingReadbackMismatch` — a readback comparison during the disable phase, write phase, or restore-decode phase observed a value that does not match what was written (per §Readback discipline). Rollback ran successfully. The `zpci.Error` variant is defined by `docs/specs/core/errors.md`.
- `ProgrammingWriteFailed` — a `ConfigSpace` write or readback returned an accessor error during the save phase, disable phase, write phase, or restore-decode phase, before rollback started. Rollback ran successfully. Save-phase reads that fail also map to this variant because no state has changed and the semantics ("commit could not proceed") match.
- `ProgrammingPartial` — a rollback write or rollback readback itself failed, or the restore-decode step at the end of the write phase failed such that base registers are programmed but decode state is not restored. Hardware is neither in the pre-commit state nor the planned post-commit state.

Rules:

- Programming MUST NOT synthesize other `zpci.Error` variants. `ConfigSpace.Error` values are mapped to `ProgrammingWriteFailed` at the point of the failing access.
- `bridge.encodeWindow`'s `error.BridgeWindowUnencodable` returned during the write phase MUST be mapped to `ProgrammingWriteFailed` — the plan produced an unencodable placement and programming cannot proceed. Rollback runs before the error propagates.
- Programmer errors (mismatched `Source` variant vs header kind, duplicate BAR-index assignments, duplicate window assignments) MUST be enforced by assertion per `docs/specs/config/space.md` §Validation vs assertion. They are not typed errors.

## Wire / layout invariants

None owned. Bit-level BAR encoding is owned by `docs/specs/bar.md`. Expansion ROM register layout is owned by `docs/specs/header/type0.md` and `docs/specs/header/type1.md`. Bridge window register layout is owned by `docs/specs/header/type1.md` and its `EncodedWindow` mapping by `docs/specs/resources/bridge.md`. Command register layout is owned by `docs/specs/header/common.md`.

## View / borrowing behavior

- `plan.assignments` is borrowed; programming reads only.
- Each `Assignment.requirement.source` transitively borrows a `config.Function`; lifetime follows the underlying `ConfigSpace` backend.
- The per-function save frame lives on the internal recursion stack for one commit block; it is discarded on function-group return.
- No allocation, no cross-call caching.

## zstdx usage

None. Alignment masks and register widths are `u32`-bounded; the save frame is a fixed-size struct on the internal stack.

## Facade re-export `[zpci]`

`src/resources.zig`:

```zig
pub const programming = @import("resources/programming.zig");
```

Callers reach the public surface as `zpci.resources.programming.commit` and `zpci.resources.programming.Error`.

## Usage

**Commit a plan produced by assignment:**

```zig
const plan = try zpci.resources.assignment.intoScratch(input, &plan_scratch);
try zpci.resources.programming.commit(plan);
// Every function in the plan is now programmed with its planned bases and windows.
// Command register is restored to its pre-commit value on every function; caller
// enables IO / memory / bus-master separately via header.common helpers.
```

**Handle programming failures:**

```zig
zpci.resources.programming.commit(plan) catch |err| switch (err) {
    error.ProgrammingReadbackMismatch => {
        // A device did not accept a value programming wrote. Rollback restored
        // the affected function to its pre-commit state; prior functions in the
        // plan are still committed.
        return err;
    },
    error.ProgrammingWriteFailed => {
        // A config-space access failed. Rollback restored the affected function
        // to its pre-commit state; prior functions in the plan are still committed.
        return err;
    },
    error.ProgrammingPartial => {
        // Rollback itself failed. The affected function is in an unknown state;
        // prior functions in the plan are still committed. Caller inspects hardware
        // to identify the failing function and decides recovery policy.
        return err;
    },
};
```

**Enable decode after commit:**

```zig
// Caller-owned per docs/specs/header/common.md.
try zpci.header.common.setCommand(function, .{
    .io_space = true,
    .memory_space = true,
    .bus_master = true,
    // ...
});
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `commit` | never | backend-defined non-sleeping I/O; O(N × R × 2) config accesses (save + write + readback per register) | O(N × R) writes total; per-function frame O(R) | plan-targeted config state on success; pre-commit state on rollback-success; unspecified on `ProgrammingPartial` | single-thread over one `ConfigSpace` | DFS preorder per plan; §Per-function commit sequence per function |

`N = plan.assignments.len`; `R = max writes per function group` (bounded by header layout: ≤ 13 register writes per endpoint, ≤ 8 per bridge, plus 2 Command writes).

Rules:

- `commit` MUST NOT allocate, retry, log, or synchronize.
- `commit` MUST run single-threaded over one `ConfigSpace`. Concurrent commits on disjoint plans through the same `ConfigSpace` are caller policy.
- `commit` MUST be deterministic on stable hardware: same `plan` produces the same write / readback sequence.

## Required tests (category level)

**Happy path:**

- `unit:` single endpoint, one `.mmio32` BAR → save reads captured; disable-decode written; base RMW-written; decode restored; readback observes the written base.
- `unit:` single endpoint, one `.mmio64_pref` BAR → both low and high dwords written; low dword RMW preserves prefetchable bit from saved value; high dword written without RMW; readback observes both.
- `unit:` endpoint with mixed IO + memory BARs → disable-decode clears both `io_space` and `memory_space`; each BAR RMW-written; decode restored.
- `unit:` endpoint with expansion ROM → base written with saved enable bit preserved; reserved bits `[10:1]` written as zero even when saved value had them set.
- `unit:` bridge with IO window (16-bit) → `0x1C`, `0x1D` written; `0x30` and `0x32` explicitly zeroed; readback matches at each register.
- `unit:` bridge with IO window (32-bit) → `0x1C`, `0x1D`, `0x30`, `0x32` all written with real values.
- `unit:` bridge with memory window → `0x20`, `0x22` written.
- `unit:` bridge with prefetchable-32 window → `0x24`, `0x26` written; `0x28` and `0x2C` explicitly zeroed as `u32`.
- `unit:` bridge with prefetchable-64 window → `0x24`, `0x26`, `0x28`, `0x2C` written with real values.
- `unit:` bridge with all three windows → windows written in ascending offset order (`.io` first, `.memory` second, `.prefetchable_memory` third).
- `unit:` bridge BAR alongside bridge windows → BAR RMW then windows.
- `unit:` multi-function plan → DFS preorder respected; each function's Command is disabled and restored independently; readbacks confirm.
- `unit:` `Assignment.pool` differs from `Requirement.kind` (fallback case) → RMW low dword preserves the wire type bits from saved BAR value (which reflect the requirement's kind, not the pool).
- `unit:` deterministic: two commits of identical plans on identical fakes produce byte-identical write sequences.

**Failure and rollback:**

- `unit:` save-phase read failure → `ProgrammingWriteFailed`; no writes issued.
- `unit:` disable-decode write failure → `ProgrammingWriteFailed`; no rollback needed (state unchanged).
- `unit:` disable-decode readback mismatch → `ProgrammingReadbackMismatch`; no rollback needed.
- `unit:` BAR write failure mid-plan → rollback restores every previously-written BAR + Command; returns `ProgrammingWriteFailed`.
- `unit:` BAR readback mismatch mid-plan → rollback restores every previously-written BAR + Command; returns `ProgrammingReadbackMismatch`.
- `unit:` bridge window write failure → rollback restores BARs, ROM, previously-written windows, and Command; returns `ProgrammingWriteFailed`.
- `unit:` bridge window readback mismatch → rollback as above; returns `ProgrammingReadbackMismatch`.
- `unit:` restore-decode write failure at step 5 → rollback attempts to reverse the write phase; returns `ProgrammingPartial`.
- `unit:` rollback write failure during recovery → returns `ProgrammingPartial`; no further restores attempted.
- `unit:` rollback readback mismatch during recovery → returns `ProgrammingPartial`.
- `unit:` multi-function plan, group K fails → groups `0..K-1` remain committed; group K rolled back; groups `K+1..N-1` untouched.
- `unit:` `bridge.encodeWindow` returns `BridgeWindowUnencodable` during write phase → mapped to `ProgrammingWriteFailed`; rollback runs before the error propagates.

**Malformed / programmer error (assertion):**

- `malformed:` `.bridge_window` `Assignment` on a type-0 function → programmer-error assertion.
- `malformed:` two `.endpoint_bar` `Assignment`s with the same `BarRef.index` on one function → programmer-error assertion.
- `malformed:` two `.bridge_window` `Assignment`s with the same `window` on one function → programmer-error assertion.
- `malformed:` `.endpoint_bar` with `BarRef.index >= 6` on a type-0 function → programmer-error assertion.
- `malformed:` `.endpoint_bar` with `BarRef.index >= 2` on a type-1 function → programmer-error assertion.
- `malformed:` consecutive `Assignment`s in one function group reference different `config.Function` values → programmer-error assertion.

## Non-goals

- Bus-number programming (`docs/specs/resources/bus.md`).
- Command-register programming beyond decode-disable / restore (`docs/specs/header/common.md`).
- Bridge-control programming (`docs/specs/header/type1.md`).
- Expansion ROM enable-bit programming (`docs/specs/header/type0.md` / `docs/specs/header/type1.md`).
- Secondary-bus reset orchestration.
- Whole-plan rollback across prior successful function groups.
- Diagnostic out-parameters identifying the failing function.
- Retry on transient failures.
- Concurrent commits.
- MSI / MSI-X programming (`docs/specs/interrupts/msi.md`, `docs/specs/interrupts/msix.md`).
- Batched readback modes.

## Open questions

None owned by this spec.
