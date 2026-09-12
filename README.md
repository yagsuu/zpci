# zpci

`zpci` is a Zig library for PCI and PCI Express configuration-space access.

## Overview

`zpci` provides typed access to PCI and PCI Express configuration space from
Zig. It includes helpers for headers, BARs, capabilities, topology
enumeration, resource assignment, and MSI/MSI-X programming.

Applications provide the accessors that `zpci` uses for PCI configuration space
and BAR memory.

## Features

- Typed PCI identifiers and BDF/SBDF values.
- ECAM access through caller-provided segments and an x86_64 PIO backend.
- Type-0 and Type-1 header views and programming helpers.
- BAR decode and sizing probes.
- Standard, extended, and PCIe capability traversal and decode.
- Device and bridge topology enumeration using caller-provided scratch storage.
- PCI resource assignment, bridge-window encoding, and commit.
- MSI and MSI-X capability and table programming.

## Requirements and platform support

| Item | Support |
| --- | --- |
| Zig | `0.16.0` or later |
| Package | `zpci` |
| Public module | `pci` |
| Dependency | `zstdx`, declared in `build.zig.zon` |
| Configuration access | ECAM through caller-provided `Segment` values; PIO on x86_64 through `stdx.arch.x86_64.Port` |
| Default test suite | Host target; no PCI hardware, VM, or external tools required |

## Quick start

Add `zpci` and `zstdx` to your project, then import `pci`:

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

## Common workflows

### Enumerate topology through caller-supplied ECAM segments

```zig
const segments = [_]pci.config.Segment{
    pci.config.Segment.init(
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

### Plan and commit resources

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

Applications provide interrupt-routing data and BAR memory. `zpci` does not
allocate interrupt vectors or map BARs.

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
  use caller-provided storage or fixed-size internal storage.
- **Explicit hardware access.** Configuration-space I/O uses `ConfigSpace`;
  MSI-X table and PBA I/O use `BarMemory`.
- **Read-only enumeration.** Topology discovery does not program resource,
  interrupt, or command-register state.
- **Plan, then commit.** Resource assignment builds a plan without
  configuration-space I/O. Committing the plan programs hardware with readback
  and rollback.
- **Platform policy stays outside the library.** `zpci` does not parse ACPI MCFG
  data, discover root windows, allocate interrupt vectors, route interrupts,
  bind drivers, or control device reset.
- **Host-testable accessors.** The default suite uses byte buffers through the
  same accessor interfaces used in production.

## Build and test

Run the default host-side suite:

```sh
zig build test
```

Check the Zig source format:

```sh
zig fmt --check build.zig src test
```

The default suite tests decode, sizing, traversal, assignment, programming, and
interrupt paths through byte-buffer configuration-space and BAR-memory
accessors. It requires no PCI hardware.

## Documentation

The public API contracts are in [`docs/specs/`](docs/specs/).

- [`docs/specs/index.md`](docs/specs/index.md) — package scope and public facade
- [`docs/specs/architecture.md`](docs/specs/architecture.md) — layering, ownership, and dependency direction
- [`docs/guidelines/testing.md`](docs/guidelines/testing.md) — host-test contract
