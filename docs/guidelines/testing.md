# Testing

## Commands

| Command | Scope |
| --- | --- |
| `zig build check` | Compile registered host suites without running them. |
| `zig build test-host` | Run all host suites, including integration tests. |
| `zig build test-<category>` | Run one registered suite. |
| `zig build test-integration` | Run `test/all.zig`. |
| `zig build test-compile` | Check expected rejection of invalid API usage. |
| `zig build test` | Host suites and compile fixtures. |

[Build registration](../../build/testing.zig) owns suite membership. Default tests
need no PCI hardware or external tools. Privileged port I/O is not exercised;
test safe rejection paths and gate hardware-specific execution on prerequisites.

## Sources and layout

| Location | Purpose |
| --- | --- |
| Source-local `pub const unit = struct` | Owning type/module behavior. Namespace roots reference child `unit` blocks for discovery. |
| `test/*.zig`, rooted at `test/all.zig` | Multi-module integration through public APIs. |
| `test/compile/` | Minimal compile-failure contracts. |

- Keep test-only declarations inside the owning `unit`; integration files are
  already test-only. No empty suite roots or synthetic passing coverage tests.
- Within `unit`: imports/aliases, constants, fixture types, tests, then free helpers.
- Group fixture seeding, then separate backend/handle construction. A single
  action and assertion may stay together; space by purpose, not every statement.
- Keep scenario-specific backends, fault injection, and logs local. Share helpers
  only when reused, through `test/support.zig` or `pci.testing`.
- Use descriptive behavior names without mandatory category prefixes.

## Coverage and fixtures

- Test consumer-visible behavior and plausible bugs, not source text, wiring,
  language guarantees, or duplicate declarations. No fixed per-public-type checklist.
- Cover meaningful boundaries, malformed input, termination, and state transitions.
  Check allocation failures where operations own storage.
- Use byte-backed accessors through production APIs. Model hardware behavior where
  needed: BAR sizing masks, W1C, rejected writes, and bridge-controlled reachability.
  Do not mock the library operation being tested or return fake success.
- Assert values, bytes, and failure postconditions. Use access logs when ordering,
  preservation, or rejection before I/O is contractual, not to pin incidental read counts.
- Fault tests distinguish failure before mutation, partial writes, readback failure,
  successful restoration, and failed cleanup where those outcomes apply.
- Check wire encodings with independent byte fixtures. Generated layout/BitField
  checks need no duplicated size assertions; handwritten layouts retain their own checks.
- Compile fixtures protect library-owned constraints. Force analysis and match the
  intended diagnostic, not arbitrary failure or full compiler wording. Valid behavior
  belongs in runtime tests; Zig integer-width rejection needs no fixture.

Golden captures identify their source. Generated fixtures include the regeneration
command and required tools; default correctness tests do not depend on those tools.

## Benchmarks

Keep benchmarks outside default correctness tests. State workload, sizes, allocator
behavior, target, optimization mode, and baseline; performance does not prove correctness.
