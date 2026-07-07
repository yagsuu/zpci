# Open questions

Unresolved questions pulled out of specs so specs stay normative. Resolved items move into the owning spec.

## Resolved at kickoff
- Config access model: zpci owns a `ConfigSpace` accessor + ECAM impl; caller injects the base.
- Topology input: caller supplies `{segment, base, bus_start, bus_end}` descriptors; zpci does not parse MCFG.
- Scope includes read/enumerate/compute plus broad PCI resource assignment/programming.
- BAR sizing uses the write-probe-restore sequence.
- MSI and MSI-X programming are in scope.
- PIO config-space reads are in scope.
- Import name: `zpci` (`const zpci = @import("zpci");`).
- Zig version: 0.16.

## docs/specs/bar.md
- Behavior when a BAR is unimplemented (reads 0) vs implemented-but-zero-size.
- Whether BAR sizing is allowed on already-enabled devices without first disabling memory/IO decode.


## docs/specs/header/common.md
- Which reserved/`status` bits zpci validates vs passes through.
- Command-register decode and programming policy: IO space, memory space, bus mastering, interrupt disable, SERR, parity response.
