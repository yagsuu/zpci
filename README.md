# zpci

`zpci` is a PCI and PCI Express library for Zig.

## Requirements

Zig `0.17.x` and `zstdx`. Configuration access uses caller-mapped ECAM regions
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
| `pci.capabilities` | Capability traversal, typed access, and programming |
| `pci.memory` | BAR-mapped memory access |
| `pci.resources` | Resource assignment, bridge windows, and programming |
| `pci.topology` | Enumeration, bus numbering, traversal, and paths |
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

## Topology configuration

```zig
const pci = @import("pci");

const Root = pci.topology.Root;

const roots = [_]Root{
    .{ .segment = .from(0), .buses = .of(first_bus, last_bus) },
};

// Cold hierarchy; VFs disabled.
const tree = try pci.topology.configure(allocator, .{
    .config = ecam.config(),
    .roots = &roots,
    .ari = .enable_supported,
    .vfs = .advertised, // Reserve bus capacity; leave VFs disabled.
});
defer tree.deinit(allocator);
```

## Resource allocation

- `requirements`: measured BAR or ROM requirements for one endpoint.
- `mmio_base` / `mmio_size`: an available 32-bit memory aperture.

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

### MSI

Interrupt sources quiesced; MSI-X disabled.

```zig
const pci = @import("pci");

const Msi = pci.capabilities.msi.Capability;

const msi = (try Msi.find(function)) orelse return error.NoMsi;

try msi.updateControl(.{ .enable = false });

try msi.program(.{
    .address = 0xFEE0_0000, // x86 local APIC, destination 0.
    .data = vector_data,
    .num_vectors = .one,
});

try msi.updateControl(.{ .enable = true });
```

### MSI-X

Requires quiesced interrupt sources and platform-specific MMIO ordering, barriers,
and completion.

```zig
const pci = @import("pci");

const Msi = pci.capabilities.msi.Capability;
const Msix = pci.capabilities.msix.Capability;
const Table = pci.capabilities.msix.Table;

const msix = (try Msix.find(function)) orelse return error.NoMsix;

if (try Msi.find(function)) |msi| {
    try msi.updateControl(.{ .enable = false });
}

const num_vectors = try msix.numVectors();
const table = Table.from(table_memory, num_vectors);

try msix.updateControl(.{ .enable = true, .function_mask = true });

// Establish Function Mask visibility before table access.
// Keep unused entries masked.
for (0..num_vectors) |index| {
    try table.setMasked(@intCast(index), true);
}

// Establish mask visibility before payload writes.
try table.program(0, .{
    .address = 0xFEE0_0000, // x86 local APIC, destination 0.
    .data = vector_data,
});

// Establish payload visibility before unmasking.
try table.setMasked(0, false);

// Establish entry-mask visibility before clearing Function Mask.
try msix.updateControl(.{ .function_mask = false });
```

Disable MSI-X:

```zig
try msix.updateControl(.{ .function_mask = true });

// Establish Function Mask visibility.
// Synchronize in-flight interrupts before disabling and releasing resources.
try msix.updateControl(.{ .enable = false });
```

## Configuration registers

### Typed read

```zig
const pci = @import("pci");

const Function = pci.config.Function;

const command = try function.read(Function.offsets.command);
```

### Masked update

```zig
const pci = @import("pci");

const Command = pci.core.header.Command;

const command = try function.command();

try function.setCommand(Command.replace(command, .{
    .mem_enable = false,
    .bus_master = true,
}));
```

## Build and test

| Command | Purpose |
| --- | --- |
| `zig build check` | Compile host tests without running them |
| `zig build test-host` | Run host tests |
| `zig build test-<category>` | Run one host category |
| `zig build test-compile` | Check rejection of invalid API usage |
| `zig build test` | Run host tests and compile fixtures |
| `zig fmt --check build.zig build.zig.zon build src test` | Check formatting |

Host categories: `core`, `config`, `header`, `bar`, `capabilities`, `memory`,
`resources`, `topology`, `testing`, and `integration`.

Tests: `src/` (unit), `test/` (integration tests), `test/compile/` (API rejection fixtures).

Host tests require no PCI hardware.
