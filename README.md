# zpci

`zpci` is a Zig-native library for PCI and PCI Express configuration-space
access, topology discovery, resource planning, and interrupt programming.

## Overview

`zpci` owns PCI identifiers, configuration-space accessors, ECAM and PIO
backends, function views, header decode and programming, BAR decode and sizing,
capability traversal, topology enumeration, resource assignment and programming,
bridge bus and window handling, and MSI/MSI-X programming.

The public Zig module is `pci`. The library does not discover platform state or
hide privileged access behind globals. It does not parse ACPI tables, discover
root resource windows, allocate interrupt vectors, map BAR memory, bind device
drivers, or define reset policy.

## Features

- Typed PCI identifiers and BDF/SBDF values.
- Explicit ECAM configuration-space access and an x86_64 PIO backend.
- Common, type-0, and type-1 header views and programming helpers.
- BAR decode and sizing probes.
- Standard, extended, and PCIe capability traversal and decode.
- Device and bridge topology enumeration over caller-provided scratch storage.
- Explicit PCI resource assignment, bridge-window encoding, and commit.
- MSI and MSI-X capability and table programming.
- Byte-backed host-test accessors that exercise production accessor contracts.

## Requirements and platform support

| Item | Support |
| --- | --- |
| Zig | `0.16.0` or later |
| Package | `zpci` |
| Public module | `pci` |
| Dependency | `zstdx`, declared in `build.zig.zon` |
| Host endianness | Little-endian hosts |
| Configuration access | ECAM through caller-provided segments; PIO on x86_64 through `stdx.arch.x86_64.Port` |
| Default test suite | Host-selected target; no hardware, VM, or external tools required |

## Quick start

Add `zpci` and its `zstdx` dependency to the consuming project's build
configuration. Import the package module as `pci`:

```zig
const zpci = b.dependency("zpci", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("pci", zpci.module("pci"));
```

```zig
const pci = @import("pci");
const stdx = @import("stdx");
```

Enumerate a topology through caller-supplied ECAM segments and scratch storage:

```zig
const segments = [_]pci.config.Segment{
    pci.config.Segment.whole(
        pci.core.SegmentId.of(0),
        stdx.addr.VirtAddr.fromInt(mapped_ecam_base),
    ),
};
var ecam = try pci.config.Ecam.from(&segments);

var nodes: [256]pci.topology.tree.Node = undefined;
var roots: [8]pci.topology.tree.NodeIndex = undefined;
const tree = try pci.topology.enumerate.intoScratch(.{
    .config = ecam.configSpace(),
    .segments = &segments,
    .nodes = &nodes,
    .roots = &roots,
});

var it = tree.preorder();
while (it.next()) |item| {
    const function = item.node.function;
    switch (try function.headerKind()) {
        .type0 => {},
        .type1 => {},
    }
}
```

## Common workflows

### Plan and commit resources

Resource assignment does not program hardware. Callers size BARs, aggregate
bridge windows, and lower topology nodes into
`pci.resources.assignment.Node` values. They then commit the explicit plan.

```zig
var assignments: [128]pci.resources.model.Assignment = undefined;
const plan = try pci.resources.assignment.intoScratch(.{
    .nodes = assignment_nodes,
    .roots = assignment_roots,
    .root_windows = root_windows,
}, &assignments);

try pci.resources.programming.commit(plan);
```

### Program MSI or MSI-X

Callers provide interrupt-routing inputs and BAR memory. `zpci` does not
allocate vectors or map BAR memory.

```zig
const msi = (try pci.interrupts.msi.View.find(function)) orelse return error.NoMsi;
try msi.program(.{
    .address = 0xFEE0_0000,
    .data = vector_data,
    .vector_count = .one,
});

const msix = (try pci.interrupts.msix.View.find(function)) orelse return error.NoMsix;
try msix.programEntry(table_memory, 0, .{
    .address = 0xFEE0_0000,
    .data = vector_data,
    .masked = false,
});
```

## Public API

`src/pci.zig` is the public facade. It re-exports these namespaces:

| Namespace | Purpose |
| --- | --- |
| `pci.core` | `SegmentId`, vendor/device/class IDs, `Bdf`, `Sbdf`, and package error categories |
| `pci.config` | `ConfigSpace`, `Function`, `HeaderKind`, ECAM `Segment` / `Ecam`, and x86_64 `Pio` |
| `pci.header` | Common, type-0, and type-1 header views; typed command, status, and window values |
| `pci.bar` | BAR decode, iteration, sizing probes, and `BarRef` |
| `pci.capabilities` | Standard, extended, and PCIe capability traversal and decode |
| `pci.memory` | `BarMemory` accessor for BAR-mapped memory |
| `pci.resources` | Resource model, bridge-window aggregation, assignment, bus commit, and programming commit |
| `pci.interrupts` | MSI and MSI-X capability and table programming |
| `pci.topology` | Enumeration, tree construction, and bridge bus/window traversal |
| `pci.testing` | Byte-backed host-test configuration and BAR-memory accessors |

## Design

- **No hidden allocation.** Enumeration, traversal, assignment, and programming
  use caller-provided storage or fixed internal frames.
- **Explicit privileged access.** Configuration-space I/O goes through
  `ConfigSpace`; MSI-X table and PBA I/O go through `BarMemory`.
- **Read-only enumeration.** Topology discovery does not program resource,
  interrupt, or command-register state.
- **Plan, then commit.** Resource assignment is pure. Programming is an explicit
  commit with readback and rollback semantics.
- **Caller-owned platform policy.** ACPI MCFG parsing, root-window discovery,
  vector allocation, interrupt-controller routing, device binding, and reset
  policy remain outside `zpci`.
- **Host-testable contracts.** The default suite uses real byte buffers through
  the same accessor contracts used in production.

## Build and test

Run the default host-side suite:

```sh
zig build test
```

Check the Zig source format:

```sh
zig fmt --check build.zig src test
```

The default suite exercises decode, sizing, traversal, assignment, programming,
and interrupt paths through byte-backed configuration-space and BAR-memory
accessors. It requires no PCI hardware.

## Documentation

The normative contracts are under [`docs/specs/`](docs/specs/). Planning
documents do not define the public API.

- [`docs/specs/index.md`](docs/specs/index.md) — package scope and public facade
- [`docs/specs/architecture.md`](docs/specs/architecture.md) — layering, ownership, and dependency direction
- [`docs/guidelines/testing.md`](docs/guidelines/testing.md) — host-test contract
- [`docs/planning/spec-queue.md`](docs/planning/spec-queue.md) — proposal process for future work
