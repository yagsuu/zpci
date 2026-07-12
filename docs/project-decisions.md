# Spec status and approval rules

## Purpose

This repository separates approved requirements from draft proposals. The `docs/specs/index.md` catalog and `docs/specs/architecture.md` layering are planning input for domains that have not yet approved a spec; individual domain specs under `docs/specs/<domain>/` become the fixed implementation contract only after they are drafted with the user and approved.

## Status labels

Use these labels in specs and planning documents:

- **Approved**: accepted project fact or decision.
- **Draft proposal**: candidate design for review; do not implement as fixed contract yet.
- **Open question**: unresolved information; implementation must not guess.
- **Deferred**: intentionally out of the current target.

## Approved facts so far

### Project

- The package name is `zpci`. The public import name is `pci` (`const pci = @import("pci");`).
- `zpci` is a Zig 0.16 PCI/PCIe configuration-space and resource-programming library.
- `zpci` owns config-space access through explicit accessors, ECAM- and PIO-backed configuration access, device/function enumeration, BAR decoding and sizing, capability traversal, PCI resource assignment/programming, MSI/MSI-X programming, and bridge/bus traversal.
- `zpci` does not own ACPI MCFG parsing, platform-description parsing, firmware phase orchestration, driver binding, interrupt-vector allocation, interrupt-controller routing, interrupt remapping policy, PCI device reset policy, SR-IOV virtual-function lifecycle, or VFIO passthrough policy.
- `zpci` depends on Zig `std` and `zstdx`. Downstream domain consumers such as `zfw` and `zacpi` consume the same `pci` module under their own target configuration.

### Design constraints

- Public APIs must not hide config-space I/O.
- All config-space reads and writes go through a `ConfigSpace` accessor. ECAM- and PIO-backed implementations are the only lines that touch real config MMIO or PIO.
- Every decode, sizing, capability-walk, traversal, resource-assignment, and interrupt-programming routine is pure over explicit accessors and caller-provided resource/vector inputs.
- Read, decode, sizing, capability traversal, assignment planning, and programming paths are non-allocating; caller scratch or allocator-taking constructors are used explicitly where storage is required.
- Assignment and programming are separate phases: assignment is pure, programming is the explicit commit step with deterministic write order.
- MSI-X table access is not config-space access; it goes through a caller-supplied `BarMemory` accessor distinct from `ConfigSpace`.
- Views never hold function pointers.
- No object system: no vtable over device types, no driver-binding dispatcher, no generic capability-handler registry.
- Debug invariant checks and tests are part of the primitive contract; assertion density follows `docs/guidelines/zig.md` §Assertions and invariants.

### Approved API direction

- `SegmentId`, `Bdf`, and `Sbdf` are `packed struct` newtypes over their PCI/PCIe-mandated integer widths.
- `Bdf` bit layout is LSB-first: `function: u3`, `device: u5`, `bus: u8`, matching the PCIe Requester ID encoding.
- `Sbdf` bit layout is LSB-first: `bdf: Bdf` in bits `0..16`, `segment: SegmentId` in bits `16..32`, matching the IOMMU source-id form used by Intel VT-d, AMD-Vi, and the Linux PCI subsystem.
- Constructor vocabulary is closed:
  - `Type.of(comptime …)` is comptime-only, rejecting out-of-range inputs via argument typing or `@compileError`;
  - `Type.from(…)` is runtime, infallible when the input domain is total and fallible when validation is required;
  - `Type.validate(inputs)` decodes wire bytes and returns a fully-typed value or a typed error;
  - `Builder.init` / `wrap` / `seal` are reserved for the deferred config-writer phase and are not used in read scope.
- The package error set `pci.core.Error` is a stable union of top-level public error categories used by more than one domain, defined by `docs/specs/core/errors.md`. Type-local error sets stay narrow and are subsets of `pci.core.Error` plus, where allowed, `std.mem.Allocator.Error`. `pci.core.Error` does not fold in `std.mem.Allocator.Error`.
- `zpci` has no `src/arch/`. The x86_64 port-I/O primitive consumed by `config.Pio` is `stdx.arch.x86_64.Port`, owned by zstdx.
- The initial library targets little-endian hosts. Config-space `extern struct`s use native integer fields under the LE-host assumption; a big-endian host would require revisiting wire-struct fields and endian conversion at the accessor boundary and is deferred until a concrete BE-host consumer exists.

### Docs flow

- A module without its owning approved spec does not land.
- Each spec is drafted with the user one by one before it is written under `docs/specs/`.
- Implementation work begins only after the required specs for that implementation slice are approved and written.
- `docs/specs/index.md` and `docs/specs/architecture.md` are cross-cutting: type declarations and signatures inside them are illustrative and lose to the owning domain spec.

## Not approved yet

The following are not approved implementation contracts until the owning per-domain spec is approved:

- exact per-domain source files beyond the architecture tree approved in `docs/specs/architecture.md`;
- exact method signatures beyond the vocabulary and constructor discipline in `docs/guidelines/conventions.md` and the identifier signatures approved in `docs/specs/core/ids.md` and `docs/specs/core/bdf.md`;
- exact PCIe capability decode surface beyond capability-list traversal (`docs/specs/capabilities/list.md`, `docs/specs/capabilities/extended.md`);
- exact resource model, assignment algorithm, programming write order, and bridge-window encoding;
- exact MSI and MSI-X programming boundaries with caller routing inputs;
- exact enumeration, tree, and bridge-traversal shapes;
- exact examples under `docs/specs/examples/`.

Track each open question against the owning spec in `docs/planning/open-questions.md`.

## Rule for API sketches

Code blocks in planning documents are illustrative unless the section is explicitly labeled **Approved API**. Illustrative code may be used to discuss shape and usage, but implementation must not treat it as a stable ABI or source contract.

## Draft content placement rule

API, architecture, type, and usage proposals live in the spec for the subsystem that owns them. Cross-cutting documents (`docs/specs/index.md`, `docs/specs/architecture.md`) may link to subsystem specs, but must not become the source of truth for API or type contracts. Where a cross-cutting document disagrees with the owning domain spec, the domain spec wins and the cross-cutting document is corrected in place.

## Rule for unresolved details

If a detail is needed for implementation but appears only as an open question, implementation must stop at the boundary and either:

1. update the spec with an approved decision; or
2. isolate a temporary experiment behind a clearly named unstable interface.

Temporary experimental interfaces must not be presented as final public API.
