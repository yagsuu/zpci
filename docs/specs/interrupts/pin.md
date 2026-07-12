# PCI interrupt pin

Defines the semantic decode of the PCI Interrupt Pin register byte. Owns the `Pin` enum returned by header views when they read offset `0x3D`.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on `interrupts.Pin` and the mapping between raw config-space interrupt-pin bytes and typed values.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/header/common.md`
- `docs/specs/header/type0.md`
- `docs/specs/header/type1.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`

## Scope

Owned:

- `interrupts.Pin`, a semantic enum over the PCI Interrupt Pin register encoding.
- Decode from raw config-space byte values.
- Re-encoding a valid `Pin` to its raw byte value.
- The widened `interruptPin` return contract used by `header.common.View`, `header.type0.View`, and `header.type1.View`.

Deferred:

- Interrupt Line register semantics. Firmware, OS, or platform policy owns the line value.
- PCI INTx routing, bridge swizzling, ACPI/firmware route lookup, IOAPIC/GIC/LAPIC programming, and interrupt-remapping policy.
- MSI and MSI-X capability programming (`docs/specs/interrupts/msi.md`, `docs/specs/interrupts/msix.md`).
- Writing the Interrupt Pin register.

## Encoding `[std]`

The PCI Interrupt Pin register is an 8-bit config-space field:

| Raw byte | `Pin` | Meaning |
|---:|---|---|
| `0x00` | `.none` | No INTx pin. |
| `0x01` | `.inta` | INTA#. |
| `0x02` | `.intb` | INTB#. |
| `0x03` | `.intc` | INTC#. |
| `0x04` | `.intd` | INTD#. |
| `0x05..=0xFF` | — | Malformed field value. |

## API `[zpci]`

```zig
pub const Pin = enum(u8) {
    none = 0,
    inta = 1,
    intb = 2,
    intc = 3,
    intd = 4,

    pub const Error = error{MalformedField};

    pub fn from(encoded: u8) Error!Pin;
    pub fn raw(self: Pin) u8;
};
```

Rules:

- `Pin.from(encoded)` returns `.none`, `.inta`, `.intb`, `.intc`, or `.intd` for encoded values `0..=4`.
- `Pin.from(encoded)` returns `error.MalformedField` for encoded values `5..=255`.
- `raw` returns the exact PCI register byte for a valid typed pin.
- `Pin` is a semantic type, not a wire struct. It carries no pointer, performs no I/O, allocates no memory, and does not block or wait.

## Header view integration `[zpci]`

Header views decode the Interrupt Pin register at the read boundary:

```zig
pub fn interruptPin(self: View) (ConfigSpace.Error || Pin.Error)!Pin;
```

Rules:

- `header.common.View.interruptPin`, `header.type0.View.interruptPin`, and `header.type1.View.interruptPin` read byte `0x3D` through `config.Function.read8`.
- Config-space accessor failures propagate as `ConfigSpace.Error`.
- Raw values `0..=4` decode with `Pin.from`.
- Raw values `5..=255` return `error.MalformedField`.
- The methods do not allocate, block, retry, write config space, or consult platform interrupt-routing state.

## Errors

`Pin.Error` is `error{MalformedField}`, a subset of `pci.core.Error` per `docs/specs/core/errors.md`. Header view `interruptPin` methods union this error with `ConfigSpace.Error` because they both read config space and decode the byte.

## Facade re-export `[zpci]`

`src/interrupts.zig` re-exports the public type:

```zig
const pin = @import("interrupts/pin.zig");

pub const Pin = pin.Pin;
```

Callers reach the type as `pci.interrupts.Pin`.

## Usage

```zig
const pin = try view.interruptPin();
switch (pin) {
    .none => {},
    .inta, .intb, .intc, .intd => {},
}
```

## Non-goals

- A typed interrupt-line value.
- A route table, swizzle helper, or platform interrupt-controller abstraction.
- MSI/MSI-X routing or vector allocation.
- Interrupt Pin writes.
- Compatibility raw-byte accessors on header views.

## Open questions

None owned by this spec.
