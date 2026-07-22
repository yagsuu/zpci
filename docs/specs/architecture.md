# Architecture

Layering and ownership rules for zpci modules. This document and `docs/specs/index.md` define cross-cutting structure — layering, type-world separation, validation phases, and the public re-export catalog. Type declarations shown here are illustrative; the owning domain spec under `docs/specs/<domain>/` wins on disagreement.

Markers: `[std]` = PCI / PCI Express mandated; `[zpci]` = zpci design choice.

Related specs:

- `docs/specs/index.md`
- `docs/specs/config/accessor.md`
- `docs/specs/config/space.md`
- `docs/specs/config/ecam.md`
- `docs/specs/config/pio.md`
- `docs/specs/header/common.md`
- `docs/specs/header/type0.md`
- `docs/specs/header/type1.md`
- `docs/specs/interrupts/pin.md`
- `docs/specs/bar.md`
- `docs/specs/memory/bar.md`
- `docs/specs/capabilities/list.md`
- `docs/specs/capabilities/extended.md`
- `docs/specs/capabilities/pcie.md`
- `docs/specs/resources/model.md`
- `docs/specs/resources/assignment.md`
- `docs/specs/resources/programming.md`
- `docs/specs/resources/bridge.md`
- `docs/specs/resources/bus.md`
- `docs/specs/interrupts/msi.md`
- `docs/specs/interrupts/msix.md`
- `docs/specs/topology/enumerate.md`
- `docs/specs/topology/tree.md`
- `docs/specs/topology/bridge.md`

## Layering

```text
caller
  -> Segment[]                            (ECAM apertures, caller-supplied)
  -> HostBridgeApertures                   (IO/MMIO32/MMIO64 pools, caller-supplied)
  -> InterruptRouting                     (MSI/MSI-X message + vector identity)
  -> ConfigSpace                          (caller-constructed: Ecam | Pio | testing.config.TestConfigSpace)
  -> BarMemory                            (caller-supplied accessor for MSI-X table/PBA)

reader (per function)
  ConfigSpace + Sbdf
    -> config.Function.validate           (presence + header type)
       |- zstdx.core.Range / zstdx.bytes (offset containment)
       `- core/ids   (vendor/device/class decode)
    -> header.{common, type0, type1}.View (typed field access)
    -> bar.Iterator                       (decode + sizing probe; restores writes)
    -> capabilities.{list, extended}.Iterator
    -> capabilities.pcie.View             (programming-policy facts)

planner (whole tree)
  []Segment + ConfigSpace
    -> topology.enumerate                 (presence, multifunction, bridge recursion)
    -> topology.tree                      (parent/child borrowed view)
    -> resources.model.Requirement[]      (per-function BAR + bridge-window needs)
    -> resources.assignment.plan          (allocation over HostBridgeApertures; no writes)
    -> resources.bridge.encodeWindow      (limit/base values, disabled encodings)

programmer (commit step)
  Plan + ConfigSpace
    -> resources.programming.commit       (deterministic order; rollback on fail)
    -> interrupts.msi.enable              (caller-supplied routing)
    -> interrupts.msix.programEntry +
       interrupts.msix.enable             (table via caller BarMemory)
```

## Layer responsibilities

```text
core/          identifier newtypes, BDF/SBDF math, package error set.
               No PCI semantics beyond identifier shape.
config/        ConfigSpace contract, Ecam, Pio, Function view.
               The only modules that perform config-space I/O.
header/        Common, type-0, and type-1 wire layouts + ABI assertions +
               typed accessors + programming helpers.
bar            BAR decode and the sizing probe (the only writes a reader emits).
memory/        BarMemory accessor for BAR-mapped memory reads and writes,
               owned by MSI-X table/PBA programming. Semantic-free storage
               abstraction; the only module that performs BAR-memory I/O.
capabilities/  Standard list traversal, extended list traversal, PCIe capability
               decode required by enumeration/programming policy.
resources/     Resource model, assignment planner, bridge-window encoding,
               programming committer.
interrupts/    INTx pin decode plus MSI and MSI-X capability/table programming.
topology/      Enumeration, borrowed device tree, bridge traversal.
               zpci has no architecture-specific source in the initial library;
               x86_64 port I/O is consumed from zstdx.
testing/      Reusable host-test fixtures and byte-backed accessors.
               Imports production domains; production domains never import it.
pci.zig +     Public package facade plus namespace facades. Re-exports only;
src/<dom>.zig  no behavior.
```

## Ownership rules `[zpci]`

1. **`config/` owns config-space I/O.** No header, BAR, capability, topology, resource, or interrupt module performs config MMIO or PIO directly. They take a `ConfigSpace` and an `Sbdf`.
2. **`ConfigSpace` is the only public function-pointer / vtable / comptime-interface seam.** Views never hold function pointers; they hold a `ConfigSpace` value plus a borrowed slice or `Sbdf`.
3. **`Ecam` does not discover its own base.** Callers supply `Segment{ .segment, .base, .bus_start, .bus_end }` descriptors. `Pio` does not own raw inline assembly; it consumes `stdx.arch.x86_64.Port` from zstdx.
4. **Header modules own their wire layout.** A header's `extern struct`, packed flag words, ABI assertions, and register-level programming helpers all live in header modules. `core/` carries no header semantics.
5. **No cross-table imports between header modules.** `header/common.zig` is shared. `header/type0.zig` and `header/type1.zig` never import each other; type dispatch lives at the `config/space.zig` boundary.
6. **`core/` is PCI-semantic-free.** `core/bdf.zig` knows BDF math, not which header type carries which field. `core/ids.zig` knows integer newtypes, not which capability advertises which id. Generic range and byte-containment primitives live in zstdx, not zpci core.
7. **`bar.zig` owns the only writes a reader emits.** BAR sizing saves, writes all-ones, reads back, and restores the original value. Decode-disable around the probe, if required by `docs/specs/bar.md`, is also bar-owned. No module outside `bar.zig` performs BAR-related writes during read scope.
8. **Capability modules walk and decode; they do not dispatch.** No registry, vtable, or generic capability-handler map. Callers switch on capability id at the call site.
9. **`resources/` is the only path for resource writes.** Assignment and programming are separate phases: assignment is pure (caller storage in, plan out, no I/O); programming is the explicit commit step with deterministic order and rollback per the programming spec.
10. **`interrupts/` owns interrupt decoding/programming.** `interrupts/pin.zig` owns INTx pin byte decode and is pure. MSI/MSI-X routing inputs (message address/data, vector identity) cross the module boundary as zpci-owned plain values supplied by the caller. zpci does not allocate platform vectors and does not consult APIC/IOAPIC/IR/firmware/OS facilities.
11. **MSI-X table access is not config-space access.** MSI-X table and PBA writes go through a caller-supplied `BarMemory` accessor owned by `docs/specs/memory/bar.md`. `BarMemory` is a distinct I/O seam from `ConfigSpace`.
12. **`topology/` does not program.** Enumeration and traversal never write BAR bases, bridge windows, command-register enables, MSI, MSI-X, or bus-number registers in their read-only modes. Bridge bus-number programming, if owned by the assignment spec, belongs under `resources/programming.zig`.
13. **No view holds a function pointer.** Borrowed-slice views (`header.*.View`, capability views, BAR refs) carry only the `ConfigSpace` value, an `Sbdf`, and zero or more byte slices.
14. **No zpci architecture module.** zpci has no `src/arch/`. The x86_64 port-I/O primitives consumed by `config.Pio` are owned by `zstdx`, not pci.
15. **Facades have no behavior.** `src/pci.zig` and the `src/<domain>.zig` namespace facades only re-export. Adding validation, allocation, dispatch, or I/O to a facade is a layering violation.

## Dependency direction

```text
pci.zig
   |
   v
namespace facades (config.zig, header.zig, bar.zig, capabilities.zig,
                   memory.zig, resources.zig, interrupts.zig, topology.zig,
                   testing.zig)
   |
   v
top-level implementation modules
   |
   v
domain implementation modules (config/*.zig, header/*.zig, ...)
   |
   v
core/                                  (leaf)
```

Rules:

- Any implementation module may import `zstdx` for domain-neutral primitives approved by the owning zpci spec; facades may re-export only zpci-owned names.
- `core/` and `memory/` are the zpci leaves. Each imports only `std`, `builtin`, and approved `zstdx` namespaces; neither imports sibling zpci domains.
- `config/` imports `core/` and `zstdx` (including `stdx.arch.x86_64.Port` from `config/pio.zig`). It is the only non-leaf with config-space I/O.
- `header/`, `bar`, and `capabilities/` import `core/` and `config/`. Header modules may import only the pure leaf `interrupts/pin.zig` from `interrupts/`; they never import MSI/MSI-X programming modules.
- `resources/` imports `core/`, `config/`, `header/`, and `bar`. It does not import `interrupts/`, `topology/`, or `memory/`.
- `interrupts/pin.zig` imports only `std`. Other `interrupts/` modules import `core/`, `config/`, `header/`, `capabilities/`, and `memory/`. `interrupts/` does not import `resources/` or `topology/`.
- `topology/` imports `core/`, `config/`, and `header/`. It does not import `bar`, `capabilities/`, `resources/`, `memory/`, or `interrupts/`; callers compose those modules with topology nodes themselves.
- `testing/` imports production modules such as `core/`, `config/`, and `memory/` as needed. Production modules do not import `testing/`.
- Unlisted lower-to-higher imports are forbidden. The only approved exception is header views importing the pure `interrupts/pin.zig` decoder.
- Cycles are forbidden. A new import that would close a cycle requires moving the shared concept down into `core/` (semantic-free) or up into the caller.

## Two type worlds

zpci distinguishes wire types from semantic types and never mixes them in one type.

- **Wire types** `[std]` — `extern struct`, packed flag words, fixed offsets, `zstdx.layout.Le(T)`/`Be(T)` for endian integer lanes or byte-sized fields where no endian wrapper is needed. Layout asserted in a `comptime { ... }` block at the end of the type body per `docs/guidelines/conventions.md` §Compile-time assertions. Examples: header common/type-0/type-1 bodies, BAR raw value, capability list headers, MSI/MSI-X capability bodies, MSI-X table entry.
- **Semantic types** `[zpci]` — Zig-idiomatic enums, tagged unions, option structs, iterators, resource and assignment records, routing inputs. No `extern struct` discipline. Produce or consume wire types at the boundary; they do not embed wire bytes.

Crossing the boundary:

- **Reads** decode wire types into semantic types (e.g. `header.type0.View.bar(i)` returns a `bar.Kind` union, not the raw `u32`).
- **Writes** encode semantic types into wire bytes inside the owning module (`resources/programming.zig`, `interrupts/msi.zig`, `interrupts/msix.zig`).
- A semantic type never carries a raw wire pointer past the module that produced it. Inter-module hand-offs use decoded semantic records.

## Borrowing and lifetime

- **Views** borrow from `ConfigSpace` plus an `Sbdf` (or, for MSI-X table entries, from a `BarMemory` plus an entry index). They are valid while the underlying accessor is valid and the device is not removed from under the caller.
- **Iterators** carry the same borrow plus walk state. They never allocate; storage limits are caller-provided or fixed by the iterator type.
- **Trees** built by `topology/` borrow the `ConfigSpace`. Nodes do not own decoded snapshots unless `docs/specs/topology/tree.md` later promotes a caching mode.
- **Assignment plans** are owned, semantic-type records. They do not borrow from hardware and are valid past the lifetime of the topology tree that produced them, provided the caller treats hardware state as unchanged in between.

## I/O surfaces

zpci has exactly three I/O surfaces. Every other module is pure over these.

1. **`ConfigSpace`** — config-space reads (`read8`/`read16`/`read32`) and writes (`write8`/`write16`/`write32`) at an `(Sbdf, offset)` location inside the 4 KiB function window. Implementations: `Ecam`, `Pio`, `testing.config.TestConfigSpace`, and caller-owned responder backends.
2. **`BarMemory`** — explicit caller-provided BAR memory accessor for reads and writes of BAR-mapped memory (MSI-X table, PBA). Owned by `docs/specs/memory/bar.md`. Distinct from `ConfigSpace`. zpci never maps, infers, or owns BAR memory.
3. **`stdx.arch.x86_64.Port`** — zstdx-owned x86_64 port-I/O primitive consumed by `config.Pio`. zpci does not own a port-I/O type, does not allocate ports, and does not provide a serialization wrapper. Callers go through `Pio` for config-space access; the underlying `Port` methods are not part of the zpci public surface.

Anything else — APIC/IOAPIC writes, interrupt remapping, ACPI table parsing, MCFG discovery, page-table mapping, device reset — is outside zpci and not hidden inside it.

## Host endianness

zpci's initial library targets little-endian hosts (x86_64, aarch64 little-endian, riscv64 little-endian).

Rules:

- PCI configuration space and BAR memory are little-endian on the wire.
- Reads from `ConfigSpace` and `BarMemory` return native integer values.
- Wire types defined as `extern struct` use native integer fields under the LE-host assumption; no `zstdx.layout.Le(uN)` wrapper is required around them.
- Big-endian host support is deferred; if promoted, wire-struct fields and accessor boundaries revisit endianness.
- Byte-backed test accessors may still use `zstdx.bytes.load(zstdx.layout.Le(uN), ...)` for byte-stable safety, but it is not required.

## Validation phases

Validation runs in fixed phases. Each phase has one owner and a documented error set; later phases assume earlier phases succeeded.

1. **Input shape** — segment descriptors, BDF/SBDF ranges, config offsets, access widths, root resource windows, and interrupt programming requests. Owners: `core/bdf`, `config/space`, `resources/model`, `interrupts/{msi,msix}`. zstdx primitives may implement generic range and byte checks, but they do not own PCI validation policy.
2. **Function presence** — vendor id `0xFFFF` means absent; absence is reported, never an error. Owner: `config/space`.
3. **Header decode** — common header fields, header type, type-specific layout access. Owners: `header/common`, `header/type0`, `header/type1`.
4. **BAR decode/sizing** — BAR kind, width, implemented state, save/probe/restore correctness, decode-disable handling. Owner: `bar`.
5. **Capability traversal** — pointer range, alignment where required, malformed next-pointer, cycle termination. Owners: `capabilities/list`, `capabilities/extended`. Per-capability decode is owned by the capability module (`capabilities/pcie`, `interrupts/msi`, `interrupts/msix`).
6. **Topology traversal** — bus-range containment, bridge path traversal, storage exhaustion, multifunction policy. Owners: `topology/enumerate`, `topology/bridge`.
7. **Resource assignment** — requirement validity, pool containment, alignment, bridge-window encodability, exhaustion. Owner: `resources/assignment`.
8. **Resource programming** — deterministic write order, failed-write handling, rollback or preserved-state behavior. Owner: `resources/programming`.
9. **Interrupt programming** — MSI/MSI-X capability validity, caller-supplied routing input validity, table bounds, masking/enabling order. Owners: `interrupts/msi`, `interrupts/msix`.

Public validation returns typed errors. It does not assert on malformed hardware/input bytes. Assertions document programmer errors after the relevant phase has succeeded — for example, reading a type-1 field through a type-0 view, or indexing past a validated bound.

Primitive failures from zstdx (`bytes.EndOfStream`, `core.Range` errors) and zpci core identifiers map into the owning module's domain error at the module boundary; raw primitive errors do not surface in public APIs.

## No object system `[zpci]`

zpci does not define a generic device, capability, BAR, or resource registry; no vtable over device types; no driver-binding dispatcher; no plug-in extension point.

Dispatch is explicit at the call site:

- header type via `header.common.View.headerType()` followed by `header.type0.View` or `header.type1.View`,
- capability id via the iterator's `cap.id()` switch,
- BAR kind via the `bar.Kind` union,
- resource kind via the `resources.model` union.

Shared mechanics live in `core/` (semantic-free), in the per-domain facade for re-export, or in a narrow helper named for its concept.

## Host-testability `[zpci]`

Every module in zpci builds and tests under `zig build test` on the host.

- Decode, sizing, traversal, capability walking, assignment, programming, and interrupt programming are all pure over `ConfigSpace` and (for MSI-X) `BarMemory`. The byte-backed test accessors under `pci.testing` implement the same contract as `Ecam`, `Pio`, and the BAR-memory accessor.
- `Ecam`, `Pio`, and the `stdx.arch.x86_64` primitives consumed by `Pio` keep their hardware-touching surface trivial. They are the only lines not exercised by host tests; their hardware paths are gated and stubbed off-target so the surrounding modules compile and run host-side.
- No mocks. Host tests use real byte buffers.

See `docs/guidelines/testing.md` for the full test policy.

## Non-goals

- Driver binding, device-driver dispatch, protocol publication, OS handoff, or device-path construction.
- ACPI MCFG parsing or platform-description parsing.
- Platform resource discovery beyond what callers hand in.
- Platform interrupt-vector allocation or interrupt-controller routing.
- Interrupt remapping policy.
- PCI device reset policy.
- SR-IOV virtual-function lifecycle and resource policy.
- VFIO passthrough policy or config-shadowing.
- Non-x86_64 architecture-specific behavior in the initial library.
- Advanced PCIe services beyond capabilities explicitly specced under this package.
