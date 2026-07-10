# Conventions

Implementation conventions for zpci source and specs. Terse rules; deviations need a reason in review.

These conventions extend `docs/guidelines/zig.md` and `docs/guidelines/spec-writing.md`.

## Authority order

When rules conflict, follow this order:

1. approved domain specs under `docs/specs/<domain>/`;
2. approved aggregator and cross-cutting specs (`docs/specs/index.md`, `docs/specs/architecture.md`) for layering, ownership boundaries, and the public re-export catalog — illustrative type declarations inside them lose to the owning domain spec, which is corrected in place;
3. this conventions document;
4. baseline `docs/guidelines/spec-writing.md`;
5. baseline `docs/guidelines/zig.md`;
6. planning notes under `docs/planning/`, which are never authoritative for landed code.

## Spec ownership

Every public module is owned by one spec under `docs/specs/`.

- Source module headers cite the owning spec path.
- A module without an approved owning spec does not land.
- Planning documents do not define public API contracts.
- Specs define contracts; source implements them.

## Spec writing

Spec ownership, status values, document format, per-operation contract sections,
and spec testing requirements are defined in
`docs/guidelines/spec-writing.md`. New and substantially revised specs under
`docs/specs/` follow that guide.

## Directory ownership

Source directory ownership is defined by `docs/specs/architecture.md`.

- `src/core/` — shared PCI primitives: identifiers (Bdf, SegmentId, Vendor/Device/Class), package errors. No PCI-topology semantics and no wrappers around zstdx generic primitives.
- `src/config/` — the config-space accessor abstraction plus ECAM and PIO-backed implementations. The one place config-space I/O happens.
- `src/header/` — common header plus type-0 (endpoint) and type-1 (bridge) layouts, with colocated layout assertions.
- `src/bar.zig` — BAR decode and the sizing probe.
- `src/capabilities/` — standard and extended capability-list walks, plus selected capability decoders.
- `src/resources/` — PCI resource model, assignment, bridge-window computation, and config-space programming of BAR/window/command state.
- `src/interrupts/` — MSI and MSI-X capability programming. Caller owns vector allocation and platform routing unless an interrupt spec says otherwise.
- `src/topology/` — enumeration, the borrowed device tree, and bridge bus traversal.
- zpci has no `src/arch/`. The x86_64 port-I/O primitive consumed by `config.Pio` is `stdx.arch.x86_64.Port`, owned by zstdx.
- `src/zpci.zig` — the public package facade (`const zpci = @import("zpci");`). Thin: namespace re-exports only.
- `src/<domain>.zig` — public namespace facades following the package-root pattern: import implementation modules from `src/<domain>/` and re-export selected public names.

## File responsibility

Use the baseline ownership rules in `docs/guidelines/zig.md`. zpci split decisions must follow the owning spec and the owned mechanic, not file length.

Allowed zpci split shapes:

- `header/common.zig` plus `header/type0.zig` and `header/type1.zig` because each layout has independent field mechanics.
- `config/accessor.zig`, `config/ecam.zig`, `config/pio.zig`, `config/space.zig` because each backend and the shared function view have distinct contracts.
- `resources/model.zig`, `resources/assignment.zig`, `resources/programming.zig`, `resources/bridge.zig` because assignment and programming are separate phases.

Disallowed zpci split shapes:

- `utils.zig`, `helpers.zig`, `common.zig`, `misc.zig`.
- `manager.zig` unless the spec owns a type named `Manager`.

## Namespace facades

`src/zpci.zig` is the public package facade. Domain facade files such as `src/config.zig`, `src/header.zig`, or `src/capabilities.zig` may re-export the stable public surface for one domain.

Domain facades follow the baseline thin-facade rule in `docs/guidelines/zig.md`. They may:

- import implementation files;
- re-export approved public types, functions, constants, and submodules;
- provide short aliases to declarations owned by implementation files.

Domain facades must not:

- perform validation, allocation, config-space I/O, BAR probes, resource assignment, programming, or enumeration;
- wrap sibling packages (`zstdx`, `std`) with alternative interfaces.

Implementation modules import each other directly when the owning specs allow the dependency; the dependency graph is fixed by `docs/specs/architecture.md`.

## Imports and aliases

Use the baseline import and alias rules in `docs/guidelines/zig.md`.

zpci additions:

- Top-of-file imports and aliases are grouped in this order, one blank line between non-empty groups: `std`/`builtin`; external packages (`zstdx`); local module imports (`const foo = @import("foo.zig");`); module aliases drawn from already-imported namespaces (`const bar = foo.bar;`); type aliases; value constants; function aliases.
- Import names mirror the module's own domain noun. `_mod` and `_module` suffixes are forbidden. If a local symbol collides with the desired import name, rename the local symbol; the import keeps the clean name.
- Prefer a top-level type alias when a file repeatedly uses one type from a module (`const Bdf = bdf.Bdf;`). Keep the module import alongside when several declarations from the same module are referenced.
- Within a group, use dependency order when it improves reading flow; otherwise sort by alias name. Omit any group with no members; do not leave a blank line for an absent group. Do not add comments that merely label these groups.

## Comments

Use the baseline comment and module-header rules in `docs/guidelines/zig.md`.

zpci additions:

- Module-header (`//!`) and exported-item (`///`) doc comments are one short paragraph at most. Lead with the load-bearing fact. No ceremony, marketing language, or emoji.
- Default to no comment. Add a `///` doc comment only when the type signature does not carry what the caller needs: ownership, lifetime, units, invariants, allocation behavior, ordering, error conditions, or why the obvious alternative is wrong.
- Spec links inside comments cite paths under `docs/specs/` only. Planning paths under `docs/planning/` rot and are not cited from source.

## Within-file declaration order

Source files read top-down:

1. module header doc-comment (`//!`);
2. import groups (above);
3. public type, value, and function declarations;
4. private helpers;
5. `test` blocks, after every non-test declaration the file owns.

## Compile-time assertions

`comptime` assertions about a type's size, alignment, field offsets, or packed-bit widths live in a single `comptime { ... }` block at the **end of the type body**, after every field and declaration. One block per type; not interleaved with fields.

```zig
pub const CommonHeader = extern struct {
    vendor_id: u16 align(1),
    device_id: u16 align(1),
    // ...remaining fields...

    pub fn vendor(self: CommonHeader) VendorId { ... }
    // ...remaining declarations...

    comptime {
        std.debug.assert(@sizeOf(CommonHeader) == 0x40);
        std.debug.assert(@offsetOf(CommonHeader, "vendor_id") == 0x00);
        std.debug.assert(@offsetOf(CommonHeader, "device_id") == 0x02);
    }
};
```

File-level `comptime` blocks remain valid for assertions that are not type-owned.

Every config-space `extern struct` and packed flag/bit word carries a colocated `comptime` block asserting `@sizeOf`, `@alignOf`, mandated field offsets, and packed-flag bit widths. Multi-byte config fields are little-endian; raw host layout is never a wire contract without these assertions.

## Public API strictness

zpci public APIs are explicit and PCI-domain-scoped. A public surface lands only under the namespace approved by its owning spec.

- Public APIs do not hide config-space I/O, allocation, blocking, or platform assumptions.
- Views never hold function pointers. The `ConfigSpace` accessor is the one place a public function-pointer / vtable / comptime-interface seam is allowed for config-space I/O.
- Dispatch on header type, capability id, and resource kind is explicit at the call site. No generic device/driver/capability registry or vtable over device types.
- zpci does not parse MCFG or discover ECAM bases. Callers supply `{segment, base, bus_start, bus_end}` descriptors.
- Compatibility aliases after a rename are not left in place; callers update to the new name.

## Naming discipline

zpci names encode PCI role and lifetime.

- `View` — borrowed read-only access over a function's config space or a wire-typed byte slice; never allocates, never holds a function pointer.
- `Function` — one borrowed configuration-space function (`ConfigSpace` + `Sbdf`).
- `Segment` — one caller-supplied ECAM aperture descriptor.
- `Plan` — an owned semantic record produced by `resources/assignment.zig`.
- `Iterator` — lazy traversal returning one element per step (capability lists, extended lists, enumeration).
- Wire-typed aggregates are `extern struct`s with colocated layout assertions; semantic types are Zig-idiomatic enums, tagged unions, and option structs and carry no `extern` discipline.

## API grammar

zpci public names use the baseline Zig naming rules with these package terms:

- namespaces and modules are lower-case domain nouns: `core`, `config`, `header`, `bar`, `capabilities`, `resources`, `interrupts`, `topology`;
- type names and type factories are PascalCase: `Bdf`, `Sbdf`, `SegmentId`, `VendorId`, `CommonHeader`, `Function`, `Ecam`, `Pio`;
- runtime functions and methods are lower camel case: `read8`, `write32`, `vendorId`, `headerKind`, `busRelativeOffset`;
- acronyms are treated as words unless a PCI/PCIe spec fixes the exact spelling: `Bdf`, `Sbdf`, `Msi`, `Msix`, `Ecam`, `Pio`;
- iterators and lazy walks use `walk` or `iterate` and return an iterator value the caller drives with `next()`;
- BAR sizing uses the verb `size` (the save → write all-ones → read back → restore probe);
- reserved constructor vocabulary for the deferred config-writer phase: `Builder.init`, `wrap`, `seal`. Not used in read scope.

## Constructors

zpci constructor vocabulary is closed. Pick the verb by argument shape, I/O, and fallibility:

- `Type.of(comptime …)` — comptime-only literal constructor. Rejects out-of-range inputs with a compile error via argument typing (`u5`, `u3`, `u12`) or explicit `@compileError`. Used by identifier newtypes and `Bdf`/`Sbdf`.
- `Type.init(...)` — pure assembly from already-validated inputs. Returns `Type` directly, never `Error!Type`. Performs no I/O and no fallible input validation. Used by borrowed handles that only assemble a struct literal (`bar.View.init`, `header.common.View.init`, `ConfigSpace.init`).
- `Type.from(…)` — runtime constructor that may fail on input shape only. May be infallible (`VendorId.from`) or fallible (`Bdf.from` → `error.InvalidIdentifier`, `ClassCode.from`, `Ecam.from`, `capabilities.list.Cursor.from`). A fallible `from` performs no I/O; failures are decided by inspecting the argument bytes. Returns a subset of `zpci.Error` or a type-local error set.
- `Type.validate(inputs)` — fallible constructor that performs I/O against hardware (or reads wire bytes from a caller-supplied buffer) to decide whether the value is well-formed. Returns `Error!Type`. Used by `Function.validate`, `capabilities.list.Iterator.validate`, `capabilities.extended.Iterator.validate`, `capabilities.pcie.View.validate`, and every read path that decodes wire bytes before construction.
- `Type.unchecked(...)` — bypasses `validate` for responder-side / test / caller-known-good paths. Returns `Type` directly. Every type that owns a `validate` may also own an `unchecked` when the bypass has a legitimate consumer (`Function.unchecked`).
- `Builder.init` / `wrap` / `seal` — reserved for the deferred config-writer phase. Not used in read scope.
- `deinit` — releases resources owned by the value. zpci's read/decode/sizing/assignment/programming paths are non-allocating; `deinit` is reserved for the owned semantic records that later specs promote.

Rules:

- `init` never returns `Error!Self`. A constructor that can fail is `from` (no I/O) or `validate` (I/O).
- `from` never performs I/O. If a constructor must peek at hardware or a wire buffer to decide validity, it is `validate`.
- `intoScratch(buf, ...)` — writes into a caller-supplied slice and returns a borrowed view of the filled prefix. Failure is `StorageExhausted` decided by an upfront `buf.len >= required` check; scratch is unmodified on failure. Assignment plans, topology trees, and any future collection producing `[]const T` results follow this pattern. An allocator-backed sibling constructor is added only when a real consumer needs it; a `FixedBufferAllocator` adapter is not a substitute because it changes the lifetime, cost, and error models.

## Error vocabulary

zpci uses one canonical name per error condition. The union of top-level public error categories is defined by `docs/specs/core/errors.md` as `zpci.Error`. Reuse those names across specs; do not invent near-duplicates.

Rules:

- Error variant names describe the violated invariant, not the failing operation.
- Type-local error sets stay narrow and are subsets of `zpci.Error` plus, where allowed, `std.mem.Allocator.Error`.
- Primitive errors from zstdx byte/range helpers and zpci identifier parsing are mapped into the owning module's domain error before crossing a public boundary; raw primitive errors are not part of any public domain surface.
- Public APIs do not expose `anyerror`. Orchestration that fans across domains unions the type-local sets explicitly.

## Error placement

- Free functions in a module → module-level `pub const Error = error{...}`.
- Types with state or methods → nested `pub const Error = error{...}` inside the type.
- The package error set `zpci.Error` lives at `src/core/errors.zig` and is re-exported through `src/core.zig` and `src/zpci.zig`.
- Facades do not synthesize error unions. A caller writes `zpci.config.ConfigSpace.Error` or `zpci.core.Error`, never `zpci.Error` for a per-operation type-local set.

Per-operation error sets may narrow the type-level union when a method can only produce a subset of variants. The type-level `Error` remains a documentary union over every variant the type can return.

## Validation vs assertion

- Public validation rejects malformed hardware/input bytes with typed errors; it does not assert on them.
- Assertions are for programmer errors after typed validation succeeded (e.g. reading a type-1 field through a type-0 view, or an offset past the validated window).
- Baseline assertion density (see `docs/guidelines/zig.md` §Assertions and invariants) applies to every non-trivial zpci function.

## Config-space access and programming discipline

- All config-space reads and writes go through a `ConfigSpace` accessor (`docs/specs/config/accessor.md`). ECAM- and PIO-backed implementations own the only config-space I/O in zpci.
- Every decode, sizing, capability-walk, traversal, resource-assignment, and interrupt-programming routine is pure over explicit accessors and caller-provided resource/vector inputs. This keeps logic host-testable against real byte-backed fakes (see `docs/guidelines/testing.md`).
- Offsets are validated against the 4 KiB function window before every read or write.
- An absent function (vendor id `0xFFFF`) is "not present", never an error.
- Capability and extended-capability walks are bounded and must terminate on a cycle or out-of-range next-pointer rather than loop.
- BAR sizing always restores the saved value.
- Resource programming is explicit and belongs under `src/resources/`: BAR bases, bridge windows, command-register enables, and bridge-control writes are not hidden inside enumeration.
- MSI/MSI-X programming is explicit and belongs under `src/interrupts/`: zpci programs device-visible capability/table state from caller-supplied routing inputs; it does not allocate platform interrupt vectors.

## Runtime contracts

zpci specs use the baseline public-contract checklist in `docs/guidelines/zig.md`.

Every non-trivial public API states its allocation, blocking/waiting, capacity, execution-bound, invalidation, concurrency, and ordering behavior. Reads and writes state which validation phase they assume completed and which error variants they can produce.

## No generated source

`src/` is handwritten. Config-space structs are transcribed into explicit Zig types with colocated assertions. Generated artifacts are limited to fixtures or manifests outside `src/` and carry a documented regeneration command.

## Domain scope

zpci owns PCI/PCIe configuration-space access, decode, sizing, capability traversal, resource assignment/programming, MSI/MSI-X programming, and bridge/bus traversal. It does not own domain systems outside PCI.

Allowed examples:

- ECAM- and PIO-backed config-space access;
- BAR decode and the sizing probe;
- capability-list traversal and selected capability decoders;
- resource assignment and programming;
- MSI and MSI-X capability/table programming.

Disallowed examples:

- ACPI MCFG parsing;
- platform-description parsing;
- interrupt-vector allocation and interrupt-controller routing;
- device-driver binding or protocol publication;
- VFIO passthrough policy or config-shadowing;
- SR-IOV virtual-function lifecycle;
- non-x86_64 architecture-specific behavior in the initial library.

## Implementation order per module

Each module lands in this order:

1. owning spec exists and is approved;
2. public type skeletons plus compile-time layout assertions;
3. unit tests for contracts and malformed inputs;
4. implementation;
5. traversal, round-trip, and integration tests where the spec requires them.

A module without its owning approved spec does not land.
