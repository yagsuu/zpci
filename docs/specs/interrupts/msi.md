# MSI capability

Defines the typed view of the Message Signaled Interrupt capability identified by capability id `0x05` in the standard capability list, and its programming surface. Owns the wire layout of every MSI register in the four capability shapes (`addr_64` × `pvm`), the `VectorCount` enum, the `MessageControl` packed struct, `interrupts.msi.View`, the save-then-write-then-verify commit sequence in `View.program` and `View.disable`, and the caller-supplied `Routing` shape.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `interrupts.msi.View`, `Routing`, `VectorCount`, and `MessageControl`. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/header/common.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- Public constants naming each MSI register's byte offset relative to the capability base, for every capability shape (`!addr_64 && !pvm`, `addr_64 && !pvm`, `!addr_64 && pvm`, `addr_64 && pvm`).
- The `MessageControl` packed struct decoding of the 16-bit Message Control register at capability offset `0x02`.
- The `VectorCount` named enum for the `multiple_message_capable` / `multiple_message_enable` power-of-two encoding.
- `interrupts.msi.View`, a borrowed typed view over `config.Function` scoped to one MSI capability instance.
- `View.find` and `View.validate` constructors, capability-static queries, live typed reads, `View.setMask`, `View.program`, and `View.disable`.
- Version-independent capability-shape gating: `addr_64_capable`, `pvm_capable`, and `ext_msg_data_capable` snapshot values fixed at `validate` and consulted for offset dispatch and assertions.
- Reserved-bit preservation policy for Message Control writes.
- Save-then-write-then-verify commit discipline with per-view rollback in `View.program` and `View.disable`.
- Routing-input validation: multi-vector alignment of `data`, 32-bit-address enforcement on `!addr_64_capable`, extended-message-data enforcement on `!ext_msg_data_capable`, `vector_count <= multiple_message_capable`.

Deferred:

- MSI-X capability (`docs/specs/interrupts/msix.md`).
- Command-register programming, including `interrupt_disable` orchestration (`docs/specs/header/common.md`).
- Vector allocation strategy (caller policy).
- Message-address encoding for a specific interrupt controller (LAPIC, x2APIC, GIC).
- Cross-function MSI coordination.
- Pending-bit acknowledgement policy.
- Function-level reset before MSI programming.
- Retry on transient failures.
- Diagnostic out-parameters.
- Concurrent commits on one `ConfigSpace`.

## Layering `[zpci]`

`interrupts/msi` is the only zpci module that programs MSI capability registers.

Layering constraints from `docs/specs/architecture.md`:

- `interrupts/` imports `core/`, `config/`, and `capabilities/`. This spec imports `capabilities/list.zig` for `list.Iterator`, `list.Cursor`, and `list.Capability`; `config/space.zig` for `config.Function` and `config.ConfigSpace`.
- `interrupts/` MUST NOT import `resources/`, `topology/`, `memory/`, or `header/`.
- `View.program` and `View.disable` MUST NOT allocate. Save state lives in a fixed-size frame on the internal stack.

## Host-endianness assumption

This spec assumes a little-endian host, per `docs/specs/architecture.md` §Host endianness. `MessageControl` bit-casts from a native `u16` read; multi-byte address and data reads return native integer values from `ConfigSpace`.

## Public constants `[std]`

```zig
pub const cap_id: u8 = 0x05;

pub const register = struct {
    pub const message_control: u8 = 0x02;
    pub const message_address_lo: u8 = 0x04;
    pub const message_address_hi_64: u8 = 0x08;
    pub const message_data_32: u8 = 0x08;
    pub const message_data_64: u8 = 0x0C;
    pub const ext_message_data_32: u8 = 0x0A;
    pub const ext_message_data_64: u8 = 0x0E;
    pub const mask_bits_32: u8 = 0x0C;
    pub const mask_bits_64: u8 = 0x10;
    pub const pending_bits_32: u8 = 0x10;
    pub const pending_bits_64: u8 = 0x14;
};
```

Rules:

- `message_control`, `message_address_lo` occupy fixed offsets on every capability shape.
- `message_address_hi_64` applies only when `addr_64_capable == true`.
- `message_data_32` applies when `addr_64_capable == false`; `message_data_64` applies when `addr_64_capable == true`.
- `ext_message_data_32` / `ext_message_data_64` apply only when `ext_msg_data_capable == true`.
- `mask_bits_*` and `pending_bits_*` apply only when `pvm_capable == true`.
- The bytes at `0x00` (capability id) and `0x01` (next pointer) are owned by `docs/specs/capabilities/list.md` and are not reached through `View`.

## `MessageControl` `[std]`

```zig
pub const MessageControl = packed struct(u16) {
    msi_enable: bool,
    multiple_message_capable: u3,
    multiple_message_enable: u3,
    addr_64_capable: bool,
    pvm_capable: bool,
    ext_msg_data_capable: bool,
    ext_msg_data_enable: bool,
    _reserved11: u5,
};
```

Rules:

- `MessageControl` is bit-cast from the `u16` read at `capability.offset + register.message_control`.
- `_reserved11` (bits `[15:11]`) is `RsvdP` per PCI base r5.0. `View.program` and `View.disable` preserve these bits from the saved value.
- `msi_enable` (bit `[0]`) is RW.
- `multiple_message_capable` (bits `[3:1]`) is RO; hardware reports the maximum vector count as a power-of-two exponent.
- `multiple_message_enable` (bits `[6:4]`) is RW; software MUST NOT set a value greater than `multiple_message_capable`.
- `addr_64_capable` (bit `[7]`) is RO; fixes the layout of address and data registers.
- `pvm_capable` (bit `[8]`) is RO; fixes the presence of mask and pending registers.
- `ext_msg_data_capable` (bit `[9]`) is RO; controls the presence of the extended-message-data register.
- `ext_msg_data_enable` (bit `[10]`) is RW.

## `VectorCount` `[std]`

```zig
pub const VectorCount = enum(u3) {
    one = 0,
    two = 1,
    four = 2,
    eight = 3,
    sixteen = 4,
    thirty_two = 5,
    _,

    pub fn numVectors(self: VectorCount) MalformedFieldError!u6;
    pub fn fromCount(n: u6) InvalidRoutingError!VectorCount;
};

pub const MalformedFieldError = error{MalformedField};
pub const InvalidRoutingError = error{InvalidRouting};
```

Rules:

- Encodings `0..5` correspond to vector counts `1, 2, 4, 8, 16, 32`.
- Encodings `6` and `7` are reserved by PCI base r5.0. `numVectors` returns `error.MalformedField` for either.
- `fromCount(n)` requires `n` to be a power of two in `1..=32`; any other value returns `error.InvalidRouting`.

## `View` `[zpci]`

```zig
pub const View = struct {
    function: config.Function,
    base: u8,
    control_snapshot: MessageControl,

    pub const ReadError = error{
        MalformedCapability,
        MalformedField,
    } || config.ConfigSpace.Error;

    pub const ProgramError = error{
        MalformedField,
        InvalidRouting,
        ProgrammingReadbackMismatch,
        ProgrammingWriteFailed,
        ProgrammingPartial,
    };

    pub const Routing = struct {
        address: u64,
        data: u16,
        vector_count: VectorCount,
        pvm: PvmRouting = .unused,
        ext_data: ExtDataRouting = .unused,

        pub const PvmRouting = union(enum) {
            unused: void,
            /// Initial 32-bit mask register value. Bit `i` set to `1`
            /// masks vector `i`; bit `0` cleared unmasks vector `i`.
            /// Callers requesting all vectors initially masked pass
            /// `.initial_mask = 0xFFFF_FFFF`.
            initial_mask: u32,
        };

        pub const ExtDataRouting = union(enum) {
            unused: void,
            value: u16,
        };
    };

    pub fn find(function: config.Function) ReadError!?View;
    pub fn validate(function: config.Function, capability: list.Capability) ReadError!View;

    pub fn addr64Capable(self: View) bool;
    pub fn pvmCapable(self: View) bool;
    pub fn extMessageDataCapable(self: View) bool;
    pub fn multipleMessageCapable(self: View) ReadError!VectorCount;

    pub fn messageControl(self: View) ReadError!MessageControl;
    pub fn messageAddress(self: View) ReadError!u64;
    pub fn messageData(self: View) ReadError!u16;
    pub fn multipleMessageEnable(self: View) ReadError!VectorCount;
    pub fn extendedMessageData(self: View) ReadError!u16;
    pub fn extendedMessageDataEnabled(self: View) ReadError!bool;
    pub fn mask(self: View) ReadError!u32;
    pub fn pending(self: View) ReadError!u32;

    /// Reads current MSI state into a `Routing` value populated with
    /// `.pvm = .unused` on `!pvm_capable` views and `.ext_data = .unused`
    /// on `!ext_msg_data_capable` views. Symmetric with `program(Routing)`.
    /// Performs one config read for Message Control plus 3-6 additional
    /// reads depending on capability gating.
    pub fn readRouting(self: View) ReadError!Routing;

    /// Sets or clears the mask bit for one vector by reading `mask()`,
    /// applying the change, and writing back. Composes `mask()` and
    /// `setMask()`. Asserts `pvm_capable`. Vector index MUST be in
    /// `0..numVectors(multipleMessageCapable())`.
    pub fn setVectorMasked(self: View, index: u5, masked: bool) ProgramError!void;

    pub fn setMask(self: View, value: u32) ProgramError!void;
    pub fn program(self: View, routing: Routing) ProgramError!void;
    pub fn disable(self: View) ProgramError!void;
};
```

Rules:

- `View` is a value type storing `config.Function`, the capability base offset, and a cached `MessageControl` snapshot captured at `validate`.
- `control_snapshot` supplies `addr_64_capable`, `pvm_capable`, `ext_msg_data_capable`, and `multiple_message_capable` without re-reading Message Control. Software-writable bits (`msi_enable`, `multiple_message_enable`, `ext_msg_data_enable`) MUST be read live via `messageControl`.
- `Routing` is a plain value type; `program` consumes it by value.
- `PvmRouting = .unused` and `ExtDataRouting = .unused` are structural defaults naming capability absence, not policy choices. Callers MUST supply `.masked = <mask>` when `pvm_capable == true` and `.value = <data>` when programming extended message data.
- Every method MUST NOT allocate, retry, log, or synchronize.
- `View` is copyable. Copies share the same `config.Function` and observe the same live state.

### `find` `[zpci]`

`find(function)` walks the standard capability list rooted at `common.Status.capabilities_list` and returns a `View` for the first capability whose id is `cap_id`.

1. Construct `capabilities.list.Iterator.validate(function)`.
2. For each yielded `Capability`, if `capability.id == cap_id`, delegate to `validate(function, capability)` and return the result.
3. If iteration completes without finding `cap_id`, return `null`.

Rules:

- `find` returns `null` when the function has no MSI capability. This is a valid steady-state result, not an error.
- `find` propagates `MalformedCapability` from the iterator when the capability list itself is malformed.
- `find` propagates `MalformedField` from `validate` when the found MSI capability's Message Control has a reserved `multiple_message_capable` encoding.
- `find` propagates `ConfigSpace.Error` from any config read during traversal or validation.

### `validate` `[zpci]`

`validate(function, capability)` constructs a `View` from a specific capability entry the caller already identified.

1. Assert `capability.id == cap_id`. Programmer error.
2. Read `MessageControl` via `function.read16(capability.offset + register.message_control)`.
3. Call `multiple_message_capable_as_enum.numVectors()`. Propagate `error.MalformedField` on a reserved encoding.
4. Return `View{ .function = function, .base = capability.offset, .control_snapshot = message_control }`.

Rules:

- `capability.id != cap_id` is a programmer error and MUST be enforced by assertion per `docs/specs/config/space.md` §Validation vs assertion. It is not a typed error.
- `validate` performs exactly one config read.
- `validate` MUST NOT re-read `MessageControl` after the initial read.

### Capability-static queries

Rules:

- `addr64Capable`, `pvmCapable`, and `extMessageDataCapable` return `self.control_snapshot.<field>` without config access.
- `multipleMessageCapable` returns `self.control_snapshot.multiple_message_capable` decoded as `VectorCount`. Reserved encodings propagate `error.MalformedField`.

### Live reads

Rules:

- Every live read performs one config access at the offset dictated by `addr_64_capable`, `pvm_capable`, and `ext_msg_data_capable` per §Public constants.
- `messageAddress` returns `@as(u64, address_high) << 32 | address_low` when `addr_64_capable == true`, else `@as(u64, address_low)` and does not read the high register.
- `messageData` reads at `register.message_data_32` when `addr_64_capable == false`, else at `register.message_data_64`.
- `multipleMessageEnable` reads live Message Control and returns `multiple_message_enable` decoded as `VectorCount`.
- `extendedMessageData` asserts `self.extMessageDataCapable()`. The assertion enforces that callers gate on the capability bit; a call on a `!ext_msg_data_capable` view is a programmer error. Reads at `register.ext_message_data_32` or `register.ext_message_data_64` per `addr_64_capable`.
- `extendedMessageDataEnabled` reads live Message Control and returns `ext_msg_data_enable`.
- `mask` and `pending` assert `self.pvmCapable()`. The assertion enforces that callers gate on the capability bit; a call on a `!pvm_capable` view is a programmer error. Reads use the 32-bit or 64-bit offset variants per `addr_64_capable`.

### `setMask` `[zpci]`

`setMask(value)` writes the full 32-bit mask register when `pvm_capable == true`.

1. Assert `self.pvmCapable()`. Programmer error to call otherwise.
2. Read the saved mask value.
3. Write `value` to `register.mask_bits_32` or `register.mask_bits_64` per `addr_64_capable`.
4. Read back and compare against `value`. On mismatch, restore the saved value with readback; on rollback success return `error.ProgrammingReadbackMismatch`; on rollback failure return `error.ProgrammingPartial`.
5. On write or readback `ConfigSpace.Error`, map to `error.ProgrammingWriteFailed`; run rollback with the same discipline.

Rules:

- Callers modifying individual mask bits read `mask()` first, apply their bit changes to the returned `u32`, and call `setMask(new_value)`. The mask register is software-owned; no hardware writes are expected between the read and the write.
- `setMask` does not touch Message Control or any other register.

## `Routing` `[zpci]`

Rules:

- `address` is the full message-address value in native byte order. When `addr_64_capable == false`, `address > 0xFFFF_FFFF` MUST return `error.InvalidRouting`. When `addr_64_capable == true`, the high 32 bits are written to `register.message_address_hi_64` even when zero.
- `data` is the base message-data value. Hardware fills the low `log2(numVectors(vector_count))` bits when signaling a specific vector on multi-vector configurations; callers MUST supply `data` with those low bits clear. A non-zero low-bits value returns `error.InvalidRouting`.
- `vector_count` MUST satisfy `numVectors(vector_count) <= numVectors(view.multipleMessageCapable())`. A larger request returns `error.InvalidRouting`.
- `pvm == .initial_mask` MUST match `view.pvmCapable() == true`. A `.initial_mask` value on a `!pvm_capable` view returns `error.InvalidRouting`. A `.unused` value on a `pvm_capable` view is legal and does not modify the mask register.
- `ext_data == .value` MUST match `view.extMessageDataCapable() == true`. A `.value` on a `!ext_msg_data_capable` view returns `error.InvalidRouting`.

## `program` `[zpci]`

`program(routing)` writes a complete MSI configuration in one atomic-per-view commit sequence.

Sequence:

1. **Routing validation** — validate `routing` per §Routing rules. Any violation returns `error.InvalidRouting` before any config access.
2. **Save phase** — read Message Control, message address low, message address high (when `addr_64_capable`), message data (at the shape-selected offset), extended message data (when `ext_msg_data_capable`), and mask (when `pvm_capable`) into a stack-local save frame. Any read failure returns `error.ProgrammingWriteFailed`; no writes issued.
3. **Disable phase** — compute `new_control = saved_control` with `msi_enable = false`. Write Message Control; readback. On failure, no rollback is required (state is unchanged from the initial Message Control read); return `error.ProgrammingReadbackMismatch` or `error.ProgrammingWriteFailed`.
4. **Mask phase** — when `pvm == .initial_mask`, write `routing.pvm.initial_mask` to the mask register; readback. On failure, run §Rollback and return the original error.
5. **Address write phase** — write `@truncate(routing.address)` to `register.message_address_lo`; readback. When `addr_64_capable == true`, write `@truncate(routing.address >> 32)` to `register.message_address_hi_64`; readback. On failure, run §Rollback and return the original error.
6. **Data write phase** — write `routing.data` to the shape-selected message data offset; readback. On failure, run §Rollback and return the original error.
7. **Extended-data write phase** — when `ext_data == .value`, write `routing.ext_data.value` to the shape-selected extended-message-data offset; readback. On failure, run §Rollback and return the original error.
8. **Enable phase** — compute the final Message Control: `msi_enable = true`; `multiple_message_enable = @intFromEnum(routing.vector_count)`; `ext_msg_data_enable = (routing.ext_data == .value)`; `_reserved11 = saved_control._reserved11`. Write Message Control; readback. On failure, run §Rollback and return the original error.

### Rollback

Rules:

- Rollback restores every previously-written register in reverse write order. Each restore write is followed by a readback and compared against the saved value.
- A restore-phase write or restore-readback failure returns `error.ProgrammingPartial` immediately; further restores are abandoned.
- On successful rollback, `program` returns the original error (`error.ProgrammingReadbackMismatch` or `error.ProgrammingWriteFailed`) that triggered rollback.
- Rollback MUST NOT retry a failed restore.
- Rollback does not touch registers outside the save frame. Command register state and every register on other functions are unchanged.

### Readback discipline

Rules:

- Every write in phases 3–8 and every restore write is followed by a read at the same offset and width.
- Message Control comparison is full 16-bit equality. `_reserved11` bits are preserved by the write and MUST match the saved value on readback.
- Address, data, extended-data, and mask comparisons are full-width equality at the register's natural width.
- A read failure during readback returns `error.ProgrammingWriteFailed` and triggers rollback.
- A comparison mismatch returns `error.ProgrammingReadbackMismatch` and triggers rollback.

## `disable` `[zpci]`

`disable()` clears `msi_enable` without touching address, data, mask, or extended-message-data registers.

Sequence:

1. Read Message Control.
2. Compute `new_control = saved_control` with `msi_enable = false`.
3. Write Message Control; readback. On mismatch return `error.ProgrammingReadbackMismatch`; on `ConfigSpace.Error` return `error.ProgrammingWriteFailed`.

Rules:

- `disable` performs one read, one write, and one readback.
- `disable` is idempotent: calling `disable` on a view whose `msi_enable == false` still issues the write; readback observes the unchanged value.
- `disable` preserves `_reserved11`, `multiple_message_enable`, `ext_msg_data_enable`, and every other Message Control bit.
- On write or readback failure, `disable` returns the corresponding error without rollback. The single write's failure leaves Message Control in its pre-`disable` state.

## Errors

```zig
pub const ReadError = error{
    MalformedCapability,
    MalformedField,
} || config.ConfigSpace.Error;

pub const ProgramError = error{
    MalformedField,
    InvalidRouting,
    ProgrammingReadbackMismatch,
    ProgrammingWriteFailed,
    ProgrammingPartial,
};
```

Variant sourcing:

- `MalformedCapability` — `find` propagates it from `capabilities.list.Iterator` when the capability list is malformed. `validate` propagates it in no case owned here; the assertion on `capability.id == cap_id` catches misuse before any read. The `zpci.Error` variant is defined by `docs/specs/core/errors.md`.
- `MalformedField` — Message Control's `multiple_message_capable` decoded to a reserved encoding (6 or 7). Reachable through `multipleMessageCapable` and through `validate`.
- `InvalidRouting` — routing-input validation failed per §`Routing` rules. Returned before any config access.
- `ProgrammingReadbackMismatch` — a readback comparison in `program`, `setMask`, or `disable` observed a value that does not match what was written. Rollback ran successfully.
- `ProgrammingWriteFailed` — a `ConfigSpace` read or write returned an accessor error during the save phase or a write phase of `program`, `setMask`, or `disable`. Rollback ran successfully.
- `ProgrammingPartial` — a rollback write or rollback readback itself failed. Hardware is neither in the pre-commit state nor the planned post-commit state.
- `ConfigSpace.Error` — propagated by `find`, `validate`, and every live read. Programming operations map `ConfigSpace.Error` to `ProgrammingWriteFailed` at the point of failure and do not propagate `ConfigSpace.Error` directly.

Rules:

- Programmer errors (calling `validate` with a non-MSI capability, calling `extendedMessageData` on a `!ext_msg_data_capable` view, calling `mask` / `pending` / `setMask` on a `!pvm_capable` view) MUST be enforced by assertion. They are not typed errors.
- `ProgramError` MUST NOT include `MalformedCapability` or `ConfigSpace.Error`. Program operations assume `View.validate` succeeded; the capability structure is already validated.

## Wire / layout invariants

None owned as `extern struct`. `MessageControl` is `packed struct(u16)`, bit-cast from a native `u16` read.

Compile-time size assertions:

```zig
comptime {
    std.debug.assert(@sizeOf(MessageControl) == 2);
    std.debug.assert(@bitSizeOf(MessageControl) == 16);
}
```

Reserved bits (`_reserved11`) round-trip byte-for-byte on writes performed through `program`, `disable`, and `setMask` (which does not touch Message Control).

## View / borrowing behavior

- `View` stores `config.Function`, `u8`, and `MessageControl` inline.
- `View.function` is a borrowed handle; lifetime follows the underlying `ConfigSpace` backend.
- `Routing` is a plain value; `program` consumes it by value.
- The save frame in `program` (≤ 6 × `u32` + `u16`) lives on the internal recursion stack for one call; discarded on return.
- No allocation.
- Copies of a `View` are independent value copies of the same `config.Function` handle and cached snapshot.

## zstdx usage

None. `u32` masks and `u16` control values fit natively; the save frame is a fixed-size struct on the internal stack.

## Facade re-export `[zpci]`

`src/interrupts.zig`:

```zig
pub const msi = @import("interrupts/msi.zig");
```

Callers reach the public surface as `zpci.interrupts.msi.View`, `zpci.interrupts.msi.View.Routing`, `zpci.interrupts.msi.VectorCount`, `zpci.interrupts.msi.MessageControl`, `zpci.interrupts.msi.cap_id`, and `zpci.interrupts.msi.register`.

## Usage

**Discover and program a single-vector MSI:**

```zig
const view = try zpci.interrupts.msi.View.find(function) orelse return error.NoMsi;
try view.program(.{
    .address = 0xFEE0_0000,
    .data = 0x30,
    .vector_count = .one,
});
```

**Program a multi-vector MSI with per-vector masking:**

```zig
const view = try zpci.interrupts.msi.View.find(function) orelse return error.NoMsi;
try view.program(.{
    .address = 0xFEE0_0000,
    .data = 0x50,
    .vector_count = .four,
    .pvm = .{ .initial_mask = 0xFFFF_FFFF },
});
```

**Mask one vector after MSI is programmed:**

```zig
const current = try view.mask();
try view.setMask(current | (@as(u32, 1) << 3));
```

**Read current state during driver reload:**

```zig
const control = try view.messageControl();
if (control.msi_enable) {
    const active = try view.multipleMessageEnable();
    const addr = try view.messageAddress();
    const data = try view.messageData();
    _ = .{ active, addr, data };
}
```

**Coordinate with `Command.interrupt_disable` (caller-owned, per `docs/specs/header/common.md`):**

```zig
const header = try zpci.header.common.View.validate(function);
var cmd = try header.command();
cmd.interrupt_disable = true;
try header.setCommand(cmd);

const view = try zpci.interrupts.msi.View.find(function) orelse return error.NoMsi;
try view.program(.{
    .address = 0xFEE0_0000,
    .data = 0x30,
    .vector_count = .one,
});
```

**Handle programming failures:**

```zig
view.program(routing) catch |err| switch (err) {
    error.InvalidRouting => return err,
    error.MalformedField => return err,
    error.ProgrammingReadbackMismatch,
    error.ProgrammingWriteFailed => return err,
    error.ProgrammingPartial => return err,
};
```

## Behavior contract

| Operation | Allocation | Waiting | Bounds | Invalidation | Concurrency | Ordering |
|---|---|---|---|---|---|---|
| `View.find` | never | O(N) config reads (N ≤ 48 capability slots) | capability-list traversal per `docs/specs/capabilities/list.md` | none | backend-defined | list order |
| `View.validate` | never | one config read | capability id + Message Control read | none | backend-defined | Message Control |
| Capability-static queries | never | never | snapshot lookup | none | pure | none |
| Live reads (`messageControl`, `messageAddress`, `messageData`, `multipleMessageEnable`, `extendedMessageData`, `extendedMessageDataEnabled`, `mask`, `pending`) | never | 1–2 config reads per call | offset math within the shape-selected register | none | backend-defined | one register per call |
| `View.setMask` | never | 1 read + 1 write + 1 readback; up to 1 restore write + readback | offset math | mask register on success; pre-commit state on rollback-success; unspecified on `ProgrammingPartial` | single-thread over one `ConfigSpace` | write then readback |
| `View.program` | never | O(R × 2) config accesses; R ≤ 6 in the maximal `addr_64 && pvm && ext_msg_data` case | routing-input validation + capability-gated dispatch | on success: MSI enabled with routing state; on rollback-success: pre-commit state; on `ProgrammingPartial`: unspecified | single-thread over one `ConfigSpace` | disable → mask → address → data → ext_data → enable |
| `View.disable` | never | 1 read + 1 write + 1 readback | Message Control | on success: `msi_enable == false`; other fields unchanged | single-thread over one `ConfigSpace` | RMW Message Control |

Rules:

- `View.program`, `View.setMask`, and `View.disable` MUST NOT allocate, retry, log, or synchronize.
- Every write MUST be immediately followed by a readback at the same offset and width.
- `View.program` MUST run single-threaded over one `ConfigSpace`. Concurrent `program` calls on the same function are caller policy.
- `View.program` MUST be deterministic on stable hardware: same `routing` produces the same write / readback sequence.

## Required tests (category level)

**View decode:**

- `unit:` valid MSI with `!addr_64 && !pvm && !ext` → `find` returns non-null; snapshot fields correct.
- `unit:` valid MSI with `addr_64 && !pvm && !ext` → offsets dispatch to `register.message_address_hi_64` and `register.message_data_64`.
- `unit:` valid MSI with `!addr_64 && pvm && !ext` → offsets dispatch to `register.mask_bits_32` and `register.pending_bits_32`.
- `unit:` valid MSI with `addr_64 && pvm && ext` → offsets dispatch to `register.mask_bits_64`, `register.pending_bits_64`, and `register.ext_message_data_64`.
- `unit:` `multiple_message_capable == 6` → `validate` returns `error.MalformedField`.
- `unit:` `multiple_message_capable == 7` → `validate` returns `error.MalformedField`.
- `unit:` `find` on a function with no capability list → returns `null`.
- `unit:` `find` on a function whose capability list contains no `cap_id` → returns `null`.
- `unit:` `find` on a function whose capability list has a cycle → returns `error.MalformedCapability`.
- `unit:` `validate` called on a non-MSI capability → programmer-error assertion.

**Live reads:**

- `unit:` `messageAddress` on `addr_64` device reads both dwords; returns `(hi << 32) | lo`.
- `unit:` `messageAddress` on `!addr_64` device reads only the low dword; returns `@as(u64, lo)`.
- `unit:` `messageData` reads at the shape-selected offset.
- `unit:` `multipleMessageEnable` on a device with `multiple_message_enable == 2` returns `.four`.
- `unit:` `extendedMessageDataEnabled` returns the live `ext_msg_data_enable` bit from Message Control.
- `unit:` `extendedMessageData` called on `!ext_msg_data_capable` view → programmer-error assertion.
- `unit:` `mask` and `pending` called on `!pvm_capable` view → programmer-error assertion.

**Routing validation:**

- `unit:` `vector_count > multiple_message_capable` → `program` returns `error.InvalidRouting` before any write.
- `unit:` `data & ((1 << log2(numVectors(vector_count))) - 1) != 0` → `error.InvalidRouting`.
- `unit:` `address > 0xFFFF_FFFF` on `!addr_64_capable` → `error.InvalidRouting`.
- `unit:` `pvm == .initial_mask` on `!pvm_capable` → `error.InvalidRouting`.
- `unit:` `ext_data == .value` on `!ext_msg_data_capable` → `error.InvalidRouting`.
- `unit:` `pvm == .unused` on `pvm_capable` → accepted; mask register left at pre-commit value; `msi_enable` becomes true.

**`program` happy path:**

- `unit:` minimal MSI (`!addr_64 && !pvm && !ext`), single vector → write sequence: disable, address low, data, enable.
- `unit:` `addr_64` MSI, single vector → write sequence: disable, address low, address high, data, enable.
- `unit:` `pvm` MSI, single vector, `pvm == .initial_mask = 0xFFFF_FFFF` → write sequence: disable, mask, address, data, enable.
- `unit:` `ext` MSI, single vector, `ext_data == .value = 0xABCD` → write sequence includes extended-message-data write between data and enable; enable phase sets `ext_msg_data_enable == true`.
- `unit:` multi-vector: `vector_count = .four`, `data = 0x40` → validation passes (`0x40 & 0x3 == 0`); enable phase writes Message Control with `multiple_message_enable == 2`.
- `unit:` `program` writes reserved bits (`_reserved11`) preserved from the saved value in both disable and enable phases.
- `unit:` deterministic: two `program` calls with identical `routing` on identical fakes produce byte-identical write sequences.

**`program` failure and rollback:**

- `unit:` save-phase read failure → `error.ProgrammingWriteFailed`; no writes issued.
- `unit:` disable-phase readback mismatch → `error.ProgrammingReadbackMismatch`; no rollback needed (Message Control write is the only mutation and readback confirms).
- `unit:` mask-phase write failure → rollback restores Message Control; returns `error.ProgrammingWriteFailed`.
- `unit:` address-low write readback mismatch → rollback restores mask (when written) and Message Control; returns `error.ProgrammingReadbackMismatch`.
- `unit:` data write failure → rollback restores address(es), mask, Message Control; returns `error.ProgrammingWriteFailed`.
- `unit:` extended-data write failure → rollback restores data, address(es), mask, Message Control.
- `unit:` enable-phase readback mismatch → rollback restores every previously-written register; returns `error.ProgrammingReadbackMismatch`.
- `unit:` rollback write failure during recovery → returns `error.ProgrammingPartial`.
- `unit:` rollback readback mismatch during recovery → returns `error.ProgrammingPartial`.

**`disable`:**

- `unit:` MSI currently enabled → `disable` reads Message Control, writes with `msi_enable == false`, readback matches.
- `unit:` MSI already disabled → `disable` still writes and readbacks; readback matches saved value.
- `unit:` `disable` preserves `_reserved11`, `multiple_message_enable`, and `ext_msg_data_enable`.
- `unit:` `disable` does not touch address, data, mask, or extended-message-data registers.
- `unit:` `disable` write failure → `error.ProgrammingWriteFailed`; single-write failure requires no rollback.
- `unit:` `disable` readback mismatch → `error.ProgrammingReadbackMismatch`.

**`setMask`:**

- `unit:` `setMask` on `pvm_capable` view writes the full `u32` and readbacks.
- `unit:` `setMask` write failure → rollback attempts to restore the saved mask value; returns `error.ProgrammingWriteFailed`.
- `unit:` `setMask` readback mismatch → rollback restores saved mask; returns `error.ProgrammingReadbackMismatch`.
- `unit:` `setMask` rollback failure → `error.ProgrammingPartial`.
- `unit:` `setMask` on `!pvm_capable` view → programmer-error assertion.

**Malformed / programmer error (assertion):**

- `malformed:` `View` constructed on a non-MSI capability then used → programmer-error assertion at `validate`.
- `malformed:` `setMask` on `!pvm_capable` view → programmer-error assertion.
- `malformed:` `extendedMessageData` on `!ext_msg_data_capable` view → programmer-error assertion.
- `malformed:` `mask` or `pending` on `!pvm_capable` view → programmer-error assertion.

## Non-goals

- MSI-X capability (`docs/specs/interrupts/msix.md`).
- Command-register programming, including `interrupt_disable` orchestration.
- Vector allocation strategy.
- Message-address encoding for a specific interrupt controller.
- Cross-function MSI coordination.
- Pending-bit acknowledgement policy.
- Function-level reset before MSI programming.
- Retry on transient failures.
- Diagnostic out-parameters identifying which register failed rollback.
- Concurrent commits on one `ConfigSpace`.
- Whole-list `View.findAll` batch discovery.

## Open questions

None owned by this spec.
