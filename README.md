# zpci

`zpci` is a PCI and PCI Express library for Zig.

## Requirements

Zig `0.16.0` and `zstdx`. Configuration access uses caller-mapped ECAM regions
or PIO on x86_64.

## Build integration

Add `zpci` and `zstdx` as package dependencies. Import their `pci` and `stdx`
modules in `build.zig`:

```zig
const zpci = b.dependency("zpci", .{
    .target = target,
    .optimize = optimize,
});

const zstdx = b.dependency("zstdx", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("pci", zpci.module("pci"));
exe.root_module.addImport("stdx", zstdx.module("stdx"));
```

## Public API

| Namespace | Purpose |
| --- | --- |
| `pci.core` | PCI identifiers, wire types, offsets, and register masks |
| `pci.config` | Configuration access through ECAM or PIO |
| `pci.header` | Type 0/1 header access and bridge windows |
| `pci.bar` | BAR decoding, iteration, and sizing |
| `pci.capabilities` | Standard, extended, and PCIe capability traversal and decoding |
| `pci.memory` | BAR-mapped memory access |
| `pci.resources` | Resource assignment, bridge windows, bus numbering, and programming |
| `pci.interrupts` | MSI and MSI-X capability and table programming |
| `pci.topology` | Enumeration, traversal, and paths |
| `pci.testing` | Byte-backed configuration and BAR-memory test backends |

## Device enumeration

```zig
const std = @import("std");
const pci = @import("pci");

const Ecam = pci.config.Ecam;
const Segment = pci.config.Segment;

const segments = [_]Segment{
    .{ .segment = .from(0), .buses = .{ .start = first_bus, .end = last_bus } },
};

const regions = [_]Ecam.Region{
    .{ .segment = segments[0], .base = .from(mapped_ecam_base) },
};

var ecam = try Ecam.tryFrom(&regions);

const tree = try pci.topology.enumerate(allocator, .{
    .config = ecam.config(),
    .segments = &segments,
});
defer tree.deinit(allocator);

var it = tree.preorder();
while (it.next()) |item| {
    std.debug.print("{f}: {s}\n", .{ item.node.function.sbdf, @tagName(item.node.format) });
}
```

## Resource allocation

- `requirements`: measured BAR or ROM requirements for one endpoint.
- `mmio_base` / `mmio_size`: an available 32-bit memory aperture.

`ProgrammingPartial` means rollback failed; hardware may remain partially programmed.

```zig
const stdx = @import("stdx");
const pci = @import("pci");

const Node = pci.resources.assignment.Node;
const Apertures = pci.resources.Apertures;
const Range = stdx.ranges.Range(u64);

const nodes = [_]Node{
    .{ .parent = null, .type = .endpoint, .requirements = requirements },
};

const apertures: Apertures = .{
    .mmio32 = .{
        .type = .mmio32,
        .bounds = try Range.fromStartLen(mmio_base, mmio_size),
    },
};

const assignments = try pci.resources.assign(allocator, .{
    .nodes = &nodes,
    .roots = &.{0},
    .apertures = apertures,
});
defer allocator.free(assignments);

try pci.resources.commit(assignments);
```

## Interrupts

Use message data `vector_data` for a caller-allocated interrupt vector.
`ProgrammingPartial` means rollback failed; hardware may remain partially programmed.

### MSI

```zig
const pci = @import("pci");

const Msi = pci.interrupts.msi.Capability;

const msi = (try Msi.find(function)) orelse return error.NoMsi;

try msi.program(.{
    .address = 0xFEE0_0000, // x86 local APIC, destination 0.
    .data = vector_data,
    .num_vectors = .one,
});
```

### MSI-X

Stop device interrupt generation and install the handler for `vector_data` before setup.
Enable device interrupt generation only after setup succeeds.
The setup sequence is not atomic; on error, keep device interrupt generation stopped.

`table_memory` starts at the offset returned by `msix.tableLocation()` within
the indicated BAR.

```zig
const pci = @import("pci");

const Msi = pci.interrupts.msi.Capability;
const Msix = pci.interrupts.msix.Capability;
const Table = pci.interrupts.msix.Table;

const msix = (try Msix.find(function)) orelse return error.NoMsix;
const control = try msix.control();

try msix.setFunctionMask(true);
try msix.disable();

if (try Msi.find(function)) |msi| {
    try msi.disable();
}

const num_vectors = @as(u16, control.table_size_minus_one) + 1;
const table = Table.from(table_memory, num_vectors);

// Keep unused entries masked.
for (0..num_vectors) |index| {
    try table.setMasked(@intCast(index), true);
}

try table.program(0, .{
    .address = 0xFEE0_0000, // x86 local APIC, destination 0.
    .data = vector_data,
    .masked = true,
});

try msix.enable();
try table.setMasked(0, false);
try msix.setFunctionMask(false);
```

Stop device interrupt generation before teardown:

```zig
try msix.setFunctionMask(true);
try table.setMasked(0, true);
try msix.disable();
```

After successful teardown, drain in-flight handlers, remove the handler, and release
the interrupt vector.

## Configuration registers

### Typed read

```zig
const pci = @import("pci");

const Function = pci.config.Function;

const command = try function.read(Function.offsets.command);
```

### Masked command update

```zig
const pci = @import("pci");

const Command = pci.core.header.Command;

const selected = Command.mask(.{ .mem_enable, .bus_master });
const ordinary = selected & Command.masks.assign;

const observed = Command.raw(try function.command());
const desired = Command.encode(.{ .mem_enable = false, .bus_master = true });

try function.setCommand(Command.from((observed & ~ordinary) | (desired & ordinary)));
```

## Build and test

| Command | Purpose |
| --- | --- |
| `zig build check` | Compile host tests without running them |
| `zig build test-host` | Run host tests |
| `zig build test-<category>` | Run one host category |
| `zig build test-compile` | Check valid and invalid API compile fixtures |
| `zig build test` | Run host tests and compile fixtures |
| `zig fmt --check build.zig build.zig.zon build src test` | Check formatting |

Host categories: `core`, `config`, `header`, `bar`, `capabilities`, `interrupts`,
`memory`, `resources`, `topology`, `testing`, and `integration`.

Tests: `src/` (unit), `test/integration/` (workflows), `test/compile/` (API fixtures).

Host tests require no PCI hardware.
