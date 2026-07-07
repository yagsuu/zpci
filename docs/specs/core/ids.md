# Core identifiers

Defines the identifier newtypes shared by every zpci subsystem: PCI segment, vendor id, device id, class code, and revision id. Backs the public `core` facade surface and every per-function decode path. The bus/device/function trio is owned by `docs/specs/core/bdf.md`.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/bdf.md`
- `docs/specs/core/errors.md`
- `docs/specs/header/common.md`

## Scope

Owned:

- `SegmentId`, `VendorId`, `DeviceId`, `RevisionId` integer newtypes.
- `ClassCode` aggregate plus `BaseClass`, `Subclass`, `ProgIf` byte newtypes.
- Constructors and accessors for each newtype.
- Named values for the PCI-SIG base-class vocabulary and a small curated set of well-known full `ClassCode` triples.
- `comptime` layout assertions for the wire-bearing aggregate (`ClassCode`).

Deferred:

- BDF and SBDF math (`core/bdf.md`).
- The header common register layout that carries these values on the wire (`header/common.md`).
- Vendor, device, subclass, and programming-interface catalogs. zpci does not ship name databases for those spaces; callers compare via `Subclass.of(...)` and `ProgIf.of(...)` against their own constants.

## Conventions `[zpci]`

- Every identifier is a single-field newtype: a `struct` wrapping the smallest integer or byte array required by the PCI spec. Distinct types prevent mixing at the type level — a `VendorId` cannot be passed where a `DeviceId` is expected, even though both are `u16`.
- Integer newtypes carry the field name `value`.
- `extern struct` aggregates carry colocated `comptime` layout assertions per `docs/guidelines/conventions.md` §Compile-time assertions.
- Constructors named `of` are `comptime`-only and reject out-of-range inputs at compile time. Constructors named `from` are runtime; they return `error.InvalidIdentifier` from `zpci.Error` on out-of-range input.
- `eql` compares value-by-value.
- Named values exist only for closed, spec-defined vocabularies. They live as `pub const` declarations on the owning newtype.

## Newtypes `[zpci wrappers over std layout]`

### `SegmentId`

PCI segment group number. The PCIe spec admits up to 65 536 segment groups; zpci treats segment-id values as opaque `u16` keys supplied by the caller.

```zig
pub const SegmentId = packed struct(u16) {
    value: u16,

    pub fn of(comptime n: u16) SegmentId { return .{ .value = n }; }
    pub fn from(n: u16) SegmentId { return .{ .value = n }; }
    pub fn eql(a: SegmentId, b: SegmentId) bool { return a.value == b.value; }

    comptime {
        std.debug.assert(@bitSizeOf(SegmentId) == 16);
    }
};
```

`SegmentId` accepts the full `u16` range. zpci does not impose ordering across segment groups; callers pair `SegmentId` with a `Segment` descriptor (see `docs/specs/config/ecam.md`).

### `VendorId`

PCI configuration-space `Vendor ID` at offset `0x00` (16 bits, little-endian).

```zig
pub const VendorId = struct {
    value: u16,

    /// Spec-mandated absent-function marker. A vendor id of `0xFFFF`
    /// reported by hardware means "no function present at this BDF".
    pub const absent: VendorId = .{ .value = 0xFFFF };

    pub fn of(comptime n: u16) VendorId { return .{ .value = n }; }
    pub fn from(n: u16) VendorId { return .{ .value = n }; }
    pub fn eql(a: VendorId, b: VendorId) bool { return a.value == b.value; }
    pub fn isAbsent(self: VendorId) bool { return self.value == 0xFFFF; }
};
```

Rules:

- Vendor id `0xFFFF` is the PCI-mandated "no device" marker. Callers route absence through `VendorId.isAbsent`. Header decode and topology enumeration translate this into `zpci.Error.AbsentFunction` only when an operation requires a present function.
- `VendorId.of(0)` is accepted; PCI assigns no semantics to `0x0000`.

### `DeviceId`

PCI configuration-space `Device ID` at offset `0x02` (16 bits, little-endian).

```zig
pub const DeviceId = struct {
    value: u16,

    pub fn of(comptime n: u16) DeviceId { return .{ .value = n }; }
    pub fn from(n: u16) DeviceId { return .{ .value = n }; }
    pub fn eql(a: DeviceId, b: DeviceId) bool { return a.value == b.value; }
};
```

`DeviceId` is fully opaque to zpci; the full `u16` range is accepted.

### `RevisionId`

PCI configuration-space `Revision ID` at offset `0x08` (8 bits).

```zig
pub const RevisionId = struct {
    value: u8,

    pub fn of(comptime n: u8) RevisionId { return .{ .value = n }; }
    pub fn from(n: u8) RevisionId { return .{ .value = n }; }
    pub fn eql(a: RevisionId, b: RevisionId) bool { return a.value == b.value; }
};
```

### `BaseClass`, `Subclass`, `ProgIf`

Byte components of the PCI class code. Distinct types prevent mixing.

```zig
pub const BaseClass = struct {
    value: u8,

    // PCI-SIG Code and ID Assignment Specification, base class values.
    pub const unclassified:           BaseClass = .of(0x00);
    pub const mass_storage:           BaseClass = .of(0x01);
    pub const network_controller:     BaseClass = .of(0x02);
    pub const display_controller:     BaseClass = .of(0x03);
    pub const multimedia_controller:  BaseClass = .of(0x04);
    pub const memory_controller:      BaseClass = .of(0x05);
    pub const bridge:                 BaseClass = .of(0x06);
    pub const simple_comm_controller: BaseClass = .of(0x07);
    pub const base_system_peripheral: BaseClass = .of(0x08);
    pub const input_device:           BaseClass = .of(0x09);
    pub const docking_station:        BaseClass = .of(0x0A);
    pub const processor:              BaseClass = .of(0x0B);
    pub const serial_bus_controller:  BaseClass = .of(0x0C);
    pub const wireless_controller:    BaseClass = .of(0x0D);
    pub const intelligent_controller: BaseClass = .of(0x0E);
    pub const satellite_comm:         BaseClass = .of(0x0F);
    pub const encryption_controller:  BaseClass = .of(0x10);
    pub const signal_processing:      BaseClass = .of(0x11);
    pub const processing_accelerator: BaseClass = .of(0x12);
    pub const non_essential_instr:    BaseClass = .of(0x13);
    pub const coprocessor:            BaseClass = .of(0x40);
    pub const unassigned:             BaseClass = .of(0xFF);

    pub fn of(comptime n: u8) BaseClass { return .{ .value = n }; }
    pub fn from(n: u8) BaseClass { return .{ .value = n }; }
    pub fn eql(a: BaseClass, b: BaseClass) bool { return a.value == b.value; }
};

pub const Subclass = struct {
    value: u8,

    pub fn of(comptime n: u8) Subclass { return .{ .value = n }; }
    pub fn from(n: u8) Subclass { return .{ .value = n }; }
    pub fn eql(a: Subclass, b: Subclass) bool { return a.value == b.value; }
};

pub const ProgIf = struct {
    value: u8,

    pub fn of(comptime n: u8) ProgIf { return .{ .value = n }; }
    pub fn from(n: u8) ProgIf { return .{ .value = n }; }
    pub fn eql(a: ProgIf, b: ProgIf) bool { return a.value == b.value; }
};
```

`Subclass` and `ProgIf` expose no named constants. Their value spaces vary per `BaseClass` and zpci does not catalog them.

### `ClassCode`

The three-byte class code at PCI configuration-space offsets `0x09..0x0C`, stored little-endian: `prog_if` at `0x09`, `subclass` at `0x0A`, `base_class` at `0x0B`. zpci models it as an `extern struct` so it can be decoded by direct byte access at the wire boundary.

```zig
pub const ClassCode = extern struct {
    prog_if: ProgIf,     // 0x09
    subclass: Subclass,  // 0x0A
    base_class: BaseClass, // 0x0B

    // Well-known full triples used widely enough to warrant a name.
    pub const bridge: ClassCode = .of(0x06, 0x04, 0x00); // PCI-to-PCI bridge
    pub const nvme:   ClassCode = .of(0x01, 0x08, 0x02);
    pub const ahci:   ClassCode = .of(0x01, 0x06, 0x01);
    pub const vga:    ClassCode = .of(0x03, 0x00, 0x00);
    pub const xhci:   ClassCode = .of(0x0C, 0x03, 0x30);
    pub const ehci:   ClassCode = .of(0x0C, 0x03, 0x20);
    pub const uhci:   ClassCode = .of(0x0C, 0x03, 0x00);

    /// Order: (base_class, subclass, prog_if).
    pub fn of(comptime base: u8, comptime sub: u8, comptime pif: u8) ClassCode {
        return .{
            .prog_if = ProgIf.of(pif),
            .subclass = Subclass.of(sub),
            .base_class = BaseClass.of(base),
        };
    }

    pub fn from(base: u8, sub: u8, pif: u8) ClassCode {
        return .{
            .prog_if = ProgIf.from(pif),
            .subclass = Subclass.from(sub),
            .base_class = BaseClass.from(base),
        };
    }

    pub fn eql(a: ClassCode, b: ClassCode) bool {
        return a.base_class.eql(b.base_class)
            and a.subclass.eql(b.subclass)
            and a.prog_if.eql(b.prog_if);
    }

    comptime {
        std.debug.assert(@sizeOf(ClassCode) == 3);
        std.debug.assert(@alignOf(ClassCode) == 1);
        std.debug.assert(@offsetOf(ClassCode, "prog_if") == 0);
        std.debug.assert(@offsetOf(ClassCode, "subclass") == 1);
        std.debug.assert(@offsetOf(ClassCode, "base_class") == 2);
    }
};
```

`ClassCode` is the only wire-bearing aggregate in `core/ids.zig`. Header modules read the class-code triple by reinterpreting bytes `0x09..0x0C` as `*const ClassCode`; alignment is `1`, so no `@alignCast` is required.

The named-triple set is closed. New entries require a spec amendment.

## Errors `[zpci]`

`core/ids` constructors do not surface a local `Error` set. `of` is `comptime` and uses compile-error diagnostics; `from` accepts the full integer domain for every newtype defined here and therefore cannot fail.

## Facade re-export `[zpci]`

`src/core.zig` re-exports the public newtypes:

```zig
const ids = @import("core/ids.zig");

pub const SegmentId = ids.SegmentId;
pub const VendorId = ids.VendorId;
pub const DeviceId = ids.DeviceId;
pub const ClassCode = ids.ClassCode;
pub const RevisionId = ids.RevisionId;
pub const BaseClass = ids.BaseClass;
pub const Subclass = ids.Subclass;
pub const ProgIf = ids.ProgIf;
```

Through the root facade callers reach them as `zpci.core.VendorId`, `zpci.core.ClassCode`, etc.

## Usage

Comptime literals:

```zig
const intel: zpci.core.VendorId = .of(0x8086);
const segment0: zpci.core.SegmentId = .of(0);
```

Switching on the class triple:

```zig
const class = function.classCode();
if (class.eql(zpci.core.ClassCode.bridge)) {
    // PCI-to-PCI bridge
} else if (class.eql(zpci.core.ClassCode.nvme)) {
    // NVMe controller
}
```

Branching by base class only:

```zig
if (class.base_class.eql(zpci.core.BaseClass.network_controller)) {
    // Any network controller, regardless of subclass/prog_if.
}
```

Runtime input:

```zig
const vid = zpci.core.VendorId.from(raw_u16);
if (vid.isAbsent()) return; // function not present
```

Class-code decode at the wire boundary (header decode owns the byte slice; the snippet illustrates the layout contract):

```zig
const class_ptr: *const zpci.core.ClassCode = @ptrCast(&header_bytes[0x09]);
const class = class_ptr.*;
```

## Non-goals

- Vendor and device name databases. zpci stores raw ids and does not ship vendor or device name data.
- Subclass and programming-interface catalogs. Their spaces are large, vary per base class, and drift across PCI-SIG revisions.
- ASCII identifier newtypes. PCI does not require ASCII identifier fields at the surfaces zpci owns.
- Subsystem vendor/device id newtypes. Subsystem ids live in type-0 header decode (`docs/specs/header/type0.md`) and reuse `VendorId` and `DeviceId`.

## Open questions

None owned by this spec.
