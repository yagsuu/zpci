# zpci

A Zig-native PCI/PCIe configuration-space and resource-programming library.

`zpci` owns PCI identifiers, config-space accessors, ECAM and PIO backends,
config-function views, header decode/programming, BAR decode and sizing,
capability traversal, topology enumeration, resource assignment/programming,
bridge bus/window handling, and MSI/MSI-X programming. Callers provide platform
facts: ECAM segments, root resource windows, interrupt routing inputs, and
BAR-memory accessors.

The public Zig module is `pci`. The package is explicit by design: enumeration
is read-only, resource assignment produces a plan, and programming commits that
plan through caller-supplied accessors. The default host suite uses byte-backed
config-space and BAR-memory accessors over real layouts; no hardware is needed.

## Requirements

| Field | Value |
| --- | --- |
| Minimum Zig | `0.16.0` |
| Host target | host-selected target for `zig build test` |
| Package name | `zpci` |
| Public module | `pci` |
| Dependency | `zstdx` via `build.zig.zon` |
| Transcription sources | PCI / PCI Express specifications |

## Install

Add `zpci` alongside its `zstdx` dependency, then import the module as `pci`:

```zig
const zpci = b.dependency("zpci", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("pci", zpci.module("pci"));
```

Public imports:

```zig
const pci = @import("pci");
const stdx = @import("stdx");
```

## Usage

Topology enumeration over caller-supplied ECAM segments:

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

Resource assignment and programming stay separate. Callers size BARs, aggregate
bridge windows, and lower topology nodes into `pci.resources.assignment.Node`
values, then commit the resulting explicit plan:

```zig
var assignments: [128]pci.resources.model.Assignment = undefined;
const plan = try pci.resources.assignment.intoScratch(.{
    .nodes = assignment_nodes,
    .roots = assignment_roots,
    .root_windows = root_windows,
}, &assignments);

try pci.resources.programming.commit(plan);
```

MSI and MSI-X consume caller-owned routing and memory inputs. `zpci` does not
allocate vectors or map BAR memory:

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

The facade is `src/pci.zig`. It re-exports ten namespaces.

| Namespace | Owns |
| --- | --- |
| `pci.core` | `SegmentId`, vendor/device/class IDs, `Bdf`, `Sbdf`, package error categories |
| `pci.config` | `ConfigSpace`, `Function`, `HeaderKind`, ECAM `Segment` / `Ecam`, x86_64 `Pio` |
| `pci.header` | common, type-0, and type-1 header views plus typed command/status/window words |
| `pci.bar` | BAR decode, iteration, sizing probe, `BarRef` |
| `pci.capabilities` | standard, extended, and PCIe capability traversal/decode |
| `pci.memory` | `BarMemory` accessor for BAR-mapped memory |
| `pci.resources` | resource model, bridge-window aggregation, assignment, bus commit, programming commit |
| `pci.interrupts` | MSI and MSI-X capability/table programming |
| `pci.topology` | enumeration, tree construction, bridge bus/window traversal |
| `pci.testing` | byte-backed host-test config and BAR-memory accessors |

## Design constraints

- **No hidden allocation.** Enumeration, traversal, assignment, and programming
  use caller-provided storage or fixed internal frames.
- **Explicit privileged access.** Config-space I/O goes through `ConfigSpace`;
  MSI-X table/PBA I/O goes through `BarMemory`.
- **Read-only enumeration.** Topology discovery never programs resource,
  interrupt, or command-register state.
- **Plan then commit.** Resource assignment is pure; programming is an explicit
  commit step with readback and rollback semantics.
- **Caller-owned platform policy.** ACPI MCFG parsing, root-window discovery,
  vector allocation, interrupt-controller routing, device binding, and reset
  policy live outside `zpci`.
- **Host-testable.** The default suite uses real byte buffers via test accessors,
  not mocks.
- **PIO is isolated.** The x86_64 PIO backend consumes `stdx.arch.x86_64.Port`;
  the rest of the surface is pure over explicit accessors.

## Repository layout

```text
src/
  pci.zig             # public facade
  core/               # IDs, BDF/SBDF, error set
  config/             # accessors, Function, ECAM, PIO
  header/             # common/type-0/type-1 config headers
  capabilities/       # standard, extended, PCIe capability handling
  resources/          # model, assignment, bridge, bus, programming
  interrupts/         # MSI, MSI-X
  topology/           # tree, enumerate, bridge traversal
  memory/             # BAR-memory accessor
  testing/            # host-test backends

test/
  all.zig             # host-side test aggregate
  integration/        # cross-module workflow tests

docs/
  specs/              # normative per-module specs
  guidelines/         # Zig, testing, spec-writing conventions
  planning/           # spec queue and open questions
```

## Verification

```sh
zig build test
zig fmt --check build.zig src test
```

The host suite composes real byte-backed config-space and BAR-memory fixtures
through the same accessor contracts production code uses.

## Documentation

Normative contracts live under `docs/specs/`. Planning documents are not public
API authority.

Start with:

- [`docs/specs/index.md`](docs/specs/index.md) — package scope and public facade
- [`docs/specs/architecture.md`](docs/specs/architecture.md) — layering and dependency direction
- [`docs/guidelines/testing.md`](docs/guidelines/testing.md) — host-test contract
- [`docs/planning/spec-queue.md`](docs/planning/spec-queue.md) — future proposal flow

## Status

Version `0.1.0`. The initial approved surface is implemented and covered by the
host-side unit and integration suite. Future examples and optional PCIe service
surfaces enter through the spec queue.
