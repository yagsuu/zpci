# Testing

Test requirements for zpci implementation work.

## Required commands

- `zig build test` runs the default host suite.
- No target-specific check is required for decode, sizing, traversal, resource-programming, or interrupt-programming logic — each is pure over explicit accessors and caller-provided inputs.
- Architecture-specific tests (currently limited to the `config.Pio` path over `stdx.arch.x86_64.Port`) are gated by target checks.
- External tools are not required by the default test command.

## Test locations

- In-source `test` blocks cover local pure logic.
- `test/` contains multi-module, fixture-driven, traversal, and integration-style tests.
- Benchmarks live outside the default correctness test path unless a spec says otherwise.

## Test naming

Use category prefixes:

```zig
test "unit: bdf encodes ecam offset" { ... }
test "layout: type0 header offsets" { ... }
test "malformed: capability pointer cycle terminates" { ... }
test "sizing: 64-bit memory bar reports 256 MiB" { ... }
test "topology: bridge subordinate bus bounds the walk" { ... }
test "programming: commit rolls back on read-back mismatch" { ... }
```

## Required per-public-type test set

Each implemented public type must include tests for:

- successful construction and validation over the smallest valid input;
- non-trivial input covering the field set the type owns;
- every public error variant the type can produce;
- boundary offsets, lengths, and bus ranges the type exposes;
- save/restore correctness for the BAR sizing probe (config bytes restored to their pre-probe value);
- traversal termination for every variable-length walk (capability list, extended list, bus range);
- decoded round-trip (encode → write → read → decode) for every wire-typed programming helper.

## Allocation contract tests

Allocation behavior is part of the public contract.

Required checks:

- read, decode, sizing, capability traversal, assignment planning, and programming paths do not allocate;
- APIs that explicitly allocate consume the caller-supplied allocator and surface `std.mem.Allocator.Error` at the point of allocation;
- caller-supplied scratch slices are the sole storage for enumeration and traversal iterators.

## The fake accessor (not a mock)

Host tests construct real byte-backed fakes for `ConfigSpace` and any BAR-table memory accessor required by MSI-X: `[]u8` buffers holding actual config-space or table bytes laid out per the headers under test. Tests read/probe/program through those fakes exactly as production reads through `Ecam` or PIO-backed config access. These are real buffers, not behavioral mocks. The hardware I/O adapters themselves stay trivial and are the only lines not exercised by host tests.

## Malformed input

Malformed-input tests must cover, at minimum:

- short function window;
- capability pointer out of bounds;
- capability list cycle (must terminate, not loop);
- extended-cap next-pointer out of `0x100..0xFFF`;
- bridge subordinate < secondary;
- absent function (vendor id `0xFFFF`) treated as not-present;
- reserved bits where the owning spec validates them.

## Layout and byte tests

Layout and binary helpers must cover:

- endian round trips at the config-space and BAR-memory boundaries;
- unaligned loads/stores at every supported access width;
- offset overflow and truncation at the function-window edge;
- packed-field masks, shifts, and bit-width invariants for `Bdf`, `Sbdf`, and command/status registers;
- compile-time size, alignment, and bit-size assertions colocated with every wire-typed `extern struct` or packed word.

## Ordering and concurrency tests

zpci does not own concurrent primitives. Ordering appears only through the `ConfigSpace` and `BarMemory` accessors and through resource programming write order. Tests must:

- exercise the deterministic programming write order (BARs → bridge windows → command bits) prescribed by `docs/specs/resources/programming.md`;
- assert readback semantics after every write whose spec requires it;
- gate any x86_64 PIO tests behind target checks.

## Fixtures

Golden fixtures are real captured config-space dumps or zpci-emitted bytes, checked in. Generated fixtures document source input, generator command, expected output path, and any external tool. Default `zig build test` requires no external tool.

## No mocks

Tests use real byte buffers via fake accessors. Tests do not mock accessor behavior, header views, sizing logic, resource assignment, or interrupt programming. Real-hardware enumeration belongs to downstream integration tests, not zpci's host suite.

## Benchmark discipline

Benchmarks are evidence for optimization, not correctness gates. A benchmark must state its workload, input sizes, allocator behavior, target, optimization mode, and comparison baseline. A clever implementation is not accepted solely because it benchmarks well on one workload.
