# Bus/device/function

Defines `Bdf` (bus, device, function) and `Sbdf` (segment + Bdf), plus the offset math every config-space accessor consumes. Owns the integer packing, ECAM aperture-relative offset, the 4 KiB function-window offset combine, and the iteration helpers used by enumeration.

Per `docs/guidelines/conventions.md` §Authority order, this domain spec is the sole authority on the `Bdf` and `Sbdf` types, their layouts, and their APIs. Any conflicting declarations in `docs/specs/index.md` or `docs/specs/architecture.md` are illustrative and are corrected to match this spec.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/architecture.md`
- `docs/specs/core/ids.md`
- `docs/specs/core/errors.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/ecam.md`
- `docs/specs/topology/enumerate.md`

## Scope

Owned:

- `Bdf` type (`packed struct(u16)`, bit-compatible with the PCIe Requester ID).
- `Sbdf` type (`packed struct(u32)`, segment plus Bdf).
- Comptime and runtime constructors for both.
- ECAM aperture-relative offset math from `(bus, device, function)`.
- Combine of the bus-relative offset with the 4 KiB function-window offset.
- Function-0 derivation used by multifunction discovery.
- Bdf and Sbdf ordering and iteration helpers required by enumeration.
- Equality and formatting.

Deferred:

- The `Segment` aperture descriptor type and bus-range containment by segment (`docs/specs/config/ecam.md` owns the descriptor; this spec exposes a Bdf-only helper that takes raw `bus_start`/`bus_end` bytes).
- Multifunction policy (`docs/specs/topology/enumerate.md`).
- ARI flat-function-space policy (`docs/specs/topology/enumerate.md`).
- Programming bridge bus-number registers (`docs/specs/resources/bus.md`).

## Conventions `[zpci]`

- `Bdf` is a `packed struct(u16)`. The bit layout matches the PCIe Requester ID encoding: `function` in the three LSBs, `device` in the next five bits, `bus` in the high byte. The field declaration order is LSB-first per Zig's packed-struct layout rule.
- `Sbdf` is a `packed struct(u32)` carrying a `Bdf` in the low 16 bits and a `SegmentId` in the high 16 bits. Field declaration order is LSB-first.
- Construction names follow `core/ids.md`: `of` is `comptime`-only; `from` is runtime and returns `error.InvalidIdentifier` (mapped from `zpci.Error`) on out-of-range input.
- Comptime layout assertions live at the end of each type body per `docs/guidelines/conventions.md` §Compile-time assertions.
- Neither `Bdf` nor `Sbdf` may have its fields taken by reference (`&bdf.bus`). All internal helpers read fields by value. New helpers must follow the same rule.

## `Bdf`

```zig
pub const Bdf = packed struct(u16) {
    function: u3,
    device: u5,
    bus: u8,

    /// Comptime constructor. Compile error if `device > 31` or
    /// `function > 7`. The `bus` parameter accepts the full `u8` range.
    pub fn of(comptime b: u8, comptime d: u5, comptime f: u3) Bdf {
        return .{ .function = f, .device = d, .bus = b };
    }

    /// Runtime constructor. Returns `error.InvalidIdentifier` when
    /// `device > 31` or `function > 7`.
    pub fn from(b: u8, d: u8, f: u8) error{InvalidIdentifier}!Bdf {
        if (d > 31 or f > 7) return error.InvalidIdentifier;
        return .{
            .function = @intCast(f),
            .device = @intCast(d),
            .bus = b,
        };
    }

    pub fn eql(a: Bdf, b: Bdf) bool {
        return @as(u16, @bitCast(a)) == @as(u16, @bitCast(b));
    }

    /// Total ordering used by enumeration iterators. The packed layout
    /// places `bus` in the high byte and `function` in the LSBs, so the
    /// u16 bit-cast already yields bus-major, device-minor,
    /// function-least ordering.
    pub fn lessThan(a: Bdf, b: Bdf) bool {
        return @as(u16, @bitCast(a)) < @as(u16, @bitCast(b));
    }

    /// Function 0 at the same (bus, device). Used by multifunction
    /// discovery to read the header-type byte on function 0 before
    /// scanning functions 1..7.
    pub fn function0(self: Bdf) Bdf {
        return .{ .function = 0, .device = self.device, .bus = self.bus };
    }

    /// Same (bus, device) with the given function. Infallible; `u3`
    /// narrows the input to the valid range at the call site.
    pub fn withFunction(self: Bdf, f: u3) Bdf {
        return .{ .function = f, .device = self.device, .bus = self.bus };
    }

    /// True when `function == 0`. The header-type multifunction bit is
    /// only meaningful on function-0 reads.
    pub fn isFunction0(self: Bdf) bool {
        return self.function == 0;
    }

    /// 8-bit "DF" key — device and function packed into the same byte
    /// pattern PCIe uses inside one bus. Equivalent to the low byte of
    /// the packed encoding.
    pub fn df(self: Bdf) u8 {
        return @truncate(@as(u16, @bitCast(self)));
    }

    /// Raw 16-bit packed encoding. Matches PCIe Requester ID layout.
    pub fn asU16(self: Bdf) u16 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@sizeOf(Bdf) == 2);
        std.debug.assert(@bitSizeOf(Bdf) == 16);
        std.debug.assert(@bitOffsetOf(Bdf, "function") == 0);
        std.debug.assert(@bitOffsetOf(Bdf, "device") == 3);
        std.debug.assert(@bitOffsetOf(Bdf, "bus") == 8);
    }
};
```

### Validation rules

- `Bdf.of` is a compile-time guard; out-of-range device or function values fail to compile through `u5` / `u3` argument typing.
- `Bdf.from` rejects `d > 31` and `f > 7` with `error.InvalidIdentifier`. The full `u8` range of `bus` is accepted; bus-range containment against a segment is a separate check (`inSegmentRange` below).
- A `Bdf` value does not imply the function exists. Presence is decided by the vendor-id read at offset `0x00` per `docs/specs/config/space.md`.

### Iteration bounds

The PCI conventional-bus enumeration iterates devices `0..32` and functions `0..8`. `core/bdf.zig` exposes these as compile-time constants; `topology/enumerate.zig` consumes them.

```zig
pub const max_device: u8 = 32;
pub const max_function: u8 = 8;
```

## `Sbdf`

`Sbdf` pairs a `SegmentId` with a `Bdf` and is the address type carried by `ConfigSpace` accessor calls. It is itself a packed struct over `u32`, so equality, ordering, and IOMMU-style source-id encoding all collapse to a single integer.

```zig
pub const Sbdf = packed struct(u32) {
    bdf: Bdf,           // bits 0..16  (function | device | bus, per Bdf)
    segment: SegmentId, // bits 16..32

    pub fn of(comptime s: u16, comptime b: u8, comptime d: u5, comptime f: u3) Sbdf {
        return .{
            .bdf = Bdf.of(b, d, f),
            .segment = SegmentId.of(s),
        };
    }

    /// Pair a `SegmentId` with an existing `Bdf`. Infallible.
    pub fn init(segment: SegmentId, bdf: Bdf) Sbdf {
        return .{ .bdf = bdf, .segment = segment };
    }

    pub fn from(s: u16, b: u8, d: u8, f: u8) error{InvalidIdentifier}!Sbdf {
        return .{
            .bdf = try Bdf.from(b, d, f),
            .segment = SegmentId.from(s),
        };
    }

    pub fn eql(a: Sbdf, b: Sbdf) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }

    /// Total ordering: segment, then Bdf. The packed layout places the
    /// segment in the high half, so the u32 bit-cast already yields the
    /// desired segment-major, Bdf-minor ordering.
    pub fn lessThan(a: Sbdf, b: Sbdf) bool {
        return @as(u32, @bitCast(a)) < @as(u32, @bitCast(b));
    }

    pub fn function0(self: Sbdf) Sbdf {
        return .{ .bdf = self.bdf.function0(), .segment = self.segment };
    }

    /// Raw 32-bit packed encoding (`segment | bus | device | function`).
    /// Matches the IOMMU source-id form used by Intel VT-d, AMD-Vi, and
    /// the Linux PCI subsystem.
    pub fn asU32(self: Sbdf) u32 {
        return @bitCast(self);
    }

    comptime {
        std.debug.assert(@sizeOf(Sbdf) == 4);
        std.debug.assert(@bitSizeOf(Sbdf) == 32);
        std.debug.assert(@bitOffsetOf(Sbdf, "bdf") == 0);
        std.debug.assert(@bitOffsetOf(Sbdf, "segment") == 16);
    }
};
```

`Sbdf` does not own the segment's ECAM base or bus range; those live in `config.Segment` (`docs/specs/config/ecam.md`).

## ECAM offset math

Two distinct offsets:

- **Bus-relative offset** — bytes from the start of one ECAM segment aperture to the start of one function's 4 KiB configuration window. Computed from the `Bdf` and the segment's `bus_start`.
- **Function-window offset** — bytes from the start of one function's 4 KiB window to a specific register inside it. The function-window offset is `0..=0xFFF`.

```zig
/// Bytes from a segment's ECAM base to the start of `bdf`'s 4 KiB
/// configuration window. The caller has already validated that
/// `bdf.bus` is inside the segment's `bus_start..=bus_end` range.
pub fn busRelativeOffset(bdf: Bdf, bus_start: u8) u32 {
    return (@as(u32, bdf.bus - bus_start) << 20)
        | (@as(u32, bdf.device) << 15)
        | (@as(u32, bdf.function) << 12);
}

/// Bytes from a segment's ECAM base to a specific register inside
/// `bdf`'s configuration window. `register` is `0..=0xFFF`; callers
/// pass an offset already validated by `config/accessor` or `config/space`.
pub fn ecamOffset(bdf: Bdf, bus_start: u8, register: u12) u32 {
    return busRelativeOffset(bdf, bus_start) | @as(u32, register);
}

/// True when `bdf.bus` lies inside `[bus_start, bus_end]` inclusive.
/// Used by `Ecam` before calling `busRelativeOffset`; bridge
/// traversal uses the same helper to reject out-of-range hops.
pub fn inSegmentRange(bdf: Bdf, bus_start: u8, bus_end: u8) bool {
    return bdf.bus >= bus_start and bdf.bus <= bus_end;
}
```

Rules:

- The formula matches PCIe ECAM: bus contributes 20 bits, device 15, function 12. The result is a `u32` because one ECAM segment aperture spans at most `256 * 32 * 8 * 4 KiB = 256 MiB`, which fits in 28 bits.
- `bus - bus_start` is performed on `u8`s the caller has already containment-checked. Producing it requires `inSegmentRange(bdf, bus_start, bus_end)` to have returned `true`; passing an out-of-range Bdf is a programmer error and is asserted by the helper's callers, not validated here.
- The `register` argument to `ecamOffset` is typed `u12` so the compiler enforces the `0..=0xFFF` bound at every call site. `config/accessor` or `config/space` owns multi-byte containment checks and may use `zstdx.core.Range` or `zstdx.bytes` helpers where applicable (e.g. a `u32` read starting at `0xFFF` would overrun the window).

## Formatting

```zig
/// Writes "ssss:bb:dd.f" using zero-padded lowercase hex,
/// matching the conventional `lspci -D` rendering.
pub fn format(self: Sbdf, writer: *std.Io.Writer) !void {
    try writer.print(
        "{x:0>4}:{x:0>2}:{x:0>2}.{d}",
        .{ self.segment.value, self.bdf.bus, @as(u8, self.bdf.device), @as(u8, self.bdf.function) },
    );
}
```

`Bdf` also implements `format` for the segment-less rendering `bb:dd.f`. Richer rendering belongs to callers.

## Errors

`core/bdf` surfaces no named local `Error` type. Runtime constructors `Bdf.from` and `Sbdf.from` return the inline set `error{InvalidIdentifier}`, a subset of `zpci.Error` per `docs/specs/core/errors.md`. ECAM offset helpers do not return errors: their inputs are pre-validated (`device` and `function` by the `Bdf` type system, `bus` by `inSegmentRange`, `register` by `u12`).

## Facade re-export `[zpci]`

`src/core.zig` re-exports the public types:

```zig
const bdf = @import("core/bdf.zig");

pub const Bdf = bdf.Bdf;
pub const Sbdf = bdf.Sbdf;
```

The implementation module owns the offset helpers (`busRelativeOffset`, `ecamOffset`, `inSegmentRange`) and the iteration bounds (`max_device`, `max_function`); those are consumed via the implementation module path inside zpci and are not re-exported through the facade. Callers reach the types as `zpci.core.Bdf` and `zpci.core.Sbdf`.

## Usage

Comptime literals:

```zig
const bdf = zpci.core.Bdf.of(0, 1, 0);
const addr = zpci.core.Sbdf.of(0, 0, 1, 0);
```

Runtime construction:

```zig
const bdf = try zpci.core.Bdf.from(bus_byte, device_byte, function_byte);
```

Multifunction discovery:

```zig
const f0 = bdf.function0();
const common = try function.commonHeader(f0);
if (common.headerType().isMultifunction()) {
    var i: u3 = 1;
    while (true) : (i +%= 1) {
        const fi = bdf.withFunction(i);
        // probe fi
        if (i == 7) break;
    }
}
```

ECAM access (illustrative; production code goes through `ConfigSpace`):

```zig
const offset = busRelativeOffset(bdf, segment.bus_start) | 0x00; // vendor id
const vendor_id_ptr: *const u16 = @ptrCast(@alignCast(segment.base + offset));
```

Sorted iteration:

```zig
std.sort.pdq(zpci.core.Sbdf, list, {}, zpci.core.Sbdf.lessThan);
```

Formatting:

```zig
std.log.info("{f}", .{addr}); // "0000:00:01.0"
```

## Non-goals

- A non-packed `Bdf` or `Sbdf` shape. The packed forms are normative.
- BDF↔name caches.
- Owning the `Segment` aperture descriptor type. That lives in `docs/specs/config/ecam.md`.

## Open questions

None owned by this spec.
