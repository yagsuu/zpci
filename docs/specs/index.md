# zpci specs

zpci is a Zig 0.16 PCI/PCIe configuration-space and resource-programming library. It owns config-space access through explicit accessors, ECAM-backed and PIO-backed configuration access, device/function enumeration, BAR decoding and sizing, capability traversal, PCI resource assignment/programming, MSI/MSI-X programming, and bridge/bus traversal. It is consumed as a package module named `zpci`.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Type declarations and signatures shown in this index are illustrative. The owning domain spec under `docs/specs/<domain>/` is authoritative; on disagreement the domain spec wins.

Related documents:

- `docs/guidelines/zig.md`
- `docs/guidelines/conventions.md`
- `docs/guidelines/testing.md`
- `docs/project-decisions.md`
- `docs/planning/spec-queue.md`
- `docs/planning/open-questions.md`

## Scope

Owned:

- PCI segment, bus/device/function, vendor/device, class/subclass/prog-if, and revision identifier primitives.
- `ConfigSpace` accessor contract.
- ECAM-backed config-space access over caller-supplied segment descriptors.
- PIO-backed config-space reads through `stdx.arch.x86_64.Port`.
- Config-function reads and writes over the 4 KiB PCIe function configuration window.
- PCI common header decode and command/status programming.
- Type-0 endpoint header decode and programming.
- Type-1 PCI-to-PCI bridge header decode and programming.
- BAR decode for I/O, 32-bit memory, and 64-bit memory BARs.
- BAR sizing by the save → write all-ones → read back → restore probe.
- PCI resource model for I/O, non-prefetchable MMIO32, prefetchable MMIO32, non-prefetchable MMIO64, and prefetchable MMIO64.
- BAR assignment within caller-supplied resource windows.
- Bridge I/O, memory, and prefetchable-memory window sizing and programming.
- Command-register programming for I/O space, memory space, bus mastering, interrupt disable, SERR, parity response, and related bits specified by header/resource/interrupt specs.
- Standard capability-list traversal.
- PCIe extended-capability traversal.
- PCI Express capability decode required for enumeration and programming policy.
- MSI capability decode and programming.
- MSI-X capability decode and programming, including table/PBA access through an explicit caller-provided BAR-memory accessor.
- ECAM enumeration over caller-supplied `{segment, base, bus_start, bus_end}` descriptors.
- Device/function tree construction and traversal.
- Bridge traversal using programmed bus-number fields before assignment and programmed bus-number/window fields during assignment.
- Host-test support namespace with test config-space and BAR-memory access over real byte buffers.

Not owned:

- ACPI MCFG parsing. Callers that get ECAM topology from ACPI parse MCFG outside zpci and pass segment descriptors to zpci.
- Platform-description parsing. Callers lower platform facts into zpci segment/resource/interrupt inputs.
- Firmware phase orchestration, protocol installation, device-path construction, handle/protocol databases, or OS handoff policy.
- Platform resource discovery. Callers supply root I/O/MMIO windows that zpci may allocate from.
- Platform interrupt-vector allocation and interrupt-controller routing. Callers supply MSI/MSI-X message address/data and routing identity.
- Driver binding, device-driver dispatch, or protocol publication.
- VFIO passthrough policy or config-shadowing.
- MSI/MSI-X interrupt remapping policy.
- PCI device reset policy.
- SR-IOV virtual-function lifecycle and resource policy.
- Advanced PCIe services beyond specs explicitly listed under this package.

Deferred:

- SR-IOV, ARI, ATS, AER, ACS, PRI, PASID, DOE, and other extended-capability semantics beyond list traversal and explicitly specced programming surfaces.
- Device-driver binding and downstream firmware integration policy.
- VFIO passthrough policy and config-shadowing.
- Non-x86_64 architecture-specific behavior.

## Build product `[zpci]`

zpci is a library package, not firmware.

Required build behavior:

- `build.zig` exposes a module named `zpci`.
- `zig build test` runs the host-side test suite.
- zpci does not produce its own firmware artifact.
- Downstream packages consume the same `zpci` module under their own target configuration.
- Target-specific code is isolated under config-access adapters that consume `stdx.arch.x86_64` (zstdx-owned) and must not prevent host tests from compiling.
- The default test command requires no hardware, no VM, and no external tools.

Dependency policy:

- The package depends on Zig `std` and `zstdx`.
- zpci uses zstdx only for domain-neutral primitives: byte access, endian storage wrappers, ranges, strong addresses, fixed-capacity collections, and caller-buffer arenas where an owning zpci spec approves them.
- zpci does not import downstream consumers or platform-description libraries.
- Topology, root resource windows, and interrupt-routing inputs cross the package boundary as zpci-owned plain Zig values.

## Layering

```text
caller
  -> lowers ACPI MCFG or another platform description into zpci segment descriptors
  -> supplies root resource windows (IO/MMIO32/MMIO64)
  -> supplies interrupt routing inputs (message address/data, vector identity)
  -> constructs explicit accessors
      |- Ecam over real config MMIO
      |- Pio over `stdx.arch.x86_64.Port`
      |- byte-backed test config accessor
      `- BAR-memory accessor for MSI-X table/PBA programming

single function
  ConfigSpace + Sbdf
    -> config.Function
    -> header.Common
    -> header.Type0 / header.Type1
    -> bar.decode / bar.size
    -> capabilities.Iterator / extended.Iterator
    -> resources.Requirement
    -> interrupts.Msi / interrupts.Msix

topology
  []Segment + ConfigSpace
    -> topology.enumerate.intoScratch
    -> topology.tree.Tree
    -> resources.assignment.Plan
    -> resources.programming.commit
    -> interrupts programming from caller-supplied routing inputs
```

Layer responsibilities:

```text
core/          identifier newtypes, BDF/SBDF math, package errors.
config/        ConfigSpace accessor contract, ECAM access, PIO access, function-window view.
header/        PCI common, type-0 endpoint, and type-1 bridge header layouts/programming.
bar            BAR decode and sizing probe.
capabilities/  standard and extended capability-list walking; selected capability decoders.
memory/        BarMemory accessor for BAR-mapped memory reads/writes.
resources/     resource model, assignment, bridge windows, BAR/window/command programming.
interrupts/    MSI and MSI-X capability/table programming.
topology/      enumeration, tree construction, bridge traversal.
zpci.zig       public package facade.
```

zpci has no `src/arch/`. The x86_64 port-I/O primitive used by `config.Pio`
is `stdx.arch.x86_64.Port`, owned by zstdx.

Ownership rules:

1. `config/` owns config-space I/O. No header, BAR, capability, topology, resource, or interrupt module performs config MMIO or PIO directly.
2. Config-space accessors are passed explicitly. Public APIs do not hide privileged access behind globals.
3. `Ecam` never discovers its own base. Callers provide `{segment, base, bus_start, bus_end}` descriptors.
4. `Pio` consumes `stdx.arch.x86_64.Port` from zstdx; zpci does not own a port-I/O type, port-allocation policy, or inline assembly.
5. Header modules own their wire layouts, layout assertions, and register-level programming helpers.
6. BAR sizing always restores the saved value.
7. Resource assignment produces an explicit plan. Programming is a separate explicit commit step.
8. MSI/MSI-X programming consumes caller-supplied routing inputs. zpci does not allocate platform vectors.
9. MSI-X table/PBA memory access is explicit. zpci does not infer or map BAR memory.
10. Capability modules walk lists and decode selected capability payloads; they do not dispatch to device drivers.
11. Topology modules build zpci-owned views/trees; they do not install protocols, publish device paths, or mutate caller state.
12. No resource, interrupt, or command-register writes are hidden inside read-only enumeration.

## Facade structure `[zpci]`

zpci follows the package-root plus namespace-facade pattern.

`src/zpci.zig` is the package root. It re-exports namespace facades only.

```zig
//! zpci package facade. Spec: docs/specs/index.md.

pub const core = @import("core.zig");
pub const config = @import("config.zig");
pub const header = @import("header.zig");
pub const bar = @import("bar.zig");
pub const capabilities = @import("capabilities.zig");
pub const memory = @import("memory.zig");
pub const resources = @import("resources.zig");
pub const interrupts = @import("interrupts.zig");
pub const topology = @import("topology.zig");
pub const testing = @import("testing.zig");
```

Rules:

- `src/zpci.zig` performs no validation, allocation, config-space reads/writes, BAR probes, resource assignment, programming, or enumeration.
- Public names are exported from namespace facades such as `src/config.zig` or `src/resources.zig`.
- Implementation files live under the matching directory, e.g. `src/config/ecam.zig`, `src/resources/assignment.zig`; reusable test-support helpers live under `src/testing/`.
- Namespace facades re-export selected public names from implementation modules.
- Namespace facades do not perform behavior.
- `src/testing.zig` and `src/testing/*` expose host-test helpers only. Production zpci modules do not import `testing`; testing helpers return ordinary production accessors instead of alternate I/O seams.

### `src/core.zig`

```zig
//! Core PCI primitives. Spec: docs/specs/core/{ids,bdf,errors}.md.

const bdf = @import("core/bdf.zig");
const errors = @import("core/errors.zig");
const ids = @import("core/ids.zig");

pub const SegmentId = ids.SegmentId;
pub const VendorId = ids.VendorId;
pub const DeviceId = ids.DeviceId;
pub const ClassCode = ids.ClassCode;
pub const RevisionId = ids.RevisionId;

pub const Bdf = bdf.Bdf;
pub const Sbdf = bdf.Sbdf;

pub const Error = errors.Error;
```

### `src/config.zig`

```zig
//! Config-space access namespace. Spec: docs/specs/config/*.md.

const accessor = @import("config/accessor.zig");
const ecam = @import("config/ecam.zig");
const pio = @import("config/pio.zig");
const space = @import("config/space.zig");

pub const ConfigSpace = accessor.ConfigSpace;
pub const Function = space.Function;

pub const Ecam = ecam.Ecam;
pub const Segment = ecam.Segment;

pub const Pio = pio.Pio;
```

### `src/header.zig`

```zig
//! PCI header namespace. Spec: docs/specs/header/*.md.

pub const common = @import("header/common.zig");
pub const type0 = @import("header/type0.zig");
pub const type1 = @import("header/type1.zig");

pub const CommonHeader = common.CommonHeader;
```

### `src/capabilities.zig`

```zig
//! PCI capability namespace. Spec: docs/specs/capabilities/*.md.

pub const list = @import("capabilities/list.zig");
pub const extended = @import("capabilities/extended.zig");
pub const pcie = @import("capabilities/pcie.zig");
```

### `src/memory.zig`

```zig
//! BAR memory namespace. Spec: docs/specs/memory/bar.md.

const bar = @import("memory/bar.zig");

pub const BarMemory = bar.BarMemory;
```

### `src/resources.zig`

```zig
//! PCI resource namespace. Spec: docs/specs/resources/*.md.

pub const model = @import("resources/model.zig");
pub const assignment = @import("resources/assignment.zig");
pub const programming = @import("resources/programming.zig");
pub const bridge = @import("resources/bridge.zig");
pub const bus = @import("resources/bus.zig");
```

### `src/interrupts.zig`

```zig
//! PCI interrupt-programming namespace. Spec: docs/specs/interrupts/*.md.

pub const msi = @import("interrupts/msi.zig");
pub const msix = @import("interrupts/msix.zig");
```

### `src/topology.zig`

```zig
//! PCI topology namespace. Spec: docs/specs/topology/*.md.

pub const enumerate = @import("topology/enumerate.zig");
pub const tree = @import("topology/tree.zig");
pub const bridge = @import("topology/bridge.zig");
```

### `src/testing.zig`

```zig
//! Host-test support namespace. Spec: docs/specs/index.md.

pub const config = @import("testing/config.zig");
pub const memory = @import("testing/memory.zig");
```

`src/testing/config.zig` is owned by `docs/specs/config/accessor.md` and exposes `TestConfigSpace` as `zpci.testing.config.TestConfigSpace`. `src/testing/memory.zig` is owned by `docs/specs/memory/bar.md` and exposes `TestBarMemory` as `zpci.testing.memory.TestBarMemory`.


## Core public concepts

### Segment descriptors

`config.Segment` describes one ECAM aperture supplied by the caller.

```zig
pub const Segment = struct {
    segment: core.SegmentId,
    base: zstdx.addr.VirtAddr,
    bus_start: u8,
    bus_end: u8,
};
```

Rules:

- `base` is the mapped virtual address zpci reads/writes through, not a physical address requiring translation by zpci.
- `bus_start <= bus_end`.
- ECAM address calculation uses `(bus - bus_start) << 20`, not `bus << 20`.
- A segment descriptor does not imply ownership of the underlying MMIO mapping.
- zpci does not parse ACPI MCFG to produce segment descriptors.

### BDF and SBDF

`core.Bdf` identifies a function inside one segment.

```zig
pub const Bdf = struct {
    bus: u8,
    device: u5,
    function: u3,
};
```

`core.Sbdf` pairs a segment id with a BDF.

```zig
pub const Sbdf = struct {
    segment: SegmentId,
    bdf: Bdf,
};
```

`Bdf` owns ECAM offset math that is independent of the segment base:

```text
bus-relative offset =
    ((bus - segment.bus_start) << 20) |
    (device << 15) |
    (function << 12)
```

The low 12 bits are the offset inside one function's 4 KiB config window.

### Config-space accessor

`config.ConfigSpace` is the only public config-space I/O seam. It supplies typed reads and the write capability required by BAR sizing, resource programming, and MSI/MSI-X programming. Its exact representation is specified in `docs/specs/config/accessor.md`.

Required semantic operations:

```zig
read8(sbdf, offset) Error!u8
read16(sbdf, offset) Error!u16
read32(sbdf, offset) Error!u32

write8(sbdf, offset, value) Error!void
write16(sbdf, offset, value) Error!void
write32(sbdf, offset, value) Error!void
```

Rules:

- Reads and writes validate that `offset` is inside `0x000..=0xFFF`.
- Multi-byte accesses validate containment inside the 4 KiB function window.
- Endianness is little-endian.
- Access-width alignment rules are owned by `docs/specs/config/accessor.md`.
- The byte-backed test accessor used by tests implements the same contract as hardware-backed accessors.
- ECAM config access is specified by `docs/specs/config/ecam.md`.
- PIO config access is specified by `docs/specs/config/pio.md`.

### Function view

`config.Function` is a borrowed view over one `core.Sbdf` through a `config.ConfigSpace`.

Owned behavior:

- Read vendor id.
- Report absence when vendor id is `0xFFFF`.
- Read common header fields.
- Select type-0 or type-1 header path from header type.
- Produce BAR, capability, resource, and interrupt views through the owning modules.

`Function` does not own topology allocation, platform resource windows, or interrupt-vector allocation.

## Header model

### Common header

The common header covers bytes `0x00..0x3F` shared by all PCI header types:

- vendor id,
- device id,
- command,
- status,
- revision id,
- programming interface,
- subclass,
- class code,
- cache line size,
- latency timer,
- header type,
- BIST,
- capability pointer where applicable.

`header/common.zig` owns:

- wire constants and offsets,
- `header.CommonHeader` view,
- command/status/header-type flag words,
- absent-function detection,
- header-type decoding,
- command-register programming helpers.

### Type-0 endpoint header

`header/type0.zig` owns endpoint-specific fields:

- six BAR slots at `0x10..0x27`,
- cardbus CIS pointer,
- subsystem vendor/device ids,
- expansion ROM BAR,
- capabilities pointer,
- interrupt line/pin.

It also owns type-0 programming helpers for BAR registers and expansion ROM register writes.

### Type-1 bridge header

`header/type1.zig` owns PCI-to-PCI bridge fields:

- two BAR slots,
- primary/secondary/subordinate bus numbers,
- I/O base/limit,
- memory base/limit,
- prefetchable memory base/limit,
- bridge control,
- capabilities pointer.

It also owns type-1 programming helpers for bus-number registers, bridge resource windows, bridge BARs, expansion ROM, and bridge-control fields.

## BAR model

`bar.zig` owns BAR decode and sizing.

Owned BAR kinds:

```zig
pub const Kind = union(enum) {
    io: Io,
    mem32: Memory32,
    mem64: Memory64,
};
```

Required decoded facts:

- BAR index,
- raw value,
- I/O vs memory kind,
- 32-bit vs 64-bit memory kind,
- prefetchable bit for memory BARs,
- base address after masking flags,
- implemented vs unimplemented state.

BAR sizing:

- saves the original BAR value,
- disables decode when required by `docs/specs/bar.md`,
- writes all ones to the BAR register,
- reads the masked size bits,
- restores the original value,
- restores decode state when it changed it,
- reports the computed size,
- treats the second dword of a 64-bit BAR as part of the same BAR.

BAR sizing does not assign a new base address. Resource assignment owns base selection; resource programming owns final BAR writes.

## Resource model and programming

`resources/` owns PCI resource assignment and programming.

### Resource model

`resources/model.zig` defines:

- I/O windows,
- non-prefetchable MMIO32 windows,
- prefetchable MMIO32 windows,
- non-prefetchable MMIO64 windows,
- prefetchable MMIO64 windows,
- resource requirements derived from endpoint BARs,
- bridge-window requirements derived from child resources,
- assignment records.

Callers supply root resource windows. zpci allocates within those windows; it does not discover platform apertures.

### Assignment

`resources/assignment.zig` owns allocation of endpoint BARs and bridge windows from caller-supplied pools.

Rules:

- Assignment consumes a topology tree plus root resource windows.
- Assignment produces an explicit assignment plan.
- Assignment does not write config space.
- Assignment failure leaves hardware state unchanged.
- Assignment reports storage exhaustion, resource exhaustion, malformed BARs, and unsupported resource combinations as typed errors.

### Programming

`resources/programming.zig` owns config-space writes that commit an assignment plan.

Programming writes may include:

- disabling endpoint and bridge decodes before programming,
- endpoint BAR base writes,
- type-1 bridge I/O window writes,
- type-1 bridge memory window writes,
- type-1 bridge prefetchable-memory window writes,
- bridge bus-number writes when owned by the assignment spec,
- command-register I/O-space, memory-space, and bus-master enables,
- bridge-control fields required by the resource spec.

Rules:

- Programming is an explicit commit step.
- Programming order is deterministic and specified by `docs/specs/resources/programming.md`.
- Partial failure either leaves the device tree in the previous programmed state or returns an error after executing the rollback specified by the programming spec.
- Programming never silently continues after a failed config write.

### Bridge windows

`resources/bridge.zig` owns the type-1 bridge window calculations and encodings.

Owned windows:

- I/O base/limit,
- memory base/limit,
- prefetchable memory base/limit,
- 64-bit prefetchable base/limit upper dwords.

Rules:

- Bridge windows are computed from child assignments.
- Empty windows are represented using the PCI-defined disabled encodings.
- 64-bit prefetchable windows are used only when the bridge and assignment inputs support them.

## Capability model

### Standard capabilities

`capabilities/list.zig` owns the PCI standard capability list.

Rules:

- The list is present only when the status register's capability-list bit is set.
- The first pointer is the header's capability pointer.
- Capability pointers are bounded to the conventional config-space region.
- The walk terminates on null, out-of-range pointer, malformed pointer, or detected cycle.
- The iterator reports malformed termination as a typed error rather than looping.

### Extended capabilities

`capabilities/extended.zig` owns PCIe extended capability traversal.

Rules:

- The walk starts at offset `0x100`.
- The walk stays inside `0x100..=0xFFF`.
- The iterator decodes extended capability id, version, and next-pointer fields.
- The walk terminates on null next-pointer, out-of-range next-pointer, malformed header, or detected cycle.

### PCI Express capability

`capabilities/pcie.zig` owns the PCI Express capability payload required by enumeration and programming policy.

Owned facts:

- PCI Express capability version,
- device/port type,
- slot-implemented bit where applicable,
- fields required by bridge traversal and resource programming specs,
- fields required to decide whether ARI-aware enumeration is allowed, if ARI is promoted by the topology spec.

Detailed PCIe feature services remain out of scope unless their owning specs promote them.

## Interrupt programming

`interrupts/` owns MSI and MSI-X programming.

zpci does not allocate platform interrupt vectors and does not route interrupts through APIC, IOAPIC, interrupt remapping, firmware protocols, or operating-system facilities. The caller supplies message address/data and any vector identity required by the programming request.

### MSI

`interrupts/msi.zig` owns MSI capability decode and programming.

Owned behavior:

- locate the MSI capability,
- validate capability shape,
- report supported multi-message count,
- program message address,
- program message data,
- program mask/pending fields when present and owned by the MSI spec,
- enable/disable MSI,
- coordinate INTx-disable and command-register state as specified by `docs/specs/interrupts/msi.md`.

### MSI-X

`interrupts/msix.zig` owns MSI-X capability decode and programming.

Owned behavior:

- locate the MSI-X capability,
- decode table and pending-bit-array BAR indicators and offsets,
- validate table size,
- program table entries through an explicit caller-provided BAR-memory accessor,
- mask/unmask table entries in deterministic order,
- enable/disable MSI-X,
- coordinate INTx-disable and command-register state as specified by `docs/specs/interrupts/msix.md`.

MSI-X table/PBA access is not config-space access. It is a separate explicit memory accessor supplied by the caller.

## Topology model

`topology/` owns enumeration and tree construction.

Input:

- one or more caller-supplied `config.Segment` descriptors,
- a `config.ConfigSpace` accessor,
- caller-provided storage or allocator as defined by `docs/specs/topology/enumerate.md`.

Output:

- an iterable zpci-owned topology view/tree,
- one node per present function included by the enumeration policy,
- parent/child relationships for discovered bridges,
- segment and SBDF identity for every node.

Enumeration rules owned at index level:

- Function 0 is probed first for each device.
- Vendor id `0xFFFF` means absent.
- Non-multifunction devices do not require probing functions 1..7.
- Multifunction discovery uses the header-type multifunction bit unless a later topology spec promotes an ARI-aware policy.
- Bridges are traversed through type-1 bus-number registers before resource assignment.
- Enumeration does not program BAR bases, bridge windows, command-register enables, MSI, or MSI-X.

## Validation

Validation layers:

1. **Input shape** — segment descriptors, BDF/SBDF ranges, config offsets, access widths, root resource windows, and interrupt programming requests.
2. **Function presence** — vendor id `0xFFFF` means absent, not malformed.
3. **Header decode** — common header fields, header type, type-specific layout access.
4. **BAR decode/sizing** — BAR kind, width, implemented state, save/probe/restore correctness.
5. **Capability traversal** — pointer range, alignment where required, malformed next-pointer, cycle termination.
6. **Topology traversal** — bus range containment, bridge path traversal, storage exhaustion.
7. **Resource assignment** — resource requirement validity, pool containment, alignment, bridge-window encodability, exhaustion.
8. **Resource programming** — deterministic write order, failed-write handling, rollback or preserved-state behavior.
9. **Interrupt programming** — MSI/MSI-X capability validity, caller-supplied routing input validity, table bounds, masking/enabling order.

Public validation returns typed errors. It does not assert on malformed hardware/input bytes. Assertions are reserved for programmer errors after validation has established the relevant invariant.

## Usage

### ECAM enumeration

```zig
const std = @import("std");
const zpci = @import("zpci");

const segments = [_]zpci.config.Segment{
    .{
        .segment = zpci.core.SegmentId.of(0),
        .base = 0xE000_0000,
        .bus_start = 0,
        .bus_end = 255,
    },
};

var ecam = try zpci.config.Ecam.from(&segments);

var nodes: [256]zpci.topology.tree.Node = undefined;
var roots: [8]zpci.topology.tree.NodeIndex = undefined;
const tree = try zpci.topology.enumerate.intoScratch(.{
    .config = ecam.configSpace(),
    .segments = &segments,
    .nodes = &nodes,
    .roots = &roots,
});

var it = tree.preorder();
while (it.next()) |node| {
    // Enumeration already filtered absent functions; node.function is present.
    const class = try node.function.classCode();
    _ = class;

    switch (try node.function.headerKind()) {
        .type0 => {}, // endpoint; see docs/specs/header/type0.md
        .type1 => {}, // bridge;   see docs/specs/header/type1.md
    }
}
```

### BAR sizing

```zig
const fn0 = try zpci.config.Function.validate(
    ecam.configSpace(),
    zpci.core.Sbdf.of(0, 0, 1, 0),
);

const view = zpci.bar.View.init(fn0, .type0);
var bars = view.iterator();
while (try bars.next()) |entry| {
    _ = entry; // decoded via entry.kind; per-slot sizing via view.size(entry.index)
}

// One decode-disable window for all BARs:
var scratch: [zpci.header.type0.bar_count]zpci.bar.Entry = undefined;
const entries = try view.sizeAll(&scratch);
_ = entries;
```

### Resource assignment and programming

```zig
const windows = zpci.resources.model.RootWindows{
    .io = .{ .base = 0xC000, .size = 0x4000 },
    .mmio32 = .{ .base = 0x8000_0000, .size = 0x1000_0000 },
    .mmio64 = .{ .base = 0x1_0000_0000, .size = 0x1_0000_0000 },
};

var assignments: [256]zpci.resources.model.Assignment = undefined;
const plan = try zpci.resources.assignment.intoScratch(.{
    .tree = tree,
    .windows = windows,
    .scratch = &assignments,
});

try zpci.resources.programming.commit(.{
    .config = ecam.configSpace(),
    .tree = tree,
    .plan = plan,
});
```

Assignment produces a plan without changing hardware. `commit` is the explicit programming boundary.

### MSI programming

```zig
const routing = zpci.interrupts.msi.Message{
    .address = 0xFEE0_0000,
    .data = vector_data,
};

try zpci.interrupts.msi.enable(.{
    .function = fn0,
    .message = routing,
    .vectors = .one,
});
```

The caller supplies message address/data. zpci programs the device capability.

### MSI-X programming

```zig
// Caller owns the mapping. The returned value is a zpci.memory.BarMemory
// accessor over the MSI-X table region. Spec: docs/specs/memory/bar.md.
const table: zpci.memory.BarMemory = try caller.mapMsixTable(function_bar, table_offset, table_size);
defer caller.unmapMsixTable(table);

try zpci.interrupts.msix.programEntry(.{
    .function = fn0,
    .table = table,
    .entry = 0,
    .message = .{
        .address = 0xFEE0_0000,
        .data = vector_data,
    },
});

try zpci.interrupts.msix.enable(.{
    .function = fn0,
    .table = table,
});
```

The MSI-X table accessor is explicit BAR memory access supplied by the caller.

### Capability walk

```zig
var caps = try zpci.capabilities.list.Iterator.validate(fn0);
while (try caps.next()) |cap| {
    switch (cap.idTag()) {
        .pci_express => {
            // PCI Express capability decode: docs/specs/capabilities/pcie.md.
        },
        .msi   => {}, // docs/specs/interrupts/msi.md
        .msi_x => {}, // docs/specs/interrupts/msix.md
        _      => {},
    }
}
```

Capability iteration is bounded and cycle-safe.

## Source layout

```text
build.zig
build.zig.zon

src/
  zpci.zig

  core.zig
  core/
    ids.zig
    bdf.zig
    errors.zig

  config.zig
  config/
    accessor.zig
    space.zig
    ecam.zig
    pio.zig

  header.zig
  header/
    common.zig
    type0.zig
    type1.zig

  bar.zig

  capabilities.zig
  capabilities/
    list.zig
    extended.zig
    pcie.zig

  memory.zig
  memory/
    bar.zig

  resources.zig
  resources/
    model.zig
    assignment.zig
    programming.zig
    bridge.zig
    bus.zig

  interrupts.zig
  interrupts/
    msi.zig
    msix.zig

  topology.zig
  topology/
    enumerate.zig
    tree.zig
    bridge.zig

test/
  all.zig
```

Directory ownership follows `docs/guidelines/conventions.md`.

## Documentation map

```text
index.md
architecture.md

core/
  errors.md
  ids.md
  bdf.md

config/
  accessor.md
  space.md
  ecam.md
  pio.md

header/
  common.md
  type0.md
  type1.md

bar.md

capabilities/
  list.md
  extended.md
  pcie.md

memory/
  bar.md

resources/
  model.md
  assignment.md
  programming.md
  bridge.md
  bus.md

interrupts/
  msi.md
  msix.md

topology/
  enumerate.md
  tree.md
  bridge.md

examples/
  enumerate-ecam.md
  size-bars.md
  assign-resources.md
  program-msi.md
  walk-capabilities.md
  bridge-traversal.md
```
